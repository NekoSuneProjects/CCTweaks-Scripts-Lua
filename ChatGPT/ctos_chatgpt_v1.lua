--[[
----------------------------------------------------------
CTOS - Multi-Provider AI Interface for ComputerCraft
----------------------------------------------------------
Code Created by 0x00sec but modified by NekoSuneVR
----------------------------------------------------------
]]

local APP_NAME = "CTOS"
local APP_VERSION = "2026.03.11-1"
local SETTINGS_PREFIX = "ctos."

local Utility = {}
local Screen = {}
local Settings = {}
local Commands = {}
local Messages = {}

local PROVIDERS = {
    anthropic = { label = "Anthropic", mode = "anthropic", defaultHost = "https://api.anthropic.com", defaultModel = "claude-3-5-sonnet-latest", requiresKey = true },
    deepseek = { label = "DeepSeek", mode = "openai", defaultHost = "https://api.deepseek.com", defaultPath = "/v1/chat/completions", defaultModel = "deepseek-chat", requiresKey = true },
    google = { label = "Google AI", mode = "google", defaultHost = "https://generativelanguage.googleapis.com", defaultModel = "gemini-2.0-flash", requiresKey = true },
    grok = { label = "Grok AI / xAI", mode = "openai", defaultHost = "https://api.x.ai", defaultPath = "/v1/chat/completions", defaultModel = "grok-2-latest", requiresKey = true },
    groq = { label = "Groq", mode = "openai", defaultHost = "https://api.groq.com/openai", defaultPath = "/v1/chat/completions", defaultModel = "llama-3.3-70b-versatile", requiresKey = true },
    litellm = { label = "LiteLLM (Selfhosted)", mode = "openai", defaultHost = "http://127.0.0.1:4000", defaultPath = "/v1/chat/completions", defaultModel = "gpt-4o-mini", requiresKey = false },
    lmstudio = { label = "LM Studio", mode = "openai", defaultHost = "http://127.0.0.1:1234", defaultPath = "/v1/chat/completions", defaultModel = "local-model", requiresKey = false },
    localai = { label = "LocalAI", mode = "openai", defaultHost = "http://127.0.0.1:8080", defaultPath = "/v1/chat/completions", defaultModel = "local-model", requiresKey = false },
    mistral = { label = "Mistral", mode = "openai", defaultHost = "https://api.mistral.ai", defaultPath = "/v1/chat/completions", defaultModel = "mistral-small-latest", requiresKey = true },
    ollama = { label = "Ollama", mode = "ollama", defaultHost = "http://127.0.0.1:11434", defaultModel = "llama3.2", requiresKey = false },
    openai = { label = "OpenAI", mode = "openai", defaultHost = "https://api.openai.com", defaultPath = "/v1/chat/completions", defaultModel = "gpt-4o-mini", requiresKey = true },
    openrouter = { label = "OpenRouter", mode = "openai", defaultHost = "https://openrouter.ai/api", defaultPath = "/v1/chat/completions", defaultModel = "openai/gpt-4o-mini", requiresKey = true },
    together = { label = "Together", mode = "openai", defaultHost = "https://api.together.xyz", defaultPath = "/v1/chat/completions", defaultModel = "meta-llama/Llama-3.3-70B-Instruct-Turbo", requiresKey = true },
    vllm = { label = "vLLM", mode = "openai", defaultHost = "http://127.0.0.1:8000", defaultPath = "/v1/chat/completions", defaultModel = "local-model", requiresKey = false },
}

local titles = {
    "  _______ _______  ____   _____\n / ____/ /_  __/ / / / | / / _ \\\n/ /     __/ / / /_/ /  |/ / , _/\n\\_/    /_/ /_/\\____/_/|_/_/|_|\n",
    "  _______ ______  ____  _____\n / ___/ _ \\/ __/ / __ \\/ ___/\n/ /__/ ___/\\ \\  / /_/ / /__\n\\___/_/  /___/ \\____/\\___/\n",
    "  ______ ______  ____  _____\n / ____//_  __/ / __ \\/ ___/\n/ /      / /   / /_/ /\\__ \\\n\\_/      /_/    \\____//____/\n",
}

Utility.split = function(inputstr)
    local parts = {}
    for token in string.gmatch(inputstr or "", "%S+") do
        table.insert(parts, token)
    end
    return parts
end

Utility.trim = function(value)
    if value == nil then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end

