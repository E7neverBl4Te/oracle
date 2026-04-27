-- Oracle // 09_echo.lua
-- ECHO — Signature-Informed Replay
-- RSO-driven arg pre-fill · Chain sequencer · Cadence mimic · Trust envelope replay
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
local discR  = G.discR
local rlog   = G.rlog
local CFG    = G.CFG
local CON    = G.CON
local RepS   = G.RepS
local LP     = G.LP

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ECHO ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Pull live RSO observation data if available
local function getRSOobs()
    -- 07_rso.lua stores its OBS table internally
    -- We reach it through G if exported, otherwise return empty
    return G.RSO_OBS or {}
end

-- Build an ECHO session from an RSO signature
-- Returns a session table describing the full replay plan
local function buildSession(targetName)
    local obs  = getRSOobs()
    local rec  = obs[targetName]
    local sig  = rec and (rec.sig or (rec.dirty and nil or rec.sig)) or nil

    local session = {
        target      = targetName,
        args        = {},       -- [{typeKey, value, label, editable}]
        chain       = {},       -- [{name, delayMs, args}] predecessors in order
        cadence     = nil,      -- observed cadence pattern
        repeatCount = 1,
        repeatDelay = 0,        -- ms between repeats
        hasSig      = sig ~= nil,
    }

    if not sig then return session end

    -- Recompute if needed
    if rec.dirty then
        -- sig may be stale — caller should ensure it's fresh
    end

    -- Pre-fill args from schema constraints
    for i = 1, sig.argCount do
        local s  = sig.schema and sig.schema[i]
        local cs = sig.constraints and sig.constraints[i]
        if s then
            local bestVal = ""
            if s.topVals and #s.topVals > 0 then
                bestVal = s.topVals[1].v
            end
            local typeKey = s.domType
            -- Map observed type to ECHO type key
            local tk
            if typeKey == "string"  then tk = "str"
            elseif typeKey == "int" or typeKey == "float"
                or typeKey == "NaN" or typeKey == "Inf" then tk = "num"
            elseif typeKey == "boolean" then tk = "bool"
            elseif typeKey == "Vector3" then tk = "V3"
            elseif typeKey == "CFrame"  then tk = "CF"
            elseif typeKey == "nil"     then tk = "nil"
            else                             tk = "str" end

            table.insert(session.args, {
                typeKey  = tk,
                value    = bestVal,
                label    = "Arg "..i,
                card     = s.card,
                kind     = cs and cs.kind or "dynamic",
                topVals  = s.topVals or {},
                editable = true,
            })
        end
    end

    -- Build chain prerequisites
    if sig.chains then
        for _, ch in ipairs(sig.chains) do
            if ch.causal then
                local predRec  = obs[ch.pred]
                local predArgs = {}
                if predRec and predRec.sig and predRec.sig.argCount > 0 then
                    for i = 1, predRec.sig.argCount do
                        local ps = predRec.sig.schema[i]
                        if ps and ps.topVals and #ps.topVals > 0 then
                            table.insert(predArgs, {
                                typeKey = "str",
                                value   = ps.topVals[1].v,
                                label   = "Arg "..i,
                            })
                        end
                    end
                end
                table.insert(session.chain, {
                    name    = ch.pred,
                    delayMs = math.max(16, math.floor(ch.jMean)),
                    args    = predArgs,
                    causal  = true,
                })
            end
        end
        -- Reverse so we fire earliest predecessor first
        local rev = {}
        for i = #session.chain, 1, -1 do
            table.insert(rev, session.chain[i])
        end
        session.chain = rev
    end

    session.cadence = sig.cadence
    if sig.cadence then
        -- Default repeat delay = observed mean interval
        session.repeatDelay = math.floor(sig.cadence.mean * 1000)
    end

    return session
end

