-- Oracle // 33_modcache.lua
-- MODCACHE — Module Cache Poisoning Probe
-- Detects remotes that write client-controlled values into shared module tables
-- Proves shared mutable state across server scripts via behavioral correlation
-- Vector 3: Client writes value → module table mutated → behavior changes globally
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
-- MODCACHE ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Module table field names commonly exposed through remotes
-- These are the keys we attempt to write into the server-side module cache
local TARGET_KEYS = {
    -- Logic control flags
    "enabled",  "disabled",  "active",    "debug",
    "verbose",  "testing",   "override",  "bypass",
    "admin",    "vip",       "staff",     "owner",
    "locked",   "open",      "public",    "private",

    -- Numeric thresholds and config values
    "damage",   "health",    "speed",     "multiplier",
    "maxLevel", "minLevel",  "cooldown",  "duration",
    "limit",    "cap",       "rate",      "amount",
    "price",    "cost",      "reward",    "xpRate",

    -- Handler / routing keys
    "handler",  "callback",  "processor", "validator",
    "mode",     "type",      "version",   "level",

    -- Config object keys
    "config",   "settings",  "options",   "data",
    "rules",    "perms",     "roles",     "flags",
}

-- Values we write when testing mutations
-- Chosen to be observable: extremes, sentinel values
local MUTATION_VALUES = {
    {tag="max_int",    v=2147483647},
    {tag="neg_one",    v=-1},
    {tag="zero",       v=0},
    {tag="true",       v=true},
    {tag="false",      v=false},
    {tag="admin_str",  v="admin"},
    {tag="owner_str",  v="owner"},
    {tag="bypass_str", v="bypass"},
    {tag="sentinel",   v=999999},
}

-- Payload formats that write a key-value pair
-- Different games use different conventions for their setter remotes
local function buildMutationPayloads(key, value)
    return {
        -- Positional (key, value)
        {tag="positional",    args={key, value}},
        -- Named table
        {tag="named_table",   args={{key=key, value=value}}},
        -- Action-style
        {tag="action_set",    args={{action="set",    key=key, value=value}}},
        {tag="action_update", args={{action="update", field=key, value=value}}},
        {tag="action_config", args={{action="config", key=key, val=value}}},
        -- Direct key in table
        {tag="direct_key",    args={{[key]=value}}},
        -- Nested config
        {tag="nested_config", args={{config={[key]=value}}}},
        {tag="nested_data",   args={{data={[key]=value}}}},
        {tag="nested_settings",args={{settings={[key]=value}}}},
        -- Admin-style setter
        {tag="admin_set",     args={{command="set",   target=key, newValue=value}}},
        -- Property-style
        {tag="property",      args={{property=key,   newValue=value}}},
    }
end

-- ── Baseline capture ──────────────────────────────────────────────────────────
-- Fires each probe remote and records its response signature
-- Used to detect behavioral changes after mutation attempts

local function captureBaseline(remotes, logFn)
    local baselines = {}
    for _, remote in ipairs(remotes) do
        task.wait(0.06)
        local sig = {}
        -- Fire with empty, nil, zero, and sentinel inputs
        for _, input in ipairs({{}, nil, 0, "test", {action="get"}}) do
            local ok, ret = pcall(function()
                if remote:IsA("RemoteFunction") then
                    if input ~= nil then
                        return remote:InvokeServer(input)
                    else
                        return remote:InvokeServer()
                    end
                else
                    -- For RemoteEvents, capture any server-to-client responses
                    remote:FireServer()
                    return nil
                end
            end)
            -- Signature: hash of return value type + rough value
            local retSig
            if not ok then
                retSig = "ERR:" .. tostring(ret):sub(1,20)
            elseif ret == nil then
                retSig = "nil"
            elseif type(ret) == "table" then
                local parts = {}
                for k,v in pairs(ret) do
                    table.insert(parts, tostring(k).."="..vs(v):sub(1,15))
                end
                table.sort(parts)
                retSig = "{"..table.concat(parts,","):sub(1,60).."}"
            else
                retSig = type(ret)..":"..vs(ret):sub(1,30)
            end
            table.insert(sig, retSig)
            task.wait(0.04)
        end
        baselines[remote.Name] = {
            remote    = remote,
            signature = table.concat(sig, "|"),
            raw       = sig,
        }
    end
    return baselines
