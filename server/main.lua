local QBCore = exports['qb-core']:GetCoreObject()

local ActiveRoutes = {}
local PendingRoutes = {}

local function debugPrint(message)
    if Config.Debug then
        print(('[acg_postal] %s'):format(message))
    end
end

local function clearRoute(playerId)
    if ActiveRoutes[playerId] or PendingRoutes[playerId] then
        ActiveRoutes[playerId] = nil
        PendingRoutes[playerId] = nil
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
        local pendingRoute = PendingRoutes[playerId]

        if pendingRoute and pendingRoute.vehicle and pendingRoute.vehicle ~= 0 then
            debugPrint(('DELETE PENDING POSTAL VEHICLE\nReason: %s\nPlayer: %s\nEntity: %s'):format(
                reason,
                playerId,
                pendingRoute.vehicle
            ))

            if DoesEntityExist(pendingRoute.vehicle) then
                DeleteEntity(pendingRoute.vehicle)
            end
        end

        clearRoute(playerId)
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


local function failVehicleCreation(playerId, vehicle, message, debugMessage)
    debugPrint(debugMessage)

    if vehicle and vehicle ~= 0 and DoesEntityExist(vehicle) then
        debugPrint(('Deleting failed postal entity: %s'):format(vehicle))
        DeleteEntity(vehicle)
    end

    clearRoute(playerId)
    TriggerClientEvent('acg_postal:client:routeDenied', playerId, message)
end


local function startVehicleDiagnostic(playerId, vehicle, vehicleNetId)
    local checks = {
        { delay = 1000, label = '1-second' },
        { delay = 5000, label = '5-second' },
        { delay = 10000, label = '10-second' },
        { delay = 30000, label = '30-second' }
    }

    for _, check in ipairs(checks) do
        local delay = check.delay
        local label = check.label

        SetTimeout(delay, function()
            local exists = vehicle ~= 0 and DoesEntityExist(vehicle)

            debugPrint(('%s SERVER check: %s entity=%s netId=%s player=%s'):format(
                label,
                exists and 'EXISTS' or 'MISSING',
                vehicle,
                vehicleNetId,
                playerId
            ))
        end)
    end
end

RegisterNetEvent('acg_postal:server:requestRoute', function()
    local src = source
    debugPrint(('Route requested by player %s'):format(src))

    if ActiveRoutes[src] or PendingRoutes[src] then
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

    PendingRoutes[src] = {
        vehicle = 0
    }

    local spawn = Config.VehicleSpawn
    local model = joaat(Config.VehicleModel)
    debugPrint('Creating vehicle with CreateVehicle')
    debugPrint(('Model name: %s'):format(Config.VehicleModel))
    debugPrint(('Model hash: %s'):format(model))
    debugPrint(('Spawn: %.2f %.2f %.2f %.2f'):format(spawn.x, spawn.y, spawn.z, spawn.w))

    if type(CreateVehicle) ~= 'function' then
        debugPrint('ERROR: Server CreateVehicle native is unavailable in this artifact')
        clearRoute(src)
        TriggerClientEvent('acg_postal:client:routeDenied', src, 'This server artifact does not expose the server CreateVehicle native.')
        return
    end

    local vehicle = CreateVehicle(
        model,
        spawn.x,
        spawn.y,
        spawn.z,
        spawn.w,
        true,
        true
    )

    debugPrint(('CreateVehicle returned entity: %s'):format(vehicle))
    debugPrint(('DoesEntityExist immediately: %s'):format(vehicle ~= 0 and DoesEntityExist(vehicle) or false))

    local entityTimeout = GetGameTimer() + 5000

    while vehicle ~= 0 and not DoesEntityExist(vehicle) and GetGameTimer() < entityTimeout do
        Wait(50)
    end

    if vehicle == 0 or not DoesEntityExist(vehicle) then
        clearRoute(src)
        TriggerClientEvent('acg_postal:client:routeDenied', src, 'The postal vehicle could not be created by the server.')
        return
    end

    if not PendingRoutes[src] then
        failVehicleCreation(
            src,
            vehicle,
            'Postal vehicle creation was cancelled.',
            'ERROR: Postal vehicle creation was cancelled before entity registration'
        )
        return
    end

    PendingRoutes[src].vehicle = vehicle

    SetEntityOrphanMode(vehicle, 2)
    SetEntityRoutingBucket(vehicle, GetPlayerRoutingBucket(src))

    local vehicleNetId = 0
    local networkTimeout = GetGameTimer() + 5000
    debugPrint('Waiting for usable network ID...')

    while GetGameTimer() < networkTimeout do
        if DoesEntityExist(vehicle) then
            vehicleNetId = NetworkGetNetworkIdFromEntity(vehicle)

            if vehicleNetId and vehicleNetId > 0 and vehicleNetId < 65534 then
                break
            end
        else
            break
        end

        Wait(50)
    end

    if not vehicleNetId or vehicleNetId <= 0 or vehicleNetId >= 65534 or not DoesEntityExist(vehicle) then
        failVehicleCreation(
            src,
            vehicle,
            'The postal vehicle could not obtain a usable network ID.',
            'ERROR: Postal vehicle failed to obtain usable network ID'
        )
        return
    end

    debugPrint(('Network ID: %s'):format(vehicleNetId))

    if not PendingRoutes[src] or not GetPlayerName(src) then
        failVehicleCreation(
            src,
            vehicle,
            'Postal vehicle creation was cancelled.',
            'ERROR: Postal vehicle creation was cancelled before route registration'
        )
        return
    end

    local plate = generatePlate()
    SetVehicleNumberPlateText(vehicle, plate)

    ActiveRoutes[src] = {
        vehicle = vehicle,
        vehicleNetId = vehicleNetId,
        plate = plate
    }
    PendingRoutes[src] = nil

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
    local seenPlayerIds = {}

    for playerId in pairs(ActiveRoutes) do
        playerIds[#playerIds + 1] = playerId
        seenPlayerIds[playerId] = true
    end

    for playerId in pairs(PendingRoutes) do
        if not seenPlayerIds[playerId] then
            playerIds[#playerIds + 1] = playerId
        end
    end

    for _, playerId in ipairs(playerIds) do
        deleteRouteVehicle(playerId, 'acg_postal resource stopped')
    end
end)
