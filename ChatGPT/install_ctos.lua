local APP_NAME = "CTOS"
local APP_PATH = "/ctos_chatgpt_v1.lua"
local STARTUP_PATH = "/startup.lua"
local BACKUP_PATH = "/startup_ctos_backup.lua"
local REPO_ROOT = "https://raw.githubusercontent.com/NekoSuneProjects/CCTweaks-Scripts-Lua/"

local BRANCH_OPTIONS = {
    { key = "1", label = "Release", branch = "RELEASE" },
    { key = "2", label = "Beta", branch = "BETA" },
}

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

local function chooseBranch()
    while true do
        print("Select channel:")
        for _, option in ipairs(BRANCH_OPTIONS) do
            print(option.key .. ". " .. option.label)
        end
        write("> ")

        local choice = read()
        for _, option in ipairs(BRANCH_OPTIONS) do
            if choice == option.key then
                return option
            end
        end

        print("Invalid selection. Try again.")
        print("")
    end
end

local function makeUrl(branch, file)
    return REPO_ROOT .. branch .. "/ChatGPT/" .. file
end

local function installStartup(startupUrl)
    local startup = download(startupUrl)
    local current = readFile(STARTUP_PATH)
    if current and current ~= startup and not fs.exists(BACKUP_PATH) then
        writeFile(BACKUP_PATH, current)
    end
    writeFile(STARTUP_PATH, startup)
end

local function installApp(appUrl)
    writeFile(APP_PATH, download(appUrl))
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
local branchOption = chooseBranch()
local appUrl = makeUrl(branchOption.branch, "ctos_chatgpt_v1.lua")
local startupUrl = makeUrl(branchOption.branch, "startup_ctos.lua")
print("")
print("Installing " .. APP_NAME .. "...")
installStartup(startupUrl)
installApp(appUrl)
print("Installed startup updater to " .. STARTUP_PATH)
print("Launching " .. APP_NAME .. "...")
sleep(0.5)
shell.run(APP_PATH)
