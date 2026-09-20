local QBCore = exports['qb-core']:GetCoreObject()

local onDuty = false
local routeVehicle = nil
local routeVehicleNetId = nil

local routeRequestPending = false
local returnRequestPending = false

local routeStops = {}
local currentStop = 1
local carryingPackage = false
local packageObject = nil
local arrivedAtStop = false
local routeBlip = nil
local deliveriesComplete = false
local deliveryRequestPending = false
local vehicleLostNotified = false
local vehicleMissingSince = nil
local vehicleExistenceCheckPending = false

local carryAnimDict = 'anim@heists@box_carry@'
local carryAnimName = 'idle'
local ResolveRouteVehicle

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

local function NormalizePlate(plate)
    return (plate or ''):gsub('^%s*(.-)%s*$', '%1'):upper()
end

local function entityExists(vehicle)
    return vehicle ~= nil and vehicle ~= 0 and DoesEntityExist(vehicle)
end

local function runInitializationOperation(label, vehicle, operation)
    debugPrint(('BEFORE %s entity exists=%s'):format(label, tostring(entityExists(vehicle))))

    local success, errorMessage = pcall(operation)

    if not success then
        debugPrint(('ERROR: %s failed: %s'):format(label, errorMessage))
    end

    debugPrint(('AFTER %s entity exists=%s'):format(label, tostring(entityExists(vehicle))))
end

local function SetPostalVehicleFuel(vehicle)
    if not entityExists(vehicle) then
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

local function GivePostalVehicleKeys(vehicle, expectedPlate)
    if not entityExists(vehicle) then
        debugPrint('ERROR: Postal vehicle key assignment skipped because the entity does not exist')
        return false
    end

    if GetResourceState('qb-vehiclekeys') ~= 'started' then
        debugPrint('ERROR: Postal vehicle key assignment failed because qb-vehiclekeys is not started')
        return false
    end

    local actualPlate = NormalizePlate(GetVehicleNumberPlateText(vehicle))
    expectedPlate = NormalizePlate(expectedPlate)

    if expectedPlate == '' or actualPlate ~= expectedPlate then
        debugPrint(('ERROR: Postal vehicle key assignment skipped due to plate mismatch expected=%s actual=%s'):format(
            expectedPlate,
            actualPlate
        ))
        return false
    end

    local success, errorMessage = pcall(function()
        TriggerEvent('vehiclekeys:client:SetOwner', expectedPlate)
    end)

    if not success then
        debugPrint(('ERROR: Postal vehicle key assignment failed: %s'):format(errorMessage))
        return false
    end

    debugPrint(('Postal vehicle keys assigned: %s'):format(expectedPlate))
    return true
end

local function removeRouteBlip()
    if routeBlip and DoesBlipExist(routeBlip) then
        SetBlipRoute(routeBlip, false)
        RemoveBlip(routeBlip)
    end

    routeBlip = nil
end

local function cleanupPackage()
    local ped = PlayerPedId()

    if packageObject and DoesEntityExist(packageObject) then
        DetachEntity(packageObject, true, true)
        SetEntityAsMissionEntity(packageObject, true, true)
        DeleteObject(packageObject)

        if DoesEntityExist(packageObject) then
            DeleteEntity(packageObject)
        end
    end

    packageObject = nil
    carryingPackage = false
    StopAnimTask(ped, carryAnimDict, carryAnimName, 1.0)
    SetPedCanSwitchWeapon(ped, true)
end


local function createRouteBlip(coords, label, sprite)
    removeRouteBlip()

    routeBlip = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(routeBlip, sprite)
    SetBlipColour(routeBlip, 5)
    SetBlipScale(routeBlip, 0.85)
    SetBlipAsShortRange(routeBlip, false)
    SetBlipRoute(routeBlip, true)
    SetBlipRouteColour(routeBlip, 5)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(label)
    EndTextCommandSetBlipName(routeBlip)
end


local function setCurrentDeliveryBlip()
    local stop = routeStops[currentStop]

    if not stop then
        return
    end

    createRouteBlip(stop.coords, 'Postal Delivery', 478)
    debugPrint(('Current stop: %s'):format(currentStop))
