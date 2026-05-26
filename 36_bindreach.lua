-- Oracle // 36_bindreach.lua
-- BINDREACH — BindableFunction Reachability Probe
-- Finds BindableFunctions/BindableEvents in shared containers
-- that have live server-side handlers, enabling cross-boundary invocation
-- Vector 6: Client invokes BindableFunction in ReplicatedStorage
--            → server OnInvoke handler executes with server authority
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
-- BINDREACH ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Scoring thresholds
local SCORE_REPORT   = 6   -- minimum score to report a finding
local SCORE_CONFIRM  = 14  -- score at which we consider it confirmed

-- Latency thresholds for BindableFunction (ms)
-- Pure client-side (no handler, returns nil): 0-5ms
-- Client-side handler exists:                 0-10ms
-- Server-side handler (async work):           40-400ms  ← key signal
local BF_ASYNC_MIN   = 40  -- above this = likely server processing

-- Probe payloads for BindableFunctions
-- Designed to match common server-side handler signatures
local BF_PROBES = {
    -- Empty / nil
    {tag="nil",         args={}},
    -- Common action patterns
    {tag="action_get",  args={{action="get"}}},
    {tag="action_exec", args={{action="exec"}}},
    {tag="action_run",  args={{action="run"}}},
    {tag="action_call", args={{action="call"}}},
    -- Data fetch patterns
    {tag="get_data",    args={{type="getData"}}},
    {tag="get_player",  args={{type="getPlayer", userId=LP.UserId}}},
    {tag="get_config",  args={{type="config"}}},
    -- Auth/role patterns
    {tag="get_role",    args={{query="role",      userId=LP.UserId}}},
    {tag="get_perms",   args={{query="perms",     player=LP.Name}}},
    {tag="check_admin", args={{check="admin",     userId=LP.UserId}}},
    -- Grant patterns
    {tag="give_item",   args={{action="give",     item="coins", amount=100}}},
    {tag="give_tool",   args={{action="giveItem", player=LP.Name}}},
    -- Numeric ID
    {tag="uid",         args={LP.UserId}},
    {tag="name_str",    args={LP.Name}},
}

-- Probe payloads for BindableEvents (fire-and-forget)
local BE_PROBES = {
    {tag="nil",         args={}},
    {tag="action_fire", args={{action="fire"}}},
    {tag="event_exec",  args={{event="exec",   code=""}}},
    {tag="player_ref",  args={{player=LP.Name, userId=LP.UserId}}},
    {tag="grant_coins", args={{action="grant", currency="coins", amount=9999}}},
    {tag="grant_xp",    args={{action="grant", stat="xp",        amount=9999}}},
}

-- ── Bindable instance discovery ───────────────────────────────────────────────
local function discoverBindables()
    local bindFuncs  = {}
    local bindEvents = {}
    local seen       = {}

    local function scan(root, prefix)
        local ok, ch = pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _, x in ipairs(ch) do
            if not seen[x] then
                seen[x] = true
                if x:IsA("BindableFunction") then
                    table.insert(bindFuncs, {
                        instance = x,
                        name     = x.Name,
                        path     = prefix.."."..x.Name,
                        class    = "BindableFunction",
                    })
                elseif x:IsA("BindableEvent") then
                    table.insert(bindEvents, {
                        instance = x,
                        name     = x.Name,
                        path     = prefix.."."..x.Name,
                        class    = "BindableEvent",
                    })
                end
            end
        end
    end

    scan(RepS,                                    "ReplicatedStorage")
    scan(game.Workspace,                          "Workspace")
    pcall(function() scan(game:GetService("ReplicatedFirst"), "ReplicatedFirst") end)
    pcall(function() scan(game:GetService("StarterGui"),      "StarterGui") end)
    pcall(function() scan(game:GetService("StarterPack"),     "StarterPack") end)

    return bindFuncs, bindEvents
end

-- ── BindableFunction confirmation probe ──────────────────────────────────────
-- Three signals evaluated simultaneously:
--   1. Non-nil return value   → a handler exists and responded
--   2. Latency > BF_ASYNC_MIN → handler did async work (server processing)
--   3. State delta            → server state changed after invocation
--   4. Server→client event    → handler triggered a remote back to us