end

-- ── Mutation attempt ──────────────────────────────────────────────────────────
-- Fires a candidate remote with all key-value mutation payload formats
-- Returns true if any payload was accepted without error
local function attemptMutation(remote, key, value, logFn)
    local payloads = buildMutationPayloads(key, value)
    local accepted = {}
    for _, payload in ipairs(payloads) do
        task.wait(0.04)
        local ok, ret = pcall(function()
            if remote:IsA("RemoteFunction") then
                return remote:InvokeServer(table.unpack(payload.args))
            else
                remote:FireServer(table.unpack(payload.args))
                return true
            end
        end)
        if ok then
            table.insert(accepted, {
                tag  = payload.tag,
                ret  = vs(ret or ""):sub(1,40),
                confirmed = ret ~= nil and ret ~= false,
            })
        end
    end
    return accepted
end

-- ── Behavioral comparison ─────────────────────────────────────────────────────
-- Re-probes all baseline remotes after a mutation
-- Returns any that changed behavior (signature changed)
local function compareToBaseline(baselines, logFn)
    local changed = {}
    for name, baseline in pairs(baselines) do
        local remote = baseline.remote
        task.wait(0.06)
        local newSig = {}
        for _, input in ipairs({{}, nil, 0, "test", {action="get"}}) do
            local ok, ret = pcall(function()
                if remote:IsA("RemoteFunction") then
                    if input ~= nil then
                        return remote:InvokeServer(input)
                    else
                        return remote:InvokeServer()
                    end
                end
                return nil
            end)
            local retSig
            if not ok then
                retSig = "ERR:" .. tostring(ret):sub(1,20)
            elseif ret == nil then
                retSig = "nil"
            elseif type(ret) == "table" then
                local parts = {}
                for k,v in pairs(ret) do
                    table.insert(parts, tostring(k).."="..vs(v):sub(1,15))
                end
                table.sort(parts)
                retSig = "{"..table.concat(parts,","):sub(1,60).."}"
            else
                retSig = type(ret)..":"..vs(ret):sub(1,30)
            end
            table.insert(newSig, retSig)
            task.wait(0.04)
        end
        local newSigStr = table.concat(newSig, "|")
        if newSigStr ~= baseline.signature then
            table.insert(changed, {
                name     = name,
                remote   = remote,
                before   = baseline.signature,
                after    = newSigStr,
                beforeRaw= baseline.raw,
                afterRaw = newSig,
            })
            if logFn then
                logFn("FINDING",
                    ("Behavior changed: %s"):format(name),
                    ("Before: %s"):format(baseline.signature:sub(1,60)),
                    true)
                logFn("DELTA",
                    ("After:  %s"):format(newSigStr:sub(1,60)),
                    "Module cache mutation confirmed — shared state was written",
                    true)
            end
        end
    end
    return changed
end

-- ── Full probe pipeline ───────────────────────────────────────────────────────
-- 1. Capture baseline signatures across all remotes
-- 2. For each candidate remote × target key × mutation value:
--      a. Attempt mutation
--      b. Re-probe behavior of all remotes
--      c. If behavior changed → module cache poisoning confirmed
-- 3. Report findings with remote name, key, value, and which behavior changed

local MODCACHE_RESULTS = {}