-- Parse a value string into a Lua value
local function parseVal(tk, raw)
    raw = raw or ""
    if tk == "str" then
        return raw:gsub("\\0","\0"):gsub("\\n","\n")
    elseif tk == "num" then
        if raw=="NaN" or raw=="nan" then return 0/0 end
        if raw=="Inf" or raw=="inf" then return math.huge end
        if raw=="-Inf" or raw=="-inf" then return -math.huge end
        local n = tonumber(raw)
        if n then return n end
        local ok, v = pcall(function() return load("return "..raw)() end)
        return (ok and type(v)=="number") and v or 0
    elseif tk == "bool" then
        return raw:lower() ~= "false" and raw ~= "0" and raw ~= ""
    elseif tk == "V3" then
        local x,y,z = raw:match("^([^,]+),([^,]+),([^,]+)$")
        return Vector3.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
    elseif tk == "CF" then
        local x,y,z = raw:match("^([^,]+),([^,]+),([^,]+)$")
        return CFrame.new(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
    elseif tk == "nil" then
        return nil
    end
    return raw
end

-- Find a remote by name
local function findR(name)
    local t = nil
    local function sc(root)
        local ok,d = pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do
            if (x:IsA("RemoteEvent") or x:IsA("RemoteFunction"))
            and x.Name == name then t=x; return end
        end
    end
    sc(RepS); if not t then sc(workspace) end
    return t
end

-- Execute a full ECHO session
-- session: built by buildSession
-- argOverrides: [{typeKey, value}] from UI fields (replaces session.args)
-- logFn: function(tag, msg, detail, hi)
-- onComplete: function(results_table)
local function executeEcho(session, argOverrides, repeatCount, repeatDelayMs, logFn, onComplete)
    local results = {responses={}, deltas={}, errors={}, fired=0}

    -- Collect all remotes for response watching
    local ev = {}
    local function col(root)
        local ok,d = pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(ev,x) end end
    end
    col(RepS); col(workspace)

    for rep = 1, repeatCount do
        if rep > 1 then
            logFn("INFO", ("Repeat %d/%d — waiting %.0fms"):format(rep, repeatCount, repeatDelayMs))
            task.wait(repeatDelayMs / 1000)
        end

        -- Fire chain prerequisites first
        for _, pre in ipairs(session.chain) do
            local preRemote = findR(pre.name)
            if preRemote then
                -- Build predecessor payload
                local prePayload = {}
                for _, a in ipairs(pre.args) do
                    table.insert(prePayload, parseVal(a.typeKey, a.value))
                end
                logFn("INFO",
                    ("Chain pre-req: %s (waiting %.0fms)"):format(pre.name, pre.delayMs))
                local ok = pcall(function()
                    if preRemote:IsA("RemoteEvent") then
                        preRemote:FireServer(table.unpack(prePayload))
                    else
                        preRemote:InvokeServer(table.unpack(prePayload))
                    end
                end)
                logFn(ok and "FIRED" or "INFO",
                    "Chain: "..pre.name,
                    ok and "sent" or "rejected at client")
                -- Wait the observed jitter delay before firing target
                task.wait(pre.delayMs / 1000)
            else
                logFn("INFO", "Chain pre-req not found: "..pre.name,
                    "firing target without chain — result may differ")
            end
        end

        -- Build target payload from UI overrides
        local payload = {}
        local argSrc = argOverrides or session.args
        for _, a in ipairs(argSrc) do
            table.insert(payload, parseVal(a.typeKey, a.value))
        end

        -- Snapshot before
        local before = snap()
        for k in pairs(rlog) do rlog[k] = nil end
        local conns = hookR(ev)

        -- Fire target
        local targetRemote = findR(session.target)
        if not targetRemote then
            logFn("INFO", "Target remote not found: "..session.target)
            for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
            break
        end

        local ok, err = pcall(function()
            if targetRemote:IsA("RemoteEvent") then
                targetRemote:FireServer(table.unpack(payload))
            else
                targetRemote:InvokeServer(table.unpack(payload))
            end
        end)

        results.fired += 1
        logFn(ok and "FIRED" or "INFO",
            session.target.."  ←  "..#payload.." arg(s)",
            ok and nil or "Rejected: "..tostring(err))

        if not ok then
            for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
            table.insert(results.errors, tostring(err))
            continue
        end

        -- Watch for response
        task.wait(CFG.RW)
        local dl = tick() + CFG.WD
        while tick() < dl do
            task.wait(0.05)
            if #rlog > 0 then break end
        end

        local after = snap()
        for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end

        -- Collect responses
        for _, r in ipairs(rlog) do
            table.insert(results.responses, r)
            logFn("RESPONSE", "Server replied via "..r.name, r.args, true)
        end
        for k in pairs(rlog) do rlog[k] = nil end

        -- Collect state deltas
        for _, ch in ipairs(dif(before, after)) do
            table.insert(results.deltas, ch)
            logFn(ch.bad and "PATHOLOG" or "DELTA",
                (ch.bad and "⚠ PATHOLOGICAL — " or "State change — ")..ch.path,
                ch.bv.."  →  "..ch.av, true)
        end
    end

    if onComplete then onComplete(results) end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ECHO PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_ECHO = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.fromScale(1,1), Visible=false, ZIndex=3}, CON)