local function probeBindableFunction(bf, logFn, snapBefore, allRE)
    local results = {}

    for _, probe in ipairs(BF_PROBES) do
        task.wait(0.06)

        -- Capture state
        local before   = snapBefore or snap()
        local eventsBefore = {}
        for k in pairs(rlog) do rlog[k] = nil end
        local conns    = hookR(allRE)
        local t0       = tick()

        -- Invoke
        local ok, ret = pcall(function()
            return bf.instance:Invoke(table.unpack(probe.args))
        end)

        local latency  = (tick()-t0)*1000
        task.wait(math.max(0.05, CFG.RW))
        local after    = snap()

        for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        local responses = {}
        for _,r in ipairs(rlog) do table.insert(responses,r) end
        for k in pairs(rlog) do rlog[k] = nil end

        local deltas  = dif(before, after)

        -- Score this probe
        local score   = 0
        local signals = {}

        -- Signal 1: non-nil return
        if ok and ret ~= nil then
            local retType = type(ret)
            if retType == "table" then
                local keys = 0
                for _ in pairs(ret) do keys = keys + 1 end
                if keys > 0 then
                    score = score + 15
                    table.insert(signals, ("non-nil table return (%d key(s))"):format(keys))
                else
                    score = score + 5
                    table.insert(signals, "empty table return")
                end
            elseif retType == "boolean" or retType == "number" or retType == "string" then
                score = score + 10
                table.insert(signals, ("return value: %s=%s"):format(retType, tostring(ret):sub(1,30)))
            end
        end

        -- Signal 2: async latency
        if latency >= BF_ASYNC_MIN then
            local points = latency >= 100 and 8 or 4
            score = score + points
            table.insert(signals, ("latency %.0fms"):format(latency))
        end

        -- Signal 3: state deltas
        if #deltas > 0 then
            score = score + #deltas * 4
            for _,ch in ipairs(deltas) do
                table.insert(signals, ("state: %s %s->%s"):format(
                    ch.path, ch.bv, ch.av))
            end
        end

        -- Signal 4: server→client events triggered
        if #responses > 0 then
            score = score + #responses * 5
            table.insert(signals, ("%d server event(s) fired"):format(#responses))
        end

        if score >= SCORE_REPORT then
            table.insert(results, {
                probe     = probe.tag,
                score     = score,
                latency   = latency,
                ret       = ok and ret or nil,
                retOk     = ok,
                deltas    = deltas,
                responses = responses,
                signals   = signals,
                confirmed = score >= SCORE_CONFIRM,
            })
            if logFn then
                logFn(score >= SCORE_CONFIRM and "FINDING" or "INFO",
                    ("[BF:%s] %s — score %d"):format(probe.tag, bf.name, score),
                    table.concat(signals, "  |  "):sub(1,100),
                    score >= SCORE_CONFIRM)
            end
        end
    end

    return results
end

-- ── BindableEvent probe ───────────────────────────────────────────────────────
-- Fire-and-forget — only detectable through state changes or triggered events
local function probeBindableEvent(be, logFn, allRE)
    local results = {}

    for _, probe in ipairs(BE_PROBES) do
        task.wait(0.06)

        local before = snap()
        for k in pairs(rlog) do rlog[k] = nil end
        local conns  = hookR(allRE)

        pcall(function()
            be.instance:Fire(table.unpack(probe.args))
        end)

        -- Wait longer for events — no synchronous return to wait on
        task.wait(0.4)
        local after = snap()
        for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        local responses = {}
        for _,r in ipairs(rlog) do table.insert(responses,r) end
        for k in pairs(rlog) do rlog[k] = nil end

        local deltas = dif(before, after)
        local score  = #responses * 5 + #deltas * 4
        local signals = {}

        if #responses > 0 then
            table.insert(signals, ("%d server event(s)"):format(#responses))
        end
        for _, ch in ipairs(deltas) do
            table.insert(signals, ("state: %s"):format(ch.path))
        end

        if score >= SCORE_REPORT then
            table.insert(results, {
                probe     = probe.tag,
                score     = score,
                deltas    = deltas,
                responses = responses,
                signals   = signals,
                confirmed = score >= SCORE_CONFIRM,
            })
            if logFn then
                logFn(score >= SCORE_CONFIRM and "FINDING" or "INFO",
                    ("[BE:%s] %s — score %d"):format(probe.tag, be.name, score),
                    table.concat(signals, "  |  "):sub(1,80),
                    score >= SCORE_CONFIRM)
            end
        end
    end

    return results
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- BINDREACH PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_BR = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- topbar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_BR)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="BINDREACH — BINDABLEFUNCTION REACHABILITY",
    TextColor3=Color3.fromRGB(100,200,255),TextSize=11,
    Size=UDim2.new(0,360,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local BR_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,-374,1,0),Position=UDim2.new(0,370,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- control bar
local CTRLBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,0,30),ZIndex=4},P_BR)
stroke(C.BORDER,1,CTRLBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=4},CTRLBAR)