Utility.starts_with = function(value, prefix)
    return tostring(value or ""):sub(1, #prefix) == prefix
end

Utility.timestamp = function()
    return tostring(os.epoch("utc"))
end

Utility.normalize_host = function(host)
    host = Utility.trim(host)
    if host:sub(-1) == "/" then host = host:sub(1, -2) end
    return host
end

Utility.mask_secret = function(value)
    value = tostring(value or "")
    if value == "" then return "(empty)" end
    if #value <= 6 then return string.rep("*", #value) end
    return value:sub(1, 3) .. string.rep("*", #value - 6) .. value:sub(-3)
end

Settings.default_settings = {
    provider = "ollama",
    host = "http://127.0.0.1:11434",
    apiKey = "",
    model = "llama3.2",
    maxTokens = 256,
    temperature = 0.7,
    keepAliveMins = 90,
    saveDir = "/ctos_saves",
    systemPrompt = "You are CTOS, a concise AI assistant running on a ComputerCraft computer.",
    openaiPath = "/v1/chat/completions",
    anthropicVersion = "2023-06-01",
}

Utility.normalize_setting_value = function(setting, value)
    local default = Settings.default_settings[setting]
    if type(default) == "number" then
        local numeric = tonumber(value)
        if numeric == nil then return nil, "Value must be numeric." end
        return numeric
    end
    return value
end

Screen.clear = function()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

Screen.print_color = function(text, color)
    term.setTextColor(color)
    write(text)
    term.setTextColor(colors.white)
end

Screen.print_colored_text = function(data)
    local remaining = tostring(data or "")
    while #remaining > 0 do
        local startPos, endPos, colorName, body = remaining:find("{([%a_]+)}(.-){/%1}")
        if not startPos then
            Screen.print_color(remaining, colors.white)
            break
        end
        if startPos > 1 then
            Screen.print_color(remaining:sub(1, startPos - 1), colors.white)
        end
        Screen.print_color(body, colors[colorName] or colors.white)
        remaining = remaining:sub(endPos + 1)
    end
end

Screen.print_with_random_colors = function(data)
    for char in tostring(data or ""):gmatch(".") do
        Screen.print_color(char, 2 ^ math.random(0, 14))
    end
end

Screen.gradual_print = function(data)
    for word in tostring(data or ""):gmatch("%S+") do
        write(word .. " ")
        sleep(math.random() / 8)
    end
    write("\n")
end

Settings.set = function(name, value)
    settings.set(SETTINGS_PREFIX .. name, value)
    settings.save()
end

Settings.get = function(name)
    return settings.get(SETTINGS_PREFIX .. name)
end

Settings.init = function(name, default)
    local value = Settings.get(name)
    if value == nil then
        Settings.set(name, default)
        return default
    end
    return value
end

local function get_provider()
    local providerName = Utility.trim(Settings.get("provider") or "ollama"):lower()
    return providerName, PROVIDERS[providerName]
end

local function apply_provider_defaults(providerName)
    local provider = PROVIDERS[providerName]
    if not provider then return false, "Unknown provider." end
    Settings.set("provider", providerName)
    if provider.defaultHost then Settings.set("host", provider.defaultHost) end
    if provider.defaultModel then Settings.set("model", provider.defaultModel) end
    if provider.defaultPath then Settings.set("openaiPath", provider.defaultPath) end
    return true
end

local function ensure_save_dir()
    local saveDir = Settings.get("saveDir")
    if not fs.exists(saveDir) then fs.makeDir(saveDir) end
end

local function get_system_prompt()
    return Utility.trim(Settings.get("systemPrompt") or "")
end

local function build_chat_messages(includeSystem)
    local payloadMessages = {}
    local systemPrompt = get_system_prompt()
    if includeSystem and systemPrompt ~= "" then
        table.insert(payloadMessages, { role = "system", content = systemPrompt })
    end
    for i = 1, #Messages do
        table.insert(payloadMessages, { role = Messages[i].role, content = Messages[i].content })
    end
    return payloadMessages
end

local function build_google_contents()
    local contents = {}
    local systemPrompt = get_system_prompt()
    if systemPrompt ~= "" then
        table.insert(contents, { role = "user", parts = { { text = "System instruction:\n" .. systemPrompt } } })
    end
    for i = 1, #Messages do
        table.insert(contents, {
            role = Messages[i].role == "assistant" and "model" or "user",
            parts = { { text = Messages[i].content } }
        })
    end
    return contents
end

local function build_anthropic_messages()
    local items = {}
    for i = 1, #Messages do
        if Messages[i].role ~= "system" then
            table.insert(items, { role = Messages[i].role, content = Messages[i].content })
        end
    end
    return items
end

local function print_conversation_message(message)
    local prefix = message.role == "user" and "{magenta}[Me]{/magenta}: " or "{lime}[CTOS]{/lime}: "
    Screen.print_colored_text(prefix .. message.content .. "\n")
end

local function save_messages(name)
    ensure_save_dir()
    local filePath = fs.combine(Settings.get("saveDir"), (name or Utility.timestamp()) .. ".txt")
    local file = fs.open(filePath, "w")
    file.write(textutils.serializeJSON(Messages))
    file.close()
    write("Conversation saved to " .. filePath .. "\n")
end

local function load_messages(index)
    ensure_save_dir()
    local files = fs.list(Settings.get("saveDir"))
    table.sort(files)
    if index == nil then
        if #files == 0 then
            write("No saved conversations found.\n")
            return
        end
        for i, file in ipairs(files) do
            Screen.print_colored_text("[{lime}" .. tostring(i) .. "{/lime}]: " .. file .. "\n")
        end
        return
    end
    local n = tonumber(index)
    if n == nil or files[n] == nil then
        write("Invalid save index.\n")
        return
    end
    local file = fs.open(fs.combine(Settings.get("saveDir"), files[n]), "r")
    local content = file.readAll()
    file.close()
    local decoded = textutils.unserializeJSON(content)
    if type(decoded) ~= "table" then
        write("Save file is invalid.\n")
        return
    end
    Messages = {}
    for i = 1, #decoded do
        if type(decoded[i]) == "table" and decoded[i].role and decoded[i].content then
            table.insert(Messages, { role = decoded[i].role, content = decoded[i].content })
        end
    end
    Screen.clear()
    for i = 1, #Messages do
        print_conversation_message(Messages[i])
    end
end

local function print_setting(name)
    local value = Settings.get(name)
    if name == "apiKey" then value = Utility.mask_secret(value) end
    write(name .. ": " .. tostring(value) .. "\n")
end

local function read_error_message(body, fallback)
    local decoded = textutils.unserializeJSON(body or "")
    if type(decoded) ~= "table" then return fallback end
    if decoded.error then
        if type(decoded.error) == "table" and decoded.error.message then
            return tostring(decoded.error.message)
        end
        return tostring(decoded.error)
    end
    return fallback
end

local function http_post_json(url, payloadTable, headers)
    local handle, err = http.post(url, textutils.serializeJSON(payloadTable), headers)
    if not handle then return false, err or "Request failed to start." end
    local body = handle.readAll()
    local code = handle.getResponseCode and handle.getResponseCode() or 200
    handle.close()
    if code >= 400 then return false, read_error_message(body, "HTTP " .. tostring(code)) end
    local decoded = textutils.unserializeJSON(body)
    if type(decoded) ~= "table" then return false, "Invalid JSON response." end
    return true, decoded
end

local function get_openai_endpoint()
    local host = Utility.normalize_host(Settings.get("host") or "")
    local path = Utility.trim(Settings.get("openaiPath") or "/v1/chat/completions")
    if host == "" then return nil end
    if path == "" then path = "/v1/chat/completions" end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return host .. path
end

local function get_ollama_endpoint()
    local host = Utility.normalize_host(Settings.get("host") or "")
    if host == "" then return nil end
    return host .. "/api/chat"
end

local function get_google_endpoint()
    local host = Utility.normalize_host(Settings.get("host") or "")
    local model = Utility.trim(Settings.get("model") or "")
    local key = Utility.trim(Settings.get("apiKey") or "")
    if host == "" or model == "" or key == "" then return nil end
    if not Utility.starts_with(model, "models/") then model = "models/" .. model end
    return host .. "/v1beta/" .. model .. ":generateContent?key=" .. textutils.urlEncode(key)
end

local function get_anthropic_endpoint()
    local host = Utility.normalize_host(Settings.get("host") or "")
    if host == "" then return nil end
    return host .. "/v1/messages"
end

local function parse_provider_reply(provider, decoded)
    if provider.mode == "ollama" then
        if decoded.message and decoded.message.content then return decoded.message.content end
        return nil, decoded.error and tostring(decoded.error) or "Invalid Ollama response."
    elseif provider.mode == "openai" then
        local choice = decoded.choices and decoded.choices[1]
        if choice and choice.message and choice.message.content then return choice.message.content end
        if decoded.error then
            return nil, type(decoded.error) == "table" and tostring(decoded.error.message or "API error") or tostring(decoded.error)
        end
        return nil, "Invalid provider response."
    elseif provider.mode == "google" then
        local candidate = decoded.candidates and decoded.candidates[1]
        local parts = candidate and candidate.content and candidate.content.parts
        if type(parts) == "table" then
            local chunks = {}
            for i = 1, #parts do
                if parts[i].text then table.insert(chunks, parts[i].text) end
            end
            local combined = table.concat(chunks, "\n")
            if combined ~= "" then return combined end
        end
        return nil, decoded.error and tostring(decoded.error.message or decoded.error) or "Invalid Google AI response."
    elseif provider.mode == "anthropic" then
        if type(decoded.content) == "table" then
            local chunks = {}
            for i = 1, #decoded.content do
                if decoded.content[i].text then table.insert(chunks, decoded.content[i].text) end
            end
            local combined = table.concat(chunks, "\n")
            if combined ~= "" then return combined end
        end
        return nil, decoded.error and tostring(decoded.error.message or decoded.error) or "Invalid Anthropic response."
    end
    return nil, "Unsupported provider mode."
end

local function request_chat_response()
    local providerName, provider = get_provider()
    if not provider then return false, "Unknown provider '" .. tostring(providerName) .. "'." end

    Screen.print_colored_text("{lime}[CTOS]{/lime}: ")
    write(".")

    local ok, decoded
    if provider.mode == "ollama" then
        local endpoint = get_ollama_endpoint()
        if not endpoint then return false, "Ollama host is not configured." end
        ok, decoded = http_post_json(endpoint, {
            model = Settings.get("model"),
            messages = build_chat_messages(true),
            stream = false,
            options = { temperature = Settings.get("temperature"), num_predict = Settings.get("maxTokens") },
            keep_alive = tostring(Settings.get("keepAliveMins")) .. "m",
        }, { ["Content-Type"] = "application/json" })
    elseif provider.mode == "openai" then
        local endpoint = get_openai_endpoint()
        local apiKey = Utility.trim(Settings.get("apiKey") or "")
        if not endpoint then return false, "Provider host is not configured." end
        if provider.requiresKey and apiKey == "" then return false, "API key is required for " .. provider.label .. "." end
        local headers = { ["Content-Type"] = "application/json" }
        if apiKey ~= "" then headers["Authorization"] = "Bearer " .. apiKey end
        if Settings.get("provider") == "openrouter" then
            headers["HTTP-Referer"] = "https://computercraft.local"
            headers["X-Title"] = APP_NAME
        end
        ok, decoded = http_post_json(endpoint, {
            model = Settings.get("model"),
            messages = build_chat_messages(true),
            temperature = Settings.get("temperature"),
            max_tokens = Settings.get("maxTokens"),
        }, headers)
    elseif provider.mode == "google" then
        local endpoint = get_google_endpoint()
        if not endpoint then return false, "Google AI host, model, or apiKey is not configured." end
        ok, decoded = http_post_json(endpoint, {
            contents = build_google_contents(),
            generationConfig = {
                temperature = Settings.get("temperature"),
                maxOutputTokens = Settings.get("maxTokens"),
            }
        }, { ["Content-Type"] = "application/json" })
    elseif provider.mode == "anthropic" then
        local endpoint = get_anthropic_endpoint()
        local apiKey = Utility.trim(Settings.get("apiKey") or "")
        if not endpoint then return false, "Anthropic host is not configured." end
        if provider.requiresKey and apiKey == "" then return false, "API key is required for " .. provider.label .. "." end
        ok, decoded = http_post_json(endpoint, {
            model = Settings.get("model"),
            max_tokens = Settings.get("maxTokens"),
            temperature = Settings.get("temperature"),
            system = get_system_prompt(),
            messages = build_anthropic_messages(),
        }, {
            ["Content-Type"] = "application/json",
            ["x-api-key"] = apiKey,
            ["anthropic-version"] = Settings.get("anthropicVersion"),
        })
    else
        ok, decoded = false, "Unsupported provider mode."
    end

    local _, y = term.getCursorPos()
    term.setCursorPos(1, y)
    term.clearLine()
    if not ok then return false, decoded end

    local reply, parseErr = parse_provider_reply(provider, decoded)
    if not reply then return false, parseErr end
    table.insert(Messages, { role = "assistant", content = reply })
    Screen.print_colored_text("{lime}[CTOS]{/lime}: ")
    Screen.gradual_print(reply)
    return true
end

local descriptions = {
    exit = "Stops the program.",
    clear = "Clears the screen.",
    new = "Starts a new conversation.",
    save = "{lime}/save{/lime} {green}[name]{/green}\n- Saves the current conversation.",
    load = "{lime}/load{/lime} {green}[index]{/green}\n- Lists or loads saved conversations.",
    help = "{lime}/help{/lime} {green}[command]{/green}\n- Shows command help.",
    providers = "{lime}/providers{/lime} {green}[list|use|info]{/green} {green}[name]{/green}\n- Lists or switches providers.\n- Includes Ollama, OpenAI, Google AI, Grok AI, LiteLLM and more.",
    ctos = "{lime}ctos{/lime} {green}[subcommand]{/green}\n- Main CTOS control command.\n- Examples: {lime}ctos provider openai{/lime}, {lime}ctos set apiKey sk-...{/lime}",
    settings = "{lime}/settings{/lime} {green}[list|set|reset]{/green} {green}[setting]{/green} {green}[value]{/green}\n- Settings include provider, host, apiKey, model, systemPrompt.",
    status = "{lime}/status{/lime}\n- Shows version, provider, host, model, and message count.",
}

local controller = {}

controller.help = function(args)
    if args == nil or #args == 0 then
        local sortedCommands = {}
        for key, _ in pairs(Commands) do table.insert(sortedCommands, key) end
        table.sort(sortedCommands)
        for _, key in ipairs(sortedCommands) do
            Screen.print_color("/" .. key, colors.lime)
            write(" - " .. Commands[key].brief .. "\n")
        end
        return
    end
    local command = Commands[args[1]]
    if command then
        Screen.print_colored_text(command.description .. "\n")
    else
        write("Command not found.\n")
    end
end

controller.exit = function() error("CTOS offline.", 0) end
controller.clear = function() Screen.clear() end
controller.new = function() Messages = {}; Screen.clear(); write("New CTOS conversation started.\n") end
controller.save = function(args) save_messages(args[1]) end
controller.load = function(args) load_messages(args[1]) end

controller.status = function()
    local providerName, provider = get_provider()
    write(APP_NAME .. " status\n")
    write("version: " .. APP_VERSION .. "\n")
    write("provider: " .. providerName .. (provider and (" (" .. provider.label .. ")") or "") .. "\n")
    print_setting("host")
    print_setting("model")
    print_setting("apiKey")
    write("messages: " .. tostring(#Messages) .. "\n")
end

controller.providers = function(args)
    local subcommand = (args[1] or "list"):lower()
    if subcommand == "list" then
        local names = {}
        for name, _ in pairs(PROVIDERS) do table.insert(names, name) end
        table.sort(names)
        for _, name in ipairs(names) do
            local provider = PROVIDERS[name]
            local marker = Settings.get("provider") == name and "*" or " "
            write(marker .. " " .. name .. " - " .. provider.label .. "\n")
        end
        return
    elseif subcommand == "use" then
        local providerName = Utility.trim(args[2] or ""):lower()
        if providerName == "" then write("Please specify provider name.\n"); return end
        local ok, err = apply_provider_defaults(providerName)
        if not ok then write(err .. "\n"); return end
        write("Provider set to " .. providerName .. ".\n")
        controller.status()
        return
    elseif subcommand == "info" then
        local providerName = Utility.trim(args[2] or Settings.get("provider") or ""):lower()
        local provider = PROVIDERS[providerName]
        if not provider then write("Unknown provider.\n"); return end
        write(providerName .. " - " .. provider.label .. "\n")
        write("mode: " .. provider.mode .. "\n")
        write("defaultHost: " .. tostring(provider.defaultHost) .. "\n")
        write("defaultModel: " .. tostring(provider.defaultModel) .. "\n")
        write("requiresKey: " .. tostring(provider.requiresKey) .. "\n")
        return
    end
    write("Unknown providers subcommand.\n")
end

controller.ctos = function(args)
    local subcommand = (args[1] or "status"):lower()
    if subcommand == "help" then
        Screen.print_colored_text(descriptions.ctos .. "\n")
    elseif subcommand == "status" then
        controller.status()
    elseif subcommand == "providers" then
        controller.providers({ "list" })
    elseif subcommand == "provider" then
        if args[2] then controller.providers({ "use", args[2] }) else controller.providers({ "list" }) end
    elseif subcommand == "list" then
        controller.settings({ "list" })
    elseif subcommand == "set" or subcommand == "reset" or subcommand == "clear" or subcommand == "default" then
        controller.settings(args)
    elseif Settings.default_settings[subcommand] ~= nil then
        controller.settings({ subcommand })
    else
        write("Unknown CTOS subcommand. Use 'ctos help'.\n")
    end
end

controller.settings = function(args)
    local subcommand = (args[1] or "list"):lower()
    if Settings.default_settings[subcommand] ~= nil then
        print_setting(subcommand)
        return
    end
    if subcommand == "list" then
        local ordered = {}
        for setting, _ in pairs(Settings.default_settings) do table.insert(ordered, setting) end
        table.sort(ordered)
        for _, setting in ipairs(ordered) do print_setting(setting) end
        return
    elseif subcommand == "set" then
        local setting = args[2]
        local value = table.concat(args, " ", 3)
        if not setting or setting == "" then write("Please specify setting.\n"); return end
        if Settings.default_settings[setting] == nil then write("Invalid setting.\n"); return end
        if not value or value == "" then write("Please specify value.\n"); return end
        local normalized, err = Utility.normalize_setting_value(setting, value)
        if err then write(err .. "\n"); return end
        if setting == "provider" then
            local ok, applyErr = apply_provider_defaults(tostring(normalized):lower())
            if not ok then write(applyErr .. "\n"); return end
        else
            Settings.set(setting, normalized)
        end
        write("Updated " .. setting .. ".\n")
        return
    elseif subcommand == "reset" or subcommand == "clear" or subcommand == "default" then
        local setting = args[2]
        if not setting or setting == "" then write("Please specify setting.\n"); return end
        if Settings.default_settings[setting] == nil then write("Invalid setting.\n"); return end
        Settings.set(setting, Settings.default_settings[setting])
        write("Reset " .. setting .. ".\n")
        return
    end
    write("Unknown settings subcommand.\n")
end

Commands = {
    clear = { brief = "Clears the screen.", description = descriptions.clear, dispatch = controller.clear },
    ctos = { brief = "Primary CTOS control command.", description = descriptions.ctos, dispatch = controller.ctos },
    exit = { brief = "Stops the program.", description = descriptions.exit, dispatch = controller.exit },
    help = { brief = "Get commands and command info.", description = descriptions.help, dispatch = controller.help },
    load = { brief = "Loads a saved conversation.", description = descriptions.load, dispatch = controller.load },
    new = { brief = "Starts a new conversation.", description = descriptions.new, dispatch = controller.new },
    providers = { brief = "Lists or switches AI providers.", description = descriptions.providers, dispatch = controller.providers },
    save = { brief = "Saves the current conversation.", description = descriptions.save, dispatch = controller.save },
    settings = { brief = "Lists or updates settings.", description = descriptions.settings, dispatch = controller.settings },
    status = { brief = "Shows current CTOS connection details.", description = descriptions.status, dispatch = controller.status },
}

local function init_settings()
    for setting, default in pairs(Settings.default_settings) do
        Settings.init(setting, default)
    end
end

local function print_intro()
    Screen.clear()
    if not pocket then
        Screen.print_with_random_colors(titles[math.random(1, #titles)])
    end
    Screen.print_colored_text("{lime}" .. APP_NAME .. "{/lime} v" .. APP_VERSION .. " multi-provider AI terminal\n")
    Screen.print_colored_text("{lightGray}Code Created by 0x00sec but modified by NekoSuneVR{/lightGray}\n")
    Screen.print_colored_text("Type {lime}/help{/lime} or {lime}ctos help{/lime} for commands.\n\n")
end

local function main()
    init_settings()
    ensure_save_dir()
    print_intro()
    while true do
        Screen.print_colored_text("{magenta}[Me]{/magenta}: ")
        local userInput = Utility.trim(read())
        local firstToken = Utility.split(userInput)[1]
        local firstTokenLower = firstToken and firstToken:lower() or nil
        if userInput ~= "" and (Utility.starts_with(userInput, "/") or firstTokenLower == "ctos") then
            local commandText = Utility.starts_with(userInput, "/") and userInput:sub(2) or userInput
            local parts = Utility.split(commandText)
            local commandName = parts[1] and parts[1]:lower() or nil
            if commandName and Commands[commandName] then
                Commands[commandName].dispatch({ table.unpack(parts, 2) })
            else
                Commands.help.dispatch({})
            end
        elseif userInput ~= "" then
            table.insert(Messages, { role = "user", content = userInput })
            local success, err = request_chat_response()
            if not success then
                table.remove(Messages, #Messages)
                write("Request failed: " .. tostring(err) .. "\n")
            end
        end
    end
end

main()
