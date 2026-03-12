local PROTOCOL_DISCOVERY = "jukebox_v2_discovery"
local PROTOCOL_CONTROL   = "jukebox_v2_control"
local PROTOCOL_STATE     = "jukebox_v2_state"
local APP_VERSION = "2026.03.12-12"

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
    playlist={},
    remoteRole="guest",
    remoteList={},
    speakers={},
    speakerCount=0,
    onlineSpeakerCount=0,
    brokenSpeakerCount=0,
    online=false,
    volume=1,
    localSpeakerCount=0,
}

local buttons={}
local scroll=1
local lastStateAt=0
local ONLINE_TIMEOUT=12

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

local function trimText(text,maxLen)
    text=tostring(text or "")
    if #text<=maxLen then return text end
    if maxLen<=3 then return text:sub(1,maxLen) end
    return text:sub(1,maxLen-3).."..."
end

local function fillRect(surface,x1,y1,x2,y2,bg)
    surface.setBackgroundColor(bg)
    for y=y1,y2 do
        surface.setCursorPos(x1,y)
        surface.write(string.rep(" ",math.max(0,x2-x1+1)))
    end
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

local function addActionButton(name,x1,y1,x2,y2,bg,fg,label,enabled)
    if enabled==nil then enabled=true end

    local drawBg=enabled and bg or colors.gray
    local drawFg=enabled and fg or colors.lightGray

    term.setBackgroundColor(drawBg)
    term.setTextColor(drawFg)

    for y=y1,y2 do
        term.setCursorPos(x1,y)
        term.write(string.rep(" ",x2-x1+1))
        if enabled then
            buttons[y]=buttons[y] or {}
            for x=x1,x2 do
                buttons[y][x]=name
            end
        end
    end

    local tx=math.max(x1,math.floor((x1+x2-#label)/2))
    local ty=math.floor((y1+y2)/2)

    term.setCursorPos(tx,ty)
    term.write(trimText(label,math.max(1,x2-x1+1)))
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

local function isAdmin()
    return state.remoteRole=="owner" or state.remoteRole=="admin"
end

local function isOwner()
    return state.remoteRole=="owner"
end

local function isOnline()
    return pairData.targetId and (os.clock()-lastStateAt) <= ONLINE_TIMEOUT
end

local function visibleRows()
    local _,h=term.getSize()
    local top=16
    return math.max(1,h-top+1)
end

local function clampScroll()
    local maxStart=math.max(1,#(state.playlist or {})-visibleRows()+1)
    if scroll<1 then scroll=1 end
    if scroll>maxStart then scroll=maxStart end
end

local function ensureSelectionVisible()
    local rows=visibleRows()
    local selected=tonumber(state.selectedIndex) or 1
    if selected<scroll then
        scroll=selected
    elseif selected>(scroll+rows-1) then
        scroll=selected-rows+1
    end
    clampScroll()
end

local function selectSong(index)
    index=tonumber(index)
    if not index or not state.playlist or not state.playlist[index] then
        return
    end
    send("select",{index=index})
end

local function moveSelection(delta)
    if not state.playlist or #state.playlist==0 then
        return
    end

    local nextIndex=(tonumber(state.selectedIndex) or 1)+delta
    if nextIndex<1 then nextIndex=1 end
    if nextIndex>#state.playlist then nextIndex=#state.playlist end
    selectSong(nextIndex)
end

local function pageScroll(delta)
    scroll=scroll+(visibleRows()*delta)
    clampScroll()
end

local function sendHeartbeat()
    if not pairData.targetId then return end
    rednet.send(pairData.targetId,{
        type="heartbeat",
        targetId=pairData.targetId,
        remoteName=remoteName
    },PROTOCOL_CONTROL)
    send("request_state")
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
    fillRect(term,1,1,w,h,colors.black)

    local function drawPill(x1,y,text,bg,fg)
        fillRect(term,x1,y,math.min(w,x1+#text+1),y,bg)
        term.setCursorPos(x1+1,y)
        term.setBackgroundColor(bg)
        term.setTextColor(fg)
        term.write(text)
    end

    local function drawPanel(x1,y1,x2,y2,headBg,title)
        fillRect(term,x1,y1,x2,y2,colors.black)
        fillRect(term,x1,y1,x2,y1,colors.gray)
        fillRect(term,x1,y2,x2,y2,colors.gray)
        fillRect(term,x1,y1,x1,y2,colors.gray)
        fillRect(term,x2,y1,x2,y2,colors.gray)
        fillRect(term,x1+1,y1+1,x2-1,y1+1,headBg)
        term.setCursorPos(x1+2,y1+1)
        term.setBackgroundColor(headBg)
        term.setTextColor(colors.black)
        term.write(trimText(title,math.max(1,x2-x1-2)))
    end

    local function remoteButton(name,x1,y1,x2,y2,bg,fg,label,enabled)
        addActionButton(name,x1,y1,x2,y2,bg,fg,label,enabled)
    end

    fillRect(term,1,1,1,h,colors.cyan)
    fillRect(term,2,1,w,1,colors.orange)
    term.setCursorPos(3,1)
    term.setBackgroundColor(colors.orange)
    term.setTextColor(colors.black)
    term.write(trimText("POCKET REMOTE "..APP_VERSION,math.max(1,w-3)))

    fillRect(term,2,2,w,2,colors.black)
    term.setCursorPos(3,2)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.write(trimText(pairData.targetName or "No target",math.max(1,w-12)))
    drawPill(math.max(3,w-8),2,isOnline() and "ON" or "OFF",isOnline() and colors.lime or colors.red,colors.black)

    fillRect(term,2,3,w,5,colors.black)
    term.setCursorPos(3,3)
    term.setTextColor(colors.lightGray)
    term.write(trimText("Status "..string.upper(state.status or "Idle"),math.max(1,w-4)))

    term.setCursorPos(3,4)
    term.setTextColor(colors.white)
    term.write(trimText(state.nowPlaying or "Nothing",math.max(1,w-4)))

    local onlineSpeakers=tonumber(state.onlineSpeakerCount) or 0
    local totalSpeakers=tonumber(state.speakerCount) or 0
    local selectedIndex=tonumber(state.selectedIndex) or 0
    local totalSongs=tonumber(state.count) or #(state.playlist or {})
    local summary=string.format("Sel %d/%d  Sp %d/%d",selectedIndex,totalSongs,onlineSpeakers,totalSpeakers)
    term.setCursorPos(2,5)
    term.setTextColor(colors.lightGray)
    term.write(trimText(summary,math.max(1,w-2)))
    drawPill(math.max(3,w-8),5,string.format("V%.1f",tonumber(state.volume) or 1),colors.gray,colors.black)

    drawPanel(2,6,w,13,colors.orange,"REMOTE")
    remoteButton("prev",4,8,10,9,colors.orange,colors.black,"Prev",true)
    remoteButton("play",13,7,20,9,colors.lime,colors.black,"Play",true)
    remoteButton("stop",23,8,30,9,colors.red,colors.white,"Stop",true)

    remoteButton("pair",4,11,10,12,colors.cyan,colors.black,"Pair",true)
    remoteButton("sync",13,10,20,12,colors.yellow,colors.black,"Sync",true)
    remoteButton("speakers",23,11,30,12,colors.gray,colors.white,"Spk",true)

    remoteButton("list_up",33,7,w-1,8,colors.gray,colors.white,"Up",true)
    remoteButton("next",33,9,w-1,10,colors.orange,colors.black,"Next",true)
    remoteButton("list_down",33,11,w-1,12,colors.gray,colors.white,"Down",true)

    fillRect(term,2,14,w,14,colors.cyan)
    term.setBackgroundColor(colors.cyan)
    term.setTextColor(colors.black)
    local listSummary=string.format("Playlist %d/%d",totalSongs>0 and math.min(scroll,totalSongs) or 0,totalSongs)
    term.setCursorPos(3,14)
    term.write(trimText(listSummary,math.max(1,w-3)))

    fillRect(term,2,15,w,15,colors.black)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.gray)
    local shortcutLine="Enter play  Left/Right page"
    if isOwner() then
        shortcutLine="A add  D del  R fix  M adm  B boot"
    elseif isAdmin() then
        shortcutLine="A add  D del  R fix  [ ] volume"
    elseif not isAdmin() then
        shortcutLine="S spk  Up/Down select"
    end
    term.setCursorPos(3,15)
    term.write(trimText(shortcutLine,math.max(1,w-3)))

    local top=16
    local rows=math.max(1,h-top+1)

    for i=1,rows do
        local idx=scroll+i-1
        local y=top+i-1
        local bg=(i%2==0) and colors.gray or colors.black
        local fg=(i%2==0) and colors.black or colors.white

        if idx==state.selectedIndex then
            bg=colors.blue
            fg=colors.white
        end

        if idx==state.currentIndex and state.playing then
            bg=colors.lime
            fg=colors.black
        end

        fillRect(term,2,y,w,y,bg)

        if state.playlist[idx] then
            local source="F"
            if state.playlist[idx].ytId then
                source="Y"
            elseif state.playlist[idx].url then
                source="U"
            end

            fillRect(term,2,y,4,y,idx==state.currentIndex and state.playing and colors.black or colors.orange)
            term.setCursorPos(3,y)
            term.setBackgroundColor(idx==state.currentIndex and state.playing and colors.black or colors.orange)
            term.setTextColor(idx==state.currentIndex and state.playing and colors.lime or colors.black)
            term.write(source)
            term.setCursorPos(6,y)
            term.setBackgroundColor(bg)
            term.setTextColor(fg)
            term.write(trimText(string.format("%02d %s",idx,state.playlist[idx].name or "Unknown"),math.max(1,w-7)))

            buttons[y]=buttons[y] or {}
            for x=2,w do
                buttons[y][x]="song:"..idx
            end
        end
    end
end

local function promptAddSong()
    if not isAdmin() then
        showMessage({"Admin access required"},1.5)
        return
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1,1)
    print("Add Song By URL")
    print("")
    print("Name:")
    local name=read()
    if not name or trim(name)=="" then
        return
    end

    print("")
    print("URL:")
    local url=read()
    if not url or trim(url)=="" then
        return
    end

    send("add_url",{name=name,url=url})
    send("request_state")
end

local function promptDeleteSong()
    if not isAdmin() then
        showMessage({"Admin access required"},1.5)
        return
    end

    if not state.playlist or #state.playlist==0 then
        showMessage({"No songs to delete"},1.5)
        return
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1,1)
    print("Delete Song")
    print("")
    print("Number to delete")
    print("blank = selected")
    local n=read()
    local idx=tonumber(n) or state.selectedIndex
    if not idx then
        return
    end

    send("delete",{index=idx})
    send("request_state")
end

local function showSpeakerInfo()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1,1)
    print("Speaker Status")
    print("")

    if not state.speakers or #state.speakers==0 then
        print("No paired speakers seen")
    else
        for i,item in ipairs(state.speakers) do
            print(string.format("%d) %s [%d]",i,item.name or "Speaker",item.id or 0))
            print("   "..tostring(item.status or "Waiting").." Q:"..tostring(item.queueSize or 0).." Broken:"..tostring(item.stuck==true))
            print("   v"..tostring(item.version or "?"))
        end

        if isAdmin() then
            print("")
            print("Restart speaker # or blank")
            local pick=tonumber(read())
            local item=pick and state.speakers[pick] or nil
            if item then
                send("restart_speaker",{speakerId=item.id})
                send("request_state")
                return
            end
        end
    end

    print("")
    print("Tap or key to return")
    os.pullEvent()
end

local function manageAdmins()
    if not isOwner() then
        showMessage({"Owner access required"},1.5)
        return
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1,1)
    print("Admin Panel")
    print("")

    if not state.remoteList or #state.remoteList==0 then
        print("No paired remotes")
        os.pullEvent("key")
        return
    end

    for i,item in ipairs(state.remoteList) do
        print(string.format("%d) %s [%d]",i,item.name or "Pocket",item.id or 0))
        print("   role: "..tostring(item.role or "guest"))
    end

    print("")
    print("G = grant  R = revoke")
    local mode=string.lower(trim(read() or ""))
    if mode~="g" and mode~="r" then
        return
    end

    print("Remote number:")
    local pick=tonumber(read())
    local item=pick and state.remoteList[pick] or nil
    if not item then
        return
    end

    if mode=="g" then
        send("grant_admin",{remoteId=item.id})
    else
        send("revoke_admin",{remoteId=item.id})
    end
    send("request_state")
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

                elseif hit=="restart" then
                    send("restart_speakers")

                elseif hit=="speakers" then
                    showSpeakerInfo()

                elseif hit=="add" then
                    promptAddSong()

                elseif hit=="delete" then
                    promptDeleteSong()

                elseif hit=="vol_up" then
                    send("volume_up")

                elseif hit=="list_up" then
                    pageScroll(-1)

                elseif hit=="list_down" then
                    pageScroll(1)

                elseif hit:sub(1,5)=="song:" then
                    local id=tonumber(hit:sub(6))
                    selectSong(id)
                end
            end
        elseif e[1]=="mouse_scroll" then
            scroll=scroll+e[2]
            clampScroll()

        elseif e[1]=="rednet_message" then

            local id,msg,prot=e[2],e[3],e[4]

            if prot==PROTOCOL_STATE and id==pairData.targetId then
                state=msg
                lastStateAt=os.clock()
                ensureSelectionVisible()
            end
        elseif e[1]=="key" then
            if e[2]==keys.q or e[2]==keys.backspace then
                showMessage({"Closing Pocket Jukebox..."},0.5)
                return
            elseif e[2]==keys.up then
                moveSelection(-1)
            elseif e[2]==keys.down then
                moveSelection(1)
            elseif e[2]==keys.left then
                pageScroll(-1)
            elseif e[2]==keys.right then
                pageScroll(1)
            elseif e[2]==keys.enter then
                send("play")
            end
        elseif e[1]=="char" then
            local ch=string.lower(e[2] or "")
            if ch=="s" then
                showSpeakerInfo()
            elseif ch=="a" and isAdmin() then
                promptAddSong()
            elseif ch=="d" and isAdmin() then
                promptDeleteSong()
            elseif ch=="r" and isAdmin() then
                send("restart_speakers")
            elseif ch=="m" and isOwner() then
                manageAdmins()
            elseif ch=="b" and isOwner() then
                send("restart_jukebox")
            elseif ch=="[" and isAdmin() then
                send("volume_down")
            elseif ch=="]" and isAdmin() then
                send("volume_up")
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