local function mkBtn(txt,col,x)
    local b=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=col,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text=txt,
        TextColor3=Color3.fromRGB(8,8,12),TextSize=9,
        Size=UDim2.new(0,0,0,22),AutomaticSize=Enum.AutomaticSize.X,
        Position=UDim2.new(0,x,0.5,-11),ZIndex=5},CTRLBAR)
    corner(5,b)
    mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},b)
    return b
end

local DISC_BTN  = mkBtn("Discover",      Color3.fromRGB(100,200,255),  8)
local BF_BTN    = mkBtn("Probe BF",      Color3.fromRGB(80,210,180),   106)
local BE_BTN    = mkBtn("Probe BE",      Color3.fromRGB(140,180,255),  198)
local FULL_BTN  = mkBtn("Full Scan",     Color3.fromRGB(255,200,60),   286)
local STOP_BTN  = mkBtn("Stop",          Color3.fromRGB(60,15,15),     390)
STOP_BTN.TextColor3=Color3.fromRGB(255,80,80)
stroke(Color3.fromRGB(255,80,80),1,STOP_BTN)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,62),Size=UDim2.new(1,0,1,-62),ZIndex=3},P_BR)

-- left: discovered bindables + findings
local BL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},BL)
local LEFT_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},BL)
pad(6,8,LEFT_SCROLL); listV(LEFT_SCROLL,5)
local LEFT_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Run Discover to find\nBindableFunctions and\nBindableEvents in\nshared containers.",
    TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
    Size=UDim2.new(1,0,0,60),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LEFT_SCROLL)

-- right: log
local BR2=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,241,0,0),Size=UDim2.new(1,-241,1,0),ZIndex=3},BODY)
local PROG_BG=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,3),ZIndex=5},BR2)
local PROG_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(100,200,255),
    BorderSizePixel=0,Size=UDim2.new(0,0,1,0),ZIndex=6},PROG_BG)
corner(2,PROG_BAR)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,3),Size=UDim2.new(1,0,1,-3),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},BR2)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="BINDREACH probes BindableFunction/Event\ninstances in shared containers.\n\n"..
         "BindableFunctions are designed for\nsame-environment calls only. But when\n"..
         "placed in ReplicatedStorage with a\n"..
         "server-side OnInvoke handler attached,\n"..
         "a client Invoke() can reach that handler.\n\n"..
         "Four confirmation signals:\n"..
         "  1. Non-nil return value from Invoke()\n"..
         "  2. Latency >40ms (async server work)\n"..
         "  3. Server state changes after invoke\n"..
         "  4. Server-to-client events triggered\n\n"..
         "BindableEvents are fire-and-forget.\n"..
         "Only signals 3 and 4 apply.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,210),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- log helpers
