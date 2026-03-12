local dfpwm = require("cc.audio.dfpwm")
local APP_VERSION = "2026.03.12-11"

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
local broadcastStateToPaired
local stopSpeakerNodes = function() end
local stopLocalSpeakers = function() end
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
    local listTop = 15
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
    if stopSpeakerNodes then
        stopSpeakerNodes()
    end
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

    local function drawCapsule(x1, y, text, bg, fg)
        local width = #text + 2
        fillRect(monitor, x1, y, math.min(w, x1 + width - 1), y, bg)
        drawText(x1 + 1, y, text, fg, bg)
    end

    local function drawCard(x1, y1, x2, y2, accent, title, main, sub)
        if x1 > x2 or y1 > y2 then
            return
        end
        fillRect(monitor, x1, y1, x2, y2, colors.gray)
        fillRect(monitor, x1, y1, x1, y2, accent)
        if x2 < w then
            fillRect(monitor, x2 + 1, y1 + 1, x2 + 1, y2, colors.black)
        end
        if y2 < h then
            fillRect(monitor, x1 + 1, y2 + 1, x2, y2 + 1, colors.black)
        end
        drawText(x1 + 2, y1, trimText(title, math.max(1, x2 - x1 - 2)), colors.white, colors.gray)
        drawText(x1 + 2, y1 + 1, trimText(main, math.max(1, x2 - x1 - 2)), colors.black, colors.gray)
        if y1 + 2 <= y2 then
            drawText(x1 + 2, y1 + 2, trimText(sub, math.max(1, x2 - x1 - 2)), colors.lightGray, colors.gray)
        end
    end

    fillRect(monitor, 1, 1, w, 3, colors.black)
    fillRect(monitor, 1, 1, 2, h, colors.cyan)
    fillRect(monitor, 3, 1, w, 1, colors.lightBlue)
    fillRect(monitor, 3, 2, w, 3, colors.black)
    drawText(5, 1, "Jukebox Nexus", colors.black, colors.lightBlue)
    drawText(5, 2, trimText(config.playerName, math.max(1, w - 24)), colors.white, colors.black)
    drawText(5, 3, trimText(nowPlaying, math.max(1, w - 24)), colors.lightGray, colors.black)
    drawText(math.max(3, w - 15), 1, "v" .. APP_VERSION, colors.black, colors.lightBlue)
    drawText(math.max(3, w - 10), 2, "#" .. os.getComputerID(), colors.lightGray, colors.black)
    drawCapsule(math.max(3, w - 18), 3, playing and " LIVE " or " IDLE ", playing and colors.lime or colors.orange, colors.black)

    local cardGap = 2
    local cardWidth = math.max(14, math.floor((w - 8 - (cardGap * 3)) / 4))
    local card1 = 4
    local card2 = card1 + cardWidth + cardGap
    local card3 = card2 + cardWidth + cardGap
    local card4 = card3 + cardWidth + cardGap

    drawCard(card1, 5, card1 + cardWidth - 1, 7, colors.yellow, "Pair", config.pairCode, "Tap pair for new code")
    drawCard(card2, 5, card2 + cardWidth - 1, 7, colors.cyan, "Library", tostring(#playlist) .. " tracks", "Selected " .. tostring(selectedIndex))
    drawCard(card3, 5, card3 + cardWidth - 1, 7, colors.orange, "Network", tostring(getRemoteCount()) .. " pockets", tostring(getSpeakerCount()) .. " speakers")
    drawCard(card4, 5, w - 2, 7, colors.lime, "Output", "Vol " .. string.format("%.1f", config.volume), tostring(getBrokenSpeakerCount()) .. " broken")

    fillRect(monitor, 4, 9, w - 2, 13, colors.black)
    fillRect(monitor, 4, 9, w - 2, 9, colors.gray)
    drawText(6, 9, "Now Playing", colors.black, colors.gray)
    drawText(6, 10, trimText(nowPlaying, math.max(1, w - 12)), colors.white, colors.black)

    local selectedName = (#playlist > 0 and playlist[selectedIndex] and playlist[selectedIndex].name) or "None"
    drawText(6, 11, trimText("Selected  " .. selectedName, math.max(1, w - 12)), colors.lightGray, colors.black)
    drawText(math.max(6, w - 16), 11, "Q/Back Exit", colors.gray, colors.black)

    local barX = 6
    local barY = 13
    local barW = math.max(12, w - 12)
    local fill = math.floor(barW * getProgressValue())
    fillRect(monitor, barX, barY, barX + barW - 1, barY, colors.gray)
    if fill > 0 then
        fillRect(monitor, barX, barY, barX + fill - 1, barY, colors.lime)
    end
    drawCapsule(math.max(barX, math.floor((w - 11) / 2)), 12, playing and " PLAYING " or " STOPPED ", playing and colors.lime or colors.red, colors.black)

    fillRect(monitor, 4, 14, w - 2, 14, colors.cyan)
    drawText(6, 14, "Playlist", colors.black, colors.cyan)
    local rangeStart = #playlist > 0 and math.min(listScroll, #playlist) or 0
    local rangeEnd = #playlist > 0 and math.min(#playlist, listScroll + getVisibleRows() - 1) or 0
    local rangeText = string.format("%d-%d / %d", rangeStart, rangeEnd, #playlist)
    drawText(math.max(6, w - #rangeText - 3), 14, rangeText, colors.black, colors.cyan)

    local listTop = 15
    local listBottom = h - 5
    local rows = math.max(1, listBottom - listTop + 1)
    local startIndex = listScroll

    for row = 0, rows - 1 do
        local idx = startIndex + row
        local y = listTop + row
        local bg = (row % 2 == 0) and colors.black or colors.gray
        local fg = (row % 2 == 0) and UI.text or colors.white

        if idx == currentIndex and playing then
            bg = UI.playing
            fg = colors.black
        elseif idx == selectedIndex then
            bg = UI.selected
            fg = colors.white
        end

        fillRect(monitor, 1, y, w, y, bg)

        if playlist[idx] then
            local sourceTag = "FILE"
            if playlist[idx].ytId then
                sourceTag = "YT"
            elseif playlist[idx].url then
                sourceTag = "URL"
            end

            fillRect(monitor, 4, y, 9, y, idx == currentIndex and playing and colors.black or colors.lightBlue)
            drawText(5, y, trimText(sourceTag, 4), idx == currentIndex and playing and colors.lime or colors.black, idx == currentIndex and playing and colors.black or colors.lightBlue)
            drawText(12, y, string.format("%02d", idx), colors.lightGray, bg)
            drawText(16, y, trimText(playlist[idx].name or "Unknown", math.max(1, w - 18)), fg, bg)
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

stopSpeakerNodes = function()
    for idStr in pairs(speakerNodes) do
        rednet.send(tonumber(idStr), {
            type = "stop",
            session = playSession,
        }, PROTOCOL_SPEAKER)
    end
end

stopLocalSpeakers = function()
    for _, localSpeaker in ipairs(localSpeakers) do
        localSpeaker.stop()
    end
end

local function interruptPlayback()
    playRequestId = playRequestId + 1
    stopRequested = true
    if stopLocalSpeakers then
        stopLocalSpeakers()
    end
    if stopSpeakerNodes then
        stopSpeakerNodes()
    end
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
