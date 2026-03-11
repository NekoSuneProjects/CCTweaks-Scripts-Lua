local dfpwm = require("cc.audio.dfpwm")
local APP_VERSION = "2026.03.11-1"

local PROTOCOL_SPEAKER = "jukebox_v2_speaker"

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

local function redraw(status)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Wireless Speaker Node v" .. APP_VERSION)
    print("ID: " .. os.getComputerID())
    print("Status: " .. status)
    print("Queue: " .. #queue)
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
    rednet.broadcast({
        type = "speaker_hello",
        name = os.getComputerLabel() or ("Speaker-" .. os.getComputerID()),
    }, PROTOCOL_SPEAKER)

    while not quitting do
        local id, msg, protocol = rednet.receive()
        if protocol == PROTOCOL_SPEAKER and type(msg) == "table" then
            if msg.type == "discover_speakers" then
                rednet.send(id, {
                    type = "speaker_hello",
                    name = os.getComputerLabel() or ("Speaker-" .. os.getComputerID()),
                }, PROTOCOL_SPEAKER)
            elseif msg.type == "audio_chunk" then
                enqueueChunk(msg)
                redraw("Playing")
            elseif msg.type == "stop" then
                activeSession = msg.session or (activeSession + 1)
                queue = {}
                speaker.stop()
                redraw("Stopped")
            end
        end
    end
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
        if key == keys.q or key == keys.backspace then
            quitting = true
            queue = {}
            speaker.stop()
            redraw("Closed")
            return
        end
    end
end

parallel.waitForAny(rednetLoop, audioLoop, keyboardLoop)
