local APP_NAME = "CTOS"
local APP_PATH = "/ctos_chatgpt_v1.lua"
local APP_URL = "https://raw.githubusercontent.com/NekoSuneProjects/CCTweaks-Scripts-Lua/main/ChatGPT/ctos_chatgpt_v1.lua"
local STARTUP_PATH = "/startup.lua"
local STARTUP_URL = "https://raw.githubusercontent.com/NekoSuneProjects/CCTweaks-Scripts-Lua/main/ChatGPT/startup_ctos.lua"
local BACKUP_PATH = "/startup_ctos_backup.lua"

local function readFile(path)
    if not fs.exists(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local data = handle.readAll()
    handle.close()
    return data
end

local function writeFile(path, data)
    local handle = fs.open(path, "w")
    if not handle then error("Failed to write " .. path) end
    handle.write(data)
    handle.close()
end

local function download(url)
    if not http then error("HTTP API is disabled") end
    local handle, err = http.get(url, nil, true)
    if not handle then error("Download failed: " .. tostring(err)) end
    local data = handle.readAll()
    handle.close()
    return data
end

local function installStartup()
    local startup = download(STARTUP_URL)
    local current = readFile(STARTUP_PATH)
    if current and current ~= startup and not fs.exists(BACKUP_PATH) then
        writeFile(BACKUP_PATH, current)
    end
    writeFile(STARTUP_PATH, startup)
end

local function installApp()
    writeFile(APP_PATH, download(APP_URL))
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Installing " .. APP_NAME .. "...")
installStartup()
installApp()
print("Installed startup updater to " .. STARTUP_PATH)
print("Launching " .. APP_NAME .. "...")
sleep(0.5)
shell.run(APP_PATH)
