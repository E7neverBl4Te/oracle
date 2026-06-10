-- Oracle // 39_trustui.lua
-- TRUST UI — Interface for the Trust Engine (38_trust.lua)
-- Scan controls · live log · finding cards · evidence + fix documentation

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

-- Engine refs (38_trust.lua)
local trust_scan   = G.trust_scan
local trust_abort  = G.trust_abort

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- COLOURS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local SEV_COL = {
    CRITICAL = Color3.fromRGB(255, 70,  70),
    HIGH     = Color3.fromRGB(255, 140, 40),
    MEDIUM   = Color3.fromRGB(255, 210, 50),
    LOW      = Color3.fromRGB(120, 200, 120),
}
local CONFIRMED_COL = Color3.fromRGB(255, 70,  70)
local PROBABLE_COL  = Color3.fromRGB(200, 120, 60)
local PROG_COL      = Color3.fromRGB(100, 120, 220)
local CLEAN_COL     = Color3.fromRGB(80,  180, 120)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ROOT PANEL
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P = mk("Frame", {
    Size             = UDim2.new(1, 0, 1, 0),
    BackgroundColor3 = C.BG,
    BorderSizePixel  = 0,
})
listV(P, 0)

-- ── Header ────────────────────────────────────────────────────────────────────

local HDR = mk("Frame", {
    Size             = UDim2.new(1, 0, 0, 36),
    BackgroundColor3 = C.SURFACE,
    BorderSizePixel  = 0,
    LayoutOrder      = 1,
}, P)
corner(6, HDR)
stroke(C.BORDER, 1, HDR)
pad(8, 0, HDR)
listH(HDR, 8)

mk("TextLabel", {
    Size                   = UDim2.new(0, 70, 1, 0),
    BackgroundTransparency = 1,
    Text                   = "TRUST",
    TextColor3             = C.TEXT,
    Font                   = Enum.Font.GothamBold,
    TextSize               = 13,
    TextXAlignment         = Enum.TextXAlignment.Left,
    LayoutOrder            = 1,
}, HDR)

mk("TextLabel", {
    Size                   = UDim2.new(1, -280, 1, 0),
    BackgroundTransparency = 1,
    Text                   = "Numeric Argument Trust Auditor",
    TextColor3             = C.MUTED,
    Font                   = Enum.Font.Gotham,
    TextSize               = 11,
    TextXAlignment         = Enum.TextXAlignment.Left,
    LayoutOrder            = 2,
}, HDR)

local STATUS = mk("TextLabel", {
    Size                   = UDim2.new(0, 200, 1, 0),
    BackgroundTransparency = 1,
    Text                   = "idle",
    TextColor3             = C.MUTED,
    Font                   = Enum.Font.GothamMedium,
    TextSize               = 11,
    TextXAlignment         = Enum.TextXAlignment.Right,
    LayoutOrder            = 3,
}, HDR)

-- ── Progress bar ──────────────────────────────────────────────────────────────

local PROG_TRACK = mk("Frame", {
    Size             = UDim2.new(1, 0, 0, 3),
    BackgroundColor3 = C.BORDER,
    BorderSizePixel  = 0,
    LayoutOrder      = 2,
}, P)
corner(1, PROG_TRACK)

local PROG_BAR = mk("Frame", {
    Size             = UDim2.new(0, 0, 1, 0),
    BackgroundColor3 = PROG_COL,
    BorderSizePixel  = 0,
}, PROG_TRACK)
corner(1, PROG_BAR)

-- ── Controls ──────────────────────────────────────────────────────────────────

local CTRL = mk("Frame", {
    Size            = UDim2.new(1, 0, 0, 32),
    BackgroundTransparency = 1,
    LayoutOrder     = 3,
}, P)
pad(8, 0, CTRL)
listH(CTRL, 6)

local function mkBtn(label, bg, lo)
    local b = mk("TextButton", {
        Size             = UDim2.new(0, 110, 1, -4),
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        Text             = label,
        TextColor3       = C.WHITE,
        Font             = Enum.Font.GothamBold,
        TextSize         = 11,
        AutoButtonColor  = false,
        LayoutOrder      = lo,
    }, CTRL)
    corner(5, b)
    return b
end

local QUICK_BTN = mkBtn("Quick Scan",  Color3.fromRGB(60, 100, 200), 1)
local FULL_BTN  = mkBtn("Full Audit",  Color3.fromRGB(80,  60, 160), 2)
local ABORT_BTN = mkBtn("Abort",       Color3.fromRGB(100, 30,  30), 3)

