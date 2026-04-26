-- Oracle // 06_init.lua
-- Tab system · Oracle engine (scan/fire/watch) · Window behaviour · Init
local G       = ...
local C       = G.C
local TI      = G.TI
local mk      = G.mk
local tw      = G.tw
local corner  = G.corner
local stroke  = G.stroke
local pad     = G.pad
local listH   = G.listH
local GUI     = G.GUI
local WIN     = G.WIN
local TBAR    = G.TBAR
local SUB     = G.SUB
local MINBTN  = G.MINBTN
local CLSBTN  = G.CLSBTN
local TBROW   = G.TBROW
local DW      = G.DW;   local DH   = G.DH
local MW      = G.MW;   local MH   = G.MH
local XW      = G.XW;   local XH   = G.XH
local GRIP    = G.GRIP
local TAGCOL  = G.TAGCOL
local CFG     = G.CFG
local RepS    = G.RepS
local LP      = G.LP
local RS      = G.RS
local UIS     = G.UIS
local PAYLOADS= G.PAYLOADS
local snap    = G.snap
local dif     = G.dif
local rlog    = G.rlog
local hookR   = G.hookR
local discR   = G.discR
-- dashboard
local P_DASH  = G.P_DASH
local SCANBTN = G.SCANBTN
local STOPBTN = G.STOPBTN
local CLEARBTN= G.CLEARBTN
local WDOT    = G.WDOT
local LS      = G.LS
local setStat = G.setStat
local addLog  = G.addLog
local addSep  = G.addSep
-- target
local P_TGT   = G.P_TGT
local TSUB    = G.TSUB
local RBOX    = G.RBOX
local FBTN    = G.FBTN
local FSTAT   = G.FSTAT
local addTR   = G.addTR
local clrTR   = G.clrTR
local popR    = G.popR
local getSelPay = G.getSelPay
-- compose
local P_CMP   = G.P_CMP
local CSUB    = G.CSUB
local CRNAME  = G.CRNAME
local BBTN    = G.BBTN
local BSTAT   = G.BSTAT
local addCR   = G.addCR
local clrCR   = G.clrCR
local buildTable = G.buildTable

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TAB SYSTEM
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local TABS = {
    {k="dash",    l="Dashboard",   p=P_DASH},
    {k="target",  l="Target Mode", p=P_TGT},
    {k="compose", l="Compose",     p=P_CMP},
}
local tBtns = {}; local aTab = nil; local tPop = false

local function swTab(key)
    if aTab == key then return end
    aTab = key
    for _, t in ipairs(TABS) do
        local b  = tBtns[t.k]
        local on = (t.k == key)
        t.p.Visible = on
        tw(b, TI.fast, {
            BackgroundColor3       = on and C.CARD or Color3.fromRGB(0,0,0),
            BackgroundTransparency = on and 0 or 1,
            TextColor3             = on and C.TEXT or C.MUTED,
        })
        local ln = b:FindFirstChild("AL")
        if ln then tw(ln, TI.fast, {BackgroundTransparency = on and 0 or 1}) end
    end
    -- auto-populate remote browser on first Target visit
    if key == "target" and not tPop then
        tPop = true
        task.defer(popR)
    end
    -- sync Compose remote display with RBOX
    if key == "compose" then
        local n = RBOX.Text:match("^%s*(.-)%s*$")
        if n ~= "" then
            CRNAME.Text       = n
            CRNAME.TextColor3 = C.TEXT
        else
            CRNAME.Text       = "no remote selected — pick one in Target Mode"
            CRNAME.TextColor3 = C.MUTED
        end
    end
end

