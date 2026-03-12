local dfpwm = require("cc.audio.dfpwm")
local APP_VERSION = "2026.03.12-7"

local PROTOCOL_SPEAKER = "jukebox_v2_speaker"
local DATA_FILE = "/speaker_node_pair.db"
local MAX_QUEUE = 4
local BOOT_SOUND_URL = "https://ipfs.ballisticok.xyz/ipfs/QmcdBJ6RRTiLvChbSA9RS8aaFF2QQCfchzKFuyUX6GQoAh"
local PAIRED_SOUND_URL = "https://ipfs.ballisticok.xyz/ipfs/QmXQmJ8SiKLWg9cJ6AuWvgxz7KYrCi3pkNHFV41DSUyVGv"

local speaker = peripheral.find("speaker")
local modemName = peripheral.find("modem", function(name, modem)
    return modem.isWireless == nil or modem.isWireless()
end)

if not speaker then error("No speaker attached.") end
if not modemName then error("Wireless modem required.") end

rednet.open(peripheral.getName(modemName))

local decoder = dfpwm.make_decoder()
local queue = {}
local activeSession = 0
local quitting = false
local lastChunkAt = 0
local nodeStatus = "Waiting"
local currentVolume = 1
local pairData = {
    jukeboxId = nil,
    jukeboxName = nil,
}

local function sendHello()
    if not pairData.jukeboxId then
        return
    end

    rednet.send(pairData.jukeboxId, {
        type = "speaker_hello",
        name = os.getComputerLabel() or ("Speaker-" .. os.getComputerID()),
    }, PROTOCOL_SPEAKER)
end

local function savePairData()
    local handle = fs.open(DATA_FILE, "w")
    if not handle then
        return
    end

    handle.write(textutils.serialize(pairData))
    handle.close()
end

local function loadPairData()
    if not fs.exists(DATA_FILE) then
        return
    end

    local handle = fs.open(DATA_FILE, "r")
    if not handle then
        return
    end

    pairData = textutils.unserialize(handle.readAll()) or pairData
    handle.close()
end

local function trim(value)
    value = tostring(value or "")
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function playUrlOnce(url, volume)
    if not http or type(url) ~= "string" or url == "" then
        return false
    end

    local response = http.get(url, nil, true)
    if not response then
        return false
    end

    local streamDecoder = dfpwm.make_decoder()
    speaker.stop()

    while true do
        local chunk = response.read(16 * 1024)
        if not chunk then
            break
        end

        local buffer = streamDecoder(chunk)
        while not speaker.playAudio(buffer, volume or currentVolume) do
            local event = { os.pullEvent() }
            if event[1] == "terminate" then
                response.close()
                error("Terminated")
            end
        end
    end

    response.close()

    local drainTimer = os.startTimer(0.2)
    while true do
        local event = { os.pullEvent() }
        if event[1] == "speaker_audio_empty" then
            break
        elseif event[1] == "timer" and event[2] == drainTimer then
            break
        elseif event[1] == "terminate" then
            error("Terminated")
        end
    end

    return true
end

