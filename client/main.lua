local QBCore = exports['qb-core']:GetCoreObject()

local onDuty = false
local routeVehicle = nil
local routeVehicleNetId = nil
local routeVehiclePlate = nil

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

local carryAnimDict = 'anim@heists@box_carry@'
local carryAnimName = 'idle'

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
    routeVehiclePlate = nil
    routeRequestPending = false
    returnRequestPending = false
    routeStops = {}
    currentStop = 1
    arrivedAtStop = false
    deliveriesComplete = false
    deliveryRequestPending = false
    vehicleLostNotified = false
end

local function generatePostalPlate()
    local prefix = tostring(Config.VehiclePlatePrefix or 'POSTAL'):upper():gsub('%s+', ''):sub(1, 6)
    return ('%s%02d'):format(prefix, math.random(0, 99))
end

local function deleteClientRouteVehicle(reason)
    local vehicle = routeVehicle

    debugPrint(('Deleting client postal vehicle reason=%s entity=%s netId=%s'):format(
        tostring(reason),
        tostring(vehicle),
        tostring(routeVehicleNetId)
    ))

    if not entityExists(vehicle) then
        return
    end

    NetworkRequestControlOfEntity(vehicle)
    local timeout = GetGameTimer() + 1000

    while DoesEntityExist(vehicle) and not NetworkHasControlOfEntity(vehicle) and GetGameTimer() < timeout do
        NetworkRequestControlOfEntity(vehicle)
        Wait(0)
    end

    if type(QBCore.Functions.DeleteVehicle) == 'function' then
        local success, errorMessage = pcall(QBCore.Functions.DeleteVehicle, vehicle)

        if not success then
            debugPrint(('ERROR: QBCore vehicle deletion failed: %s'):format(errorMessage))
        end
    else
        DeleteVehicle(vehicle)
    end
end

local function failVehicleSpawn(message, reason)
    TriggerServerEvent('acg_postal:server:routeSpawnFailed')
    deleteClientRouteVehicle(reason)
    ClearRouteState(reason)
    QBCore.Functions.Notify(message, 'error')
end

local function spawnRouteVehicle()
    if not isVehicleSpawnClear() then
        failVehicleSpawn('The postal vehicle spawn is blocked.', 'vehicle_spawn_blocked')
        return
    end

    local success, errorMessage = pcall(function()
        QBCore.Functions.SpawnVehicle(Config.VehicleModel, function(vehicle)
            if not entityExists(vehicle) then
                failVehicleSpawn('The postal vehicle could not be spawned.', 'vehicle_spawn_failed')
                return
            end

            routeVehicle = vehicle
            local plate = generatePostalPlate()
            SetVehicleNumberPlateText(vehicle, plate)
            plate = NormalizePlate(QBCore.Functions.GetPlate(vehicle))

            routeVehicleNetId = NetworkGetNetworkIdFromEntity(vehicle)

            if not routeVehicleNetId or routeVehicleNetId <= 0 then
                failVehicleSpawn('The postal vehicle could not be networked.', 'vehicle_network_id_failed')
                return
            end

            routeVehiclePlate = plate
            SetNetworkIdCanMigrate(routeVehicleNetId, true)
            SetVehicleEngineOn(vehicle, true, true, false)
            SetVehicleNeedsToBeHotwired(vehicle, false)
            SetVehicleHasBeenOwnedByPlayer(vehicle, true)
            SetVehRadioStation(vehicle, 'OFF')
            SetPostalVehicleFuel(vehicle)
            GivePostalVehicleKeys(vehicle, plate)
            TaskWarpPedIntoVehicle(PlayerPedId(), vehicle, -1)
            Wait(250)

            local enteredVehicle = GetVehiclePedIsIn(PlayerPedId(), false) == vehicle
            debugPrint(('Player successfully entered postal vehicle: %s'):format(tostring(enteredVehicle)))

            onDuty = true
            debugPrint('Postal vehicle spawned')
            debugPrint(('Postal vehicle net ID: %s'):format(routeVehicleNetId))
            debugPrint(('Postal vehicle plate: %s'):format(routeVehiclePlate))
            TriggerServerEvent(
                'acg_postal:server:registerRouteVehicle',
                routeVehicleNetId,
                routeVehiclePlate
            )
        end, Config.VehicleSpawn, true, false)
    end)

    if not success then
        debugPrint(('ERROR: QBCore vehicle spawn failed: %s'):format(errorMessage))
        failVehicleSpawn('The postal vehicle could not be spawned.', 'qbcore_spawn_error')
    end
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

    local vehicle = routeVehicle

    if not vehicle or not DoesEntityExist(vehicle) then
        QBCore.Functions.Notify('Your postal vehicle could not be found.', 'error')
        return
    end

    if #(GetEntityCoords(vehicle) - Config.Depot) > Config.ReturnDistance then
        QBCore.Functions.Notify('Bring your postal vehicle closer to the depot.', 'error')
        return
    end

    returnRequestPending = true
    TriggerServerEvent('acg_postal:server:returnVehicle', routeVehicleNetId, routeVehiclePlate)