local function runModcacheProbe(allRemotes, candidateRemotes, logFn, progressFn, stopFn)
    local results = {}

    -- Phase 1: baseline
    if logFn then logFn("INFO","Phase 1: capturing behavioral baselines") end
    local baselines = captureBaseline(allRemotes, logFn)
    if logFn then
        logFn("INFO",
            ("Baseline captured: %d remote(s)"):format(#allRemotes),
            "Signatures recorded for behavioral comparison")
    end

    -- Phase 2: mutation attempts
    -- Limit combinations to keep runtime reasonable
    -- Priority: keys most commonly exposed × high-impact values
    local priorityKeys = {
        "admin","enabled","bypass","override","debug",
        "damage","speed","handler","mode","config",
        "level","multiplier","active","vip","owner",
    }
    local priorityVals = {
        {tag="sentinel", v=999999},
        {tag="true",     v=true},
        {tag="admin_str",v="admin"},
        {tag="max_int",  v=2147483647},
        {tag="neg_one",  v=-1},
    }

    local totalProbes = #candidateRemotes * #priorityKeys * #priorityVals
    local probeCount  = 0

    for _, candRemote in ipairs(candidateRemotes) do
        if stopFn and stopFn() then break end

        for _, key in ipairs(priorityKeys) do
            if stopFn and stopFn() then break end

            for _, mutVal in ipairs(priorityVals) do
                if stopFn and stopFn() then break end

                probeCount = probeCount + 1
                if progressFn then
                    progressFn(probeCount, totalProbes,
                        candRemote.Name.."."..key.."="..tostring(mutVal.v))
                end

                -- Attempt mutation
                local accepted = attemptMutation(
                    candRemote, key, mutVal.v, nil)

                if #accepted > 0 then
                    task.wait(0.1)  -- brief pause for server to propagate mutation
                    -- Re-probe behavior
                    local changed = compareToBaseline(baselines, nil)

                    if #changed > 0 then
                        -- Confirmed: mutation caused observable behavior change
                        local finding = {
                            mutRemote  = candRemote.Name,
                            key        = key,
                            value      = mutVal.v,
                            valueTag   = mutVal.tag,
                            acceptedBy = accepted[1].tag,
                            changed    = changed,
                            confirmed  = true,
                        }
                        table.insert(results, finding)

                        if logFn then
                            logFn("FINDING",
                                ("MODULE CACHE POISONED: %s"):format(candRemote.Name),
                                ("Key=%s  Value=%s  Changed: %s"):format(
                                    key, tostring(mutVal.v),
                                    changed[1].name),
                                true)
                        end

                        -- Update baseline to current state
                        -- (so we detect subsequent mutations from this new state)
                        baselines = captureBaseline(allRemotes, nil)
                    end
                end
            end
        end
    end

    return results
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MODCACHE PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_MOD = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- topbar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_MOD)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="MODCACHE — MODULE CACHE POISONING",
    TextColor3=Color3.fromRGB(80,210,180),TextSize=11,
    Size=UDim2.new(0,320,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local MOD_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,-334,1,0),Position=UDim2.new(0,330,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- control bar
local CTRLBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,0,30),ZIndex=4},P_MOD)
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

local BASE_BTN  = mkBtn("Capture Baseline",  Color3.fromRGB(80,140,255),  8)
local PROBE_BTN = mkBtn("Probe Mutations",   Color3.fromRGB(80,210,180),  162)
local FULL_BTN  = mkBtn("Full Scan",         Color3.fromRGB(255,200,60),  298)
local STOP_BTN  = mkBtn("Stop",              Color3.fromRGB(60,15,15),    400)
STOP_BTN.TextColor3=Color3.fromRGB(255,80,80)
stroke(Color3.fromRGB(255,80,80),1,STOP_BTN)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,62),Size=UDim2.new(1,0,1,-62),ZIndex=3},P_MOD)

-- left: findings
local CL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},CL)
local RES_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},CL)
pad(6,8,RES_SCROLL); listV(RES_SCROLL,5)
local RES_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Findings will appear here.\nEach card shows which remote\nwas mutated, which key, and\nwhich other remote's behavior\nchanged as a result.",
    TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
    Size=UDim2.new(1,0,0,80),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},RES_SCROLL)

-- right: log
local CR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,241,0,0),Size=UDim2.new(1,-241,1,0),ZIndex=3},BODY)
local PROG_BG=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,3),ZIndex=5},CR)
local PROG_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(80,210,180),
    BorderSizePixel=0,Size=UDim2.new(0,0,1,0),ZIndex=6},PROG_BG)