-- top bar
local TOPBAR = mk("Frame", {BackgroundColor3=C.SURFACE, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32), ZIndex=4}, P_ECHO)
stroke(C.BORDER, 1, TOPBAR)
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1), Position=UDim2.new(0,0,1,-1), ZIndex=5}, TOPBAR)
pad(12, 0, TOPBAR); listH(TOPBAR, 10)

mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
    Text="⟳  ECHO — Signature Replay", TextColor3=C.ACCENT, TextSize=11,
    Size=UDim2.new(1,-220,1,0), TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5, LayoutOrder=1}, TOPBAR)

local ECHO_STATUS = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="no session loaded", TextColor3=C.MUTED, TextSize=9,
    Size=UDim2.new(0,120,1,0), TextXAlignment=Enum.TextXAlignment.Right,
    ZIndex=5, LayoutOrder=2}, TOPBAR)

-- body: left=config, right=log
local BODY = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32), Size=UDim2.new(1,0,1,-32), ZIndex=3}, P_ECHO)

-- ── LEFT: session config ──────────────────────────────────────────────────────
local EL = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.new(0.46,0,1,0), ZIndex=3}, BODY)

-- dock pinned to bottom
local EL_DOCK = mk("Frame", {BackgroundColor3=C.SURFACE, BorderSizePixel=0,
    Position=UDim2.new(0,0,1,-100), Size=UDim2.new(1,0,0,100), ZIndex=5}, EL)
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(1,-20,0,1), Position=UDim2.new(0,10,0,0), ZIndex=6}, EL_DOCK)
pad(10, 8, EL_DOCK); listV(EL_DOCK, 6)

-- Repeat controls row
local REP_ROW = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,22), ZIndex=6, LayoutOrder=1}, EL_DOCK)
listH(REP_ROW, 8)
mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
    Text="Repeats", TextColor3=C.MUTED, TextSize=9,
    Size=UDim2.new(0,55,1,0), TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=7, LayoutOrder=1}, REP_ROW)
local REP_BOX = mk("TextBox", {BackgroundColor3=C.CARD, BorderSizePixel=0,
    Text="1", PlaceholderText="1", PlaceholderColor3=C.MUTED,
    TextColor3=C.WHITE, TextSize=11, Font=Enum.Font.Code,
    ClearTextOnFocus=false, TextXAlignment=Enum.TextXAlignment.Center,
    Size=UDim2.new(0,40,0,20), ZIndex=7, LayoutOrder=2}, REP_ROW)
corner(4, REP_BOX); stroke(C.BORDER, 1, REP_BOX)

mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
    Text="Delay (ms)", TextColor3=C.MUTED, TextSize=9,
    Size=UDim2.new(0,65,1,0), TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=7, LayoutOrder=3}, REP_ROW)
local DELAY_BOX = mk("TextBox", {BackgroundColor3=C.CARD, BorderSizePixel=0,
    Text="0", PlaceholderText="ms", PlaceholderColor3=C.MUTED,
    TextColor3=C.WHITE, TextSize=11, Font=Enum.Font.Code,
    ClearTextOnFocus=false, TextXAlignment=Enum.TextXAlignment.Center,
    Size=UDim2.new(0,50,0,20), ZIndex=7, LayoutOrder=4}, REP_ROW)
corner(4, DELAY_BOX); stroke(C.BORDER, 1, DELAY_BOX)

-- mimic cadence checkbox
local MIM_ROW = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,18), ZIndex=6, LayoutOrder=2}, EL_DOCK)
listH(MIM_ROW, 8)
local MIM_CHK = mk("TextButton", {AutoButtonColor=false,
    BackgroundColor3=C.ACCDIM, BorderSizePixel=0,
    Font=Enum.Font.GothamBold, Text="✓", TextColor3=C.ACCENT, TextSize=9,
    Size=UDim2.new(0,18,0,18), ZIndex=7, LayoutOrder=1}, MIM_ROW)
corner(4, MIM_CHK)
local mimicCadence = true
mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="Use observed cadence delay", TextColor3=C.TEXT, TextSize=9,
    Size=UDim2.new(1,-30,1,0), TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=7, LayoutOrder=2}, MIM_ROW)

MIM_CHK.MouseButton1Click:Connect(function()
    mimicCadence = not mimicCadence
    MIM_CHK.Text = mimicCadence and "✓" or ""
    tw(MIM_CHK, TI.fast, {
        BackgroundColor3 = mimicCadence and C.ACCDIM or C.CARD
    })
end)

-- ECHO & ABORT buttons
local ECHO_BTN = mk("TextButton", {AutoButtonColor=false,
    BackgroundColor3=C.ACCENT, BorderSizePixel=0,
    Font=Enum.Font.GothamBold, Text="⟳  ECHO",
    TextColor3=C.WHITE, TextSize=12,
    Size=UDim2.new(1,0,0,32), ZIndex=6, LayoutOrder=3}, EL_DOCK)
corner(7, ECHO_BTN)
do local base=C.ACCENT
    ECHO_BTN.MouseEnter:Connect(function() tw(ECHO_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    ECHO_BTN.MouseLeave:Connect(function() tw(ECHO_BTN,TI.fast,{BackgroundColor3=base}) end)
end

-- scroll area above dock
local EL_SCROLL = mk("ScrollingFrame", {BackgroundTransparency=1,
    BorderSizePixel=0, Position=UDim2.new(0,0,0,0),
    Size=UDim2.new(1,0,1,-100),
    ScrollBarThickness=3, ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ZIndex=4}, EL)
pad(12, 10, EL_SCROLL); listV(EL_SCROLL, 8)

-- divider
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(0,1,1,-20), Position=UDim2.new(0.46,0,0,10), ZIndex=4}, BODY)

-- ── RIGHT: execution log ──────────────────────────────────────────────────────
local ER = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0.46,1,0,0), Size=UDim2.new(0.54,-1,1,0), ZIndex=3}, BODY)
local ER_SCROLL = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.fromScale(1,1), ScrollBarThickness=4,
    ScrollBarImageColor3=C.ACCDIM, CanvasSize=UDim2.fromScale(0,0),
    AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y, ZIndex=4}, ER)
pad(10, 8, ER_SCROLL); listV(ER_SCROLL, 2)

