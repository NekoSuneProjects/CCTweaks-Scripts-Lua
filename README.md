# CCTweaks-Scripts-Lua

CC: Tweaked / ComputerCraft scripts for the NekoSune community.

## Jukebox

Created by `0x00sec` and `NekoSuneVR`.

The Jukebox system is a wireless music player setup for CC: Tweaked with:

- Jukebox computer app
- Pocket remote app
- Wireless speaker node app
- Auto-update startup installers
- Pair-code based pairing for remotes and speakers
- Stream URL playback
- YouTube search / URL add support
- Wireless multi-speaker playback across your base / house
- Connected pocket count and speaker count on the jukebox UI

## What The Jukebox Has

- Wireless pairing with pocket remotes
- Wireless pairing with speaker nodes
- Pair-code security so random devices do not connect
- Playlist control from monitor or pocket remote
- Play / stop / next / previous controls
- Remote playlist selection
- YouTube add support through the configured API endpoint
- Stream URL add support
- Boot-time auto updater
- Press any key during boot to skip auto-start
- `Q` or `Backspace` to exit the apps

## Jukebox Files

- `Jukebox/jukebox_v2.lua`
- `Jukebox/pocket_remote_v2.lua`
- `Jukebox/speaker_node_v2.lua`
- `Jukebox/install_jukebox.lua`
- `Jukebox/install_pocket_remote.lua`
- `Jukebox/install_speaker_node.lua`

## Install

Make sure `http` is enabled in CC: Tweaked.

### 1. Jukebox Computer

Needed peripherals:

- monitor
- speaker
- wireless modem

Install:

```lua
wget run https://raw.githubusercontent.com/NekoSuneProjects/CCTweaks-Scripts-Lua/main/Jukebox/install_jukebox.lua
```

What it does:

- installs `/jukebox_v2.lua`
- installs `/startup.lua`
- checks for updates on every boot
- starts the jukebox automatically

### 2. Pocket Remote

Needed peripherals:

- pocket computer with wireless modem

Install:

```lua
wget run https://raw.githubusercontent.com/NekoSuneProjects/CCTweaks-Scripts-Lua/main/Jukebox/install_pocket_remote.lua
```

What it does:

- installs `/pocket_remote_v2.lua`
- installs `/startup.lua`
- checks for updates on every boot
- starts the remote automatically

Pairing:

- open the pocket remote
- press `Pair`
- choose the jukebox number
- enter the pair code shown on the jukebox monitor

### 3. Wireless Speaker Node

Needed peripherals:

- computer with speaker
- wireless modem

Install:

```lua
wget run https://raw.githubusercontent.com/NekoSuneProjects/CCTweaks-Scripts-Lua/main/Jukebox/install_speaker_node.lua
```

What it does:

- installs `/speaker_node_v2.lua`
- installs `/startup.lua`
- checks for updates on every boot
- starts the speaker node automatically

Pairing:

- open the speaker node
- press `P`
- choose the jukebox number
- enter the pair code shown on the jukebox monitor

Unpair:

- press `U`

## Usage

### Add Music On Jukebox

Use the `Add` button on the jukebox monitor.

Current add modes:

- Stream URL
- YouTube search / URL

### Pocket Controls

The pocket remote can:

- pair to a jukebox
- sync state
- play / stop
- next / previous
- select songs from playlist

### Speaker Nodes

Speaker nodes:

- pair to one jukebox only
- ignore other jukeboxes
- play wireless audio chunks from the paired jukebox

## Boot / Update Behavior

On boot:

- the startup script checks for updates
- it shows whether the device updated or is already current
- it shows the version being run
- press any key during the short boot delay to skip auto-start

## Notes

- YouTube playback depends on the configured external API / relay service
- Live radio MP3 streams need a relay that converts audio to DFPWM for CC: Tweaked
- Wireless speakers are best-effort and may have some delay depending on network conditions

## TODO

- Live radio support is not fully tested yet
- MP3 live radio to DFPWM relay support should be treated as experimental until more testing is done

## ChatGPT

Original code by `0x00sec`, modified by `NekoSuneVR`.

`ChatGPT` is a ComputerCraft / CC: Tweaked terminal AI client with:

- local conversation saves
- boot-time auto update
- version display on startup
- provider switching
- support for hosted and selfhosted AI endpoints

### Supported Providers

- Ollama
- OpenAI
- Google AI
- Grok AI / xAI
- Anthropic
- Groq
- OpenRouter
- DeepSeek
- Mistral
- Together
- LiteLLM selfhosted
- LM Studio
- LocalAI
- vLLM

### ChatGPT Files

- `ChatGPT/ctos_chatgpt_v1.lua`
- `ChatGPT/startup_ctos.lua`
- `ChatGPT/install_ctos.lua`

### Install ChatGPT

```lua
wget run https://raw.githubusercontent.com/NekoSuneProjects/CCTweaks-Scripts-Lua/main/ChatGPT/install_ctos.lua
```

What it does:

- installs `/ctos_chatgpt_v1.lua`
- installs `/startup.lua`
- checks for updates on every boot
- shows the current version on boot
- starts CTOS automatically

### ChatGPT Commands

Commands can be used with or without `/`.

Main commands:

- `help`
- `help status`
- `status`
- `clear`
- `new`
- `save`
- `save my_chat_name`
- `load`
- `load 1`
- `exit`

Provider commands:

- `providers`
- `providers list`
- `providers info`
- `providers info ollama`
- `providers use ollama`
- `providers use openai`
- `providers use google`
- `providers use grok`
- `providers use litellm`
- `providers use openrouter`
- `providers use anthropic`
- `providers use groq`
- `providers use lmstudio`
- `providers use localai`
- `providers use vllm`

Settings commands:

- `settings list`
- `settings host`
- `settings model`
- `settings apiKey`
- `settings systemPrompt`
- `settings set host http://127.0.0.1:11434`
- `settings set apiKey YOUR_API_KEY`
- `settings set model llama3.2`
- `settings set systemPrompt You are a concise helpful assistant.`
- `settings reset host`
- `settings reset model`
- `settings reset apiKey`
- `settings reset systemPrompt`

CTOS alias commands:

- `ctos help`
- `ctos status`
- `ctos providers`
- `ctos provider ollama`
- `ctos provider openai`
- `ctos list`
- `ctos set host http://127.0.0.1:11434`
- `ctos set model llama3.2`
- `ctos set systemPrompt You are a helpful assistant.`
- `ctos reset systemPrompt`

### ChatGPT Setup Examples

Ollama:

```text
/providers use ollama
/settings set host http://127.0.0.1:11434
/settings set model llama3.2
/status
```

Remote Ollama:

```text
/providers use ollama
/settings set host http://HOSTIP:11434
/settings set model llama3.2
/status
```

OpenAI:

```text
/providers use openai
/settings set apiKey YOUR_API_KEY
/settings set model gpt-4o-mini
/status
```

Google AI:

```text
/providers use google
/settings set apiKey YOUR_API_KEY
/settings set model gemini-2.0-flash
/status
```

LiteLLM:

```text
/providers use litellm
/settings set host http://127.0.0.1:4000
/settings set apiKey YOUR_API_KEY
/settings set model gpt-4o-mini
/status
```

### Notes For ChatGPT

- `providers use ...` is a local command and should not be sent to the AI
- LiteLLM, LM Studio, LocalAI, and vLLM use OpenAI-compatible APIs
- Ollama does not require an API key by default
- `apiKey` is privacy-masked in CTOS status/settings output, so it does not print the full secret on screen