for _, t in ipairs(TABS) do
    local b = mk("TextButton", {
        Name                   = t.k,
        AutoButtonColor        = false,
        BackgroundColor3       = Color3.fromRGB(0,0,0),
        BackgroundTransparency = 1,
        BorderSizePixel        = 0,
        Font                   = Enum.Font.GothamSemibold,
        Text                   = t.l,
        TextColor3             = C.MUTED,
        TextSize               = 11,
        Size                   = UDim2.new(0, 0, 1, 0),
        AutomaticSize          = Enum.AutomaticSize.X,
        ZIndex                 = 6,
    }, TBROW)
    corner(6, b)
    mk("UIPadding", {PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12)}, b)
    local ln = mk("Frame", {
        Name                   = "AL",
        BackgroundColor3       = C.ACCENT,
        BackgroundTransparency = 1,
        BorderSizePixel        = 0,
        Position               = UDim2.new(0, 8, 1, -3),
        Size                   = UDim2.new(1, -16, 0, 2),
        ZIndex                 = 7,
    }, b)
    corner(1, ln)
    b.MouseEnter:Connect(function()
        if aTab ~= t.k then tw(b, TI.fast, {TextColor3=C.TEXT}) end
    end)
    b.MouseLeave:Connect(function()
        if aTab ~= t.k then tw(b, TI.fast, {TextColor3=C.MUTED}) end
    end)
    b.MouseButton1Click:Connect(function() swTab(t.k) end)
    tBtns[t.k] = b
end

-- G.addTab: allows later chunks (e.g. 07_rso.lua) to register new tabs
-- at runtime without modifying this file
G.addTab = function(key, label, page)
    page.Visible = false
    table.insert(TABS, {k=key, l=label, p=page})
    local b = mk("TextButton", {
        Name                   = key,
        AutoButtonColor        = false,
        BackgroundColor3       = Color3.fromRGB(0,0,0),
        BackgroundTransparency = 1,
        BorderSizePixel        = 0,
        Font                   = Enum.Font.GothamSemibold,
        Text                   = label,
        TextColor3             = C.MUTED,
        TextSize               = 11,
        Size                   = UDim2.new(0, 0, 1, 0),
        AutomaticSize          = Enum.AutomaticSize.X,
        ZIndex                 = 6,
    }, TBROW)
    corner(6, b)
    mk("UIPadding", {PaddingLeft=UDim.new(0,12), PaddingRight=UDim.new(0,12)}, b)
    local ln = mk("Frame", {
        Name                   = "AL",
        BackgroundColor3       = C.ACCENT,
        BackgroundTransparency = 1,
        BorderSizePixel        = 0,
        Position               = UDim2.new(0, 8, 1, -3),
        Size                   = UDim2.new(1, -16, 0, 2),
        ZIndex                 = 7,
    }, b)
    corner(1, ln)
    b.MouseEnter:Connect(function()
        if aTab ~= key then tw(b, TI.fast, {TextColor3=C.TEXT}) end
    end)
    b.MouseLeave:Connect(function()
        if aTab ~= key then tw(b, TI.fast, {TextColor3=C.MUTED}) end
    end)
    b.MouseButton1Click:Connect(function() swTab(key) end)
    tBtns[key] = b
end

swTab("dash")

-- ── Resize grip ───────────────────────────────────────────────────────────────
local RGRIP = mk("TextButton", {
    AutoButtonColor        = false,
    BackgroundColor3       = C.ACCDIM,
    BackgroundTransparency = 0.6,
    BorderSizePixel        = 0,
    Text                   = "",
    Size                   = UDim2.new(0, GRIP*2, 0, GRIP*2),
    Position               = UDim2.new(1, -GRIP*2, 1, -GRIP*2),
    ZIndex                 = 10,
}, WIN)
corner(4, RGRIP)
mk("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, Text = "◢",
    TextColor3 = C.ACCENT, TextSize = 12, Size = UDim2.fromScale(1,1),
    TextXAlignment = Enum.TextXAlignment.Center,
    TextYAlignment = Enum.TextYAlignment.Center, ZIndex = 11,
}, RGRIP)

-- ── Mini bar ──────────────────────────────────────────────────────────────────
local MINI = mk("Frame", {
    BackgroundColor3 = C.SURFACE, BorderSizePixel = 0,
    Position = UDim2.new(0.5,-130,1,-48),
    Size     = UDim2.new(0,260,0,36),
    Visible  = false, ZIndex = 20,
}, GUI)
corner(10, MINI); stroke(C.BORDER, 1, MINI)
listH(MINI, 10, Enum.VerticalAlignment.Center, Enum.HorizontalAlignment.Center)