local bN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; bN=bN+1; mkRow(tag,msg,detail,hi,LOG_SCROLL,bN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) bN=bN+1; mkSep(txt,LOG_SCROLL,bN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    bN=0; LOG_EMPTY.Visible=true
    tw(PROG_BAR,TI.fast,{Size=UDim2.new(0,0,1,0)})
end

-- state
local running     = false
local aborted     = false
local foundBF     = {}
local foundBE     = {}
local BIND_RESULTS= {}

STOP_BTN.MouseButton1Click:Connect(function()
    aborted=true; running=false
    BR_STATUS.Text="stopped"; BR_STATUS.TextColor3=C.MUTED
end)

-- ── Result card builder ───────────────────────────────────────────────────────
local function addFindingCard(entry, ord)
    local topScore = 0
    for _, r in ipairs(entry.results or {}) do
        if r.score > topScore then topScore = r.score end
    end
    local confirmed = topScore >= SCORE_CONFIRM
    local col       = confirmed and Color3.fromRGB(100,200,255) or
                      Color3.fromRGB(80,100,140)
    local isBF      = entry.class == "BindableFunction"

    local card=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=ord},LEFT_SCROLL)
    corner(6,card); stroke(col,1,card); pad(8,6,card); listV(card,4)

    local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
    listH(hrow,5)
    local badge=mk("Frame",{BackgroundColor3=col,BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
    corner(3,badge)
    mk("UIPadding",{PaddingLeft=UDim.new(0,3),PaddingRight=UDim.new(0,3)},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=confirmed and "REACHABLE" or (isBF and "BF" or "BE"),
        TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=entry.name,TextColor3=col,TextSize=10,
        Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=2},hrow)

    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=entry.path:sub(1,40),TextColor3=C.MUTED,TextSize=7,
        Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=2},card)

    if #(entry.results or {}) > 0 then
        local best = entry.results[1]
        for _, r in ipairs(entry.results) do
            if r.score > best.score then best=r end
        end
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=("Score %d via [%s] — %s"):format(
                best.score, best.probe,
                table.concat(best.signals, " | "):sub(1,50)),
            TextColor3=confirmed and Color3.fromRGB(100,200,255) or C.MUTED,
            TextSize=8,TextWrapped=true,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=3},card)
    end
end

-- rebuild left panel
local function rebuildLeftPanel()
    for _,c in ipairs(LEFT_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    LEFT_EMPTY.Visible = (#foundBF + #foundBE) == 0

    local ord = 0
    -- Findings first
    for _, entry in ipairs(BIND_RESULTS) do
        ord = ord + 1
        addFindingCard(entry, ord)
    end
    -- Then unprobed discoveries
    local probed = {}
    for _, r in ipairs(BIND_RESULTS) do probed[r.name] = true end

    for _, bf in ipairs(foundBF) do
        if not probed[bf.name] then
            ord = ord + 1
            local card=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                ZIndex=4,LayoutOrder=ord},LEFT_SCROLL)
            corner(5,card); stroke(C.BORDER,1,card); pad(8,5,card); listV(card,3)
            local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
                Size=UDim2.new(1,0,0,14),ZIndex=5,LayoutOrder=1},card)
            listH(hrow,4)
            local badge=mk("Frame",{BackgroundColor3=Color3.fromRGB(80,210,180),
                BorderSizePixel=0,Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
                ZIndex=6},hrow)
            corner(3,badge)
            mk("UIPadding",{PaddingLeft=UDim.new(0,3),PaddingRight=UDim.new(0,3)},badge)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text="BF",TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
                Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},badge)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text=bf.name,TextColor3=Color3.fromRGB(80,210,180),TextSize=9,
                Size=UDim2.new(1,-50,1,0),TextXAlignment=Enum.TextXAlignment.Left,
                ZIndex=6,LayoutOrder=2},hrow)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                Text=bf.path:sub(1,38),TextColor3=C.MUTED,TextSize=7,
                Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
                ZIndex=5,LayoutOrder=2},card)
        end
    end
    for _, be in ipairs(foundBE) do
        if not probed[be.name] then
            ord = ord + 1
            local card=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                ZIndex=4,LayoutOrder=ord},LEFT_SCROLL)
            corner(5,card); stroke(C.BORDER,1,card); pad(8,5,card); listV(card,3)
            local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
                Size=UDim2.new(1,0,0,14),ZIndex=5,LayoutOrder=1},card)
            listH(hrow,4)
            local badge=mk("Frame",{BackgroundColor3=Color3.fromRGB(140,180,255),
                BorderSizePixel=0,Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
                ZIndex=6},hrow)
            corner(3,badge)
            mk("UIPadding",{PaddingLeft=UDim.new(0,3),PaddingRight=UDim.new(0,3)},badge)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text="BE",TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
                Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},badge)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text=be.name,TextColor3=Color3.fromRGB(140,180,255),TextSize=9,
                Size=UDim2.new(1,-50,1,0),TextXAlignment=Enum.TextXAlignment.Left,
                ZIndex=6,LayoutOrder=2},hrow)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                Text=be.path:sub(1,38),TextColor3=C.MUTED,TextSize=7,
                Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
                ZIndex=5,LayoutOrder=2},card)
        end
    end
