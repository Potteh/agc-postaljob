local QBCore = exports['qb-core']:GetCoreObject()

local activeRoutes = {}

local function debugPrint(message)
    if Config.Debug then
        print(('[acg_postal] %s'):format(message))
    end
end

local function clearRoute(playerId)
    if activeRoutes[playerId] then
        activeRoutes[playerId] = nil
        debugPrint(('Route state cleared for player %s'):format(playerId))
    end
end

local function hasRequiredJob(player)
    if not Config.RequireJob then
        return true
    end

    local job = player.PlayerData.job
    return job and job.name == Config.JobName
end

RegisterNetEvent('acg_postal:server:requestRoute', function()
    local src = source
    debugPrint(('Route requested by player %s'):format(src))

    if activeRoutes[src] then
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

    activeRoutes[src] = {
        vehicleNetId = nil
    }

    debugPrint(('Route approved for player %s'):format(src))
    TriggerClientEvent('acg_postal:client:routeApproved', src)
end)

RegisterNetEvent('acg_postal:server:registerVehicle', function(vehicleNetId)
    local src = source
    local route = activeRoutes[src]

    if not route or route.vehicleNetId ~= nil then
        return
    end

    if type(vehicleNetId) ~= 'number' or vehicleNetId <= 0 then
        clearRoute(src)
        TriggerClientEvent('acg_postal:client:routeDenied', src, 'The postal vehicle could not be registered.')
        return
    end

    route.vehicleNetId = vehicleNetId
    debugPrint(('Registered vehicle network ID %s for player %s'):format(vehicleNetId, src))
end)

RegisterNetEvent('acg_postal:server:cancelRoute', function()
    clearRoute(source)
end)

RegisterNetEvent('acg_postal:server:returnVehicle', function(vehicleNetId)
    local src = source
    local route = activeRoutes[src]

    if not route or not route.vehicleNetId then
        TriggerClientEvent('acg_postal:client:returnDenied', src, 'You do not have an active postal vehicle.')
        return
    end

    if type(vehicleNetId) ~= 'number' or vehicleNetId ~= route.vehicleNetId then
        TriggerClientEvent('acg_postal:client:returnDenied', src, 'This is not your assigned postal vehicle.')
        return
    end

    local vehicle = NetworkGetEntityFromNetworkId(vehicleNetId)

    if vehicle ~= 0 and DoesEntityExist(vehicle) then
        local vehicleCoords = GetEntityCoords(vehicle)

        if #(vehicleCoords - Config.Depot) > Config.ReturnDistance then
            TriggerClientEvent('acg_postal:client:returnDenied', src, 'Bring your postal vehicle closer to the depot.')
            return
        end
    end

    clearRoute(src)
    debugPrint(('Vehicle returned by player %s (network ID %s)'):format(src, vehicleNetId))
    TriggerClientEvent('acg_postal:client:returnApproved', src)
end)

AddEventHandler('playerDropped', function()
    clearRoute(source)
end)
