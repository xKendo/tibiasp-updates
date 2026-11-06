-- TibiaSP launcher protocol. Paths are relative to the engine cwd (/app).
-- An interrupted .processing file is evidence, never a command to replay.
local requestPath = "data/tibiasp_launcher.request"
local processingPath = "data/tibiasp_launcher.processing"
local responsePath = "data/tibiasp_launcher.response"
local maxRequestBytes = 128
local blockedWarning = nil

local function log(message)
    print("[TibiaSP Launcher] " .. message)
end

local function warnOnce(reason)
    if blockedWarning ~= reason then
        log("BLAD " .. reason .. "; polecenie nie zostalo wykonane ponownie.")
        blockedWarning = reason
    end
end

local function closeFile(file)
    local ok, result = pcall(function() return file:close() end)
    return ok and result and true or false
end

-- Linux ENOENT is 2. Unknown errors fail closed instead of assuming absence.
local function exists(path)
    local ok, file, _, errno = pcall(io.open, path, "rb")
    if not ok then return nil end
    if file then
        if not closeFile(file) then return nil end
        return true
    end
    if errno == 2 then return false end
    return nil
end

local function publishResponse(id, status, reason)
    local temporaryPath = responsePath .. "." .. id .. ".tmp"
    local content = id .. " " .. status
    if reason then content = content .. " " .. reason end
    content = content .. "\n"

    local opened, file = pcall(io.open, temporaryPath, "wb")
    if not opened or not file then return false, "RESPONSE_OPEN_FAILED" end

    local written, result = pcall(function() return file:write(content) end)
    if not written or not result then
        if not closeFile(file) then log("BLAD RESPONSE_CLOSE_FAILED") end
        return false, "RESPONSE_WRITE_FAILED"
    end
    local flushed, flushResult = pcall(function() return file:flush() end)
    if not flushed or not flushResult then
        if not closeFile(file) then log("BLAD RESPONSE_CLOSE_FAILED") end
        return false, "RESPONSE_FLUSH_FAILED"
    end
    if not closeFile(file) then return false, "RESPONSE_CLOSE_FAILED" end

    -- Same-directory rename publishes the whole response atomically on Linux.
    local renamed, renameResult = pcall(os.rename, temporaryPath, responsePath)
    if not renamed or not renameResult then return false, "RESPONSE_RENAME_FAILED" end
    return true
end

local function clearProcessing()
    local removed, result = pcall(os.remove, processingPath)
    if not removed or not result then
        log("BLAD PROCESSING_REMOVE_FAILED; zachowanego polecenia nie wolno wykonywac ponownie.")
        return false
    end
    return true
end

local function acknowledge(id, status, reason)
    local published, failure = publishResponse(id, status, reason)
    if not published then
        log("BLAD " .. failure .. "; zachowano plik diagnostyczny; polecenie nie zostanie wykonane ponownie.")
        return false
    end
    if not clearProcessing() then
        -- The launcher waits for .processing to disappear before finalizing an ACK.
        local reported, reportFailure = publishResponse(id, "ERROR", "PROCESSING_REMOVE_FAILED")
        if not reported then log("BLAD " .. reportFailure .. "; zachowano plik diagnostyczny.") end
        return false
    end
    return true
end

local function fail(id, reason)
    log("BLAD " .. reason)
    if id then acknowledge(id, "ERROR", reason) end
end

function onThink(interval)
    local processingExists = exists(processingPath)
    if processingExists == nil then
        warnOnce("PROCESSING_STATE_UNKNOWN")
        return true
    end
    if processingExists then
        warnOnce("PROCESSING_REQUIRES_REVIEW")
        return true
    end
    local requestExists = exists(requestPath)
    if requestExists == nil then
        warnOnce("REQUEST_STATE_UNKNOWN")
        return true
    end
    if not requestExists then
        blockedWarning = nil
        return true
    end

    -- Only onThink consumes requests. PING therefore proves this event is live.
    local claimed, claimResult = pcall(os.rename, requestPath, processingPath)
    if not claimed or not claimResult then
        warnOnce("REQUEST_CLAIM_FAILED")
        return true
    end
    blockedWarning = nil

    local opened, file = pcall(io.open, processingPath, "rb")
    if not opened or not file then
        fail(nil, "REQUEST_OPEN_FAILED")
        return true
    end
    local readOk, request, readError = pcall(function() return file:read(maxRequestBytes + 1) end)
    local closed = closeFile(file)
    if not readOk or readError or not closed then
        fail(nil, "REQUEST_READ_OR_CLOSE_FAILED")
        return true
    end
    request = request or ""

    local command, id = request:match("^([A-Z]+) ([0-9a-fA-F]+)\r?\n$")
    if not id or #id ~= 32 or #request > maxRequestBytes then
        -- A valid operation ID permits a correlated error even for a bad request.
        local badId = request:match("^[A-Z]+ ([0-9a-fA-F]+)")
        if not badId or #badId ~= 32 then badId = nil end
        fail(badId, "MALFORMED_REQUEST")
        return true
    end

    if command == "PING" then
        acknowledge(id, "READY")
    elseif command == "SAVE" then
        log("Zapisuje swiat. Operacja " .. id .. ".")
        local saved, result = pcall(saveServer)
        if not saved then
            fail(id, "SAVE_FAILED")
        elseif result == false then
            fail(id, "SAVE_RETURNED_FALSE")
        else
            -- Some engine versions expose a void saveServer binding (nil).
            if acknowledge(id, "SAVE_DONE") then
                log("Zapis swiata zakonczony i potwierdzony. Operacja " .. id .. ".")
            end
        end
    elseif command == "SHUTDOWN" then
        if not Game or type(Game.setGameState) ~= "function" or GAME_STATE_SHUTDOWN == nil then
            fail(id, "SHUTDOWN_UNAVAILABLE")
        elseif acknowledge(id, "SHUTDOWN_ACCEPTED") then
            -- Publish and clear the claim first: the engine may exit in this call.
            local stopped, result = pcall(function() return Game.setGameState(GAME_STATE_SHUTDOWN) end)
            if not stopped or result == false then
                log("BLAD SHUTDOWN_FAILED")
                local published, failure = publishResponse(id, "ERROR", "SHUTDOWN_FAILED")
                if not published then log("BLAD " .. failure .. "; zatrzymanie nie zostalo potwierdzone.") end
            else
                log("Przyjeto bezpieczne zatrzymanie serwera. Operacja " .. id .. ".")
            end
        end
    else
        fail(id, "UNKNOWN_COMMAND")
    end
    return true
end