local FIND_COUNT = mk("TextLabel", {
    Size                   = UDim2.new(1, -360, 1, 0),
    BackgroundTransparency = 1,
    Text                   = "0 findings",
    TextColor3             = C.MUTED,
    Font                   = Enum.Font.GothamMedium,
    TextSize               = 11,
    TextXAlignment         = Enum.TextXAlignment.Right,
    LayoutOrder            = 4,
}, CTRL)

-- ── Body: findings left (55%) · log right (45%) ───────────────────────────────

local BODY = mk("Frame", {
    Size            = UDim2.new(1, 0, 1, -80),
    BackgroundTransparency = 1,
    LayoutOrder     = 4,
}, P)
pad(6, 0, BODY)
listH(BODY, 6)

-- Findings panel
local FP = mk("Frame", {
    Size             = UDim2.new(0.55, -3, 1, 0),
    BackgroundColor3 = C.SURFACE,
    BorderSizePixel  = 0,
    LayoutOrder      = 1,
}, BODY)
corner(6, FP)
stroke(C.BORDER, 1, FP)

mk("TextLabel", {
    Size                   = UDim2.new(1, 0, 0, 22),
    BackgroundTransparency = 1,
    Text                   = "  FINDINGS",
    TextColor3             = C.MUTED,
    Font                   = Enum.Font.GothamBold,
    TextSize               = 10,
    TextXAlignment         = Enum.TextXAlignment.Left,
    LayoutOrder            = 1,
}, FP)

local FIND_SCROLL = mk("ScrollingFrame", {
    Size                 = UDim2.new(1, 0, 1, -22),
    Position             = UDim2.new(0, 0, 0, 22),
    BackgroundTransparency = 1,
    BorderSizePixel      = 0,
    ScrollBarThickness   = 3,
    ScrollBarImageColor3 = C.BORDER,
    CanvasSize           = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize  = Enum.AutomaticSize.Y,
    LayoutOrder          = 2,
}, FP)
pad(6, 4, FIND_SCROLL)
listV(FIND_SCROLL, 6)

local FIND_EMPTY = mk("TextLabel", {
    Size                   = UDim2.new(1, 0, 0, 40),
    BackgroundTransparency = 1,
    Text                   = "No findings yet — run a scan",
    TextColor3             = C.MUTED,
    Font                   = Enum.Font.Gotham,
    TextSize               = 11,
}, FIND_SCROLL)

-- Log panel
local LP_FRAME = mk("Frame", {
    Size             = UDim2.new(0.45, -3, 1, 0),
    BackgroundColor3 = C.SURFACE,
    BorderSizePixel  = 0,
    LayoutOrder      = 2,
}, BODY)
corner(6, LP_FRAME)
stroke(C.BORDER, 1, LP_FRAME)

mk("TextLabel", {
    Size                   = UDim2.new(1, 0, 0, 22),
    BackgroundTransparency = 1,
    Text                   = "  ENGINE LOG",
    TextColor3             = C.MUTED,
    Font                   = Enum.Font.GothamBold,
    TextSize               = 10,
    TextXAlignment         = Enum.TextXAlignment.Left,
}, LP_FRAME)

local LOG_SCROLL = mk("ScrollingFrame", {
    Size                 = UDim2.new(1, 0, 1, -22),
    Position             = UDim2.new(0, 0, 0, 22),
    BackgroundTransparency = 1,
    BorderSizePixel      = 0,
    ScrollBarThickness   = 3,
    ScrollBarImageColor3 = C.BORDER,
    CanvasSize           = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize  = Enum.AutomaticSize.Y,
}, LP_FRAME)
pad(4, 3, LOG_SCROLL)
listV(LOG_SCROLL, 2)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- LOG HELPERS — uses Oracle's own mkRow/mkSep routed to our scroll frame
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local logN = 0

local function clearLog()
    for _, c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then
            c:Destroy()
        end
    end
    logN = 0
end

