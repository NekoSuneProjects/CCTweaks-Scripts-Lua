local APP_NAME = "jukebox_v2"
local APP_PATH = "/jukebox_v2.lua"
local APP_URL = "https://raw.githubusercontent.com/NekoSuneProjects/CCTweaks-Scripts-Lua/main/Jukebox/jukebox_v2.lua"
local SKIP_DELAY = 3

local function extractVersion(data)
    if not data then
        return "unknown"
    end

    return data:match('local APP_VERSION = "([^"]+)"') or "unknown"
end

local function readFile(path)
    if not fs.exists(path) then
        return nil
    end

    local handle = fs.open(path, "r")
    if not handle then
        return nil
    end

    local data = handle.readAll()
    handle.close()
    return data
end

local function writeFile(path, data)
    local handle = fs.open(path, "w")
    if not handle then
        error("Failed to write " .. path)
    end

    handle.write(data)
    handle.close()
end

local function download(url)
    if not http then
        error("HTTP API is disabled")
    end

    local handle, err = http.get(url, nil, true)
    if not handle then
        error("Download failed: " .. tostring(err))
    end

    local data = handle.readAll()
    handle.close()
    return data
end

local function updateApp()
    local remote = download(APP_URL)
    local localData = readFile(APP_PATH)
    local localVersion = extractVersion(localData)
    local remoteVersion = extractVersion(remote)

    if localData ~= remote then
        writeFile(APP_PATH, remote)
        print("Updated " .. APP_NAME .. " " .. localVersion .. " -> " .. remoteVersion)
        return remoteVersion
    else
        print(APP_NAME .. " current v" .. localVersion)
        return localVersion
    end
end

local function waitForSkip()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Booting " .. APP_NAME)
    print("Checking for updates...")
    print("")
    print("Press any key within " .. SKIP_DELAY .. "s to skip auto-start.")

    local timer = os.startTimer(SKIP_DELAY)

    while true do
        local event = {os.pullEvent()}
        if event[1] == "timer" and event[2] == timer then
            return false
        elseif event[1] == "key" or event[1] == "char" or event[1] == "mouse_click" then
            return true
        end
    end
end

local function runApp()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Starting " .. APP_NAME .. "...")
    print("Use Q or Backspace in-app to exit.")
    sleep(0.5)

    local ok, result = pcall(shell.run, APP_PATH)
    if not ok then
        print("App crashed: " .. tostring(result))
        return
    end

    if result == false then
        print("App exited with an error.")
    else
        print("App closed.")
    end
end

if waitForSkip() then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Auto-start skipped.")
    return
end

local currentVersion = "unknown"
local ok, versionOrErr = pcall(updateApp)
if not ok then
    print("Update check failed: " .. tostring(versionOrErr))
else
    currentVersion = versionOrErr or currentVersion
end

if not fs.exists(APP_PATH) then
    error("Missing app file: " .. APP_PATH)
end

print("Running v" .. currentVersion)
sleep(1)
runApp()