local function redraw(status)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Wireless Speaker Node v" .. APP_VERSION)
    print("ID: " .. os.getComputerID())
    print("Status: " .. status)
    print("Paired: " .. (pairData.jukeboxName or "None"))
    print("Queue: " .. #queue)
    print("P = Pair  U = Unpair")
    print("Q/Back = Exit")
end

local function resetPlaybackState(session, status)
    queue = {}
    activeSession = session or 0
    decoder = dfpwm.make_decoder()
    speaker.stop()
    nodeStatus = status or "Waiting"
    if status then
        redraw(status)
    end
end

local function enqueueChunk(msg)
    if type(msg.chunk) ~= "string" then
        return
    end

    if msg.session ~= activeSession then
        resetPlaybackState(msg.session or 0)
    end

    if #queue >= MAX_QUEUE then
        -- Drop stale buffered chunks so the node resyncs near-live instead of trailing behind.
        while #queue >= MAX_QUEUE do
            table.remove(queue, 1)
        end
    end

    queue[#queue + 1] = msg.chunk
    lastChunkAt = os.clock()
    if #queue > 1 then
        nodeStatus = "Queue stuck"
    else
        nodeStatus = "Playing"
    end
end

local function sendStatus()
    if not pairData.jukeboxId then
        return
    end

    rednet.send(pairData.jukeboxId, {
        type = "speaker_status",
        name = os.getComputerLabel() or ("Speaker-" .. os.getComputerID()),
        queueSize = #queue,
        status = nodeStatus,
        lastChunkAt = lastChunkAt,
        volume = currentVolume,
        version = APP_VERSION,
    }, PROTOCOL_SPEAKER)
end

local function rednetLoop()
    redraw("Waiting")
    if pairData.jukeboxId then
        sendHello()
        sendStatus()
    end

    while not quitting do
        local id, msg, protocol = rednet.receive()
        if protocol == PROTOCOL_SPEAKER and type(msg) == "table" then
            if msg.type == "discover_speakers" then
                if pairData.jukeboxId and msg.playerId == pairData.jukeboxId then
                    sendHello()
                    sendStatus()
                end
            elseif msg.type == "audio_chunk" then
                if id == pairData.jukeboxId then
                    currentVolume = tonumber(msg.volume) or currentVolume
                    enqueueChunk(msg)
                    redraw(nodeStatus)
                    sendStatus()
                end
            elseif msg.type == "stop" then
                if id == pairData.jukeboxId then
                    resetPlaybackState(msg.session or (activeSession + 1), "Stopped")
                    sendStatus()
                end
            elseif msg.type == "restart" then
                if id == pairData.jukeboxId then
                    resetPlaybackState(msg.session or (activeSession + 1), "Restarting")
                    sendStatus()
                    sleep(0.5)
                    os.reboot()
                end
            end
        end
    end
end

local function discoverJukeboxes()
    rednet.broadcast({ type = "discover" }, "jukebox_v2_discovery")

    local found = {}
    local timer = os.startTimer(1.5)

    while true do
        local event = { os.pullEvent() }
        if event[1] == "rednet_message" then
            local id, msg, protocol = event[2], event[3], event[4]
            if protocol == "jukebox_v2_discovery" and type(msg) == "table" and msg.type == "discover_reply" then
                local exists = false
                for _, item in ipairs(found) do
                    if item.id == id then
                        exists = true
                        break
                    end
                end

                if not exists then
                    found[#found + 1] = {
                        id = id,
                        name = msg.playerName or ("Jukebox-" .. id),
                    }
                end
            end
        elseif event[1] == "timer" and event[2] == timer then
            break
        end
    end

    return found
end

local function pairMenu()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Pair Speaker")
    print("")
    print("Scanning...")

    local list = discoverJukeboxes()
    if #list == 0 then
        print("")
        print("No jukebox found")
        sleep(2)
        redraw("Waiting")
        return
    end

    term.clear()
    term.setCursorPos(1, 1)
    print("Pair Speaker")
    print("")
    for i, item in ipairs(list) do
        print(i .. ") " .. item.name .. " [" .. item.id .. "]")
    end

    print("")
    print("Choose number:")
    local pick = tonumber(read())
    if not pick or not list[pick] then
        redraw("Waiting")
        return
    end

    print("Enter pair code:")
    local code = trim(read())

    rednet.send(list[pick].id, {
        type = "speaker_pair_request",
        code = code,
        name = os.getComputerLabel() or ("Speaker-" .. os.getComputerID()),
    }, PROTOCOL_SPEAKER)

    print("Pairing...")
    local deadline = os.clock() + 4

    while os.clock() < deadline do
        local remaining = math.max(0, deadline - os.clock())
        local id, msg, protocol = rednet.receive(PROTOCOL_SPEAKER, remaining)

        if id and protocol == PROTOCOL_SPEAKER and id == list[pick].id and type(msg) == "table" and msg.type == "speaker_pair_reply" then
            if msg.ok then
                pairData.jukeboxId = list[pick].id
                pairData.jukeboxName = list[pick].name
                savePairData()
                pcall(playUrlOnce, PAIRED_SOUND_URL, currentVolume)
                sendHello()
                sendStatus()
                print("Paired with " .. list[pick].name)
                sleep(1)
                redraw("Waiting")
                return
            end

            print(msg.reason or "Pair failed")
            sleep(2)
            redraw("Waiting")
            return
        end
    end

    print("No pair reply from jukebox")
    sleep(2)
    redraw("Waiting")
end

local function unpair()
    pairData.jukeboxId = nil
    pairData.jukeboxName = nil
    resetPlaybackState(0)
    savePairData()
    redraw("Unpaired")
end

local function audioLoop()
    while not quitting do
        if #queue == 0 then
            sleep(0.05)
        else
            local chunk = table.remove(queue, 1)
            local buffer = decoder(chunk)
            while not speaker.playAudio(buffer, currentVolume) do
                local event, side = os.pullEvent("speaker_audio_empty")
                if side then
                    -- continue
                end
                if quitting then
                    return
                end
            end
            if #queue <= 1 and nodeStatus ~= "Stopped" then
                nodeStatus = (#queue == 0) and "Waiting" or "Playing"
            end
            sendStatus()
        end
    end
end

local function statusLoop()
    while not quitting do
        sleep(2)
        sendHello()
        sendStatus()
    end
end

local function keyboardLoop()
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.p then
            pairMenu()
        elseif key == keys.u then
            unpair()
        elseif key == keys.q or key == keys.backspace then
            quitting = true
            resetPlaybackState(activeSession)
            redraw("Closed")
            return
        end
    end
end

loadPairData()
pcall(playUrlOnce, BOOT_SOUND_URL, currentVolume)
parallel.waitForAny(rednetLoop, audioLoop, keyboardLoop, statusLoop)
