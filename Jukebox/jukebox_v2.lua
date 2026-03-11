local dfpwm = require("cc.audio.dfpwm")
local APP_VERSION = "2026.03.11-1"

local PROTOCOL_DISCOVERY = "jukebox_v2_discovery"
local PROTOCOL_CONTROL   = "jukebox_v2_control"
local PROTOCOL_STATE     = "jukebox_v2_state"
local PROTOCOL_SPEAKER   = "jukebox_v2_speaker"

local DATA_DIR      = "/jukebox_v2"
local MUSIC_DIR     = "/disk/music"
local PLAYLIST_FILE = fs.combine(DATA_DIR, "playlist.db")
local CONFIG_FILE   = fs.combine(DATA_DIR, "config.db")
local API_BASE_URL  = "https://ipod-2to6magyna-uc.a.run.app/"
local API_VERSION   = "2.1"

local monitor = peripheral.find("monitor")
local speaker = peripheral.find("speaker")
local modemName = peripheral.find("modem", function(name, modem)
    return modem.isWireless == nil or modem.isWireless()
end)

if not monitor then error("No monitor attached.") end
if not speaker then error("No speaker attached.") end
if not modemName then error("No modem attached.") end

rednet.open(peripheral.getName(modemName))

if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
if not fs.exists(MUSIC_DIR) then fs.makeDir(MUSIC_DIR) end

monitor.setTextScale(0.5)
monitor.setBackgroundColor(colors.black)
monitor.setTextColor(colors.white)

local UI = {
    header = colors.gray,
    subHeader = colors.lightGray,
    panel = colors.gray,
    panelDark = colors.black,
    playing = colors.green,
    selected = colors.blue,
    idle = colors.black,
    text = colors.white,
    dim = colors.lightGray,
    accent = colors.cyan,
    progressBg = colors.gray,
    progressFill = colors.lime,
    buttonPlay = colors.lime,
    buttonStop = colors.red,
    buttonNext = colors.orange,
    buttonPrev = colors.orange,
    buttonAdd = colors.cyan,
    buttonDelete = colors.purple,
    buttonPair = colors.yellow,
}

local config = {
    playerName = os.getComputerLabel() or ("Jukebox-" .. os.getComputerID()),
    pairCode = tostring(math.random(1000, 9999)),
    pairedRemotes = {},
    pairedSpeakers = {}
}

local playlist = {}
local currentIndex = 1
local selectedIndex = 1
local nowPlaying = "Nothing"
local statusText = "Stopped"
local playing = false
local stopRequested = false
local version = 0
local lastProgressTick = os.clock()
local playSession = 0
local playRequestId = 0

local buttonMap = {}
local uiDirty = true
local stopPlayback, playSelected, nextSong, prevSong
local speakerNodes = {}

local function exitApp()
    stopPlayback()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Closing Jukebox...")
    sleep(0.5)
end

local function saveTable(path, tbl)
    local h = fs.open(path, "w")
    if not h then error("Failed to save " .. path) end
    h.write(textutils.serialize(tbl))
    h.close()
end

local function loadTable(path, fallback)
    if not fs.exists(path) then return fallback end
    local h = fs.open(path, "r")
    if not h then return fallback end
    local raw = h.readAll()
    h.close()
    local data = textutils.unserialize(raw)
    if type(data) == "table" then return data end
    return fallback
end

local function saveConfig() saveTable(CONFIG_FILE, config) end
local function savePlaylist() saveTable(PLAYLIST_FILE, playlist) end

local function loadData()
    config = loadTable(CONFIG_FILE, config)
    playlist = loadTable(PLAYLIST_FILE, playlist)

    if type(config.playerName) ~= "string" or config.playerName == "" then
        config.playerName = os.getComputerLabel() or ("Jukebox-" .. os.getComputerID())
    end

    if type(config.pairCode) ~= "string" or config.pairCode == "" then
        config.pairCode = tostring(math.random(1000, 9999))
    end

    if type(config.pairedRemotes) ~= "table" then
        config.pairedRemotes = {}
    end

    if type(config.pairedSpeakers) ~= "table" then
        config.pairedSpeakers = {}
    end