end

-- collect all RemoteEvents for event-hook monitoring
local function allRemoteEvents()
    local re = {}
    local function sc(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(re,x) end end
    end
    sc(RepS); sc(game.Workspace)
    return re
end

-- ── DISCOVER ─────────────────────────────────────────────────────────────────
DISC_BTN.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog()
    tw(DISC_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(20,50,80)})
    BR_STATUS.Text="discovering..."; BR_STATUS.TextColor3=Color3.fromRGB(100,200,255)

    addLogSep("BINDREACH DISCOVERY — scanning shared containers")
    task.spawn(function()
        foundBF, foundBE = discoverBindables()
        rebuildLeftPanel()

        addLog("INFO",
            ("Found %d BindableFunction(s)  %d BindableEvent(s)"):format(
                #foundBF, #foundBE),
            "Scanning: ReplicatedStorage, Workspace, ReplicatedFirst, Starter*")

        for _, bf in ipairs(foundBF) do
            addLog("INFO", ("[BF] "..bf.name), bf.path)
        end
        for _, be in ipairs(foundBE) do
            addLog("INFO", ("[BE] "..be.name), be.path)
        end

        local total = #foundBF + #foundBE
        addLogSep(("DISCOVERY COMPLETE — %d bindable(s)"):format(total))
        if total == 0 then
            addLog("CLEAN","No BindableFunctions or BindableEvents found in shared containers",
                "This game either has none or places them in non-accessible locations")
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        BR_STATUS.Text=total.." bindable(s) found"
        BR_STATUS.TextColor3=total>0 and Color3.fromRGB(100,200,255) or C.MUTED
        tw(DISC_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(100,200,255)})
        running=false
    end)
end)

