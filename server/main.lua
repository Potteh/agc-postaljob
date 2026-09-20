local QBCore = exports['qb-core']:GetCoreObject()

local ActiveRoutes = {}

local function debugPrint(message)
    if Config.Debug then
        print(('[acg_postal] %s'):format(message))
    end
end

local function normalizePlate(plate)
    return tostring(plate or ''):gsub('^%s*(.-)%s*$', '%1'):upper()
end

local function clearRoute(playerId, reason)
    if ActiveRoutes[playerId] then
        ActiveRoutes[playerId] = nil
        debugPrint(('Server route state cleared player=%s reason=%s'):format(playerId, reason))
    end
end

local function clearRouteAutomatically(playerId, reason)
    if Config.AutomaticRouteCleanup == false then
        print(('[acg_postal DIAGNOSTIC] Would have cleared route: player=%s reason=%s'):format(
            playerId,
            reason
        ))
        return
    end

    clearRoute(playerId, reason)
end

local function hasRequiredJob(player)
    if not Config.RequireJob then
        return true
    end

    local job = player.PlayerData.job
    return job and job.name == Config.JobName
end

local function isValidPostalPlate(plate)
    local prefix = normalizePlate(Config.VehiclePlatePrefix or 'POSTAL'):gsub('%s+', ''):sub(1, 6)
    local suffix = plate:sub(#prefix + 1)

    return plate:sub(1, #prefix) == prefix
        and #suffix == 2
        and tonumber(suffix) ~= nil
end

RegisterNetEvent('acg_postal:server:requestRoute', function()
    local src = source
    debugPrint(('Route requested by player %s'):format(src))

    if ActiveRoutes[src] then
        TriggerClientEvent('acg_postal:client:routeDenied', src, 'You already have an active postal route.')
        return
    end

    local player = QBCore.Functions.GetPlayer(src)

    if not player then
        return
    end

    if not hasRequiredJob(player) then
        TriggerClientEvent('acg_postal:client:routeDenied', src, 'You do not have the required postal job.')
        return
    end

    ActiveRoutes[src] = {
        vehicleNetId = nil,
        plate = nil,
        vehicleRegistered = false,
        currentStop = 1,
        totalStops = math.max(1, math.floor(tonumber(Config.DeliveriesPerRoute) or 1)),
        deliveriesComplete = false
    }

    debugPrint(('Route approved for player %s'):format(src))
    TriggerClientEvent('acg_postal:client:routeApproved', src)
end)

RegisterNetEvent('acg_postal:server:registerRouteVehicle', function(vehicleNetId, plate)
    local src = source
    local route = ActiveRoutes[src]

    if not route then
        TriggerClientEvent('acg_postal:client:routeVehicleRegistrationFailed', src, 'The server no longer has an active postal route.')
        return
    end

    plate = normalizePlate(plate)

    if route.vehicleRegistered then
        if route.vehicleNetId == vehicleNetId and route.plate == plate then
            TriggerClientEvent('acg_postal:client:routeVehicleRegistered', src, route.vehicleNetId, route.plate)
        else
            TriggerClientEvent('acg_postal:client:routeVehicleRegistrationFailed', src, 'A different postal vehicle is already registered to this route.')
        end

        return
    end

    if type(vehicleNetId) ~= 'number' or vehicleNetId <= 0 or vehicleNetId % 1 ~= 0 then
        clearRouteAutomatically(src, 'invalid_vehicle_network_id')
        TriggerClientEvent('acg_postal:client:routeVehicleRegistrationFailed', src, 'The postal vehicle has an invalid network ID.')
        return
    end

    if not isValidPostalPlate(plate) then
        clearRouteAutomatically(src, 'invalid_vehicle_plate')
        TriggerClientEvent('acg_postal:client:routeVehicleRegistrationFailed', src, 'The postal vehicle has an invalid plate.')
        return
    end

    route.vehicleNetId = vehicleNetId
    route.plate = plate
    route.vehicleRegistered = true

    debugPrint(('Postal vehicle registered player=%s netId=%s plate=%s'):format(src, vehicleNetId, plate))
    TriggerClientEvent('acg_postal:client:routeVehicleRegistered', src, vehicleNetId, plate)
end)

RegisterNetEvent('acg_postal:server:routeSpawnFailed', function()
    clearRouteAutomatically(source, 'client_vehicle_spawn_failed')
end)

RegisterNetEvent('acg_postal:server:cancelRoute', function(reason)
    local allowedReasons = {
        route_generation_failed = true,
        explicit_player_cancellation = true
    }
    local clearReason = allowedReasons[reason] and reason or 'client_requested_route_cancel'
    if clearReason == 'explicit_player_cancellation' then
        clearRoute(source, clearReason)
    else
        clearRouteAutomatically(source, clearReason)
    end
end)

RegisterNetEvent('acg_postal:server:completeDelivery', function(stopNumber)
    local src = source
    local route = ActiveRoutes[src]

    if not route or not route.vehicleRegistered then
        TriggerClientEvent('acg_postal:client:deliveryRejected', src, 'You do not have an active registered postal route.')
        return
    end

    if route.deliveriesComplete or route.currentStop > route.totalStops then
        TriggerClientEvent('acg_postal:client:deliveryRejected', src, 'All postal deliveries are already complete.')
        return
    end

    if type(stopNumber) ~= 'number' or stopNumber % 1 ~= 0 or stopNumber ~= route.currentStop then
        TriggerClientEvent('acg_postal:client:deliveryRejected', src, 'The postal delivery is out of sequence.')
        return
    end

    local completedStop = route.currentStop

    if completedStop >= route.totalStops then
        route.deliveriesComplete = true
        route.currentStop = route.totalStops + 1
    else
        route.currentStop = route.currentStop + 1
    end

    debugPrint(('Server accepted delivery %s/%s for player %s'):format(completedStop, route.totalStops, src))
    TriggerClientEvent(
        'acg_postal:client:deliveryAccepted',
        src,
        completedStop,
        route.totalStops,
        route.deliveriesComplete
    )
end)

RegisterNetEvent('acg_postal:server:returnVehicle', function(vehicleNetId, plate)
    local src = source
    local route = ActiveRoutes[src]

    if not route or not route.vehicleRegistered then
        TriggerClientEvent('acg_postal:client:returnDenied', src, 'You do not have an active postal vehicle.')
        return
    end

    if not route.deliveriesComplete then
        TriggerClientEvent('acg_postal:client:returnDenied', src, 'Complete all postal deliveries before returning the vehicle.')
        return
    end

    if type(vehicleNetId) ~= 'number' or vehicleNetId ~= route.vehicleNetId then
        TriggerClientEvent('acg_postal:client:returnDenied', src, 'This is not your assigned postal vehicle.')
        return
    end

    if normalizePlate(plate) ~= route.plate then
        TriggerClientEvent('acg_postal:client:returnDenied', src, 'The postal vehicle plate does not match your route.')
        return
    end

    clearRoute(src, 'vehicle_returned')
    debugPrint(('Vehicle return approved player=%s netId=%s plate=%s'):format(src, vehicleNetId, route.plate))
    TriggerClientEvent('acg_postal:client:returnApproved', src, vehicleNetId)
end)

AddEventHandler('playerDropped', function()
    clearRouteAutomatically(source, 'player_dropped')
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    ActiveRoutes = {}
end)