local ER_EMPTY = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="Load a session from RSO\nor select a remote to replay",
    TextColor3=C.MUTED, TextSize=10, TextWrapped=true,
    Size=UDim2.new(1,0,0,50), TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5, LayoutOrder=1}, ER_SCROLL)

-- ── LOG helpers ───────────────────────────────────────────────────────────────
local erN = 0
local function addLog(tag, msg, detail, hi)
    ER_EMPTY.Visible = false
    erN += 1
    mkRow(tag, msg, detail, hi, ER_SCROLL, erN)
    task.defer(function()
        ER_SCROLL.CanvasPosition = Vector2.new(0, ER_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt)
    erN += 1; mkSep(txt, ER_SCROLL, erN)
end
local function clearLog()
    for _, c in ipairs(ER_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    erN = 0; ER_EMPTY.Visible = true
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SESSION PANEL BUILDER
-- Renders the current session into EL_SCROLL
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local currentSession = nil
local argFields      = {}   -- [{typeKey_ref, value_ref, box, typBtn}]

local KIND_COL = {
    constant = Color3.fromRGB(80, 210, 100),
    enum     = Color3.fromRGB(255,160,  40),
    dynamic  = Color3.fromRGB(255, 90,  90),
}
local TYPE_COLORS = {
    str  = Color3.fromRGB(80,170,210),
    num  = Color3.fromRGB(168,120,255),
    bool = Color3.fromRGB(80,210,100),
    V3   = Color3.fromRGB(255,160, 40),
    CF   = Color3.fromRGB(255, 90,150),
    ["nil"] = Color3.fromRGB(80,74,108),
}
local TYPES = {"str","num","bool","V3","CF","nil"}

local function clearSessionPanel()
    for _, c in ipairs(EL_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    argFields = {}
end

local function buildSessionPanel(session)
    clearSessionPanel()
    if not session then return end

    local ord = 0
    local function o() ord+=1; return ord end

    -- ── Header card ───────────────────────────────────────────────────────────
    local hdr = mk("Frame", {BackgroundColor3=C.CARD, BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4, LayoutOrder=o()}, EL_SCROLL)
    corner(6,hdr); stroke(C.BORDER,1,hdr); pad(10,8,hdr); listV(hdr,4)

    local hrow = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,18),ZIndex=5,LayoutOrder=1},hdr)
    listH(hrow,6)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="⟳  "..session.target, TextColor3=C.WHITE, TextSize=12,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6,LayoutOrder=1},hrow)

    if session.hasSig then
        local sigBadge = mk("Frame",{BackgroundColor3=Color3.fromRGB(80,210,100),
            BorderSizePixel=0,Size=UDim2.fromOffset(0,15),
            AutomaticSize=Enum.AutomaticSize.X,ZIndex=6,LayoutOrder=2},hrow)
        corner(4,sigBadge); mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5)},sigBadge)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text="RSO", TextColor3=Color3.fromRGB(8,8,12),TextSize=8,
            Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
            TextXAlignment=Enum.TextXAlignment.Center,ZIndex=7},sigBadge)
    else
        local noBadge = mk("Frame",{BackgroundColor3=C.MUTED,
            BorderSizePixel=0,Size=UDim2.fromOffset(0,15),
            AutomaticSize=Enum.AutomaticSize.X,ZIndex=6,LayoutOrder=2},hrow)
        corner(4,noBadge); mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5)},noBadge)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text="NO SIG", TextColor3=Color3.fromRGB(8,8,12),TextSize=8,
            Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
            TextXAlignment=Enum.TextXAlignment.Center,ZIndex=7},noBadge)
    end

    if session.cadence then
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=("Observed: %s  ·  Δt̄ %.0fms  ·  %d total fires"):format(
                session.cadence.pattern,
                session.cadence.mean*1000,
                session.cadence.total),
            TextColor3=C.MUTED,TextSize=9,
            Size=UDim2.new(1,0,0,14),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2},hdr)
    else
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text="No RSO signature — args will use raw values",
            TextColor3=C.MUTED,TextSize=9,
            Size=UDim2.new(1,0,0,14),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2},hdr)
    end

    -- ── Chain prerequisites ───────────────────────────────────────────────────
    if #session.chain > 0 then
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text="CHAIN PREREQUISITES", TextColor3=C.MUTED, TextSize=9,
            Size=UDim2.new(1,0,0,14), TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=4, LayoutOrder=o()}, EL_SCROLL)

        for ci, pre in ipairs(session.chain) do
            local pc = mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                ZIndex=4,LayoutOrder=o()},EL_SCROLL)
            corner(6,pc); stroke(Color3.fromRGB(80,210,100),1,pc); pad(10,6,pc); listV(pc,3)

            local prow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
                Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},pc)
            listH(prow,6)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text=ci..". "..pre.name,TextColor3=Color3.fromRGB(80,210,100),TextSize=11,
                Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,
                ZIndex=6,LayoutOrder=1},prow)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                Text="wait "..pre.delayMs.."ms →",TextColor3=C.MUTED,TextSize=9,
                Size=UDim2.new(0,75,1,0),TextXAlignment=Enum.TextXAlignment.Right,
                ZIndex=6,LayoutOrder=2},prow)

            if #pre.args > 0 then
                local argStr = ""
                for ai, a in ipairs(pre.args) do
                    argStr = argStr..(ai>1 and "  " or "").."["..a.typeKey.."] "..(a.value~="" and a.value or "?")
                end
                mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                    Text=argStr,TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
                    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},pc)
            end
        end
    end

    -- ── Target args ───────────────────────────────────────────────────────────
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="TARGET ARGUMENTS", TextColor3=C.MUTED, TextSize=9,
        Size=UDim2.new(1,0,0,14), TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=4, LayoutOrder=o()}, EL_SCROLL)

    if #session.args == 0 then
        local noArgs = mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,28),ZIndex=4,LayoutOrder=o()},EL_SCROLL)
        corner(6,noArgs); pad(10,0,noArgs)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text="No args observed — fires as signal",TextColor3=C.MUTED,TextSize=10,
            Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},noArgs)
    else
        for i, arg in ipairs(session.args) do
            local af = {typeKey=arg.typeKey, value=arg.value}
            table.insert(argFields, af)

            local ac = mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
                Size=UDim2.new(1,0,0,32),ZIndex=4,LayoutOrder=o()},EL_SCROLL)
            corner(6,ac); stroke(C.BORDER,1,ac); pad(8,0,ac)

            -- kind indicator on left edge
            local kindBar = mk("Frame",{
                BackgroundColor3=KIND_COL[arg.kind] or C.MUTED,
                BorderSizePixel=0,
                Size=UDim2.new(0,3,1,0), Position=UDim2.new(0,0,0,0), ZIndex=6},ac)
            corner(3,kindBar)

            -- arg label
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text="Arg "..i,TextColor3=C.TEXT,TextSize=10,
                Size=UDim2.new(0,36,1,0),Position=UDim2.new(0,10,0,0),
                TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6},ac)

            -- type cycle button
            local typBtn = mk("TextButton",{AutoButtonColor=false,
                BackgroundColor3=TYPE_COLORS[af.typeKey] or C.MUTED,
                BorderSizePixel=0,Font=Enum.Font.GothamBold,Text=af.typeKey,
                TextColor3=Color3.fromRGB(8,8,12),TextSize=8,
                Size=UDim2.new(0,30,0,18),Position=UDim2.new(0,50,0.5,-9),ZIndex=6},ac)
            corner(3,typBtn); af.typBtn = typBtn

            typBtn.MouseButton1Click:Connect(function()
                -- find index
                local idx = 1
                for ti, t in ipairs(TYPES) do
                    if t == af.typeKey then idx=ti; break end
                end
                idx = (idx % #TYPES) + 1
                af.typeKey = TYPES[idx]
                typBtn.Text = af.typeKey
                tw(typBtn,TI.fast,{BackgroundColor3=TYPE_COLORS[af.typeKey] or C.MUTED})
            end)

            -- value input
            local vb = mk("TextBox",{BackgroundColor3=C.BG,BorderSizePixel=0,
                Text=af.value, PlaceholderText="value",
                PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,
                TextSize=10,Font=Enum.Font.Code,ClearTextOnFocus=false,
                TextXAlignment=Enum.TextXAlignment.Left,
                Size=UDim2.new(1,-132,0,20),Position=UDim2.new(0,84,0.5,-10),ZIndex=6},ac)
            corner(3,vb); af.box = vb
            vb:GetPropertyChangedSignal("Text"):Connect(function()
                af.value = vb.Text
            end)

            -- card size shows top observed values as hint
            if #arg.topVals > 0 and arg.card <= 8 then
                local hint = ""
                for j=1,math.min(3,#arg.topVals) do
                    hint = hint..(j>1 and " · " or "")..arg.topVals[j].v:sub(1,16)
                end
                mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                    Text="seen: "..hint,TextColor3=Color3.fromRGB(255,175,70),
                    TextSize=7,Position=UDim2.new(0,84,0,22),ZIndex=6,
                    Size=UDim2.new(1,-140,0,10)},ac)
            end
        end
    end

    -- Update delay box with observed cadence if mimic is on
    if session.cadence and session.cadence.mean > 0 then
        DELAY_BOX.Text = tostring(math.floor(session.cadence.mean * 1000))
    end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- REMOTE SELECTOR (top of EL_SCROLL, always present)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Remote input + load button sit at very top of EL_SCROLL via a sticky header
