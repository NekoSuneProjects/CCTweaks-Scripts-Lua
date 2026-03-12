local REPO_ROOT = "https://raw.githubusercontent.com/NekoSuneProjects/CCTweaks-Scripts-Lua/"
local STARTUP_PATH = "/startup.lua"

local APP_OPTIONS = {
    { key = "1", label = "Jukebox", id = "jukebox" },
    { key = "2", label = "ChatGPT", id = "chatgpt" },
}

local BRANCH_OPTIONS = {
    { key = "1", label = "Release", branch = "RELEASE" },
    { key = "2", label = "Beta", branch = "BETA" },
}

local JUKEBOX_OPTIONS = {
    {
        key = "1",
        label = "Jukebox host",
        appName = "jukebox_v2",
        appPath = "/jukebox_v2.lua",
        appDir = "Jukebox",
        appFile = "jukebox_v2.lua",
        startupFile = "startup_jukebox.lua",
        backupPath = "/startup_jukebox_backup.lua",
    },
    {
        key = "2",
        label = "Pocket remote",
        appName = "pocket_remote_v2",
        appPath = "/pocket_remote_v2.lua",
        appDir = "Jukebox",
        appFile = "pocket_remote_v2.lua",
        startupFile = "startup_pocket_remote.lua",
        backupPath = "/startup_pocket_remote_backup.lua",
    },
    {
        key = "3",
        label = "Speaker node",
        appName = "speaker_node_v2",
        appPath = "/speaker_node_v2.lua",
        appDir = "Jukebox",
        appFile = "speaker_node_v2.lua",
        startupFile = "startup_speaker_node.lua",
        backupPath = "/startup_speaker_node_backup.lua",
    },
}

local CHATGPT_OPTION = {
    appName = "CTOS",
    appPath = "/ctos_chatgpt_v1.lua",
    appDir = "ChatGPT",
    appFile = "ctos_chatgpt_v1.lua",
    startupFile = "startup_ctos.lua",
    backupPath = "/startup_ctos_backup.lua",
}

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

local function chooseOption(title, options)
    while true do
        print(title)
        for _, option in ipairs(options) do
            print(option.key .. ". " .. option.label)
        end
        write("> ")

        local choice = read()
        for _, option in ipairs(options) do
            if choice == option.key then
                return option
            end
        end

        print("Invalid selection. Try again.")
        print("")
    end
end

local function makeUrl(branch, dir, file)
    return REPO_ROOT .. branch .. "/" .. dir .. "/" .. file
end

local function installSelected(branchOption, installOption)
    local startupUrl = makeUrl(branchOption.branch, installOption.appDir, installOption.startupFile)
    local appUrl = makeUrl(branchOption.branch, installOption.appDir, installOption.appFile)

    local startup = download(startupUrl)
    local current = readFile(STARTUP_PATH)

    if current and current ~= startup and not fs.exists(installOption.backupPath) then
        writeFile(installOption.backupPath, current)
    end

    writeFile(STARTUP_PATH, startup)
    writeFile(installOption.appPath, download(appUrl))

    print("")
    print("Installed " .. installOption.appName .. " from " .. branchOption.label .. ".")
    print("Startup updater written to " .. STARTUP_PATH)
    print("Launching " .. installOption.appName .. "...")
    sleep(0.5)
    shell.run(installOption.appPath)
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)

local appOption = chooseOption("Select app:", APP_OPTIONS)
print("")
local branchOption = chooseOption("Select channel:", BRANCH_OPTIONS)
print("")

if appOption.id == "jukebox" then
    local installOption = chooseOption("Select Jukebox type:", JUKEBOX_OPTIONS)
    print("")
    print("Installing " .. installOption.appName .. "...")
    installSelected(branchOption, installOption)
else
    print("Installing " .. CHATGPT_OPTION.appName .. "...")
    installSelected(branchOption, CHATGPT_OPTION)
end
