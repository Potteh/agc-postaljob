local QBCore = exports['qb-core']:GetCoreObject()

local onDuty = false
local routeVehicle = nil
local routeVehicleNetId = nil

local routeRequestPending = false
local returnRequestPending = false

local function debugPrint(message)
    if Config.Debug then
        print(('[acg_postal] %s'):format(message))
    end
end

local function drawText3D(coords, text)
    local visible, screenX, screenY = World3dToScreen2d(coords.x, coords.y, coords.z)

    if not visible then
        return
    end

    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(255, 255, 255, 215)
    SetTextCentre(true)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(screenX, screenY)

    local width = (string.len(text) + 2) / 370
    DrawRect(screenX, screenY + 0.0125, width, 0.03, 0, 0, 0, 110)
end

local function isVehicleSpawnClear()
    local spawn = Config.VehicleSpawn
    return not IsAnyVehicleNearPoint(spawn.x, spawn.y, spawn.z, Config.VehicleSpawnClearance)
end

local function SetPostalVehicleFuel(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        debugPrint('ERROR: Postal vehicle fuel initialization skipped because the entity does not exist')
        return false
    end

    if GetResourceState('qb-fuel') ~= 'started' then
        debugPrint('ERROR: Postal vehicle fuel initialization failed because qb-fuel is not started')
        return false
    end

    local success, errorMessage = pcall(function()
        exports['qb-fuel']:SetFuel(vehicle, 100.0)
    end)

    if not success then
        debugPrint(('ERROR: Postal vehicle fuel initialization failed: %s'):format(errorMessage))
        return false
    end

    debugPrint('Postal vehicle fuel initialized to 100%')
    return true
end

local function GivePostalVehicleKeys(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then
        debugPrint('ERROR: Postal vehicle key assignment skipped because the entity does not exist')
        return false
    end

    if GetResourceState('qb-vehiclekeys') ~= 'started' then
        debugPrint('ERROR: Postal vehicle key assignment failed because qb-vehiclekeys is not started')
        return false
    end

    local success, plateOrError = pcall(function()
        local plate = tostring(QBCore.Functions.GetPlate(vehicle) or '')
            :gsub('^%s+', '')
            :gsub('%s+$', '')

        if plate == '' then
            error('the vehicle plate is empty')
        end

        TriggerEvent('vehiclekeys:client:SetOwner', plate)
        return plate
    end)

    if not success then
        debugPrint(('ERROR: Postal vehicle key assignment failed: %s'):format(plateOrError))
        return false
    end

    debugPrint(('Postal vehicle keys assigned: %s'):format(plateOrError))
    return true
end

local function clearRouteState()
    onDuty = false
    routeVehicle = nil
    routeVehicleNetId = nil
    routeRequestPending = false
    returnRequestPending = false
    debugPrint('Route state cleared')
end

local function startVehicleDiagnostic(vehicle, networkId)
    CreateThread(function()
        Wait(5000)

        local status = vehicle ~= 0 and DoesEntityExist(vehicle) and 'EXISTS' or 'MISSING'
        debugPrint(('5-second client vehicle check: %s entity=%s netId=%s'):format(
            status,
            tostring(vehicle),
            tostring(networkId)
        ))
    end)
end

local function requestRoute()
    if onDuty or routeRequestPending then
        QBCore.Functions.Notify('You already have an active postal route.', 'error')
        return
    end

    if not isVehicleSpawnClear() then
        QBCore.Functions.Notify('The postal vehicle spawn is blocked.', 'error')
        return
    end

    routeRequestPending = true
    debugPrint('Route requested')
    TriggerServerEvent('acg_postal:server:requestRoute')
end

local function requestVehicleReturn()
    if returnRequestPending then
        return
    end

    if not routeVehicleNetId then
        QBCore.Functions.Notify('The postal vehicle is still being created. Try again shortly.', 'error')
        return
    end

    local vehicle = routeVehicle

    if (not vehicle or not DoesEntityExist(vehicle)) and NetworkDoesEntityExistWithNetworkId(routeVehicleNetId) then
        vehicle = NetworkGetEntityFromNetworkId(routeVehicleNetId)
        routeVehicle = vehicle
    end

    if not vehicle or not DoesEntityExist(vehicle) then
        QBCore.Functions.Notify('Your postal vehicle could not be found.', 'error')
        return
    end

    if #(GetEntityCoords(vehicle) - Config.Depot) > Config.ReturnDistance then
        QBCore.Functions.Notify('Bring your postal vehicle closer to the depot.', 'error')
        return
    end

    returnRequestPending = true
    TriggerServerEvent('acg_postal:server:returnVehicle', routeVehicleNetId)
end

RegisterNetEvent('acg_postal:client:routeVehicleCreated', function(vehicleNetId, plate)
    if not routeRequestPending or onDuty then
        return
    end

    debugPrint('Route approved')
    debugPrint(('Resolving server vehicle network ID: %s'):format(vehicleNetId))

    if type(vehicleNetId) ~= 'number' or vehicleNetId <= 0 then
        TriggerServerEvent('acg_postal:server:cancelRoute')
        clearRouteState()
        QBCore.Functions.Notify('The server returned an invalid postal vehicle.', 'error')
        return
    end

    local timeout = GetGameTimer() + 10000
    local vehicle = 0

    while GetGameTimer() < timeout do
        if NetworkDoesEntityExistWithNetworkId(vehicleNetId) then
            vehicle = NetToVeh(vehicleNetId)

            if vehicle ~= 0 and DoesEntityExist(vehicle) then
                break
            end
        end

        Wait(100)
    end

    if vehicle == 0 or not DoesEntityExist(vehicle) then
        debugPrint(('Failed to resolve server vehicle netId=%s'):format(vehicleNetId))
        TriggerServerEvent('acg_postal:server:cancelRoute')
        clearRouteState()
        QBCore.Functions.Notify('The postal vehicle could not be loaded from the server.', 'error')
        return
    end

    routeVehicle = vehicle
    routeVehicleNetId = vehicleNetId
    onDuty = true
    routeRequestPending = false

    SetVehicleEngineOn(vehicle, true, true, false)
    SetVehicleNeedsToBeHotwired(vehicle, false)
    SetVehicleHasBeenOwnedByPlayer(vehicle, true)
    SetVehRadioStation(vehicle, 'OFF')
    SetPostalVehicleFuel(vehicle)
    GivePostalVehicleKeys(vehicle)
    TaskWarpPedIntoVehicle(PlayerPedId(), vehicle, -1)
    startVehicleDiagnostic(vehicle, vehicleNetId)

    debugPrint(('Server postal vehicle resolved: entity=%s netId=%s plate=%s'):format(vehicle, vehicleNetId, plate))
    QBCore.Functions.Notify('Postal route started. Return the vehicle to this depot when finished.', 'success')
end)

RegisterNetEvent('acg_postal:client:routeDenied', function(message)
    routeRequestPending = false
    QBCore.Functions.Notify(message or 'The postal route could not be started.', 'error')
end)

RegisterNetEvent('acg_postal:client:returnApproved', function(vehicleNetId)
    if not onDuty or not returnRequestPending then
        return
    end

    if vehicleNetId ~= routeVehicleNetId then
        returnRequestPending = false
        debugPrint(('Ignored return approval for network ID %s; active network ID is %s'):format(
            vehicleNetId,
            routeVehicleNetId or 'not assigned'
        ))
        return
    end

    debugPrint('Vehicle returned')
    clearRouteState()
    QBCore.Functions.Notify('Postal vehicle returned.', 'success')
end)

RegisterNetEvent('acg_postal:client:returnDenied', function(message)
    returnRequestPending = false
    QBCore.Functions.Notify(message or 'The postal vehicle could not be returned.', 'error')
end)

CreateThread(function()
    while true do
        local waitTime = 1000
        local playerCoords = GetEntityCoords(PlayerPedId())
        local distance = #(playerCoords - Config.Depot)

        if distance <= Config.DepotDrawDistance then
            waitTime = 0
            DrawMarker(2, Config.Depot.x, Config.Depot.y, Config.Depot.z + 0.2, 0.0, 0.0, 0.0, 0.0, 180.0, 0.0, 0.25, 0.25, 0.25, 46, 204, 113, 180, false, true, 2, false, nil, nil, false)

            if distance <= Config.InteractionDistance then
                local prompt = onDuty and '[E] Return Postal Vehicle' or '[E] Start Postal Route'
                drawText3D(Config.Depot + vector3(0.0, 0.0, 0.45), prompt)

                if IsControlJustReleased(0, 38) then
                    if onDuty then
                        requestVehicleReturn()
                    else
                        requestRoute()
                    end
                end
            end
        elseif distance <= Config.DepotDrawDistance * 2.0 then
            waitTime = 500
        end

        Wait(waitTime)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    clearRouteState()
end)