local SEL_HDR = mk("Frame", {BackgroundColor3=C.SURFACE, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,36), Position=UDim2.new(0,0,0,0), ZIndex=6}, EL)
stroke(C.BORDER, 1, SEL_HDR)
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1), Position=UDim2.new(0,0,1,-1), ZIndex=7}, SEL_HDR)
pad(10, 0, SEL_HDR); listH(SEL_HDR, 8)

mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
    Text="Remote", TextColor3=C.MUTED, TextSize=9,
    Size=UDim2.new(0,48,1,0), TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=7, LayoutOrder=1}, SEL_HDR)

local SEL_BOX = mk("TextBox", {BackgroundColor3=C.CARD, BorderSizePixel=0,
    Text="", PlaceholderText="remote name or select from RSO",
    PlaceholderColor3=C.MUTED, TextColor3=C.WHITE, TextSize=10,
    Font=Enum.Font.Code, ClearTextOnFocus=false,
    TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(1,-120,0,22), ZIndex=7, LayoutOrder=2}, SEL_HDR)
corner(5, SEL_BOX); stroke(C.BORDER,1,SEL_BOX); pad(6,0,SEL_BOX)

local LOAD_BTN = mk("TextButton", {AutoButtonColor=false,
    BackgroundColor3=C.ACCDIM, BorderSizePixel=0,
    Font=Enum.Font.GothamBold, Text="Load",
    TextColor3=C.ACCENT, TextSize=10,
    Size=UDim2.new(0,52,0,22), ZIndex=7, LayoutOrder=3}, SEL_HDR)