mk("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
    Text = "✦  Oracal", TextColor3 = C.ACCENT, TextSize = 12,
    Size = UDim2.new(0,100,0,20), TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 21,
}, MINI)

local RESTBTN = mk("TextButton", {
    AutoButtonColor = false, BackgroundColor3 = C.CARD, BorderSizePixel = 0,
    Font = Enum.Font.GothamBold, Text = "▲  Restore", TextColor3 = C.MUTED,
    TextSize = 10, Size = UDim2.new(0,80,0,24), ZIndex = 21,
}, MINI)
corner(6, RESTBTN)
RESTBTN.MouseEnter:Connect(function() tw(RESTBTN,TI.fast,{BackgroundColor3=C.ACCDIM,TextColor3=C.ACCENT}) end)
RESTBTN.MouseLeave:Connect(function() tw(RESTBTN,TI.fast,{BackgroundColor3=C.CARD, TextColor3=C.MUTED})   end)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ORACLE ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local cnt = {probes=0, deltas=0, responses=0, path=0}
local function bump(k)
    cnt[k] = (cnt[k] or 0) + 1
    if k=="probes"    then setStat("probes",    cnt.probes)           end
    if k=="deltas"    then setStat("deltas",    cnt.deltas,    C.DELTA)  end
    if k=="responses" then setStat("responses", cnt.responses, C.RESP)   end
    if k=="path"      then setStat("path",      cnt.path,      C.PATHLOG) end
end

-- watch thread
local wOn = false; local wBase = nil; local wThr = nil

local function startWatch()
    wOn   = true
    wBase = snap()
    WDOT.BackgroundColor3 = C.RESP
    wThr  = task.spawn(function()
        while wOn do
            task.wait(0.3)
            local cur = snap()
            for _, ch in ipairs(dif(wBase, cur)) do
                if ch.bad then
                    addLog("WATCH", "⚠ Delayed pathological — "..ch.path,
                        ch.bv.." → "..ch.av, true)
                    wBase[ch.path] = cur[ch.path]
                else
                    local bn, an = tonumber(ch.bv), tonumber(ch.av)
                    if bn and an and math.abs(an-bn) > 100 then
                        addLog("WATCH", "State shift — "..ch.path,
                            ("%s → %s (Δ%.0f)"):format(ch.bv, ch.av, math.abs(an-bn)))
                        wBase[ch.path] = cur[ch.path]
                    end
                end
            end
        end
    end)
end

local function stopWatch()
    wOn = false
    WDOT.BackgroundColor3 = C.CLEAN
    if wThr then task.cancel(wThr); wThr = nil end
end

-- scan state
local scanning = false; local sThr = nil

local function setS(s)
    scanning = s
    setStat("state", s and "SCANNING" or "IDLE", s and C.RESP or C.MUTED)
    SUB.Text = s and "Engine Probe  ·  scanning..." or "Engine Probe  ·  idle"
    SCANBTN.BackgroundColor3 = s and Color3.fromRGB(35,32,55) or C.ACCENT
    tw(STOPBTN, TI.fast, {BackgroundColor3 = s
        and Color3.fromRGB(160,40,40) or Color3.fromRGB(40,40,55)})
end

