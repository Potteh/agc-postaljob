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

local function generatePlate()
    local prefix = tostring(Config.VehiclePlatePrefix or 'POSTAL'):upper():gsub('%s+', ''):sub(1, 8)
    local suffixLength = 8 - #prefix

    if suffixLength == 0 then
        return prefix
    end

    local maximum = (10 ^ suffixLength) - 1
    return prefix .. string.format('%0' .. suffixLength .. 'd', math.random(0, maximum))
end

local function setVehicleFuel(vehicle)
    -- No external fuel resource was available in the workspace. Keep this helper
    -- as the single integration point when the server's fuel system is added.
    SetVehicleFuelLevel(vehicle, Config.VehicleFuelLevel + 0.0)
end

local function giveVehicleKeys(vehicle, plate)
    -- No vehicle-key resource was available in the workspace. This helper is
    -- intentionally isolated so the correct resource export/event can be added.
    debugPrint(('No vehicle-key integration configured for %s (%s)'):format(vehicle, plate))
end

local function requestControl(entity)
    if not DoesEntityExist(entity) then
        return false
    end

    NetworkRequestControlOfEntity(entity)
    local timeout = GetGameTimer() + 1000

    while not NetworkHasControlOfEntity(entity) and GetGameTimer() < timeout do
        Wait(0)
        NetworkRequestControlOfEntity(entity)
    end

    return NetworkHasControlOfEntity(entity)
end

local function deleteRouteVehicle()
    local vehicle = routeVehicle

    if (not vehicle or not DoesEntityExist(vehicle)) and routeVehicleNetId then
        vehicle = NetworkGetEntityFromNetworkId(routeVehicleNetId)
    end

    if vehicle and DoesEntityExist(vehicle) then
        requestControl(vehicle)
        SetEntityAsMissionEntity(vehicle, true, true)
        DeleteVehicle(vehicle)

        if DoesEntityExist(vehicle) then
            DeleteEntity(vehicle)
        end
    end
end

local function clearRouteState()
    onDuty = false
    routeVehicle = nil
    routeVehicleNetId = nil
    routeRequestPending = false
    returnRequestPending = false
    debugPrint('Route state cleared')
end

local function failRouteStart(message)
    TriggerServerEvent('acg_postal:server:cancelRoute')
    clearRouteState()
    QBCore.Functions.Notify(message, 'error')
end

local function spawnRouteVehicle()
    if not isVehicleSpawnClear() then
        failRouteStart('The postal vehicle spawn is blocked.')
        return
    end

    local model = joaat(Config.VehicleModel)

    if not IsModelInCdimage(model) or not IsModelAVehicle(model) then
        failRouteStart('The configured postal vehicle is invalid.')
        return
    end

    RequestModel(model)
    local timeout = GetGameTimer() + 10000

    while not HasModelLoaded(model) and GetGameTimer() < timeout do
        Wait(50)
    end

    if not HasModelLoaded(model) then
        failRouteStart('The postal vehicle could not be loaded.')
        return
    end

    local spawn = Config.VehicleSpawn
    local vehicle = CreateVehicle(model, spawn.x, spawn.y, spawn.z, spawn.w, true, true)
    SetModelAsNoLongerNeeded(model)

    if not DoesEntityExist(vehicle) then
        failRouteStart('The postal vehicle could not be spawned.')
        return
    end

    SetEntityAsMissionEntity(vehicle, true, true)
    SetVehicleOnGroundProperly(vehicle)

    local plate = generatePlate()
    SetVehicleNumberPlateText(vehicle, plate)
    setVehicleFuel(vehicle)

    routeVehicle = vehicle
    routeVehicleNetId = NetworkGetNetworkIdFromEntity(vehicle)
    SetNetworkIdCanMigrate(routeVehicleNetId, true)
    onDuty = true
    routeRequestPending = false

    TaskWarpPedIntoVehicle(PlayerPedId(), vehicle, -1)
    giveVehicleKeys(vehicle, plate)
    TriggerServerEvent('acg_postal:server:registerVehicle', routeVehicleNetId)

    debugPrint(('Vehicle spawned with plate %s'):format(plate))
    debugPrint(('Vehicle network ID: %s'):format(routeVehicleNetId))
    QBCore.Functions.Notify('Postal route started. Return the vehicle to this depot when finished.', 'success')
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
    if returnRequestPending or not routeVehicleNetId then
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

    if NetworkGetNetworkIdFromEntity(vehicle) ~= routeVehicleNetId then
        QBCore.Functions.Notify('This is not your assigned postal vehicle.', 'error')
        return
    end

    returnRequestPending = true
    TriggerServerEvent('acg_postal:server:returnVehicle', routeVehicleNetId)
end

RegisterNetEvent('acg_postal:client:routeApproved', function()
    if not routeRequestPending or onDuty then
        return
    end

    debugPrint('Route approved')
    spawnRouteVehicle()
end)

RegisterNetEvent('acg_postal:client:routeDenied', function(message)
    routeRequestPending = false
    QBCore.Functions.Notify(message or 'The postal route could not be started.', 'error')
end)

RegisterNetEvent('acg_postal:client:returnApproved', function()
    if not onDuty or not returnRequestPending then
        return
    end

    deleteRouteVehicle()
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

    deleteRouteVehicle()
    clearRouteState()
end)
