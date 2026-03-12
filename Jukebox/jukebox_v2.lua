local dfpwm = require("cc.audio.dfpwm")
local APP_VERSION = "2026.03.12-8"

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
local modemName = peripheral.find("modem", function(name, modem)
    return modem.isWireless == nil or modem.isWireless()
end)
local localSpeakerNames = {}
local localSpeakers = {}

for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "speaker" then
        localSpeakerNames[#localSpeakerNames + 1] = name
        localSpeakers[#localSpeakers + 1] = peripheral.wrap(name)
    end
end

if not monitor then error("No monitor attached.") end
if #localSpeakers == 0 then error("No speaker attached.") end
if not modemName then error("No modem attached.") end

rednet.open(peripheral.getName(modemName))

if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
if not fs.exists(MUSIC_DIR) then fs.makeDir(MUSIC_DIR) end

monitor.setTextScale(0.5)
monitor.setBackgroundColor(colors.black)
monitor.setTextColor(colors.white)

local UI = {
    header = colors.lightBlue,
    subHeader = colors.cyan,
    panel = colors.gray,
    panelDark = colors.black,
    panelAlt = colors.lightGray,
    playing = colors.lime,
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
    pairedSpeakers = {},
    ownerRemoteId = nil,
    adminRemotes = {},
    volume = 1,
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
local deleteSelectedSong, addSongEntry
local getRemoteRole, getRemoteList, getBrokenSpeakerCount
local getSpeakerCount, getExpectedSpeakerCount
local broadcastStateToPaired, stopSpeakerNodes, stopLocalSpeakers
local speakerNodes = {}
local remoteNodes = {}
local listScroll = 1
local lastSpeakerRestartAt = 0
local lastSpeakerDiscoveryAt = 0
local SPEAKER_STALE_SECONDS = 10
local SPEAKER_BROKEN_QUEUE = 1
local SPEAKER_AUTO_RESTART_SECONDS = 3
local SPEAKER_RESTART_COOLDOWN = 8
local SPEAKER_DISCOVERY_INTERVAL = 5

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

    if type(config.adminRemotes) ~= "table" then
        config.adminRemotes = {}
    end

    if config.ownerRemoteId ~= nil then
        config.ownerRemoteId = tonumber(config.ownerRemoteId)
    end

    config.volume = tonumber(config.volume) or 1
    if config.volume < 0 then config.volume = 0 end
    if config.volume > 3 then config.volume = 3 end
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

local function getVisibleRows()
    local _, h = monitor.getSize()
    local listTop = 14
    local listBottom = h - 5
    return math.max(1, listBottom - listTop + 1)
end

local function clampListScroll()
    local maxStart = math.max(1, #playlist - getVisibleRows() + 1)
    if listScroll < 1 then listScroll = 1 end
    if listScroll > maxStart then listScroll = maxStart end
end

local function ensureSelectedVisible()
    local rows = getVisibleRows()
    if selectedIndex < listScroll then
        listScroll = selectedIndex
    elseif selectedIndex > (listScroll + rows - 1) then
        listScroll = selectedIndex - rows + 1
    end
    clampListScroll()
end

local function markDirty()
    version = version + 1
    uiDirty = true
end

local function changeVolume(delta)
    config.volume = math.max(0, math.min(3, (tonumber(config.volume) or 1) + delta))
    saveConfig()
    markDirty()
    broadcastStateToPaired()
end

local function restartJukeboxSystem()
    statusText = "Rebooting jukebox"
    markDirty()
    broadcastStateToPaired()
    sleep(0.5)
    os.reboot()
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

local function fillRect(surface, x1, y1, x2, y2, bg)
    surface.setBackgroundColor(bg)
    for y = y1, y2 do
        surface.setCursorPos(x1, y)
        surface.write(string.rep(" ", math.max(0, x2 - x1 + 1)))
    end
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

local function getStatePayload(targetId)
    local speakers = {}
    for idStr, node in pairs(speakerNodes) do
        speakers[#speakers + 1] = {
            id = tonumber(idStr),
            name = node.name,
            queueSize = node.queueSize or 0,
            stuck = node.stuck == true,
            status = node.status or "Waiting",
            lastSeenAge = math.floor(os.clock() - (node.lastStatusAt or node.seenAt or os.clock())),
            version = node.version,
        }
    end

    table.sort(speakers, function(a, b)
        return (a.id or 0) < (b.id or 0)
    end)

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
        ownerRemoteId = config.ownerRemoteId,
        adminRemotes = config.adminRemotes,
        remoteRole = targetId and getRemoteRole(targetId) or "guest",
        remoteList = getRemoteList(),
        speakers = speakers,
        speakerCount = getExpectedSpeakerCount(),
        onlineSpeakerCount = getSpeakerCount(),
        brokenSpeakerCount = getBrokenSpeakerCount(),
        online = true,
        volume = config.volume,
        localSpeakerCount = #localSpeakers,
    }
end

broadcastStateToPaired = function()
    for idStr, _ in pairs(config.pairedRemotes) do
        rednet.send(tonumber(idStr), getStatePayload(tonumber(idStr)), PROTOCOL_STATE)
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

    local key = tostring(id)
    local node = speakerNodes[key] or {}
    node.id = id
    node.name = name or node.name or ("Speaker-" .. id)
    node.seenAt = os.clock()
    node.lastStatusAt = os.clock()
    node.lastChunkAt = node.lastChunkAt or 0
    node.queueSize = node.queueSize or 0
    node.stuck = false
    node.status = node.status == "Restarting" and "Restarting" or "Waiting"
    node.brokenSince = nil
    speakerNodes[key] = node
end

local function pairSpeakerNode(id)
    config.pairedSpeakers[tostring(id)] = true
    saveConfig()
    markDirty()
end

local function getPairedSpeakerCount()
    local count = 0
    for _ in pairs(config.pairedSpeakers) do
        count = count + 1
    end
    return count
end

getSpeakerCount = function()
    local count = #localSpeakers
    for _ in pairs(speakerNodes) do
        count = count + 1
    end
    return count
end

getExpectedSpeakerCount = function()
    return #localSpeakers + getPairedSpeakerCount()
end

getBrokenSpeakerCount = function()
    local count = 0
    for _, node in pairs(speakerNodes) do
        if node.stuck then
            count = count + 1
        end
    end
    return count
end

local function isOwnerRemote(id)
    return tonumber(config.ownerRemoteId) == tonumber(id)
end

local function isAdminRemote(id)
    return isOwnerRemote(id) or config.adminRemotes[tostring(id)] == true
end

getRemoteRole = function(id)
    if isOwnerRemote(id) then
        return "owner"
    end
    if isAdminRemote(id) then
        return "admin"
    end
    return "guest"
end

local function rebuildAdminList()
    for idStr in pairs(config.adminRemotes) do
        if config.pairedRemotes[idStr] ~= true then
            config.adminRemotes[idStr] = nil
        end
    end
end

local function assignOwnerIfNeeded(id)
    if not config.ownerRemoteId then
        config.ownerRemoteId = id
        saveConfig()
    end
end

local function cleanupSpeakerNodes()
    local now = os.clock()
    for idStr, node in pairs(speakerNodes) do
        local age = now - (node.lastStatusAt or node.seenAt or 0)
        if age > 60 then
            speakerNodes[idStr] = nil
        elseif age > SPEAKER_STALE_SECONDS then
            node.stuck = true
            node.status = "Offline"
            node.brokenSince = node.brokenSince or now
        end
    end
end

local function noteSpeakerStatus(id, msg)
    if config.pairedSpeakers[tostring(id)] ~= true then
        return
    end

    rememberSpeakerNode(id, msg.name)
    local node = speakerNodes[tostring(id)]
    if not node then
        return
    end

    node.name = msg.name or node.name
    node.seenAt = os.clock()
    node.lastStatusAt = os.clock()
    node.queueSize = tonumber(msg.queueSize) or 0
    node.status = tostring(msg.status or node.status or "Waiting")
    node.lastChunkAt = tonumber(msg.lastChunkAt) or node.lastChunkAt or 0
    node.volume = tonumber(msg.volume) or node.volume or config.volume
    node.version = tostring(msg.version or node.version or "?")
    node.online = true

    if node.queueSize > SPEAKER_BROKEN_QUEUE then
        node.stuck = true
        node.brokenSince = node.brokenSince or os.clock()
    else
        node.stuck = false
        node.brokenSince = nil
    end
end

local function restartSpeakerNodes(reason)
    lastSpeakerRestartAt = os.clock()
    stopSpeakerNodes()
    for idStr in pairs(config.pairedSpeakers) do
        rednet.send(tonumber(idStr), {
            type = "restart",
            session = playSession,
            reason = reason or "manual",
        }, PROTOCOL_SPEAKER)

        local node = speakerNodes[idStr]
        if node then
            node.status = "Restarting"
            node.stuck = false
            node.brokenSince = nil
        end
    end
    queueSpeakerDiscovery()
    statusText = "Restarting speakers"
    markDirty()
    broadcastStateToPaired()
end

local function restartSpeakerNode(targetId, reason)
    local node = speakerNodes[tostring(targetId)]
    if not node then
        return false
    end

    rednet.send(targetId, {
        type = "restart",
        session = playSession,
        reason = reason or "manual",
    }, PROTOCOL_SPEAKER)

    node.status = "Restarting"
    node.stuck = false
    node.brokenSince = nil
    lastSpeakerRestartAt = os.clock()
    markDirty()
    broadcastStateToPaired()
    return true
end

local function autoRecoverSpeakers()
    local now = os.clock()
    if now - lastSpeakerRestartAt < SPEAKER_RESTART_COOLDOWN then
        return
    end

    for _, node in pairs(speakerNodes) do
        if node.stuck and node.brokenSince and (now - node.brokenSince) >= SPEAKER_AUTO_RESTART_SECONDS then
            restartSpeakerNodes("auto-recover")
            return
        end
    end
end

local function keepSpeakerLinksAlive()
    local now = os.clock()
    if now - lastSpeakerDiscoveryAt < SPEAKER_DISCOVERY_INTERVAL then
        return
    end

    if getPairedSpeakerCount() == 0 then
        return
    end

    if getSpeakerCount() < getExpectedSpeakerCount() or playing then
        lastSpeakerDiscoveryAt = now
        queueSpeakerDiscovery()
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

local function getUrlParam(url, key)
    if type(url) ~= "string" or type(key) ~= "string" then
        return nil
    end

    return url:match("[?&]" .. key .. "=([^&#]+)")
end

local function getYoutubePlaylistId(query)
    if type(query) ~= "string" then
        return nil
    end

    local lower = query:lower()
    if not lower:find("youtube%.com", 1) and not lower:find("youtu%.be", 1) then
        return nil
    end

    return getUrlParam(query, "list")
end

local function findPlaylistResult(results, playlistId)
    if type(results) ~= "table" then
        return nil
    end

    local fallback = nil

    for index, item in ipairs(results) do
        if item and item.type == "playlist" and type(item.playlist_items) == "table" then
            if not fallback then
                fallback = index
            end

            if playlistId then
                if item.id == playlistId or item.playlistId == playlistId then
                    return index
                end

                local itemPlaylistId = getUrlParam(item.url, "list")
                if itemPlaylistId == playlistId then
                    return index
                end
            end
        end
    end

    return fallback
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

    local playlistId = getYoutubePlaylistId(query)
    if playlistId then
        local playlistIndex = findPlaylistResult(results, playlistId)
        if playlistIndex then
            local ok, info = addYoutubeEntries(results, playlistIndex)
            print("")
            if ok then
                print("Playlist detected.")
                print("Added " .. tostring(info) .. " track(s)")
            else
                print("Playlist add failed: " .. tostring(info))
                markDirty()
            end
            sleep(1.5)
            return
        end
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
    rednet.send(id, getStatePayload(id), PROTOCOL_STATE)
end

local function isPairedRemote(id)
    return config.pairedRemotes[tostring(id)] == true
end

local function pairRemote(id)
    config.pairedRemotes[tostring(id)] = true
    assignOwnerIfNeeded(id)
    rebuildAdminList()
    saveConfig()
    markDirty()
end

local function rememberRemoteNode(id, name)
    if config.pairedRemotes[tostring(id)] ~= true then
        return
    end

    remoteNodes[tostring(id)] = {
        id = id,
        name = name or ("Pocket-" .. id),
        seenAt = os.clock()
    }
end

local function cleanupRemoteNodes()
    local now = os.clock()
    for idStr, node in pairs(remoteNodes) do
        if now - (node.seenAt or 0) > 15 then
            remoteNodes[idStr] = nil
        end
    end
end

local function getRemoteCount()
    local count = 0
    for _ in pairs(remoteNodes) do
        count = count + 1
    end
    return count
end

getRemoteList = function()
    local list = {}
    for idStr in pairs(config.pairedRemotes) do
        local id = tonumber(idStr)
        local node = remoteNodes[idStr]
        list[#list + 1] = {
            id = id,
            name = node and node.name or ("Pocket-" .. idStr),
            role = getRemoteRole(id),
        }
    end

    table.sort(list, function(a, b)
        return (a.id or 0) < (b.id or 0)
    end)

    return list
end

addSongEntry = function(name, url)
    if trim(name) == "" or trim(url) == "" then
        return false, "Missing name or URL"
    end

    table.insert(playlist, {
        name = trim(name),
        url = trim(url),
    })
    savePlaylist()
    selectedIndex = #playlist
    currentIndex = selectedIndex
    ensureSelectedVisible()
    markDirty()
    broadcastStateToPaired()
    return true
end

local function grantAdmin(requesterId, targetId)
    if not isOwnerRemote(requesterId) then
        return false, "Owner only"
    end
    if config.pairedRemotes[tostring(targetId)] ~= true then
        return false, "Target not paired"
    end
    if isOwnerRemote(targetId) then
        return false, "Owner already has access"
    end
    config.adminRemotes[tostring(targetId)] = true
    saveConfig()
    markDirty()
    broadcastStateToPaired()
    return true
end

local function revokeAdmin(requesterId, targetId)
    if not isOwnerRemote(requesterId) then
        return false, "Owner only"
    end
    if isOwnerRemote(targetId) then
        return false, "Cannot revoke owner"
    end
    config.adminRemotes[tostring(targetId)] = nil
    saveConfig()
    markDirty()
    broadcastStateToPaired()
    return true
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

    rememberRemoteNode(id, msg.remoteName)

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
            ensureSelectedVisible()
            markDirty()
            broadcastStateToPaired()
        end
    elseif msg.action == "request_state" then
        sendStateToRemote(id)
    elseif msg.action == "restart_speakers" then
        if not isAdminRemote(id) then
            sendStateToRemote(id)
            return
        end
        restartSpeakerNodes("remote")
    elseif msg.action == "restart_speaker" then
        if not isAdminRemote(id) then
            sendStateToRemote(id)
            return
        end
        restartSpeakerNode(tonumber(msg.speakerId), "remote-single")
    elseif msg.action == "restart_jukebox" then
        if not isAdminRemote(id) then
            sendStateToRemote(id)
            return
        end
        restartJukeboxSystem()
    elseif msg.action == "delete" then
        if not isAdminRemote(id) then
            sendStateToRemote(id)
            return
        end
        local idx = tonumber(msg.index) or selectedIndex
        if idx and playlist[idx] then
            selectedIndex = idx
            deleteSelectedSong()
        end
    elseif msg.action == "add_url" then
        if not isAdminRemote(id) then
            sendStateToRemote(id)
            return
        end
        local ok = addSongEntry(msg.name, msg.url)
        if not ok then
            statusText = "Pocket add failed"
            markDirty()
            broadcastStateToPaired()
        end
    elseif msg.action == "grant_admin" then
        grantAdmin(id, tonumber(msg.remoteId))
    elseif msg.action == "revoke_admin" then
        revokeAdmin(id, tonumber(msg.remoteId))
    elseif msg.action == "volume_up" then
        if not isAdminRemote(id) then
            sendStateToRemote(id)
            return
        end
        changeVolume(0.1)
    elseif msg.action == "volume_down" then
        if not isAdminRemote(id) then
            sendStateToRemote(id)
            return
        end
        changeVolume(-0.1)
    end
end

deleteSelectedSong = function()
    if #playlist == 0 then return end
    table.remove(playlist, selectedIndex)
    clampIndices()
    ensureSelectedVisible()
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
    fillRect(monitor, 1, 1, w, h, colors.black)

    fillRect(monitor, 1, 1, w, 2, UI.header)
    drawText(2, 1, "Jukebox Control", colors.black, UI.header)
    drawText(2, 2, trimText(config.playerName, math.max(1, w - 28)), colors.black, UI.header)
    drawText(math.max(2, w - 15), 1, "v" .. APP_VERSION, colors.black, UI.header)
    drawText(math.max(2, w - 10), 2, "#" .. os.getComputerID(), colors.black, UI.header)

    local function drawCard(x1, x2, title, main, sub, accent)
        fillRect(monitor, x1, 4, x2, 6, UI.panelAlt)
        fillRect(monitor, x1, 4, x1, 6, accent)
        drawText(x1 + 2, 4, trimText(title, math.max(1, x2 - x1 - 2)), colors.black, UI.panelAlt)
        drawText(x1 + 2, 5, trimText(main, math.max(1, x2 - x1 - 2)), colors.black, UI.panelAlt)
        drawText(x1 + 2, 6, trimText(sub, math.max(1, x2 - x1 - 2)), colors.gray, UI.panelAlt)
    end

    local cardGap = 1
    local cardWidth = math.max(12, math.floor((w - 5 - (cardGap * 3)) / 4))
    local card1 = 2
    local card2 = card1 + cardWidth + cardGap
    local card3 = card2 + cardWidth + cardGap
    local card4 = card3 + cardWidth + cardGap

    drawCard(card1, card2 - cardGap - 1, "Pair Code", config.pairCode, "Tap Pair to refresh", colors.yellow)
    drawCard(card2, card3 - cardGap - 1, "Library", tostring(#playlist) .. " tracks", "Sel " .. tostring(selectedIndex) .. " / Now " .. tostring(currentIndex), colors.cyan)
    drawCard(card3, card4 - cardGap - 1, "Network", tostring(getRemoteCount()) .. " pockets", tostring(getSpeakerCount()) .. " speakers", colors.orange)
    drawCard(card4, w - 1, "Output", "Vol " .. string.format("%.1f", config.volume), tostring(getBrokenSpeakerCount()) .. " broken nodes", colors.lime)

    fillRect(monitor, 2, 8, w - 1, 11, UI.panelDark)
    drawText(3, 8, playing and "LIVE PLAYBACK" or "STANDBY", playing and colors.lime or colors.orange, UI.panelDark)
    drawText(math.max(3, w - 18), 8, "Q/Back Exit", UI.dim, UI.panelDark)
    drawText(3, 9, trimText(nowPlaying, math.max(1, w - 4)), UI.text, UI.panelDark)

    local selectedName = (#playlist > 0 and playlist[selectedIndex] and playlist[selectedIndex].name) or "None"
    drawText(3, 10, trimText("Selected: " .. selectedName, math.max(1, w - 4)), UI.dim, UI.panelDark)

    local barX = 3
    local barY = 11
    local barW = math.max(10, w - 6)
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
    monitor.setCursorPos(math.max(barX, math.floor((w - #label) / 2)), barY)
    monitor.write(label)

    fillRect(monitor, 1, 13, w, 13, UI.subHeader)
    drawText(2, 13, "Playlist", colors.black, UI.subHeader)
    local rangeStart = #playlist > 0 and math.min(listScroll, #playlist) or 0
    local rangeEnd = #playlist > 0 and math.min(#playlist, listScroll + getVisibleRows() - 1) or 0
    local rangeText = string.format("%d-%d / %d", rangeStart, rangeEnd, #playlist)
    drawText(math.max(2, w - #rangeText - 1), 13, rangeText, colors.black, UI.subHeader)

    local listTop = 14
    local listBottom = h - 5
    local rows = math.max(1, listBottom - listTop + 1)
    local startIndex = listScroll

    for row = 0, rows - 1 do
        local idx = startIndex + row
        local y = listTop + row
        local bg = (row % 2 == 0) and colors.black or colors.gray
        local fg = (row % 2 == 0) and UI.text or colors.black

        if idx == currentIndex and playing then
            bg = UI.playing
            fg = colors.black
        elseif idx == selectedIndex then
            bg = UI.selected
            fg = colors.white
        end

        fillRect(monitor, 1, y, w, y, bg)

        if playlist[idx] then
            local marker = " "
            if idx == currentIndex and playing then
                marker = ">"
            elseif idx == selectedIndex then
                marker = "*"
            end

            local sourceTag = "FILE"
            if playlist[idx].ytId then
                sourceTag = "YT"
            elseif playlist[idx].url then
                sourceTag = "URL"
            end

            local line = string.format("%s %02d [%s] %s", marker, idx, sourceTag, playlist[idx].name or "Unknown")
            drawText(2, y, trimText(line, math.max(1, w - 2)), fg, bg)
            mapArea("song:" .. idx, 1, y, w, y)
        end
    end

    local function drawButtonRow(y1, y2, defs)
        local gap = 1
        local count = #defs
        local width = math.max(6, math.floor((w - 2 - ((count - 1) * gap)) / count))
        local x = 1

        for index, def in ipairs(defs) do
            local x1 = x
            local x2 = (index == count) and w or math.min(w, x1 + width - 1)
            addButton(def.name, x1, y1, x2, y2, def.bg, def.fg, def.label)
            x = x2 + gap + 1
        end
    end

    drawButtonRow(h - 3, h - 2, {
        { name = "prev", bg = UI.buttonPrev, fg = colors.black, label = "Prev" },
        { name = "play", bg = UI.buttonPlay, fg = colors.black, label = "Play" },
        { name = "stop", bg = UI.buttonStop, fg = colors.white, label = "Stop" },
        { name = "next", bg = UI.buttonNext, fg = colors.black, label = "Next" },
        { name = "add", bg = UI.buttonAdd, fg = colors.black, label = "Add" },
        { name = "delete", bg = UI.buttonDelete, fg = colors.white, label = "Delete" },
    })

    drawButtonRow(h - 1, h, {
        { name = "list_up", bg = colors.gray, fg = colors.white, label = "Up" },
        { name = "list_down", bg = colors.gray, fg = colors.white, label = "Down" },
        { name = "vol_down", bg = colors.brown, fg = colors.white, label = "V-" },
        { name = "vol_up", bg = colors.brown, fg = colors.white, label = "V+" },
        { name = "pair", bg = UI.buttonPair, fg = colors.black, label = "Pair" },
        { name = "restart_speakers", bg = colors.lightBlue, fg = colors.black, label = "FixSpk" },
        { name = "restart_jukebox", bg = colors.red, fg = colors.white, label = "Reboot" },
    })
end

local function broadcastSpeakerChunk(chunk)
    cleanupSpeakerNodes()
    for idStr, node in pairs(speakerNodes) do
        local ok = rednet.send(tonumber(idStr), {
            type = "audio_chunk",
            session = playSession,
            chunk = chunk,
            volume = config.volume,
        }, PROTOCOL_SPEAKER)

        if not ok then
            speakerNodes[idStr] = nil
        else
            node.seenAt = os.clock()
            node.lastChunkAt = os.clock()
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

local function stopLocalSpeakers()
    for _, localSpeaker in ipairs(localSpeakers) do
        localSpeaker.stop()
    end
end

local function interruptPlayback()
    playRequestId = playRequestId + 1
    stopRequested = true
    stopLocalSpeakers()
    stopSpeakerNodes()
    os.queueEvent("jukebox_interrupt", playRequestId)
end

local function playBuffer(buffer, requestId)
    for _, localSpeaker in ipairs(localSpeakers) do
        while not localSpeaker.playAudio(buffer, config.volume) do
            os.pullEvent()
            if playRequestId ~= requestId or stopRequested then
                return false
            end
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
        ensureSelectedVisible()
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
    print("1 = Stream URL")
    print("2 = YouTube search / URL")
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
    elseif mode == "2" then
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
    ensureSelectedVisible()
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
    ensureSelectedVisible()
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
    ensureSelectedVisible()
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
    ensureSelectedVisible()
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
                ensureSelectedVisible()
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
        elseif hit == "list_up" then
            listScroll = listScroll - getVisibleRows()
            clampListScroll()
            markDirty()
        elseif hit == "list_down" then
            listScroll = listScroll + getVisibleRows()
            clampListScroll()
            markDirty()
        elseif hit == "vol_down" then
            changeVolume(-0.1)
        elseif hit == "vol_up" then
            changeVolume(0.1)
        elseif hit == "pair" then
            newPairCode()
        elseif hit == "restart_speakers" then
            restartSpeakerNodes("monitor")
        elseif hit == "restart_jukebox" then
            restartJukeboxSystem()
        end
    end
end

local function uiLoop()
    while true do
        sleep(0.2)
        cleanupRemoteNodes()
        cleanupSpeakerNodes()
        autoRecoverSpeakers()
        keepSpeakerLinksAlive()
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
                    rememberRemoteNode(id, msg.remoteName)
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
            elseif msg.type == "speaker_status" then
                noteSpeakerStatus(id, msg)
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
            if type(msg) == "table" and msg.type == "heartbeat" then
                rememberRemoteNode(id, msg.remoteName)
                markDirty()
                sendStateToRemote(id)
            else
                handleRemoteCommand(id, msg)
            end
        end
    end
end

loadData()
clampIndices()
markDirty()
queueSpeakerDiscovery()
parallel.waitForAny(audioLoop, monitorLoop, uiLoop, rednetLoop, keyboardLoop)