corner(2,PROG_BAR)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,3),Size=UDim2.new(1,0,1,-3),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},CR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="MODCACHE detects shared mutable state.\n\n"..
         "When require(module) is called on a Roblox\n"..
         "server, every script gets the SAME table.\n"..
         "If any remote writes into that table,\n"..
         "ALL scripts sharing the module are affected.\n\n"..
         "Detection: behavioral correlation.\n"..
         "No loadstring needed. No code injection.\n"..
         "Just prove that writing to remote A\n"..
         "changes the behavior of remote B.\n\n"..
         "Capture Baseline  — record response signatures\n"..
         "Probe Mutations   — test key-value writes\n"..
         "Full Scan         — automated end-to-end",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,200),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- log helpers
local cN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; cN=cN+1; mkRow(tag,msg,detail,hi,LOG_SCROLL,cN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) cN=cN+1; mkSep(txt,LOG_SCROLL,cN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    cN=0; LOG_EMPTY.Visible=true
    tw(PROG_BAR,TI.fast,{Size=UDim2.new(0,0,1,0)})
end

-- finding card builder
local function addFindingCard(finding, ord)
    RES_EMPTY.Visible=false
    local card=mk("Frame",{BackgroundColor3=Color3.fromRGB(5,18,15),
        BorderSizePixel=0,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=ord},RES_SCROLL)
    corner(6,card)
    stroke(Color3.fromRGB(80,210,180),1,card)
    pad(8,6,card); listV(card,5)

    -- Header row
    local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
    listH(hrow,5)
    local badge=mk("Frame",{BackgroundColor3=Color3.fromRGB(80,210,180),
        BorderSizePixel=0,Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
        ZIndex=6},hrow)
    corner(3,badge)
    mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4)},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="CACHE POISONED",TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=finding.mutRemote,TextColor3=Color3.fromRGB(80,210,180),TextSize=10,
        Size=UDim2.new(1,-100,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=2},hrow)

    -- Write details
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=("Write: M[%q] = %s  via %s"):format(
            finding.key, tostring(finding.value), finding.acceptedBy),
        TextColor3=Color3.fromRGB(255,175,70),TextSize=9,TextWrapped=true,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},card)

    -- Impact: which remotes changed
    for i, ch in ipairs(finding.changed) do
        if i > 3 then break end
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=("Behavior changed: %s"):format(ch.name),
            TextColor3=C.TEXT,TextSize=9,
            Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2+i},card)
    end
    if #finding.changed > 3 then
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=("...and %d more remote(s) affected"):format(#finding.changed-3),
            TextColor3=C.MUTED,TextSize=8,
            Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=6},card)
    end
end

-- state
local running   = false
local aborted   = false
local captured_baselines = nil

local function collectRemotes(limit)
    local remotes = {}
    local map = G.DISCOVERY_MAP
    if map then
        for _,r in ipairs(map.remoteEvents or {}) do
            if r.instance then table.insert(remotes, r.instance) end
        end
        for _,r in ipairs(map.remoteFunctions or {}) do
            if r.instance then table.insert(remotes, r.instance) end
        end
    end
    if #remotes == 0 then
        local function sc(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return end
            for _,x in ipairs(d) do
                if x:IsA("RemoteEvent") or x:IsA("RemoteFunction") then
                    table.insert(remotes, x)
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
    MOD_STATUS.Text="stopped"; MOD_STATUS.TextColor3=C.MUTED
end)