end


local function setDepotBlip()
    createRouteBlip(Config.Depot, 'Postal Depot', 478)
    debugPrint('Returning to depot')
end


local function generateRouteStops()
    routeStops = {}

    local locations = Config.DeliveryLocations or {}
    local requestedStops = math.max(1, math.floor(tonumber(Config.DeliveriesPerRoute) or 1))

    if #locations == 0 then
        return false
    end

    while #routeStops < requestedStops do
        local indices = {}

        for index = 1, #locations do
            indices[index] = index
        end

        for index = #indices, 2, -1 do
            local swapIndex = math.random(index)
            indices[index], indices[swapIndex] = indices[swapIndex], indices[index]
        end

        for _, locationIndex in ipairs(indices) do
            routeStops[#routeStops + 1] = locations[locationIndex]

            if #routeStops >= requestedStops then
                break
            end
        end
    end

    currentStop = 1
    arrivedAtStop = false
    deliveriesComplete = false
    deliveryRequestPending = false
    debugPrint(('Route generated: %s stops'):format(#routeStops))
    setCurrentDeliveryBlip()
    return true
end


local function takePackage()
    if carryingPackage then
        return
    end

    local ped = PlayerPedId()
    local model = joaat(Config.PackageProp)

    if not IsModelInCdimage(model) then
        QBCore.Functions.Notify('The configured package prop is invalid.', 'error')
        return
    end

    RequestModel(model)
    RequestAnimDict(carryAnimDict)
    local timeout = GetGameTimer() + 5000

    while (not HasModelLoaded(model) or not HasAnimDictLoaded(carryAnimDict)) and GetGameTimer() < timeout do
        Wait(50)
    end

    if not HasModelLoaded(model) or not HasAnimDictLoaded(carryAnimDict) then
        SetModelAsNoLongerNeeded(model)
        QBCore.Functions.Notify('The package could not be prepared.', 'error')
        return
    end

    local coords = GetEntityCoords(ped)
    packageObject = CreateObject(model, coords.x, coords.y, coords.z, false, false, false)
    SetModelAsNoLongerNeeded(model)

    if not packageObject or packageObject == 0 or not DoesEntityExist(packageObject) then
        packageObject = nil
        QBCore.Functions.Notify('The package could not be created.', 'error')
        return
    end

    AttachEntityToEntity(
        packageObject,
        ped,
        GetPedBoneIndex(ped, 60309),
        0.025,
        0.08,
        0.255,
        -145.0,
        290.0,
        0.0,
        true,
        true,
        false,
        true,
        1,
        true
    )
    TaskPlayAnim(ped, carryAnimDict, carryAnimName, 8.0, -8.0, -1, 49, 0.0, false, false, false)
    SetPedCanSwitchWeapon(ped, false)
    carryingPackage = true
    debugPrint('Package taken from vehicle')
end

local function ClearRouteState(reason)
    if not reason then
        error('ClearRouteState requires a reason')
    end

    debugPrint(('CLEAR ROUTE STATE\nreason=%s\nonDuty=%s\nvehicle=%s\nnetId=%s'):format(
        tostring(reason),
        tostring(onDuty),
        tostring(routeVehicle),
        tostring(routeVehicleNetId)
    ))

    cleanupPackage()
    removeRouteBlip()
    onDuty = false
    routeVehicle = nil
    routeVehicleNetId = nil
    routeRequestPending = false
    returnRequestPending = false
    routeStops = {}
    currentStop = 1
    arrivedAtStop = false
    deliveriesComplete = false
    deliveryRequestPending = false
    vehicleLostNotified = false
    vehicleMissingSince = nil
    vehicleExistenceCheckPending = false
end

local function logRouteVehicleStatus(networkId)
    local vehicle = ResolveRouteVehicle()

    debugPrint(('Route vehicle status: %s entity=%s netId=%s'):format(
        vehicle and 'RESOLVED' or 'UNRESOLVED',
        tostring(vehicle or 0),
        tostring(networkId)
    ))
end

local function startVehicleDiagnostic(networkId)
    CreateThread(function()
        Wait(5000)
        logRouteVehicleStatus(networkId)
    end)
end

ResolveRouteVehicle = function()
    if routeVehicle and routeVehicle ~= 0 and DoesEntityExist(routeVehicle) then
        return routeVehicle
    end

    if routeVehicleNetId and routeVehicleNetId > 0
        and NetworkDoesEntityExistWithNetworkId(routeVehicleNetId) then
        local vehicle = NetToVeh(routeVehicleNetId)

        if vehicle ~= 0 and DoesEntityExist(vehicle) then
            routeVehicle = vehicle
            return vehicle
        end
    end

    return nil
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

    if not deliveriesComplete then
        QBCore.Functions.Notify('Complete all postal deliveries before returning the vehicle.', 'error')
        return
    end

    if not routeVehicleNetId then
        QBCore.Functions.Notify('The postal vehicle is still being created. Try again shortly.', 'error')
        return
    end

    local vehicle = ResolveRouteVehicle()

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
        TriggerServerEvent('acg_postal:server:cancelRoute', 'invalid_vehicle_network_id')
        ClearRouteState('invalid_vehicle_network_id')
        QBCore.Functions.Notify('The server returned an invalid postal vehicle.', 'error')
        return
    end

    routeVehicle = nil
    routeVehicleNetId = vehicleNetId
    local timeout = GetGameTimer() + 10000
    local vehicle = nil

    while GetGameTimer() < timeout do
        vehicle = ResolveRouteVehicle()

        if vehicle then
            break
        end

        Wait(100)
    end

    if not vehicle then
        debugPrint(('Failed to resolve server vehicle netId=%s'):format(vehicleNetId))
        TriggerServerEvent('acg_postal:server:cancelRoute', 'vehicle_resolution_failed')
        ClearRouteState('vehicle_resolution_failed')
        QBCore.Functions.Notify('The postal vehicle could not be loaded from the server.', 'error')
        return
    end

    local expectedPlate = NormalizePlate(plate)
    local actualPlate = NormalizePlate(GetVehicleNumberPlateText(vehicle))
    debugPrint(('Expected server plate: %s'):format(expectedPlate))
    debugPrint(('Initial client plate: %s'):format(actualPlate))

    if actualPlate ~= expectedPlate then
        debugPrint('Waiting for postal plate replication...')
    end

    local plateTimeout = GetGameTimer() + 5000

    while actualPlate ~= expectedPlate and GetGameTimer() < plateTimeout do
        Wait(100)
        vehicle = ResolveRouteVehicle()

        if vehicle then
            actualPlate = NormalizePlate(GetVehicleNumberPlateText(vehicle))
        end
    end

    debugPrint(('Final client plate: %s'):format(actualPlate))

    if actualPlate ~= expectedPlate then
        debugPrint(('ERROR: Postal plate did not replicate before timeout expected=%s actual=%s'):format(
            expectedPlate,
            actualPlate
        ))
    end

    vehicle = ResolveRouteVehicle()

    if not vehicle then
        debugPrint(('Postal vehicle disappeared while waiting for plate replication netId=%s'):format(vehicleNetId))
        TriggerServerEvent('acg_postal:server:cancelRoute', 'plate_replication_entity_lost')
        ClearRouteState('plate_replication_entity_lost')
        QBCore.Functions.Notify('The postal vehicle disappeared before initialization.', 'error')
        return
    end

    routeVehicle = vehicle
    onDuty = true
    routeRequestPending = false

    local testFuel = not Config.DiagnosticVehicleInit or Config.TestFuel
    local testKeys = not Config.DiagnosticVehicleInit or Config.TestKeys
    local testVehicleNatives = not Config.DiagnosticVehicleInit or Config.TestVehicleNatives
    local testWarp = not Config.DiagnosticVehicleInit or Config.TestWarp

    if testVehicleNatives then
        runInitializationOperation('vehicle natives', vehicle, function()
            SetVehicleEngineOn(vehicle, true, true, false)
            SetVehicleNeedsToBeHotwired(vehicle, false)
            SetVehicleHasBeenOwnedByPlayer(vehicle, true)
            SetVehRadioStation(vehicle, 'OFF')
        end)
    end

    if testFuel then
        runInitializationOperation('qb-fuel', vehicle, function()
            SetPostalVehicleFuel(vehicle)
        end)
    end

    if testKeys then
        runInitializationOperation('qb-vehiclekeys', vehicle, function()
            GivePostalVehicleKeys(vehicle, expectedPlate)
        end)
    end

    if testWarp then
        runInitializationOperation('player warp', vehicle, function()
            TaskWarpPedIntoVehicle(PlayerPedId(), vehicle, -1)
        end)
    end

    if Config.DiagnosticVehicleInit and not testFuel and not testKeys and not testVehicleNatives and not testWarp then
        debugPrint('Diagnostic mode: leaving the server-created vehicle untouched')
    end

    startVehicleDiagnostic(vehicleNetId)

    if not generateRouteStops() then
        TriggerServerEvent('acg_postal:server:cancelRoute', 'route_generation_failed')
        ClearRouteState('route_generation_failed')
        QBCore.Functions.Notify('No postal delivery locations are configured.', 'error')
        return
    end

    logRouteVehicleStatus(vehicleNetId)

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
    ClearRouteState('vehicle_returned')
    QBCore.Functions.Notify('Postal vehicle returned.', 'success')
end)

RegisterNetEvent('acg_postal:client:returnDenied', function(message)
    returnRequestPending = false
    QBCore.Functions.Notify(message or 'The postal vehicle could not be returned.', 'error')
end)

RegisterNetEvent('acg_postal:client:deliveryAccepted', function(completedStop, totalStops, routeComplete)
    if not onDuty or not deliveryRequestPending or completedStop ~= currentStop then
        return
    end

    deliveryRequestPending = false
    debugPrint(('Server accepted delivery %s/%s'):format(completedStop, totalStops))
    QBCore.Functions.Notify(('Package delivered! %s / %s'):format(completedStop, totalStops), 'success')

    if routeComplete then
        deliveriesComplete = true
        arrivedAtStop = false
        removeRouteBlip()
        setDepotBlip()
        debugPrint('All deliveries completed')
        QBCore.Functions.Notify('Route complete! Return the postal vehicle to the depot.', 'success')
        return
    end

    currentStop = completedStop + 1
    arrivedAtStop = false
    setCurrentDeliveryBlip()
    debugPrint(('Moving to delivery %s'):format(currentStop))
end)

RegisterNetEvent('acg_postal:client:deliveryRejected', function(message)
    deliveryRequestPending = false
    QBCore.Functions.Notify(message or 'The package delivery could not be confirmed.', 'error')
end)

RegisterNetEvent('acg_postal:client:routeVehicleExists', function(vehicleNetId)
    if not onDuty or vehicleNetId ~= routeVehicleNetId then
        return
    end

    vehicleExistenceCheckPending = false

    local vehicle = ResolveRouteVehicle()

    if vehicle then
        debugPrint(('Route vehicle re-resolved successfully entity=%s netId=%s'):format(
            vehicle,
            routeVehicleNetId
        ))
        vehicleMissingSince = nil
        return
    end

    vehicleMissingSince = GetGameTimer()
    debugPrint(('Server confirms route vehicle still exists; continuing re-resolution netId=%s'):format(vehicleNetId))
end)

RegisterNetEvent('acg_postal:client:routeCancelled', function(reason, message)
    if not onDuty and not routeRequestPending then
        return
    end

    if not vehicleLostNotified then
        vehicleLostNotified = true
        QBCore.Functions.Notify(message or 'Your postal route was cancelled.', 'error')
    end

    ClearRouteState(reason or 'server_cancelled_route')
end)

CreateThread(function()
    while true do
        if not carryingPackage then
            Wait(500)
        else
            Wait(0)

            local ped = PlayerPedId()

            DisableControlAction(0, 21, true)
            DisableControlAction(0, 22, true)
            DisableControlAction(0, 23, true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 37, true)
            DisableControlAction(0, 44, true)
            DisableControlAction(0, 75, true)
            DisableControlAction(0, 140, true)
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 257, true)
            DisableControlAction(0, 263, true)
            DisableControlAction(0, 264, true)
            DisablePlayerFiring(PlayerId(), true)

            if not packageObject or not DoesEntityExist(packageObject) then
                cleanupPackage()
                QBCore.Functions.Notify('The package was lost. Retrieve another from the postal van.', 'error')
            elseif not IsEntityPlayingAnim(ped, carryAnimDict, carryAnimName, 3) then
                TaskPlayAnim(ped, carryAnimDict, carryAnimName, 8.0, -8.0, -1, 49, 0.0, false, false, false)
            end
        end
    end
end)

CreateThread(function()
    while true do
        local waitTime = 1000

        if onDuty and not deliveriesComplete and routeStops[currentStop] then
            local wasMissing = vehicleMissingSince ~= nil
            local vehicle = ResolveRouteVehicle()

            if not vehicle or IsEntityDead(vehicle) then
                local now = GetGameTimer()

                if not vehicleMissingSince then
                    vehicleMissingSince = now
                    debugPrint('Route vehicle temporarily unavailable - attempting network re-resolution')
                elseif now - vehicleMissingSince >= 10000 and not vehicleExistenceCheckPending then
                    vehicleExistenceCheckPending = true
                    debugPrint(('Requesting server route vehicle validation netId=%s'):format(routeVehicleNetId))
                    TriggerServerEvent('acg_postal:server:checkRouteVehicle')
                end
            else
                if wasMissing then
                    debugPrint(('Route vehicle re-resolved successfully entity=%s netId=%s'):format(
                        vehicle,
                        routeVehicleNetId
                    ))
                end

                vehicleMissingSince = nil
                vehicleExistenceCheckPending = false
                local ped = PlayerPedId()
                local playerCoords = GetEntityCoords(ped)
                local stop = routeStops[currentStop]
                local distanceToStop = #(playerCoords - stop.coords)

                if not arrivedAtStop and distanceToStop <= Config.DeliveryArrivalDistance then
                    arrivedAtStop = true
                    debugPrint('Arrived at delivery')
                    QBCore.Functions.Notify('Park nearby and retrieve a package from the back of your postal van.', 'primary')
                end

                if arrivedAtStop then
                    waitTime = 250

                    if carryingPackage then
                        if not deliveryRequestPending and distanceToStop <= Config.DeliveryDistance then
                            waitTime = 0
                            drawText3D(stop.coords + vector3(0.0, 0.0, 0.35), '[E] Deliver Package')

                            if IsControlJustReleased(0, 38) then
                                cleanupPackage()
                                deliveryRequestPending = true
                                debugPrint('Package delivered')
                                TriggerServerEvent('acg_postal:server:completeDelivery', currentStop)
                            end
                        end
                    elseif not deliveryRequestPending and not IsPedInAnyVehicle(ped, false) then
                        local vehicleDistance = #(GetEntityCoords(vehicle) - stop.coords)
                        local vehicleNearby = not Config.RequireVehicleNearby
                            or vehicleDistance <= Config.VehicleDeliveryDistance

                        if vehicleNearby then
                            local rearCoords = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, -3.3, 0.0)
                            local rearDistance = #(playerCoords - rearCoords)

                            if rearDistance <= Config.PackagePickupDistance then
                                waitTime = 0
                                drawText3D(rearCoords + vector3(0.0, 0.0, 0.35), '[E] Take Package')

                                if IsControlJustReleased(0, 38) then
                                    takePackage()
                                end
                            elseif rearDistance <= 10.0 then
                                waitTime = 100
                            end
                        end
                    end
                elseif distanceToStop <= Config.DeliveryArrivalDistance * 2.0 then
                    waitTime = 500
                end
            end
        end

        Wait(waitTime)
    end
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

    ClearRouteState('resource_stopping')
end)
