local QBCore = exports['qb-core']:GetCoreObject()

local ActiveRoutes = {}

local function debugPrint(message)
    if Config.Debug then
        print(('[acg_postal] %s'):format(message))
    end
end

local function clearRoute(playerId)
    if ActiveRoutes[playerId] then
        ActiveRoutes[playerId] = nil
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

local function generatePlate()
    local prefix = tostring(Config.VehiclePlatePrefix or 'POSTAL'):upper():gsub('%s+', ''):sub(1, 8)
    local suffixLength = 8 - #prefix

    if suffixLength == 0 then
        return prefix
    end

    local maximum = (10 ^ suffixLength) - 1
    return prefix .. string.format('%0' .. suffixLength .. 'd', math.random(0, maximum))
end

local function isVehicleSpawnClear()
    local spawnCoords = vector3(Config.VehicleSpawn.x, Config.VehicleSpawn.y, Config.VehicleSpawn.z)

    for _, vehicle in ipairs(GetAllVehicles()) do
        if DoesEntityExist(vehicle) and #(GetEntityCoords(vehicle) - spawnCoords) <= Config.VehicleSpawnClearance then
            return false
        end
    end

    return true
end


local function deleteRouteVehicle(playerId, reason)
    local route = ActiveRoutes[playerId]

    if not route then
        return
    end

    debugPrint(('DELETE POSTAL VEHICLE\nReason: %s\nPlayer: %s\nEntity: %s\nNetwork ID: %s'):format(
        reason,
        playerId,
        route.vehicle or 'not assigned',
        route.vehicleNetId or 'not assigned'
    ))

    if route.vehicle and route.vehicle ~= 0 and DoesEntityExist(route.vehicle) then
        DeleteEntity(route.vehicle)
    end

    clearRoute(playerId)
end


local function startVehicleDiagnostic(playerId, vehicle, vehicleNetId)
    SetTimeout(5000, function()
        local route = ActiveRoutes[playerId]
        local exists = route
            and route.vehicle == vehicle
            and route.vehicleNetId == vehicleNetId
            and DoesEntityExist(vehicle)

        debugPrint(('5-second vehicle check: %s player=%s entity=%s netId=%s'):format(
            exists and 'EXISTS' or 'MISSING',
            playerId,
            vehicle,
            vehicleNetId
        ))
    end)
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

    if not isVehicleSpawnClear() then
        TriggerClientEvent('acg_postal:client:routeDenied', src, 'The postal vehicle spawn is blocked.')
        return
    end

    ActiveRoutes[src] = {
        vehicle = 0,
        vehicleNetId = 0,
        plate = nil
    }

    local spawn = Config.VehicleSpawn
    local model = joaat(Config.VehicleModel)
    debugPrint(('Server creating postal vehicle for player %s'):format(src))

    local vehicle = CreateVehicleServerSetter(
        model,
        'automobile',
        spawn.x,
        spawn.y,
        spawn.z,
        spawn.w
    )

    debugPrint(('Server vehicle entity: %s'):format(vehicle))

    if vehicle == 0 or not DoesEntityExist(vehicle) then
        clearRoute(src)
        TriggerClientEvent('acg_postal:client:routeDenied', src, 'The postal vehicle could not be created by the server.')
        return
    end

    SetEntityOrphanMode(vehicle, 2)
    SetEntityRoutingBucket(vehicle, GetPlayerRoutingBucket(src))

    local plate = generatePlate()
    SetVehicleNumberPlateText(vehicle, plate)

    local vehicleNetId = NetworkGetNetworkIdFromEntity(vehicle)
    local timeout = GetGameTimer() + 5000

    while vehicleNetId <= 0 and DoesEntityExist(vehicle) and GetGameTimer() < timeout do
        Wait(50)

        if not DoesEntityExist(vehicle) then
            break
        end

        vehicleNetId = NetworkGetNetworkIdFromEntity(vehicle)
    end

    if vehicleNetId <= 0 or not DoesEntityExist(vehicle) then
        ActiveRoutes[src].vehicle = vehicle
        deleteRouteVehicle(src, 'server failed to obtain a network ID')
        TriggerClientEvent('acg_postal:client:routeDenied', src, 'The postal vehicle could not be networked by the server.')
        return
    end

    if not ActiveRoutes[src] or not GetPlayerName(src) then
        ActiveRoutes[src] = {
            vehicle = vehicle,
            vehicleNetId = vehicleNetId,
            plate = plate
        }
        deleteRouteVehicle(src, 'player disconnected during vehicle creation')
        return
    end

    ActiveRoutes[src] = {
        vehicle = vehicle,
        vehicleNetId = vehicleNetId,
        plate = plate
    }

    debugPrint(('Server vehicle net ID: %s'):format(vehicleNetId))
    debugPrint(('Postal plate: %s'):format(plate))
    debugPrint(('Sending postal vehicle to player %s'):format(src))
    startVehicleDiagnostic(src, vehicle, vehicleNetId)
    TriggerClientEvent('acg_postal:client:routeVehicleCreated', src, vehicleNetId, plate)
end)

RegisterNetEvent('acg_postal:server:cancelRoute', function()
    deleteRouteVehicle(source, 'route cancelled by client')
end)

RegisterNetEvent('acg_postal:server:returnVehicle', function(vehicleNetId)
    local src = source
    local route = ActiveRoutes[src]

    if not route or not route.vehicleNetId then
        TriggerClientEvent('acg_postal:client:returnDenied', src, 'You do not have an active postal vehicle.')
        return
    end

    if type(vehicleNetId) ~= 'number' or vehicleNetId ~= route.vehicleNetId then
        TriggerClientEvent('acg_postal:client:returnDenied', src, 'This is not your assigned postal vehicle.')
        return
    end

    local vehicle = route.vehicle

    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
        local vehicleCoords = GetEntityCoords(vehicle)

        if #(vehicleCoords - Config.Depot) > Config.ReturnDistance then
            TriggerClientEvent('acg_postal:client:returnDenied', src, 'Bring your postal vehicle closer to the depot.')
            return
        end
    end

    debugPrint(('Vehicle returned by player %s (network ID %s)'):format(src, vehicleNetId))
    deleteRouteVehicle(src, 'player intentionally returned postal vehicle')
    TriggerClientEvent('acg_postal:client:returnApproved', src, vehicleNetId)
end)

AddEventHandler('playerDropped', function()
    deleteRouteVehicle(source, 'player disconnected')
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    local playerIds = {}

    for playerId in pairs(ActiveRoutes) do
        playerIds[#playerIds + 1] = playerId
    end

    for _, playerId in ipairs(playerIds) do
        deleteRouteVehicle(playerId, 'acg_postal resource stopped')
    end
end)