-- core fire-and-watch (used by full scan)
local function fW(remote, payload, allR, logFn)
    local before = snap(); rlog = G.rlog
    for k in pairs(rlog) do rlog[k]=nil end
    local conns = hookR(allR)
    local ok    = pcall(function() remote:FireServer(payload) end)
    bump("probes")
    if logFn then logFn("FIRED", remote.Name.." ←", ok and nil or "Rejected at client") end
    if not ok then
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        return
    end
    task.wait(CFG.RW)
    local dl = tick() + CFG.WD
    while tick() < dl do
        task.wait(0.05); if #rlog > 0 then break end
    end
    local after = snap()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    for _, r in ipairs(rlog) do
        bump("responses")
        if logFn then logFn("RESPONSE", "Server replied via "..r.name, r.args, true) end
    end
    for k in pairs(rlog) do rlog[k]=nil end
    for _, ch in ipairs(dif(before, after)) do
        bump("deltas"); if ch.bad then bump("path") end
        if logFn then
            logFn(ch.bad and "PATHOLOG" or "DELTA",
                (ch.bad and "⚠ PATHOLOGICAL — " or "State change — ")..ch.path,
                ch.bv.."  →  "..ch.av, true)
        end
    end
end

-- full scan
local function runScan()
    if scanning then return end; setS(true)
    sThr = task.spawn(function()
        if not LP.Character then LP.CharacterAdded:Wait() end; task.wait(0.5)
        local ev, fn = discR()
        setStat("remotes", #ev)
        addLog("BASELINE", ("Found %d RemoteEvents  %d RemoteFunctions"):format(#ev, #fn))
        if #ev == 0 then
            addLog("INFO", "No RemoteEvents found — run inside a live game")
            setS(false); return
        end
        for _, r in ipairs(ev) do addLog("INFO", r:GetFullName()) end
        startWatch(); addSep("BEGIN PROBE")
        for _, remote in ipairs(ev) do
            if not scanning then break end
            addSep("→ "..remote.Name)
            for _, p in ipairs(PAYLOADS) do
                if not scanning then break end
                fW(remote, p.v, ev, addLog)
                task.wait(CFG.FI)
            end
        end
        addSep("COMPLETE")
        addLog("INFO", ("%d probes · %d deltas · %d responses · %d pathological")
            :format(cnt.probes, cnt.deltas, cnt.responses, cnt.path))
        setS(false)
    end)
end

local function stopScan()
    if not scanning then return end
    scanning = false; stopWatch()
    if sThr then task.cancel(sThr); sThr = nil end
    addSep("STOPPED"); setS(false)
end

-- find a remote by name
local function findR(name)
    local target = nil
    local function sc(root)
        local ok, d = pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _, x in ipairs(d) do
            if (x:IsA("RemoteEvent") or x:IsA("RemoteFunction")) and x.Name == name then
                target = x; return
            end
        end
    end
    sc(RepS); if not target then sc(workspace) end
    return target
end

-- single targeted fire (Target Mode + Compose)
local function doFire(remote, payload, resFn, statFn, subFn)
    local ev = {}
    local function col(root)
        local ok, d = pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _, x in ipairs(d) do
            if x:IsA("RemoteEvent") then table.insert(ev, x) end
        end
    end
    col(RepS); col(workspace)

    local before = snap()
    for k in pairs(rlog) do rlog[k]=nil end
    local conns = hookR(ev)

    local ok, err = pcall(function()
        if remote:IsA("RemoteEvent") then remote:FireServer(payload)
        else remote:InvokeServer(payload) end
    end)

    if not ok then
        for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        resFn("INFO", "Rejected at client boundary", tostring(err))
        if statFn then statFn("Client rejected the payload", C.MUTED) end
        return
    end

    resFn("FIRED", "Sent — watching for response...")
    task.wait(CFG.RW)
    local dl = tick() + CFG.WD
    while tick() < dl do
        task.wait(0.05); if #rlog > 0 then break end
    end

    local after = snap()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end

    local hits = 0
    for _, r in ipairs(rlog) do
        hits += 1
        resFn("RESPONSE", "Server replied via "..r.name, r.args, true)
        addLog("RESPONSE", "["..remote.Name.."] via "..r.name, r.args, true)
    end
    for k in pairs(rlog) do rlog[k]=nil end

    for _, ch in ipairs(dif(before, after)) do
        hits += 1
        resFn(ch.bad and "PATHOLOG" or "DELTA",
            (ch.bad and "⚠ " or "")..ch.path, ch.bv.." → "..ch.av, true)
        addLog(ch.bad and "PATHOLOG" or "DELTA",
            "["..remote.Name.."] "..ch.path, ch.bv.." → "..ch.av, ch.bad)
    end

    if hits == 0 then
        resFn("CLEAN", "No observable response or state change")
        if statFn then statFn("Clean — no observable impact", C.MUTED) end
        if subFn  then subFn("clean — no impact") end
    else
        if statFn then statFn(hits.." result(s) — check panel", C.RESP) end
        if subFn  then subFn(hits.." result(s)") end
    end
end

-- ── FIRE ONCE button ──────────────────────────────────────────────────────────
FBTN.MouseButton1Click:Connect(function()
    if scanning then
        FSTAT.Text = "Stop the scan before using target mode"
        FSTAT.TextColor3 = C.PATHLOG; return
    end
    local name = RBOX.Text:match("^%s*(.-)%s*$")
    if name == "" then
        FSTAT.Text = "Select a remote first"
        FSTAT.TextColor3 = C.PATHLOG; return
    end
    local remote = findR(name)
    if not remote then
        FSTAT.Text = "Not found: "..name
        FSTAT.TextColor3 = C.PATHLOG; return
    end
    local payload = PAYLOADS[getSelPay()]
    FSTAT.Text = "Firing "..payload.l.." ..."; FSTAT.TextColor3 = C.FIRED
    TSUB.Text  = name.."  ←  "..payload.l
    clrTR()
    addTR("INFO", "Remote: "..remote:GetFullName())
    addTR("INFO", "Payload: "..payload.l)
    task.spawn(function()
        doFire(remote, payload.v, addTR,
            function(t, c) FSTAT.Text = t; FSTAT.TextColor3 = c end,
            function(t)    TSUB.Text  = name.."  ·  "..t end)
    end)
end)

-- ── BUILD & FIRE button ───────────────────────────────────────────────────────
BBTN.MouseButton1Click:Connect(function()
    local name = RBOX.Text:match("^%s*(.-)%s*$")
    if name == "" then
        BSTAT.Text = "Select a remote in Target Mode first"
        BSTAT.TextColor3 = C.PATHLOG; return
    end
    local fRows = G.fRows
    if not fRows or #fRows == 0 then
        BSTAT.Text = "Add at least one field"
        BSTAT.TextColor3 = C.PATHLOG; return
    end
    local remote = findR(name)
    if not remote then
        BSTAT.Text = "Not found: "..name
        BSTAT.TextColor3 = C.PATHLOG; return
    end
    local payload = buildTable()
    BSTAT.Text = "Firing composed payload..."; BSTAT.TextColor3 = C.FIRED
    CSUB.Text  = name.."  ←  "..#fRows.." field(s)"
    clrCR()
    addCR("INFO", "Remote: "..remote:GetFullName())
    addCR("INFO", "Fields: "..#fRows)
    task.spawn(function()
        doFire(remote, payload, addCR,
            function(t, c) BSTAT.Text = t; BSTAT.TextColor3 = c end,
            function(t)    CSUB.Text  = name.."  ·  "..t end)
    end)
end)

-- ── Scan / Stop / Clear buttons ───────────────────────────────────────────────
SCANBTN.MouseButton1Click:Connect(runScan)
STOPBTN.MouseButton1Click:Connect(stopScan)
CLEARBTN.MouseButton1Click:Connect(function()
    for _, c in ipairs(LS:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    cnt = {probes=0, deltas=0, responses=0, path=0}
    setStat("probes","0"); setStat("deltas","0")
    setStat("responses","0"); setStat("path","0")
end)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- WINDOW BEHAVIOUR
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local isDrag = false; local isResize = false
local dragOff = Vector2.new()
local resizeStart = Vector2.new(); local resizeOrigSz = Vector2.new()
local dtX = 0; local dtY = 0; local LERP = 0.18; local isMini = false

TBAR.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        isDrag = true
        local ap = WIN.AbsolutePosition
        dragOff = Vector2.new(i.Position.X - ap.X, i.Position.Y - ap.Y)
        dtX = ap.X; dtY = ap.Y
    end
end)
TBAR.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then isDrag = false end
end)

RGRIP.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        isResize = true
        resizeStart  = Vector2.new(i.Position.X, i.Position.Y)
        resizeOrigSz = Vector2.new(WIN.AbsoluteSize.X, WIN.AbsoluteSize.Y)
    end
end)
RGRIP.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then isResize = false end
end)
RGRIP.MouseEnter:Connect(function() tw(RGRIP, TI.fast, {BackgroundTransparency=0.2}) end)
RGRIP.MouseLeave:Connect(function() tw(RGRIP, TI.fast, {BackgroundTransparency=0.6}) end)

UIS.InputChanged:Connect(function(i)
    if i.UserInputType ~= Enum.UserInputType.MouseMovement then return end
    local mx, my = i.Position.X, i.Position.Y
    if isDrag and not isMini then
        local vp = GUI.AbsoluteSize
        local sz = WIN.AbsoluteSize
        dtX = math.clamp(mx - dragOff.X, 0, vp.X - sz.X)
        dtY = math.clamp(my - dragOff.Y, 0, vp.Y - sz.Y)
    end
    if isResize then
        local dx = mx - resizeStart.X
        local dy = my - resizeStart.Y
        WIN.Size = UDim2.new(0, math.clamp(resizeOrigSz.X+dx, MW, XW),
                             0, math.clamp(resizeOrigSz.Y+dy, MH, XH))
    end
end)
UIS.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 then
        isDrag = false; isResize = false
    end
end)