end

RegisterNetEvent('acg_postal:client:routeApproved', function()
    if not routeRequestPending or onDuty then
        return
    end

    debugPrint('Route approved')
    spawnRouteVehicle()
end)

RegisterNetEvent('acg_postal:client:routeVehicleRegistered', function(vehicleNetId, plate)
    if not onDuty or vehicleNetId ~= routeVehicleNetId or NormalizePlate(plate) ~= routeVehiclePlate then
        return
    end

    routeRequestPending = false

    if not generateRouteStops() then
        TriggerServerEvent('acg_postal:server:cancelRoute', 'route_generation_failed')
        deleteClientRouteVehicle('route_generation_failed')
        ClearRouteState('route_generation_failed')
        QBCore.Functions.Notify('No postal delivery locations are configured.', 'error')
        return
    end

    QBCore.Functions.Notify('Postal route started. Follow the GPS to your first delivery.', 'success')
end)

RegisterNetEvent('acg_postal:client:routeVehicleRegistrationFailed', function(message)
    deleteClientRouteVehicle('vehicle_registration_failed')
    ClearRouteState('vehicle_registration_failed')
    QBCore.Functions.Notify(message or 'The postal vehicle could not be registered.', 'error')
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
    deleteClientRouteVehicle('vehicle_returned')
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
            local vehicle = routeVehicle

            if not vehicle or not DoesEntityExist(vehicle) or IsEntityDead(vehicle) then
                if not vehicleLostNotified then
                    vehicleLostNotified = true
                    QBCore.Functions.Notify('Your postal vehicle is unavailable. Return to the depot if it does not reappear.', 'error')
                end
            else
                vehicleLostNotified = false
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

    deleteClientRouteVehicle('resource_stopping')
    ClearRouteState('resource_stopping')
end)

local function runBareVehicleTest(modelName, displayName)
    CreateThread(function()
        local model = joaat(modelName)
        RequestModel(model)
        local timeout = GetGameTimer() + 10000

        while not HasModelLoaded(model) and GetGameTimer() < timeout do
            Wait(50)
        end

        if not HasModelLoaded(model) then
            print(('[acg_postal TEST] Failed to load %s'):format(displayName))
            return
        end

        local ped = PlayerPedId()
        local spawnCoords = GetOffsetFromEntityInWorldCoords(ped, 0.0, 5.0, 0.0)
        local heading = GetEntityHeading(ped)
        local vehicle = CreateVehicle(
            model,
            spawnCoords.x,
            spawnCoords.y,
            spawnCoords.z,
            heading,
            true,
            false
        )
        local isolatedTestVehicle = vehicle

        print(('[acg_postal TEST] Bare %s created entity=%s'):format(displayName, isolatedTestVehicle))

        local lastExists = DoesEntityExist(isolatedTestVehicle)
        print(('[acg_postal TEST] t=0 vehicle exists=%s'):format(tostring(lastExists)))

        for elapsed = 1, 30 do
            Wait(1000)

            local exists = DoesEntityExist(isolatedTestVehicle)

            if exists ~= lastExists then
                print(('[acg_postal TEST] t=%s vehicle exists=%s'):format(elapsed, tostring(exists)))
                lastExists = exists
            end
        end
    end)
end

RegisterCommand('testpostalvan', function()
    runBareVehicleTest('boxville2', 'Boxville')
end, false)

RegisterCommand('testpostalcar', function()
    runBareVehicleTest('adder', 'Adder')
end, false)
