local PROTOCOL_DISCOVERY = "jukebox_v2_discovery"
local PROTOCOL_CONTROL   = "jukebox_v2_control"
local PROTOCOL_STATE     = "jukebox_v2_state"
local APP_VERSION = "2026.03.11-2"

local DATA_FILE = "/pocket_jukebox_pair.db"

local modem = peripheral.find("modem")
if not modem then error("Wireless modem required") end
rednet.open(peripheral.getName(modem))

local pairData = { targetId=nil, targetName=nil }
local remoteName = os.getComputerLabel() or ("Pocket-"..os.getComputerID())

local state = {
    playerName="None",
    status="Idle",
    nowPlaying="Nothing",
    playing=false,
    currentIndex=1,
    selectedIndex=1,
    count=0,
    playlist={}
}

local buttons={}
local scroll=1

local function showMessage(lines,pause)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1,1)

    for i,line in ipairs(lines) do
        term.setCursorPos(1,i)
        term.write(line)
    end

    if pause and pause>0 then
        sleep(pause)
    end
end

local function trim(s)
    s=tostring(s or "")
    return (s:gsub("^%s+",""):gsub("%s+$",""))
end

------------------------------------------------
-- FILE SAVE / LOAD
------------------------------------------------

local function save()
    local f=fs.open(DATA_FILE,"w")
    f.write(textutils.serialize(pairData))
    f.close()
end

local function load()
    if fs.exists(DATA_FILE) then
        local f=fs.open(DATA_FILE,"r")
        pairData=textutils.unserialize(f.readAll()) or pairData
        f.close()
    end
end

------------------------------------------------
-- BUTTON SYSTEM
------------------------------------------------

local function clearButtons()
    buttons={}
end