end

local function clampIndices()
    if #playlist == 0 then
        currentIndex = 1
        selectedIndex = 1
        return
    end

    if currentIndex < 1 then currentIndex = #playlist end
    if currentIndex > #playlist then currentIndex = 1 end
    if selectedIndex < 1 then selectedIndex = 1 end
    if selectedIndex > #playlist then selectedIndex = #playlist end
end

local function markDirty()
    version = version + 1
    uiDirty = true
end

local function trimText(text, maxLen)
    text = tostring(text or "")
    if #text <= maxLen then return text end
    if maxLen <= 3 then return text:sub(1, maxLen) end
    return text:sub(1, maxLen - 3) .. "..."
end

local function drawFilledLine(y, bg)
    local w = monitor.getSize()
    monitor.setBackgroundColor(bg)
    monitor.setCursorPos(1, y)
    monitor.write(string.rep(" ", w))
end

local function drawText(x, y, text, fg, bg)
    if bg then monitor.setBackgroundColor(bg) end
    if fg then monitor.setTextColor(fg) end
    monitor.setCursorPos(x, y)
    monitor.write(text)
end

local function mapArea(name, x1, y1, x2, y2)
    for y = y1, y2 do
        buttonMap[y] = buttonMap[y] or {}
        for x = x1, x2 do
            buttonMap[y][x] = name
        end
    end
end

