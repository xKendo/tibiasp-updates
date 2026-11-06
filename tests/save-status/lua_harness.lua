local source, case = assert(arg[1]), assert(arg[2])
local open, rename, remove, originalPrint = io.open, os.rename, os.remove, print
local request = "data/tibiasp_launcher.request"
local processing = "data/tibiasp_launcher.processing"
local response = "data/tibiasp_launcher.response"
local id = "0123456789abcdef0123456789abcdef"
local oldId = "fedcba9876543210fedcba9876543210"
local saveCalls, stopCalls = 0, 0
local messages = {}
print = function(message) messages[#messages + 1] = message end
local function write(path, content)
    local f = assert(open(path, "wb")); assert(f:write(content)); assert(f:close())
end
local function read(path)
    local f = open(path, "rb")
    if not f then return nil end
    local value = f:read("*a"); assert(f:close()); return value
end
local function assertResponse(content) assert(read(response) == id .. " " .. content .. "\n", tostring(read(response))) end
local function command(value) write(request, value .. " " .. id .. "\n") end
local function loadHandler() assert(loadfile(source))() end
local function tick() assert(onThink(1000) == true) end
saveServer = function() saveCalls = saveCalls + 1; return true end
GAME_STATE_SHUTDOWN = 6
Game = {setGameState = function(state)
    stopCalls = stopCalls + 1
    assert(state == GAME_STATE_SHUTDOWN)
    assertResponse("SHUTDOWN_ACCEPTED")
    assert(read(processing) == nil, "claim must be cleared before potentially synchronous exit")
    return true
end}
loadHandler()

if case == "no_request" then
    tick(); assert(saveCalls == 0 and stopCalls == 0 and read(response) == nil)
elseif case == "ping" then
    command("PING"); tick(); assertResponse("READY")
    assert(saveCalls == 0 and stopCalls == 0 and read(processing) == nil and read(request) == nil)
elseif case == "save" then
    command("SAVE"); tick(); assertResponse("SAVE_DONE"); assert(saveCalls == 1)
    assert(read(processing) == nil and read(request) == nil)
elseif case == "void_save" then
    saveServer = function() saveCalls = saveCalls + 1 end
    command("SAVE"); tick(); assertResponse("SAVE_DONE"); assert(saveCalls == 1)
elseif case == "save_false" then
    saveServer = function() saveCalls = saveCalls + 1; return false end
    command("SAVE"); tick(); assertResponse("ERROR SAVE_RETURNED_FALSE"); assert(saveCalls == 1)
elseif case == "save_exception" then
    saveServer = function() saveCalls = saveCalls + 1; error("private\nmultiline detail") end
    command("SAVE"); tick(); assertResponse("ERROR SAVE_FAILED"); assert(saveCalls == 1)
elseif case == "shutdown" then
    command("SHUTDOWN"); tick(); assertResponse("SHUTDOWN_ACCEPTED"); assert(stopCalls == 1)
elseif case == "shutdown_false" or case == "shutdown_exception" then
    Game.setGameState = function()
        stopCalls = stopCalls + 1; assertResponse("SHUTDOWN_ACCEPTED")
        if case == "shutdown_exception" then error("simulated") end
        return false
    end
    command("SHUTDOWN"); tick(); assertResponse("ERROR SHUTDOWN_FAILED"); assert(stopCalls == 1)
elseif case == "shutdown_unavailable" then
    Game = nil; command("SHUTDOWN"); tick(); assertResponse("ERROR SHUTDOWN_UNAVAILABLE"); assert(stopCalls == 0)
elseif case == "legacy_request" or case == "empty_request" then
    write(request, case == "legacy_request" and "SAVE\n" or "")
    tick(); assert(saveCalls == 0 and stopCalls == 0 and read(response) == nil and read(processing) ~= nil)
    loadHandler(); tick(); assert(saveCalls == 0 and read(processing) ~= nil)
elseif case == "malformed_correlated" then
    write(request, "SAVE " .. id .. " unwanted\n"); tick(); assertResponse("ERROR MALFORMED_REQUEST"); assert(saveCalls == 0)
elseif case == "unknown_command" then
    command("DELETE"); tick(); assertResponse("ERROR UNKNOWN_COMMAND"); assert(saveCalls == 0 and stopCalls == 0)
elseif case == "oversized_request" then
    write(request, "SAVE " .. id .. " " .. string.rep("x", 200)); tick(); assertResponse("ERROR MALFORMED_REQUEST"); assert(saveCalls == 0)
elseif case == "crlf_request" then
    write(request, "PING " .. id .. "\r\n"); tick(); assertResponse("READY")
elseif case == "stale_processing" then
    write(processing, "SHUTDOWN " .. oldId .. "\n"); command("SAVE")
    tick(); tick(); loadHandler(); tick()
    assert(saveCalls == 0 and stopCalls == 0 and read(request) ~= nil and read(processing) ~= nil)
elseif case == "stale_response" then
    write(response, oldId .. " SAVE_DONE\n"); command("SAVE"); tick(); assertResponse("SAVE_DONE"); assert(saveCalls == 1)
elseif case == "atomic_response" then
    write(response, oldId .. " SAVE_DONE\n")
    local published = false
    os.rename = function(from, to)
        if to == response then
            assert(read(response) == oldId .. " SAVE_DONE\n")
            assert(read(from) == id .. " SAVE_DONE\n")
            published = true
        end
        return rename(from, to)
    end
    command("SAVE"); tick(); assert(published); assertResponse("SAVE_DONE")
elseif case == "request_claim_failure" then
    os.rename = function(from, to)
        if from == request then return nil, "injected", 13 end
        return rename(from, to)
    end
    command("SAVE"); tick(); tick(); assert(saveCalls == 0 and read(request) ~= nil and read(processing) == nil)
    assert(#messages == 1, "claim-failure logging must be rate limited")
elseif case == "processing_state_unknown" or case == "request_state_unknown" then
    io.open = function(path, mode)
        local target = case == "processing_state_unknown" and processing or request
        if path == target then return nil, "injected unknown errno" end
        return open(path, mode)
    end
    command("SAVE"); tick(); tick(); assert(saveCalls == 0 and read(request) ~= nil)
    assert(#messages == 1, "unknown-state logging must be rate limited")
elseif case == "request_read_failure" or case == "request_close_failure" then
    io.open = function(path, mode)
        local f, err, errno = open(path, mode)
        if f and path == processing and mode == "rb" then
            return {
                read = function(_, size)
                    if case == "request_read_failure" then return nil, "injected" end
                    return f:read(size)
                end,
                close = function()
                    local result = f:close()
                    if case == "request_close_failure" then return nil, "injected" end
                    return result
                end
            }
        end
        return f, err, errno
    end
    command("SAVE"); tick(); assert(saveCalls == 0 and read(processing) ~= nil and read(response) == nil)
elseif case == "processing_remove_failure" then
    os.remove = function(path)
        if path == processing then return nil, "injected", 13 end
        return remove(path)
    end
    command("SAVE"); tick(); assertResponse("ERROR PROCESSING_REMOVE_FAILED"); assert(saveCalls == 1 and read(processing) ~= nil)
    tick(); loadHandler(); tick(); assert(saveCalls == 1)
elseif case == "shutdown_remove_failure" then
    os.remove = function(path)
        if path == processing then return nil, "injected", 13 end
        return remove(path)
    end
    command("SHUTDOWN"); tick(); assertResponse("ERROR PROCESSING_REMOVE_FAILED"); assert(stopCalls == 0 and read(processing) ~= nil)
elseif case == "shutdown_response_failure" then
    io.open = function(path, mode)
        if path:match("tibiasp_launcher%.response%.") and mode == "wb" then return nil, "injected", 13 end
        return open(path, mode)
    end
    command("SHUTDOWN"); tick(); tick(); loadHandler(); tick()
    assert(stopCalls == 0 and read(processing) ~= nil and read(response) == nil)
elseif case:match("^response_.*_failure$") then
    write(response, oldId .. " SAVE_DONE\n")
    if case == "response_rename_failure" then
        os.rename = function(from, to)
            if to == response then return nil, "injected", 13 end
            return rename(from, to)
        end
    else
        io.open = function(path, mode)
            if path:match("tibiasp_launcher%.response%.") and mode == "wb" then
                if case == "response_open_failure" then return nil, "injected", 13 end
                local f = assert(open(path, mode))
                return {
                    write = function(_, content)
                        if case == "response_write_failure" then return nil, "injected" end
                        return f:write(content)
                    end,
                    flush = function()
                        if case == "response_flush_failure" then return nil, "injected" end
                        return f:flush()
                    end,
                    close = function()
                        local result = f:close()
                        if case == "response_close_failure" then return nil, "injected" end
                        return result
                    end
                }
            end
            return open(path, mode)
        end
    end
    command("SAVE"); tick()
    assert(saveCalls == 1 and read(processing) ~= nil)
    assert(read(response) == oldId .. " SAVE_DONE\n", "failed publication must preserve existing response")
    for _, message in ipairs(messages) do assert(not message:match("Save completed"), "false completion log") end
    command("SAVE"); tick(); loadHandler(); tick()
    assert(saveCalls == 1 and read(request) ~= nil, "failed response must never cause save replay")
elseif case == "new_request_during_save" then
    saveServer = function()
        saveCalls = saveCalls + 1; write(request, "PING " .. oldId .. "\n"); return true
    end
    command("SAVE"); tick(); assertResponse("SAVE_DONE"); assert(read(request) ~= nil)
    tick(); assert(read(response) == oldId .. " READY\n"); assert(saveCalls == 1)
else error("unknown test case " .. case) end

originalPrint("PASS " .. case)