local function addButton(name,x1,y1,x2,y2,bg,fg,label)

    term.setBackgroundColor(bg)
    term.setTextColor(fg)

    for y=y1,y2 do
        buttons[y]=buttons[y] or {}
        term.setCursorPos(x1,y)
        term.write(string.rep(" ",x2-x1+1))
        for x=x1,x2 do
            buttons[y][x]=name
        end
    end

    local tx=math.floor((x1+x2-#label)/2)
    local ty=math.floor((y1+y2)/2)

    term.setCursorPos(tx,ty)
    term.write(label)
end

------------------------------------------------
-- SEND COMMAND
------------------------------------------------

local function send(action,data)

    if not pairData.targetId then return end

    local payload={
        type="command",
        targetId=pairData.targetId,
        action=action,
        remoteName=remoteName
    }

    if data then
        for k,v in pairs(data) do payload[k]=v end
    end

    rednet.send(pairData.targetId,payload,PROTOCOL_CONTROL)
end

local function sendHeartbeat()
    if not pairData.targetId then return end
    rednet.send(pairData.targetId,{
        type="heartbeat",
        targetId=pairData.targetId,
        remoteName=remoteName
    },PROTOCOL_CONTROL)
end

------------------------------------------------
-- DISCOVERY
------------------------------------------------

local function discover()

    rednet.broadcast({type="discover"},PROTOCOL_DISCOVERY)

    local found={}
    local timer=os.startTimer(1)

    while true do
        local e={os.pullEvent()}

        if e[1]=="rednet_message" then
            local id,msg,prot=e[2],e[3],e[4]

            if prot==PROTOCOL_DISCOVERY and type(msg)=="table" and msg.type=="discover_reply" then
                local exists=false
                for _,entry in ipairs(found) do
                    if entry.id==id then
                        exists=true
                        break
                    end
                end

                if not exists then
                    table.insert(found,{id=id,name=msg.playerName})
                end
            end

        elseif e[1]=="timer" then
            break
        end
    end

    return found
end

------------------------------------------------
-- PAIR SCREEN
------------------------------------------------

local function pairMenu()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1,1)
    print("Pair Pocket Remote")
    print("")
    print("Scanning for jukeboxes...")

    local list=discover()

    if #list==0 then
        print("")
        print("No jukebox found")
        sleep(2)
        return
    end

    term.clear()
    term.setCursorPos(1,1)
    print("Pair Pocket Remote")
    print("")

    for i,v in ipairs(list) do
        print(i..") "..v.name.." ["..v.id.."]")
    end

    print("")
    print("Choose computer number:")

    local n=tonumber(read())
    if not list[n] then return end

    print("")
    print("Enter Pair Code:")
    local code=trim(read())

    rednet.send(list[n].id,{
        type="pair_request",
        remoteName=remoteName,
        code=code
    },PROTOCOL_DISCOVERY)

    print("")
    print("Pairing...")

    local deadline=os.clock()+4
    local replyId,msg,prot=nil,nil,nil

    while os.clock()<deadline do
        local remaining=math.max(0,deadline-os.clock())
        local rid,rmsg,rprot=rednet.receive(PROTOCOL_DISCOVERY,remaining)

        if not rid then
            break
        end

        if rprot==PROTOCOL_DISCOVERY and rid==list[n].id and type(rmsg)=="table" and rmsg.type=="pair_reply" then
            replyId,msg,prot=rid,rmsg,rprot
            break
        end
    end

    if prot==PROTOCOL_DISCOVERY and replyId==list[n].id and type(msg)=="table" and msg.type=="pair_reply" and msg.ok then
        pairData.targetId=list[n].id
        pairData.targetName=list[n].name
        save()
        state.playerName=list[n].name
        print("")
        print("Paired with "..list[n].name)
        rednet.send(pairData.targetId,{
            type="command",
            targetId=pairData.targetId,
            action="request_state"
        },PROTOCOL_CONTROL)
        sleep(1)
    else
        local reason="Pairing failed"
        if type(msg)=="table" and msg.reason and msg.reason~="" then
            reason=msg.reason
        elseif not replyId then
            reason="No pair reply from jukebox"
        end
        print("")
        print(reason)
        sleep(2)
    end
end

------------------------------------------------
-- UI DRAW
------------------------------------------------

local function draw()

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()

    clearButtons()

    local w,h=term.getSize()

    term.setCursorPos(1,1)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.black)
    term.write(string.rep(" ",w))
    term.setCursorPos(2,1)
    term.write("Pocket Jukebox v"..APP_VERSION)

    term.setBackgroundColor(colors.black)

    term.setCursorPos(1,3)
    print("Target: "..(pairData.targetName or "None"))

    term.setCursorPos(1,4)
    print("Status: "..state.status)

    term.setCursorPos(1,5)
    print("Now: "..state.nowPlaying)

    term.setCursorPos(1,6)
    print("Q/Back = Exit")

    ------------------------------------------------
    -- BUTTONS
    ------------------------------------------------

    addButton("prev",2,8,9,9,colors.orange,colors.black,"Prev")
    addButton("play",11,8,18,9,colors.lime,colors.black,"Play")
    addButton("stop",20,8,27,9,colors.red,colors.white,"Stop")
    addButton("next",29,8,36,9,colors.orange,colors.black,"Next")

    addButton("pair",2,10,9,11,colors.cyan,colors.black,"Pair")
    addButton("sync",11,10,18,11,colors.yellow,colors.black,"Sync")

    ------------------------------------------------
    -- PLAYLIST
    ------------------------------------------------

    local top=13
    local rows=h-top

    for i=1,rows do

        local idx=scroll+i-1
        local y=top+i-1

        term.setCursorPos(1,y)
        term.setBackgroundColor(colors.black)
        term.write(string.rep(" ",w))

        if state.playlist[idx] then

            local bg=colors.black
            local fg=colors.white

            if idx==state.selectedIndex then
                bg=colors.blue
            end

            if idx==state.currentIndex and state.playing then
                bg=colors.green
                fg=colors.black
            end

            term.setBackgroundColor(bg)
            term.setTextColor(fg)

            local name=state.playlist[idx].name or "Unknown"

            term.setCursorPos(1,y)
            term.write(string.format("%02d %s",idx,name))

            buttons[y]=buttons[y] or {}
            for x=1,w do
                buttons[y][x]="song:"..idx
            end
        end
    end
end

------------------------------------------------
-- EVENT LOOP
------------------------------------------------

local function uiLoop()

    while true do

        draw()

        local e={os.pullEvent()}

        if e[1]=="mouse_click" then

            local x,y=e[3],e[4]
            local hit=buttons[y] and buttons[y][x]

            if hit then

                if hit=="play" or hit=="stop" or hit=="next" or hit=="prev" then
                    send(hit)

                elseif hit=="pair" then
                    pairMenu()

                elseif hit=="sync" then
                    send("request_state")

                elseif hit:sub(1,5)=="song:" then
                    local id=tonumber(hit:sub(6))
                    send("select",{index=id})
                end
            end

        elseif e[1]=="rednet_message" then

            local id,msg,prot=e[2],e[3],e[4]

            if prot==PROTOCOL_STATE and id==pairData.targetId then
                state=msg
            end
        elseif e[1]=="key" then
            if e[2]==keys.q or e[2]==keys.backspace then
                showMessage({"Closing Pocket Jukebox..."},0.5)
                return
            end
        end
    end
end

local function heartbeatLoop()
    while true do
        sleep(5)
        sendHeartbeat()
    end
end

------------------------------------------------

load()
parallel.waitForAny(uiLoop,heartbeatLoop)