local function addLog(level, title, detail, highlight)
    logN = logN + 1
    mkRow(level, title, detail or "", highlight, LOG_SCROLL, logN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition =
            Vector2.new(0, LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end

local function addLogSep(txt)
    logN = logN + 1
    mkSep(txt, LOG_SCROLL, logN)
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- FINDING CARDS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local findCount = 0

local function clearFindings()
    for _, c in ipairs(FIND_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then
            c:Destroy()
        end
    end
    FIND_EMPTY.Parent = FIND_SCROLL
    findCount = 0
end

local function addFindingCard(f)
    FIND_EMPTY.Parent = nil
    findCount = findCount + 1

    local sevCol  = SEV_COL[f.severity] or C.MUTED
    local confCol = f.confirmed and CONFIRMED_COL or PROBABLE_COL
    local confTxt = f.confirmed and "CONFIRMED" or "PROBABLE"

    -- Card
    local card = mk("Frame", {
        Size             = UDim2.new(1, 0, 0, 0),
        AutomaticSize    = Enum.AutomaticSize.Y,
        BackgroundColor3 = C.CARD,
        BorderSizePixel  = 0,
        LayoutOrder      = findCount,
    }, FIND_SCROLL)
    corner(5, card)
    stroke(sevCol, 1, card)
    pad(8, 6, card)
    listV(card, 5)

    -- Top row: severity · remote name · confirmed badge
    local top = mk("Frame", {
        Size            = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        LayoutOrder     = 1,
    }, card)
    listH(top, 6)

    local sb = mk("TextLabel", {
        Size             = UDim2.new(0, 68, 1, 0),
        BackgroundColor3 = sevCol,
        Text             = f.severity,
        TextColor3       = C.WHITE,
        Font             = Enum.Font.GothamBold,
        TextSize         = 9,
        LayoutOrder      = 1,
    }, top)
    corner(3, sb)

    mk("TextLabel", {
        Size                   = UDim2.new(1, -150, 1, 0),
        BackgroundTransparency = 1,
        Text                   = f.remote,
        TextColor3             = C.TEXT,
        Font                   = Enum.Font.GothamBold,
        TextSize               = 11,
        TextXAlignment         = Enum.TextXAlignment.Left,
        LayoutOrder            = 2,
    }, top)

    local cb = mk("TextLabel", {
        Size             = UDim2.new(0, 72, 1, 0),
        BackgroundColor3 = confCol,
        Text             = confTxt,
        TextColor3       = C.WHITE,
        Font             = Enum.Font.GothamBold,
        TextSize         = 9,
        LayoutOrder      = 3,
    }, top)
    corner(3, cb)

    -- Class label
    mk("TextLabel", {
        Size                   = UDim2.new(1, 0, 0, 13),
        BackgroundTransparency = 1,
        Text                   = f.label or "",
        TextColor3             = sevCol,
        Font                   = Enum.Font.GothamMedium,
        TextSize               = 10,
        TextXAlignment         = Enum.TextXAlignment.Left,
        LayoutOrder            = 2,
    }, card)

    -- Evidence line
    local evText = ""
    if f.family == "NUMERIC" and f.evidence and f.evidence[1] then
        local e = f.evidence[1]
        evText = ("wrapper:%s  arg(1)→Δ%d  arg(10)→Δ%d  ratio:%.2fx"):format(
            f.wrapper or "?",
            math.floor(e.delta1  or 0),
            math.floor(e.delta10 or 0),
            e.ratio or 0)
    elseif f.family == "PRICE" and f.evidence and f.evidence[1] then
        local e = f.evidence[1]
        evText = ("wrapper:%s  price=0 accepted  Δ%s on [%s]"):format(
            f.wrapper or "?",
            tostring(e.delta_zero or "?"),
            e.path or "?")
    elseif f.family == "PERMISSION" and f.evidence and f.evidence[1] then
        local e = f.evidence[1]
        evText = ("wrapper:%s  value=%s  %d change(s) vs baseline %d"):format(
            f.wrapper or "?",
            tostring(e.value or "?"),
            e.changes  or 0,
            e.baseline or 0)
    end

    mk("TextLabel", {
        Size                   = UDim2.new(1, 0, 0, 0),
        AutomaticSize          = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Text                   = evText,
        TextColor3             = C.MUTED,
        Font                   = Enum.Font.Code,
        TextSize               = 9,
        TextXAlignment         = Enum.TextXAlignment.Left,
        TextWrapped            = true,
        LayoutOrder            = 3,
    }, card)

    -- Divider
    mk("Frame", {
        Size             = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = C.BORDER,
        BorderSizePixel  = 0,
        LayoutOrder      = 4,
    }, card)

    -- Issue description
    mk("TextLabel", {
        Size                   = UDim2.new(1, 0, 0, 0),
        AutomaticSize          = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Text                   = "ISSUE  " .. (f.desc or ""),
        TextColor3             = C.MUTED,
        Font                   = Enum.Font.Gotham,
        TextSize               = 9,
        TextXAlignment         = Enum.TextXAlignment.Left,
        TextWrapped            = true,
        LayoutOrder            = 5,
    }, card)

    -- Fix (green — the developer action item)
    mk("TextLabel", {
        Size                   = UDim2.new(1, 0, 0, 0),
        AutomaticSize          = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Text                   = "FIX    " .. (f.fix or ""),
        TextColor3             = CLEAN_COL,
        Font                   = Enum.Font.GothamMedium,
        TextSize               = 9,
        TextXAlignment         = Enum.TextXAlignment.Left,
        TextWrapped            = true,
        LayoutOrder            = 6,
    }, card)
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SCAN RUNNER
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local running = false

local function setStatus(text, col)
    STATUS.Text       = text
    STATUS.TextColor3 = col or C.MUTED
end

local function setRunning(state, text, col)
    running = state
    QUICK_BTN.Active = not state
    FULL_BTN.Active  = not state
    tw(QUICK_BTN, TI.fast, {
        BackgroundColor3 = state
            and Color3.fromRGB(40, 60, 120)
            or  Color3.fromRGB(60, 100, 200),
    })
    tw(FULL_BTN, TI.fast, {
        BackgroundColor3 = state
            and Color3.fromRGB(50, 40, 100)
            or  Color3.fromRGB(80, 60, 160),
    })
    setStatus(text or "idle", col)
end

local function onProgress(i, total, name)
    tw(PROG_BAR, TI.fast, {Size = UDim2.new(i / total, 0, 1, 0)})
    setStatus(("[%d/%d] %s"):format(i, total, name), PROG_COL)
end

local function runTrust(options, label)
    if running then return end
    clearLog()
    clearFindings()
    FIND_COUNT.Text       = "0 findings"
    FIND_COUNT.TextColor3 = C.MUTED
    tw(PROG_BAR, TI.fast, {Size = UDim2.new(0, 0, 1, 0)})
    setRunning(true, label .. "...", PROG_COL)
    addLogSep(label:upper())

    task.spawn(function()
        local lastCount = 0

        local function logFn(level, title, detail, highlight)
            addLog(level, title, detail, highlight)
            -- stream findings as they arrive
            local findings = G.trust_getFindings()
            if #findings > lastCount then
                for i = lastCount + 1, #findings do
                    addFindingCard(findings[i])
                    FIND_COUNT.Text       = findCount .. " finding(s)"
                    FIND_COUNT.TextColor3 = CONFIRMED_COL
                end
                lastCount = #findings
            end
        end

        local results = trust_scan(options, logFn, onProgress)

        -- catch any final findings not yet rendered
        for i = lastCount + 1, #results do
            addFindingCard(results[i])
        end

        tw(PROG_BAR, TI.fast, {Size = UDim2.new(1, 0, 1, 0)})

        local confirmed = 0
        for _, f in ipairs(results) do
            if f.confirmed then confirmed = confirmed + 1 end
        end

        addLogSep(("DONE — %d finding(s) · %d confirmed"):format(
            #results, confirmed))

        if #results == 0 then
            addLog("CLEAN",
                "No trust vulnerabilities found",
                "Probed remotes appear to validate or ignore client-provided values")
            setRunning(false, "clean", CLEAN_COL)
        else
            setRunning(false,
                ("%d finding(s)"):format(#results),
                confirmed > 0 and CONFIRMED_COL or PROBABLE_COL)
        end
    end)
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- BUTTON HANDLERS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

QUICK_BTN.MouseButton1Click:Connect(function()
    runTrust({quickMode = true}, "Quick Scan")
end)

FULL_BTN.MouseButton1Click:Connect(function()
    runTrust({
        families = {NUMERIC=true, PRICE=true, PERMISSION=true},
    }, "Full Audit")
end)

ABORT_BTN.MouseButton1Click:Connect(function()
    if not running then return end
    trust_abort()
    setRunning(false, "aborted", C.MUTED)
    addLog("INFO", "Scan aborted by user")
    tw(PROG_BAR, TI.fast, {Size = UDim2.new(0, 0, 1, 0)})
end)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- REGISTER TAB
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if G.addTab then
    G.addTab("trust", "TRUST", P)
else
    warn("[Oracle] G.addTab not found — 39_trustui loaded standalone")
end