RS.Heartbeat:Connect(function(dt)
    if not isDrag then return end
    local cx = WIN.Position.X.Offset
    local cy = WIN.Position.Y.Offset
    local a  = math.min(1, LERP * (dt * 60))
    WIN.Position = UDim2.new(0, cx+(dtX-cx)*a, 0, cy+(dtY-cy)*a)
end)

local function minimize()
    isMini = true
    tw(WIN, TI.med, {
        Size     = UDim2.new(0, DW, 0, 0),
        Position = UDim2.new(
            WIN.Position.X.Scale, WIN.Position.X.Offset,
            WIN.Position.Y.Scale, WIN.Position.Y.Offset + WIN.AbsoluteSize.Y/2),
    })
    task.delay(0.2, function() WIN.Visible = false; MINI.Visible = true end)
end

local function restore()
    isMini = false
    WIN.Size = UDim2.new(0, DW, 0, 0)
    WIN.Visible = true; MINI.Visible = false
    tw(WIN, TI.spring, {Size = UDim2.new(0, DW, 0, DH)})
end

MINBTN.MouseButton1Click:Connect(minimize)
RESTBTN.MouseButton1Click:Connect(restore)
CLSBTN.MouseButton1Click:Connect(function()
    tw(WIN,  TI.med, {Size=UDim2.new(0,DW,0,0), BackgroundTransparency=1})
    tw(TBAR, TI.med, {BackgroundTransparency=1})
    task.delay(0.25, function() GUI:Destroy() end)
end)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- INIT
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
setStat("state",     "IDLE",  C.MUTED)
setStat("remotes",   "—")
setStat("probes",    "0")
setStat("deltas",    "0")
setStat("responses", "0")
setStat("path",      "0")

addLog("INFO", "Oracal ready")
addLog("INFO", "Press SCAN inside a live game")
addLog("INFO", "DELTA = server state changed after your fire")
addLog("INFO", "RESPONSE = server explicitly fired back at you")
addLog("INFO", "PATHOLOG = NaN / Inf confirmed in server state")
addLog("INFO", "Target Mode → select a remote and probe it directly")
addLog("INFO", "Compose → build table payloads field by field")

-- open animation
WIN.Size     = UDim2.new(0, DW, 0, 0)
WIN.Position = UDim2.new(0.5, -DW/2, 0.5, 0)
tw(WIN, TI.spring, {
    Size     = UDim2.new(0, DW, 0, DH),
    Position = UDim2.new(0.5, -DW/2, 0.5, -DH/2),
})