corner(5, LOAD_BTN)
LOAD_BTN.MouseEnter:Connect(function() tw(LOAD_BTN,TI.fast,{BackgroundColor3=C.ACCENT,TextColor3=Color3.fromRGB(8,8,12)}) end)
LOAD_BTN.MouseLeave:Connect(function() tw(LOAD_BTN,TI.fast,{BackgroundColor3=C.ACCDIM,TextColor3=C.ACCENT}) end)

-- Shift EL_SCROLL down past the sticky header
EL_SCROLL.Position = UDim2.new(0, 0, 0, 36)
EL_SCROLL.Size     = UDim2.new(1, 0, 1, -136)  -- 36 header + 100 dock

-- ── Load button logic ─────────────────────────────────────────────────────────
LOAD_BTN.MouseButton1Click:Connect(function()
    local name = SEL_BOX.Text:match("^%s*(.-)%s*$")
    if name == "" then
        ECHO_STATUS.Text = "enter a remote name"
        ECHO_STATUS.TextColor3 = C.PATHLOG
        return
    end

    local session = buildSession(name)
    currentSession = session

    buildSessionPanel(session)

    if session.hasSig then
        ECHO_STATUS.Text = "loaded — RSO signature"
        ECHO_STATUS.TextColor3 = Color3.fromRGB(80,210,100)
    else
        ECHO_STATUS.Text = "loaded — no signature"
        ECHO_STATUS.TextColor3 = C.MUTED
    end
end)