-- ── PROBE BINDABLEFUNCTIONS ───────────────────────────────────────────────────
BF_BTN.MouseButton1Click:Connect(function()
    if running then return end
    if #foundBF == 0 then
        addLog("INFO","No BindableFunctions found","Run Discover first")
        return
    end
    running=true; aborted=false
    clearLog()
    tw(BF_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(20,60,50)})
    BR_STATUS.Text="probing BF..."; BR_STATUS.TextColor3=Color3.fromRGB(80,210,180)

    local allRE = allRemoteEvents()
    addLogSep(("PROBE BINDABLEFUNCTIONS — %d target(s)  %d probes each"):format(
        #foundBF, #BF_PROBES))
    addLog("INFO",
        "Signals: return value | latency >40ms | state delta | triggered events",
        "Score threshold: report >="..SCORE_REPORT.."  confirm >="..SCORE_CONFIRM)

    task.spawn(function()
        local baseBefore = snap()
        for i, bf in ipairs(foundBF) do
            if aborted then break end
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(i/#foundBF,0,1,0)})
            BR_STATUS.Text=("BF %d/%d: %s"):format(i,#foundBF,bf.name)
            addLogSep(bf.name.." @ "..bf.path)

            local probeResults = probeBindableFunction(bf, addLog, baseBefore, allRE)

            if #probeResults > 0 then
                local entry = {
                    name    = bf.name,
                    path    = bf.path,
                    class   = "BindableFunction",
                    results = probeResults,
                }
                table.insert(BIND_RESULTS, entry)
                rebuildLeftPanel()

                -- Summarise best result
                local best = probeResults[1]
                for _,r in ipairs(probeResults) do if r.score > best.score then best=r end end
                addLog(best.confirmed and "FINDING" or "INFO",
                    ("Best: [%s] score %d%s"):format(
                        best.probe, best.score,
                        best.confirmed and " — CONFIRMED REACHABLE" or ""),
                    table.concat(best.signals," | "):sub(1,80),
                    best.confirmed)
            else
                addLog("CLEAN","No handler signals on "..bf.name)
            end
        end

        local confirmed=0
        for _,r in ipairs(BIND_RESULTS) do
            for _,pr in ipairs(r.results) do
                if pr.confirmed then confirmed=confirmed+1; break end
            end
        end
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        addLogSep(("BF PROBE COMPLETE — %d/%d reachable"):format(confirmed,#foundBF))
        BR_STATUS.Text=confirmed>0 and ("VECTOR 6: "..confirmed.." confirmed") or "no BF handlers found"
        BR_STATUS.TextColor3=confirmed>0 and Color3.fromRGB(100,200,255) or C.MUTED
        tw(BF_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,210,180)})
        running=false
    end)
end)

-- ── PROBE BINDABLEEVENTS ──────────────────────────────────────────────────────
BE_BTN.MouseButton1Click:Connect(function()
    if running then return end
    if #foundBE == 0 then
        addLog("INFO","No BindableEvents found","Run Discover first")
        return
    end
    running=true; aborted=false
    clearLog()
    tw(BE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(30,40,80)})
    BR_STATUS.Text="probing BE..."; BR_STATUS.TextColor3=Color3.fromRGB(140,180,255)

    local allRE = allRemoteEvents()
    addLogSep(("PROBE BINDABLEEVENTS — %d target(s)"):format(#foundBE))
    addLog("INFO",
        "Signals: server state delta | server-to-client events triggered",
        "BindableEvents are fire-and-forget — no return value to inspect")

    task.spawn(function()
        for i, be in ipairs(foundBE) do
            if aborted then break end
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(i/#foundBE,0,1,0)})
            BR_STATUS.Text=("BE %d/%d: %s"):format(i,#foundBE,be.name)
            addLogSep(be.name.." @ "..be.path)

            local probeResults = probeBindableEvent(be, addLog, allRE)

            if #probeResults > 0 then
                local entry={name=be.name, path=be.path,
                    class="BindableEvent", results=probeResults}
                table.insert(BIND_RESULTS, entry)
                rebuildLeftPanel()
                local best=probeResults[1]
                for _,r in ipairs(probeResults) do if r.score>best.score then best=r end end
                addLog(best.confirmed and "FINDING" or "INFO",
                    ("Best: [%s] score %d"):format(best.probe, best.score),
                    table.concat(best.signals," | "):sub(1,80),
                    best.confirmed)
            else
                addLog("CLEAN","No handler signals on "..be.name)
            end
        end

        local confirmed=0
        for _,r in ipairs(BIND_RESULTS) do
            if r.class=="BindableEvent" then
                for _,pr in ipairs(r.results) do
                    if pr.confirmed then confirmed=confirmed+1; break end
                end
            end
        end
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        addLogSep(("BE PROBE COMPLETE — %d/%d with server signals"):format(
            confirmed,#foundBE))
        BR_STATUS.Text=confirmed>0 and ("BE: "..confirmed.." confirmed") or "no BE signals"
        BR_STATUS.TextColor3=confirmed>0 and Color3.fromRGB(140,180,255) or C.MUTED
        tw(BE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(140,180,255)})
        running=false
    end)
end)

-- ── FULL SCAN ─────────────────────────────────────────────────────────────────
FULL_BTN.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog(); BIND_RESULTS={}
    tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,60,10)})
    BR_STATUS.Text="full scan..."; BR_STATUS.TextColor3=Color3.fromRGB(255,200,60)

    addLogSep("BINDREACH FULL SCAN")
    task.spawn(function()
        -- Phase 1: discover
        addLog("INFO","Phase 1: discovering bindable instances")
        foundBF, foundBE = discoverBindables()
        rebuildLeftPanel()

        local total = #foundBF + #foundBE
        addLog("INFO",
            ("Found %d BF  %d BE"):format(#foundBF, #foundBE),
            "ReplicatedStorage + Workspace + Starter containers")

        if total == 0 then
            addLog("CLEAN","No bindable instances found in shared containers")
            addLogSep("FULL SCAN COMPLETE — Nothing to probe")
            BR_STATUS.Text="no bindables found"
            BR_STATUS.TextColor3=C.MUTED
            tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,200,60)})
            running=false; return
        end

        local allRE  = allRemoteEvents()
        local baseBefore = snap()

        -- Phase 2: probe BFs
        if #foundBF > 0 and not aborted then
            addLogSep(("Phase 2: BindableFunction probe (%d)"):format(#foundBF))
            for i, bf in ipairs(foundBF) do
                if aborted then break end
                tw(PROG_BAR,TI.fast,{Size=UDim2.new(i/total*0.6,0,1,0)})
                BR_STATUS.Text=("BF %d/%d: %s"):format(i,#foundBF,bf.name)
                local res = probeBindableFunction(bf, addLog, baseBefore, allRE)
                if #res > 0 then
                    table.insert(BIND_RESULTS,{
                        name=bf.name, path=bf.path,
                        class="BindableFunction", results=res})
                    rebuildLeftPanel()
                end
            end
        end

        -- Phase 3: probe BEs
        if #foundBE > 0 and not aborted then
            addLogSep(("Phase 3: BindableEvent probe (%d)"):format(#foundBE))
            for i, be in ipairs(foundBE) do
                if aborted then break end
                tw(PROG_BAR,TI.fast,{
                    Size=UDim2.new(0.6+i/#foundBE*0.4,0,1,0)})
                BR_STATUS.Text=("BE %d/%d: %s"):format(i,#foundBE,be.name)
                local res = probeBindableEvent(be, addLog, allRE)
                if #res > 0 then
                    table.insert(BIND_RESULTS,{
                        name=be.name, path=be.path,
                        class="BindableEvent", results=res})
                    rebuildLeftPanel()
                end
            end
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})

        local confirmed=0
        for _,r in ipairs(BIND_RESULTS) do
            for _,pr in ipairs(r.results) do
                if pr.confirmed then confirmed=confirmed+1; break end
            end
        end

        addLogSep(("FULL SCAN COMPLETE — %d confirmed / %d probed"):format(
            confirmed, total))
        if confirmed > 0 then
            addLog("FINDING",
                ("VECTOR 6: %d reachable bindable(s) confirmed"):format(confirmed),
                "Cross-boundary invocation paths exist in this game",
                true)
            BR_STATUS.Text=("VECTOR 6: "..confirmed.." confirmed")
            BR_STATUS.TextColor3=Color3.fromRGB(100,200,255)
        else
            addLog(#BIND_RESULTS > 0 and "INFO" or "CLEAN",
                #BIND_RESULTS > 0 and
                    (#BIND_RESULTS.." bindable(s) with partial signals — below confirm threshold") or
                    "No bindable handler signals detected",
                "Bindables exist but show no evidence of server-side handlers")
            BR_STATUS.Text=#BIND_RESULTS>0 and "partial signals" or "no handlers found"
            BR_STATUS.TextColor3=C.MUTED
        end

        tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,200,60)})
        running=false
    end)
end)

-- export
G.BINDREACH_RESULTS   = BIND_RESULTS
G.bindreach_discover  = discoverBindables
G.bindreach_probeBF   = probeBindableFunction
G.bindreach_probeBE   = probeBindableEvent

if G.addTab then
    G.addTab("bindreach","BindReach",P_BR)
else
    warn("[Oracle] G.addTab not found")
end
