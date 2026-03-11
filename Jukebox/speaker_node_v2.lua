local dfpwm = require("cc.audio.dfpwm")
local APP_VERSION = "2026.03.11-2"

local PROTOCOL_SPEAKER = "jukebox_v2_speaker"
local DATA_FILE = "/speaker_node_pair.db"

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
local pairData = {
    jukeboxId = nil,
    jukeboxName = nil,
}

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

local function enqueueChunk(msg)
    if type(msg.chunk) ~= "string" then
        return
    end

    if msg.session ~= activeSession then
        queue = {}
        activeSession = msg.session or 0
    end

    queue[#queue + 1] = msg.chunk
end

local function rednetLoop()
    redraw("Waiting")
    if pairData.jukeboxId then
        rednet.send(pairData.jukeboxId, {
            type = "speaker_hello",
            name = os.getComputerLabel() or ("Speaker-" .. os.getComputerID()),
        }, PROTOCOL_SPEAKER)
    end

    while not quitting do
        local id, msg, protocol = rednet.receive()
        if protocol == PROTOCOL_SPEAKER and type(msg) == "table" then
            if msg.type == "discover_speakers" then
                if pairData.jukeboxId and msg.playerId == pairData.jukeboxId then
                    rednet.send(id, {
                        type = "speaker_hello",
                        name = os.getComputerLabel() or ("Speaker-" .. os.getComputerID()),
                    }, PROTOCOL_SPEAKER)
                end
            elseif msg.type == "audio_chunk" then
                if id == pairData.jukeboxId then
                    enqueueChunk(msg)
                    redraw("Playing")
                end
            elseif msg.type == "stop" then
                if id == pairData.jukeboxId then
                    activeSession = msg.session or (activeSession + 1)
                    queue = {}
                    speaker.stop()
                    redraw("Stopped")
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
                rednet.send(pairData.jukeboxId, {
                    type = "speaker_hello",
                    name = os.getComputerLabel() or ("Speaker-" .. os.getComputerID()),
                }, PROTOCOL_SPEAKER)
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
    queue = {}
    speaker.stop()
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
            while not speaker.playAudio(buffer) do
                local event, side = os.pullEvent("speaker_audio_empty")
                if side then
                    -- continue
                end
                if quitting then
                    return
                end
            end
        end
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
            queue = {}
            speaker.stop()
            redraw("Closed")
            return
        end
    end
end

loadPairData()
parallel.waitForAny(rednetLoop, audioLoop, keyboardLoop)