-- ── ECHO button logic ─────────────────────────────────────────────────────────
local echoing = false

ECHO_BTN.MouseButton1Click:Connect(function()
    if echoing then return end
    if not currentSession then
        ECHO_STATUS.Text = "load a session first"
        ECHO_STATUS.TextColor3 = C.PATHLOG
        return
    end

    echoing = true
    tw(ECHO_BTN, TI.fast, {BackgroundColor3=Color3.fromRGB(35,32,55)})
    ECHO_STATUS.Text = "executing..."
    ECHO_STATUS.TextColor3 = C.DELTA

    clearLog()

    -- Read repeat settings
    local rCount = tonumber(REP_BOX.Text) or 1
    rCount = math.clamp(math.floor(rCount), 1, 50)

    local rDelay
    if mimicCadence and currentSession.cadence then
        rDelay = math.floor(currentSession.cadence.mean * 1000)
    else
        rDelay = tonumber(DELAY_BOX.Text) or 0
    end

    addLogSep("ECHO SESSION — "..currentSession.target)
    addLog("INFO", "Target: "..currentSession.target)
    addLog("INFO", "Repeats: "..rCount.."  ·  Delay: "..rDelay.."ms")
    if #currentSession.chain > 0 then
        local chainNames = {}
        for _,c in ipairs(currentSession.chain) do table.insert(chainNames,c.name) end
        addLog("INFO", "Chain: "..table.concat(chainNames," → ").." → "..currentSession.target)
    end

    task.spawn(function()
        executeEcho(
            currentSession,
            argFields,          -- live UI values
            rCount,
            rDelay,
            addLog,
            function(results)
                addLogSep("COMPLETE")
                addLog("INFO",
                    ("Fired: %d  ·  Responses: %d  ·  Deltas: %d"):format(
                        results.fired,
                        #results.responses,
                        #results.deltas))

                if #results.responses == 0 and #results.deltas == 0 then
                    addLog("CLEAN", "No observable server response")
                    ECHO_STATUS.Text = "clean — no response"
                    ECHO_STATUS.TextColor3 = C.MUTED
                else
                    ECHO_STATUS.Text = #results.responses.." resp  "..#results.deltas.." delta(s)"
                    ECHO_STATUS.TextColor3 = Color3.fromRGB(80,210,100)
                end

                tw(ECHO_BTN, TI.fast, {BackgroundColor3=C.ACCENT})
                echoing = false
            end
        )
    end)
end)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- EXPORT RSO_OBS bridge
-- 07_rso.lua stores OBS internally — we expose it through G so ECHO can read it
-- This runs after 07_rso.lua has already loaded
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Note: 07_rso.lua needs to export G.RSO_OBS = OBS
-- If it doesn't, ECHO still works but without RSO pre-fill

-- ── Register tab ─────────────────────────────────────────────────────────────
if G.addTab then
    G.addTab("echo", "Echo", P_ECHO)
else
    warn("[Oracle] G.addTab not found — ensure 06_init.lua is up to date")
end