-- ── CAPTURE BASELINE ──────────────────────────────────────────────────────────
BASE_BTN.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog()
    tw(BASE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(20,40,80)})
    MOD_STATUS.Text="capturing baselines..."
    MOD_STATUS.TextColor3=Color3.fromRGB(80,140,255)

    local remotes=collectRemotes(20)
    addLogSep(("BASELINE CAPTURE — %d remotes"):format(#remotes))
    addLog("INFO",
        "Recording response signatures for each remote",
        "Baseline used to detect behavioral changes after mutations")

    task.spawn(function()
        for i,r in ipairs(remotes) do
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(i/#remotes,0,1,0)})
            MOD_STATUS.Text=("baseline %d/%d: %s"):format(i,#remotes,r.Name)
        end
        captured_baselines = captureBaseline(remotes, addLog)

        local rfCount=0
        for _,r in ipairs(remotes) do
            if r:IsA("RemoteFunction") then rfCount=rfCount+1 end
        end
        addLogSep(("BASELINE COMPLETE — %d remote(s)  %d RemoteFunction(s)"):format(
            #remotes, rfCount))
        addLog("INFO",
            "Baseline locked",
            "Press Probe Mutations to begin testing key-value writes")
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        MOD_STATUS.Text="baseline captured — "..#remotes.." remotes"
        MOD_STATUS.TextColor3=Color3.fromRGB(80,140,255)
        tw(BASE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,140,255)})
        running=false
    end)
end)

-- ── PROBE MUTATIONS ───────────────────────────────────────────────────────────
PROBE_BTN.MouseButton1Click:Connect(function()
    if running then return end
    if not captured_baselines then
        addLog("INFO","Capture baseline first",
            "Run Capture Baseline before probing mutations")
        return
    end

    running=true; aborted=false
    tw(PROBE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(20,60,50)})
    MOD_STATUS.Text="probing mutations..."
    MOD_STATUS.TextColor3=Color3.fromRGB(80,210,180)

    local remotes={}
    for name, bl in pairs(captured_baselines) do
        table.insert(remotes, bl.remote)
    end
    -- Prioritize RemoteFunctions — more likely to be setter APIs
    table.sort(remotes, function(a,b)
        local aRF = a:IsA("RemoteFunction") and 1 or 0
        local bRF = b:IsA("RemoteFunction") and 1 or 0
        return aRF > bRF
    end)

    addLogSep(("MUTATION PROBE — %d candidate(s)"):format(#remotes))
    addLog("INFO",
        "Testing 15 keys x 5 values via 11 payload formats",
        "Writing to candidate remotes then checking behavioral changes")

    local totalAttempts = #remotes * 15 * 5
    local attemptCount  = 0
    local findings      = {}

    task.spawn(function()
        for _, candRemote in ipairs(remotes) do
            if aborted then break end

            local priorityKeys={
                "admin","enabled","bypass","override","debug",
                "damage","speed","handler","mode","config",
                "level","multiplier","active","vip","owner",
            }
            local priorityVals={
                {tag="sentinel",v=999999},
                {tag="true",    v=true},
                {tag="admin_str",v="admin"},
                {tag="max_int", v=2147483647},
                {tag="neg_one", v=-1},
            }

            for _, key in ipairs(priorityKeys) do
                if aborted then break end
                for _, mutVal in ipairs(priorityVals) do
                    if aborted then break end
                    attemptCount=attemptCount+1
                    tw(PROG_BAR,TI.fast,{
                        Size=UDim2.new(attemptCount/totalAttempts,0,1,0)})
                    MOD_STATUS.Text=("testing %s.%s"):format(
                        candRemote.Name, key)

                    local accepted=attemptMutation(
                        candRemote, key, mutVal.v, nil)
                    if #accepted > 0 then
                        task.wait(0.08)
                        local changed=compareToBaseline(captured_baselines, addLog)
                        if #changed > 0 then
                            local finding={
                                mutRemote  = candRemote.Name,
                                key        = key,
                                value      = mutVal.v,
                                valueTag   = mutVal.tag,
                                acceptedBy = accepted[1].tag,
                                changed    = changed,
                                confirmed  = true,
                            }
                            table.insert(findings,finding)
                            table.insert(MODCACHE_RESULTS,finding)
                            addFindingCard(finding, #findings)
                            -- Re-capture baseline at new state
                            captured_baselines=captureBaseline(remotes,nil)
                        end
                    end
                end
            end
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        addLogSep(("%d module cache poisoning finding(s)"):format(#findings))
        if #findings > 0 then
            MOD_STATUS.Text=("POISONED — %d finding(s)"):format(#findings)
            MOD_STATUS.TextColor3=Color3.fromRGB(80,210,180)
        else
            addLog("CLEAN","No module cache poisoning detected",
                "No behavioral changes observed after mutation attempts")
            MOD_STATUS.Text="no poisoning detected"
            MOD_STATUS.TextColor3=C.MUTED
        end
        tw(PROBE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,210,180)})
        running=false
    end)
end)

-- ── FULL SCAN ─────────────────────────────────────────────────────────────────
FULL_BTN.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog()
    for _,c in ipairs(RES_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    RES_EMPTY.Visible=true
    tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,60,10)})
    MOD_STATUS.Text="full scan..."
    MOD_STATUS.TextColor3=Color3.fromRGB(255,200,60)

    local remotes=collectRemotes(18)
    addLogSep(("MODCACHE FULL SCAN — %d remotes"):format(#remotes))

    task.spawn(function()
        -- Phase 1: baseline
        addLog("INFO","Phase 1: capturing behavioral baselines")
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(0.1,0,1,0)})
        captured_baselines=captureBaseline(remotes,addLog)
        addLog("INFO",("Baseline: %d remote signature(s) recorded"):format(#remotes))
        task.wait(0.3)

        -- Phase 2: mutation probing
        addLogSep("Phase 2: mutation probing")
        local priorityKeys={
            "admin","enabled","bypass","override","debug",
            "damage","speed","handler","mode","config",
            "level","multiplier","active","vip","owner",
        }
        local priorityVals={
            {tag="sentinel",v=999999},
            {tag="true",    v=true},
            {tag="admin_str",v="admin"},
            {tag="max_int", v=2147483647},
            {tag="neg_one", v=-1},
        }

        local total=#remotes*#priorityKeys*#priorityVals
        local count=0
        local findings={}

        for _,candRemote in ipairs(remotes) do
            if aborted then break end
            for _,key in ipairs(priorityKeys) do
                if aborted then break end
                for _,mutVal in ipairs(priorityVals) do
                    if aborted then break end
                    count=count+1
                    tw(PROG_BAR,TI.fast,{
                        Size=UDim2.new(0.1+count/total*0.9,0,1,0)})
                    MOD_STATUS.Text=("testing %s.%s"):format(candRemote.Name,key)

                    local accepted=attemptMutation(candRemote,key,mutVal.v,nil)
                    if #accepted>0 then
                        task.wait(0.08)
                        local changed=compareToBaseline(captured_baselines,addLog)
                        if #changed>0 then
                            local f={
                                mutRemote=candRemote.Name,
                                key=key,value=mutVal.v,
                                valueTag=mutVal.tag,
                                acceptedBy=accepted[1].tag,
                                changed=changed,confirmed=true,
                            }
                            table.insert(findings,f)
                            table.insert(MODCACHE_RESULTS,f)
                            addFindingCard(f,#findings)
                            captured_baselines=captureBaseline(remotes,nil)
                        end
                    end
                end
            end
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        addLogSep(("FULL SCAN COMPLETE — %d poisoning finding(s)"):format(#findings))
        if #findings>0 then
            MOD_STATUS.Text=("VECTOR 3 CONFIRMED — %d finding(s)"):format(#findings)
            MOD_STATUS.TextColor3=Color3.fromRGB(80,210,180)
        else
            MOD_STATUS.Text="no module cache poisoning found"
            MOD_STATUS.TextColor3=C.MUTED
        end
        tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,200,60)})
        running=false
    end)
end)

-- export
G.MODCACHE_RESULTS  = MODCACHE_RESULTS
G.modcache_baseline = captureBaseline
G.modcache_mutate   = attemptMutation
G.modcache_compare  = compareToBaseline

if G.addTab then
    G.addTab("modcache","ModCache",P_MOD)
else
    warn("[Oracle] G.addTab not found")
end