local function addButton(name, x1, y1, x2, y2, bg, fg, label)
    monitor.setBackgroundColor(bg)
    monitor.setTextColor(fg)

    for y = y1, y2 do
        monitor.setCursorPos(x1, y)
        monitor.write(string.rep(" ", x2 - x1 + 1))
    end

    local tx = math.max(x1, math.floor((x1 + x2 - #label) / 2))
    local ty = math.floor((y1 + y2) / 2)
    monitor.setCursorPos(tx, ty)
    monitor.write(label)

    mapArea(name, x1, y1, x2, y2)
end

local function getStatePayload()
    return {
        type = "state",
        playerId = os.getComputerID(),
        playerName = config.playerName,
        playing = playing,
        status = statusText,
        nowPlaying = nowPlaying,
        currentIndex = currentIndex,
        selectedIndex = selectedIndex,
        count = #playlist,
        playlist = playlist,
        pairCode = config.pairCode,
        version = version,
    }
end

local function broadcastStateToPaired()
    local payload = getStatePayload()
    for idStr, _ in pairs(config.pairedRemotes) do
        rednet.send(tonumber(idStr), payload, PROTOCOL_STATE)
    end
end

local function trim(value)
    value = tostring(value or "")
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function queueSpeakerDiscovery()
    rednet.broadcast({
        type = "discover_speakers",
        playerId = os.getComputerID(),
    }, PROTOCOL_SPEAKER)
end

local function rememberSpeakerNode(id, name)
    if config.pairedSpeakers[tostring(id)] ~= true then
        return
    end

    speakerNodes[tostring(id)] = {
        id = id,
        name = name or ("Speaker-" .. id),
        seenAt = os.clock()
    }
end

local function pairSpeakerNode(id)
    config.pairedSpeakers[tostring(id)] = true
    saveConfig()
    markDirty()
end

local function getSpeakerCount()
    local count = 0
    for _ in pairs(speakerNodes) do
        count = count + 1
    end
    return count
end

local function cleanupSpeakerNodes()
    local now = os.clock()
    for idStr, node in pairs(speakerNodes) do
        if now - (node.seenAt or 0) > 60 then
            speakerNodes[idStr] = nil
        end
    end
end

local function buildApiUrl(params)
    local out = API_BASE_URL .. "?v=" .. textutils.urlEncode(API_VERSION)
    for key, value in pairs(params) do
        out = out .. "&" .. textutils.urlEncode(key) .. "=" .. textutils.urlEncode(tostring(value))
    end
    return out
end

local function fetchJson(url)
    if not http then
        return nil, "HTTP API is disabled"
    end

    local response, err = http.get(url, nil, true)
    if not response then
        return nil, tostring(err or "Request failed")
    end

    local raw = response.readAll()
    response.close()

    local data = textutils.unserialiseJSON(raw)
    if type(data) ~= "table" then
        return nil, "Invalid JSON response"
    end

    return data
end

local function normalizeYoutubeItem(item)
    if type(item) ~= "table" then
        return nil
    end

    if type(item.id) ~= "string" or item.id == "" then
        return nil
    end

    return {
        name = item.name or item.title or "Unknown",
        artist = item.artist or item.channel or "YouTube",
        ytId = item.id,
        source = "youtube"
    }
end

local function addYoutubeEntries(results, index)
    local chosen = results[index]
    if not chosen then
        return false, "Invalid selection"
    end

    local added = 0

    if chosen.type == "playlist" and type(chosen.playlist_items) == "table" then
        for _, item in ipairs(chosen.playlist_items) do
            local entry = normalizeYoutubeItem(item)
            if entry then
                table.insert(playlist, entry)
                added = added + 1
            end
        end
    else
        local entry = normalizeYoutubeItem(chosen)
        if entry then
            table.insert(playlist, entry)
            added = 1
        end
    end

    if added == 0 then
        return false, "Nothing addable in result"
    end

    savePlaylist()
    selectedIndex = #playlist
    currentIndex = selectedIndex
    markDirty()
    broadcastStateToPaired()
    return true, added
end

local function addYoutubeFromTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)

    print("YouTube Search / Link")
    print("")
    print("Enter search text or YouTube URL:")
    local query = read()

    if not query or query == "" then
        markDirty()
        return
    end

    print("")
    print("Searching...")

    local results, err = fetchJson(buildApiUrl({ search = query }))
    if not results then
        print("")
        print("Search failed: " .. err)
        sleep(2)
        markDirty()
        return
    end

    if #results == 0 then
        print("")
        print("No results")
        sleep(1.5)
        markDirty()
        return
    end

    term.clear()
    term.setCursorPos(1, 1)
    print("YouTube Results")
    print("")

    for i, item in ipairs(results) do
        local kind = item.type == "playlist" and "[LIST]" or "[YT]"
        local artist = item.artist or item.channel or "YouTube"
        print(string.format("%d) %s %s", i, kind, item.name or item.title or "Unknown"))
        print("   " .. artist)
        if i >= 8 then
            break
        end
    end

    print("")
    print("Choose number:")
    local pick = tonumber(read())
    local ok, info = addYoutubeEntries(results, pick)

    if ok then
        print("")
        print("Added " .. tostring(info) .. " track(s)")
    else
        print("")
        print("Add failed: " .. tostring(info))
    end

    sleep(1.5)
end

local function sendStateToRemote(id)
    rednet.send(id, getStatePayload(), PROTOCOL_STATE)
end

local function isPairedRemote(id)
    return config.pairedRemotes[tostring(id)] == true
end

local function pairRemote(id)
    config.pairedRemotes[tostring(id)] = true
    saveConfig()
    markDirty()
end

local function handleRemoteCommand(id, msg)
    if not isPairedRemote(id) then
        return
    end

    if type(msg) ~= "table" or msg.type ~= "command" then
        return
    end

    if msg.targetId and msg.targetId ~= os.getComputerID() then
        return
    end

    if msg.action == "play" then
        playSelected()
    elseif msg.action == "stop" then
        stopPlayback()
    elseif msg.action == "next" then
        nextSong()
    elseif msg.action == "prev" then
        prevSong()
    elseif msg.action == "select" then
        local idx = tonumber(msg.index)
        if idx and playlist[idx] then
            selectedIndex = idx
            markDirty()
            broadcastStateToPaired()
        end
    elseif msg.action == "request_state" then
        sendStateToRemote(id)
    end
end

local function deleteSelectedSong()
    if #playlist == 0 then return end
    table.remove(playlist, selectedIndex)
    clampIndices()
    savePlaylist()
    markDirty()
    broadcastStateToPaired()
end

local function newPairCode()
    config.pairCode = tostring(math.random(1000, 9999))
    saveConfig()
    markDirty()
    broadcastStateToPaired()
end

local function getProgressValue()
    if not playing then return 0 end
    local cycle = 8
    local t = os.clock() - lastProgressTick
    local v = (t % cycle) / cycle
    return v
end

local function drawUI()
    uiDirty = false
    buttonMap = {}

    local w, h = monitor.getSize()
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    drawFilledLine(1, UI.header)
    drawText(2, 1, trimText("? " .. config.playerName, math.max(1, w - 16)), colors.black, UI.header)
    drawText(math.max(2, w - 24), 1, "v" .. APP_VERSION, colors.black, UI.header)
    drawText(math.max(2, w - 10), 1, "ID:" .. os.getComputerID(), colors.black, UI.header)

    drawFilledLine(2, UI.subHeader)
    drawText(2, 2, "Pair:" .. config.pairCode, colors.black, UI.subHeader)
    drawText(math.max(2, w - 16), 2, "Songs:" .. #playlist, colors.black, UI.subHeader)
    drawText(math.max(2, w - 33), 2, "Speakers:" .. getSpeakerCount(), colors.black, UI.subHeader)

    drawFilledLine(3, UI.panelDark)
    drawText(2, 3, "Status:", UI.dim, UI.panelDark)
    drawText(10, 3, trimText(statusText, math.max(1, w - 24)), UI.text, UI.panelDark)
    drawText(math.max(2, w - 12), 3, "Q/Back Exit", UI.dim, UI.panelDark)

    drawFilledLine(4, UI.panelDark)
    drawText(2, 4, "Now:", UI.accent, UI.panelDark)
    drawText(7, 4, trimText(nowPlaying, math.max(1, w - 8)), UI.text, UI.panelDark)

    drawFilledLine(5, UI.panelDark)
    drawText(2, 5, "Selected:", UI.dim, UI.panelDark)
    local selectedName = (#playlist > 0 and playlist[selectedIndex] and playlist[selectedIndex].name) or "None"
    drawText(12, 5, trimText(selectedName, math.max(1, w - 13)), UI.text, UI.panelDark)

    drawFilledLine(6, UI.panelDark)
    local barX = 2
    local barY = 6
    local barW = math.max(10, w - 4)
    local fill = math.floor(barW * getProgressValue())

    monitor.setBackgroundColor(UI.progressBg)
    monitor.setCursorPos(barX, barY)
    monitor.write(string.rep(" ", barW))

    if fill > 0 then
        monitor.setBackgroundColor(UI.progressFill)
        monitor.setCursorPos(barX, barY)
        monitor.write(string.rep(" ", fill))
    end

    monitor.setBackgroundColor(UI.panelDark)
    monitor.setTextColor(colors.black)
    local label = playing and " PLAYING " or " STOPPED "
    local labelX = math.max(2, math.floor((w - #label) / 2))
    monitor.setCursorPos(labelX, barY)
    monitor.write(label)

    local listTop = 8
    local listBottom = h - 4
    local rows = math.max(1, listBottom - listTop + 1)

    local startIndex = 1
    if selectedIndex > rows then
        startIndex = selectedIndex - rows + 1
    end

    for row = 0, rows - 1 do
        local idx = startIndex + row
        local y = listTop + row
        local bg = UI.idle
        local fg = UI.text

        drawFilledLine(y, bg)

        if playlist[idx] then
            if idx == currentIndex and playing then
                bg = UI.playing
                fg = colors.black
            elseif idx == selectedIndex then
                bg = UI.selected
                fg = colors.white
            end

            drawFilledLine(y, bg)
            monitor.setBackgroundColor(bg)
            monitor.setTextColor(fg)
            monitor.setCursorPos(2, y)

            local sourceTag = "[FILE] "
            if playlist[idx].ytId then
                sourceTag = "[YT] "
            elseif playlist[idx].url then
                sourceTag = "[URL] "
            end
            local line = string.format("%02d %s%s", idx, sourceTag, playlist[idx].name or "Unknown")
            monitor.write(trimText(line, math.max(1, w - 2)))

            mapArea("song:" .. idx, 1, y, w, y)
        end
    end

    local by = h - 2
    local x = 2
    addButton("prev",   x, by, x + 6, by + 1, UI.buttonPrev,   colors.black, "Prev")
    x = x + 8
    addButton("play",   x, by, x + 6, by + 1, UI.buttonPlay,   colors.black, "Play")
    x = x + 8
    addButton("stop",   x, by, x + 6, by + 1, UI.buttonStop,   colors.white, "Stop")
    x = x + 8
    addButton("next",   x, by, x + 6, by + 1, UI.buttonNext,   colors.black, "Next")
    x = x + 8
    addButton("add",    x, by, x + 6, by + 1, UI.buttonAdd,    colors.black, "Add")
    x = x + 8
    addButton("delete", x, by, x + 8, by + 1, UI.buttonDelete, colors.white, "Delete")
    x = x + 10
    addButton("pair",   x, by, x + 8, by + 1, UI.buttonPair,   colors.black, "NewCode")
end

local function broadcastSpeakerChunk(chunk)
    cleanupSpeakerNodes()
    for idStr, node in pairs(speakerNodes) do
        local ok = rednet.send(tonumber(idStr), {
            type = "audio_chunk",
            session = playSession,
            chunk = chunk,
        }, PROTOCOL_SPEAKER)

        if not ok then
            speakerNodes[idStr] = nil
        else
            node.seenAt = os.clock()
        end
    end
end

local function stopSpeakerNodes()
    for idStr in pairs(speakerNodes) do
        rednet.send(tonumber(idStr), {
            type = "stop",
            session = playSession,
        }, PROTOCOL_SPEAKER)
    end
end

local function interruptPlayback()
    playRequestId = playRequestId + 1
    stopRequested = true
    speaker.stop()
    stopSpeakerNodes()
    os.queueEvent("jukebox_interrupt", playRequestId)
end

local function playBuffer(buffer, requestId)
    while not speaker.playAudio(buffer) do
        os.pullEvent()
        if playRequestId ~= requestId or stopRequested then
            return false
        end
    end

    return playRequestId == requestId and not stopRequested
end

local function waitForPlaybackDrain(requestId)
    while playRequestId == requestId and not stopRequested do
        local ev = { os.pullEvent() }
        if playRequestId ~= requestId or stopRequested then
            return false
        end

        if ev[1] == "speaker_audio_empty" then
            return true
        end
    end

    return false
end

local function playTrack(song)
    local decoder = dfpwm.make_decoder()
    local requestId = playRequestId
    stopRequested = false
    playSession = playSession + 1
    nowPlaying = song.name or "Unknown"
    statusText = "Playing"
    lastProgressTick = os.clock()
    markDirty()
    broadcastStateToPaired()
    queueSpeakerDiscovery()

    local streamUrl = nil
    if song.ytId then
        streamUrl = buildApiUrl({ id = song.ytId })
    elseif song.url then
        streamUrl = song.url
    end

    if streamUrl then
        local response = http.get(streamUrl, nil, true)

        if not response then
            statusText = "Stream failed"
            playing = false
            nowPlaying = song.name or "Unknown"
            markDirty()
            broadcastStateToPaired()
            return
        end

        while true do
            if stopRequested or playRequestId ~= requestId then break end

            local chunk = response.read(16 * 1024)
            if not chunk then break end

            broadcastSpeakerChunk(chunk)
            local buffer = decoder(chunk)
            if not playBuffer(buffer, requestId) then break end

            if stopRequested or playRequestId ~= requestId then break end
        end

        response.close()

    elseif song.path then
        if not fs.exists(song.path) then
            statusText = "Missing file"
            playing = false
            nowPlaying = song.name or "Missing"
            markDirty()
            broadcastStateToPaired()
            return
        end

        local file = fs.open(song.path, "rb")
        if not file then
            statusText = "Open failed"
            playing = false
            nowPlaying = song.name or "Unknown"
            markDirty()
            broadcastStateToPaired()
            return
        end

        while true do
            if stopRequested or playRequestId ~= requestId then break end

            local chunk = file.read(16 * 1024)
            if not chunk then break end

            broadcastSpeakerChunk(chunk)
            local buffer = decoder(chunk)
            if not playBuffer(buffer, requestId) then break end

            if stopRequested or playRequestId ~= requestId then break end
        end

        file.close()
    else
        statusText = "Invalid track"
        playing = false
        nowPlaying = "Nothing"
        markDirty()
        broadcastStateToPaired()
        return
    end

    if stopRequested or playRequestId ~= requestId then
        return
    end

    waitForPlaybackDrain(requestId)

    if stopRequested or playRequestId ~= requestId then
        return
    end

    if playing and #playlist > 0 then
        currentIndex = currentIndex + 1
        if currentIndex > #playlist then currentIndex = 1 end
        selectedIndex = currentIndex
        markDirty()
        broadcastStateToPaired()
    end
end

local function addSongFromTerminal()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)

    print("Add Song")

    print("")
    print("1 = Local .dfpwm file")
    print("2 = Stream URL")
    print("3 = YouTube search / URL")
    print("")
    print("Choose mode:")
    local mode = read()

    if mode == "1" then
        print("")
        print("Song name:")
        local name = read()
        if not name or name == "" then
            markDirty()
            return
        end

        print("")
        print("Enter .dfpwm path:")
        local path = read()

        if not path or path == "" then
            markDirty()
            return
        end

        if not fs.exists(path) then
            print("")
            print("File not found.")
            sleep(1.5)
            markDirty()
            return
        end

        table.insert(playlist, {
            name = name,
            path = path
        })

    elseif mode == "2" then
        print("")
        print("Song name:")
        local name = read()
        if not name or name == "" then
            markDirty()
            return
        end

        print("")
        print("Enter stream URL:")
        local url = read()

        if not url or url == "" then
            markDirty()
            return
        end

        table.insert(playlist, {
            name = name,
            url = url
        })
    elseif mode == "3" then
        addYoutubeFromTerminal()
        return
    else
        print("")
        print("Invalid mode.")
        sleep(1.5)
        markDirty()
        return
    end

    savePlaylist()
    selectedIndex = #playlist
    currentIndex = selectedIndex
    markDirty()
    broadcastStateToPaired()
end

stopPlayback = function()
    interruptPlayback()
    playSession = playSession + 1
    playing = false
    statusText = "Stopped"
    nowPlaying = "Nothing"
    markDirty()
    broadcastStateToPaired()
end

playSelected = function()
    if #playlist == 0 then return end
    interruptPlayback()
    currentIndex = selectedIndex
    playing = true
    statusText = "Starting"
    lastProgressTick = os.clock()
    markDirty()
    broadcastStateToPaired()
end

nextSong = function()
    if #playlist == 0 then return end
    interruptPlayback()
    currentIndex = currentIndex + 1
    clampIndices()
    selectedIndex = currentIndex
    playing = true
    statusText = "Next"
    lastProgressTick = os.clock()
    markDirty()
    broadcastStateToPaired()
end

prevSong = function()
    if #playlist == 0 then return end
    interruptPlayback()
    currentIndex = currentIndex - 1
    clampIndices()
    selectedIndex = currentIndex
    playing = true
    statusText = "Prev"
    lastProgressTick = os.clock()
    markDirty()
    broadcastStateToPaired()
end

local function audioLoop()
    while true do
        clampIndices()

        if playing and playlist[currentIndex] then
            playTrack(playlist[currentIndex])
        else
            sleep(0.1)
        end

        if #playlist == 0 and playing then
            playing = false
            statusText = "No songs"
            nowPlaying = "Nothing"
            markDirty()
            broadcastStateToPaired()
        end
    end
end

local function monitorLoop()
    while true do
        if uiDirty then drawUI() end

        local _, side, x, y = os.pullEvent("monitor_touch")
        local hit = buttonMap[y] and buttonMap[y][x]

        if not hit then
            -- ignore
        elseif hit:sub(1, 5) == "song:" then
            local idx = tonumber(hit:sub(6))
            if idx and playlist[idx] then
                selectedIndex = idx
                markDirty()
                broadcastStateToPaired()
            end
        elseif hit == "play" then
            playSelected()
        elseif hit == "stop" then
            stopPlayback()
        elseif hit == "next" then
            nextSong()
        elseif hit == "prev" then
            prevSong()
        elseif hit == "add" then
            addSongFromTerminal()
        elseif hit == "delete" then
            deleteSelectedSong()
        elseif hit == "pair" then
            newPairCode()
        end
    end
end

local function uiLoop()
    while true do
        sleep(0.2)
        if playing then
            uiDirty = true
            drawUI()
        end
    end
end

local function keyboardLoop()
    while true do
        local _, key = os.pullEvent("key")
        if key == keys.q or key == keys.backspace then
            exitApp()
            return
        end
    end
end

local function rednetLoop()
    while true do
        local id, msg, protocol = rednet.receive()

        if protocol == PROTOCOL_DISCOVERY and type(msg) == "table" then
            if msg.type == "discover" then
                rednet.send(id, {
                    type = "discover_reply",
                    playerId = os.getComputerID(),
                    playerName = config.playerName,
                }, PROTOCOL_DISCOVERY)
            elseif msg.type == "pair_request" then
                local ok = trim(msg.code) == trim(config.pairCode)

                if ok then
                    pairRemote(id)
                end

                rednet.send(id, {
                    type = "pair_reply",
                    ok = ok,
                    playerId = os.getComputerID(),
                    playerName = config.playerName,
                    reason = ok and nil or "Invalid pair code",
                }, PROTOCOL_DISCOVERY)

                if ok then
                    sendStateToRemote(id)
                end
            end
        elseif protocol == PROTOCOL_SPEAKER and type(msg) == "table" then
            if msg.type == "speaker_hello" then
                rememberSpeakerNode(id, msg.name)
                markDirty()
            elseif msg.type == "speaker_pair_request" then
                local ok = trim(msg.code) == trim(config.pairCode)

                if ok then
                    pairSpeakerNode(id)
                    rememberSpeakerNode(id, msg.name)
                end

                rednet.send(id, {
                    type = "speaker_pair_reply",
                    ok = ok,
                    playerId = os.getComputerID(),
                    playerName = config.playerName,
                    reason = ok and nil or "Invalid pair code",
                }, PROTOCOL_SPEAKER)
            end
        elseif protocol == PROTOCOL_CONTROL then
            handleRemoteCommand(id, msg)
        end
    end
end

loadData()
clampIndices()
markDirty()
parallel.waitForAny(audioLoop, monitorLoop, uiLoop, rednetLoop, keyboardLoop)
