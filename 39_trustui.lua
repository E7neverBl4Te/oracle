-- Oracle // 37_trustui.lua
-- TRUST UI — Interface for the Trust Engine (36_trust.lua)
-- Scan controls, live log, finding cards with full evidence + fix documentation

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

-- Engine refs (provided by 36_trust.lua)
local trust_scan     = G.trust_scan
local trust_abort    = G.trust_abort
local trust_families = G.TRUST_FAMILIES

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- COLOURS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local COL = {
    CRITICAL  = Color3.fromRGB(255, 70,  70),
    HIGH      = Color3.fromRGB(255, 140, 40),
    MEDIUM    = Color3.fromRGB(255, 210, 50),
    LOW       = Color3.fromRGB(120, 200, 120),
    CONFIRMED = Color3.fromRGB(255, 70,  70),
    PROBABLE  = Color3.fromRGB(200, 120, 60),
    CLEAN     = Color3.fromRGB(80,  180, 120),
    INFO      = Color3.fromRGB(140, 160, 180),
    PROGRESS  = Color3.fromRGB(100, 120, 220),
}

local SEV_COL = {
    CRITICAL = COL.CRITICAL,
    HIGH     = COL.HIGH,
    MEDIUM   = COL.MEDIUM,
    LOW      = COL.LOW,
}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ROOT PANEL
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P = mk("Frame",{
    Size            = UDim2.new(1,0,1,0),
    BackgroundColor3= C.BG,
    BorderSizePixel = 0,
})
listV(P, 0)

-- ── Header bar ────────────────────────────────────────────────────────────────

local HDR = mk("Frame",{
    Size            = UDim2.new(1,0,0,36),
    BackgroundColor3= C.PANEL,
    BorderSizePixel = 0,
    Parent          = P,
})
corner(HDR,6)
stroke(HDR,1,C.BORDER)
pad(HDR,8,0)
listH(HDR,8)

local TITLE = mk("TextLabel",{
    Size            = UDim2.new(0,80,1,0),
    BackgroundTransparency= 1,
    Text            = "TRUST",
    TextColor3      = C.FG,
    Font            = Enum.Font.GothamBold,
    TextSize        = 13,
    TextXAlignment  = Enum.TextXAlignment.Left,
    Parent          = HDR,
})

local SUBTITLE = mk("TextLabel",{
    Size            = UDim2.new(1,-300,1,0),
    BackgroundTransparency= 1,
    Text            = "Numeric Argument Trust Auditor",
    TextColor3      = C.MUTED,
    Font            = Enum.Font.Gotham,
    TextSize        = 11,
    TextXAlignment  = Enum.TextXAlignment.Left,
    Parent          = HDR,
})

local STATUS = mk("TextLabel",{
    Size            = UDim2.new(0,180,1,0),
    BackgroundTransparency= 1,
    Text            = "idle",
    TextColor3      = C.MUTED,
    Font            = Enum.Font.GothamMedium,
    TextSize        = 11,
    TextXAlignment  = Enum.TextXAlignment.Right,
    Parent          = HDR,
})

-- ── Progress bar ──────────────────────────────────────────────────────────────

local PROG_TRACK = mk("Frame",{
    Size            = UDim2.new(1,0,0,3),
    BackgroundColor3= C.BORDER,
    BorderSizePixel = 0,
    Parent          = P,
})
corner(PROG_TRACK,1)

local PROG_BAR = mk("Frame",{
    Size            = UDim2.new(0,0,1,0),
    BackgroundColor3= COL.PROGRESS,
    BorderSizePixel = 0,
    Parent          = PROG_TRACK,
})
corner(PROG_BAR,1)

-- ── Control row ───────────────────────────────────────────────────────────────

local CTRL = mk("Frame",{
    Size            = UDim2.new(1,0,0,32),
    BackgroundTransparency= 1,
    Parent          = P,
})
pad(CTRL,8,0)
listH(CTRL,6)

local function mkBtn(label, bg, parent)
    local b = mk("TextButton",{
        Size            = UDim2.new(0,110,1,-4),
        BackgroundColor3= bg,
        BorderSizePixel = 0,
        Text            = label,
        TextColor3      = Color3.fromRGB(255,255,255),
        Font            = Enum.Font.GothamBold,
        TextSize        = 11,
        AutoButtonColor = false,
        Parent          = parent,
    })
    corner(b,5)
    return b
end

local QUICK_BTN  = mkBtn("Quick Scan",   Color3.fromRGB(60,100,200),  CTRL)
local FULL_BTN   = mkBtn("Full Audit",   Color3.fromRGB(80,60,160),   CTRL)
local ABORT_BTN  = mkBtn("Abort",        Color3.fromRGB(100,30,30),   CTRL)

local FIND_COUNT = mk("TextLabel",{
    Size            = UDim2.new(1,-350,1,0),
    BackgroundTransparency= 1,
    Text            = "0 findings",
    TextColor3      = C.MUTED,
    Font            = Enum.Font.GothamMedium,
    TextSize        = 11,
    TextXAlignment  = Enum.TextXAlignment.Right,
    Parent          = CTRL,
})

-- ── Main body: findings left, log right ───────────────────────────────────────

local BODY = mk("Frame",{
    Size            = UDim2.new(1,0,1,-80),
    BackgroundTransparency= 1,
    Parent          = P,
})
listH(BODY, 6)
pad(BODY, 6, 0)

-- Findings panel (left, 55%)
local FIND_PANEL = mk("Frame",{
    Size            = UDim2.new(0.55,-3,1,0),
    BackgroundColor3= C.PANEL,
    BorderSizePixel = 0,
    Parent          = BODY,
})
corner(FIND_PANEL,6)
stroke(FIND_PANEL,1,C.BORDER)

local FIND_HDR = mk("TextLabel",{
    Size            = UDim2.new(1,0,0,24),
    BackgroundTransparency= 1,
    Text            = "  FINDINGS",
    TextColor3      = C.MUTED,
    Font            = Enum.Font.GothamBold,
    TextSize        = 10,
    TextXAlignment  = Enum.TextXAlignment.Left,
    Parent          = FIND_PANEL,
})

local FIND_SCROLL = mk("ScrollingFrame",{
    Size            = UDim2.new(1,0,1,-24),
    Position        = UDim2.new(0,0,0,24),
    BackgroundTransparency= 1,
    BorderSizePixel = 0,
    ScrollBarThickness= 3,
    ScrollBarImageColor3= C.BORDER,
    CanvasSize      = UDim2.new(0,0,0,0),
    AutomaticCanvasSize= Enum.AutomaticSize.Y,
    Parent          = FIND_PANEL,
})
pad(FIND_SCROLL,6,4)
listV(FIND_SCROLL,6)

local FIND_EMPTY = mk("TextLabel",{
    Size            = UDim2.new(1,0,0,40),
    BackgroundTransparency= 1,
    Text            = "No findings yet — run a scan",
    TextColor3      = C.MUTED,
    Font            = Enum.Font.Gotham,
    TextSize        = 11,
    Parent          = FIND_SCROLL,
})

-- Log panel (right, 45%)
local LOG_PANEL = mk("Frame",{
    Size            = UDim2.new(0.45,-3,1,0),
    BackgroundColor3= C.PANEL,
    BorderSizePixel = 0,
    Parent          = BODY,
})
corner(LOG_PANEL,6)
stroke(LOG_PANEL,1,C.BORDER)

local LOG_HDR = mk("TextLabel",{
    Size            = UDim2.new(1,0,0,24),
    BackgroundTransparency= 1,
    Text            = "  ENGINE LOG",
    TextColor3      = C.MUTED,
    Font            = Enum.Font.GothamBold,
    TextSize        = 10,
    TextXAlignment  = Enum.TextXAlignment.Left,
    Parent          = LOG_PANEL,
})

local LOG_SCROLL = mk("ScrollingFrame",{
    Size            = UDim2.new(1,0,1,-24),
    Position        = UDim2.new(0,0,0,24),
    BackgroundTransparency= 1,
    BorderSizePixel = 0,
    ScrollBarThickness= 3,
    ScrollBarImageColor3= C.BORDER,
    CanvasSize      = UDim2.new(0,0,0,0),
    AutomaticCanvasSize= Enum.AutomaticSize.Y,
    Parent          = LOG_PANEL,
})
pad(LOG_SCROLL,5,3)
listV(LOG_SCROLL,3)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- LOG HELPERS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local LOG_COLOURS = {
    FINDING  = COL.CRITICAL,
    INFO     = COL.INFO,
    CLEAN    = COL.CLEAN,
    DELTA    = COL.MEDIUM,
    PATHOLOG = Color3.fromRGB(200,60,200),
}

local function clearLog()
    for _, c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then
            c:Destroy()
        end
    end
end

local function addLog(level, title, detail, highlight)
    local col   = LOG_COLOURS[level] or COL.INFO
    local row   = mkRow(LOG_SCROLL, highlight)
    local lbl   = mk("TextLabel",{
        Size            = UDim2.new(1,-8,0,0),
        AutomaticSize   = Enum.AutomaticSize.Y,
        BackgroundTransparency= 1,
        Text            = title,
        TextColor3      = col,
        Font            = Enum.Font.GothamMedium,
        TextSize        = 10,
        TextXAlignment  = Enum.TextXAlignment.Left,
        TextWrapped     = true,
        Parent          = row,
    })
    if detail and #detail > 0 then
        mk("TextLabel",{
            Size            = UDim2.new(1,-8,0,0),
            AutomaticSize   = Enum.AutomaticSize.Y,
            BackgroundTransparency= 1,
            Text            = detail,
            TextColor3      = C.MUTED,
            Font            = Enum.Font.Gotham,
            TextSize        = 9,
            TextXAlignment  = Enum.TextXAlignment.Left,
            TextWrapped     = true,
            Parent          = row,
        })
    end
    -- Auto-scroll to bottom
    task.defer(function()
        LOG_SCROLL.CanvasPosition = Vector2.new(
            0, LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end

local function addLogSep(text)
    local sep = mkSep(LOG_SCROLL)
    if sep then
        local lbl = sep:FindFirstChildOfClass("TextLabel")
        if lbl then lbl.Text = text end
    end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- FINDING CARDS
-- Each card shows: severity, remote name, vulnerability class,
-- evidence chain (what was sent, what changed, ratio),
-- and the developer fix — ready to copy into a report.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function clearFindings()
    for _, c in ipairs(FIND_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then
            c:Destroy()
        end
    end
    FIND_EMPTY.Parent = FIND_SCROLL
end

local function addFindingCard(f, index)
    FIND_EMPTY.Parent = nil

    local sevCol = SEV_COL[f.severity] or C.MUTED
    local confCol= f.confirmed and COL.CONFIRMED or COL.PROBABLE
    local confTxt= f.confirmed and "CONFIRMED" or "PROBABLE"

    -- Card frame
    local card = mk("Frame",{
        Size            = UDim2.new(1,0,0,0),
        AutomaticSize   = Enum.AutomaticSize.Y,
        BackgroundColor3= C.BG,
        BorderSizePixel = 0,
        Parent          = FIND_SCROLL,
    })
    corner(card,5)
    stroke(card,1,sevCol)
    pad(card,8,6)
    listV(card,5)

    -- Row 1: severity badge + remote name + confirmed badge
    local top = mk("Frame",{
        Size            = UDim2.new(1,0,0,18),
        BackgroundTransparency= 1,
        Parent          = card,
    })
    listH(top,6)

    local sevBadge = mk("TextLabel",{
        Size            = UDim2.new(0,70,1,0),
        BackgroundColor3= sevCol,
        Text            = f.severity,
        TextColor3      = Color3.fromRGB(255,255,255),
        Font            = Enum.Font.GothamBold,
        TextSize        = 9,
        Parent          = top,
    })
    corner(sevBadge,3)

    mk("TextLabel",{
        Size            = UDim2.new(1,-160,1,0),
        BackgroundTransparency= 1,
        Text            = f.remote,
        TextColor3      = C.FG,
        Font            = Enum.Font.GothamBold,
        TextSize        = 11,
        TextXAlignment  = Enum.TextXAlignment.Left,
        Parent          = top,
    })

    local confBadge = mk("TextLabel",{
        Size            = UDim2.new(0,74,1,0),
        BackgroundColor3= confCol,
        Text            = confTxt,
        TextColor3      = Color3.fromRGB(255,255,255),
        Font            = Enum.Font.GothamBold,
        TextSize        = 9,
        Parent          = top,
    })
    corner(confBadge,3)

    -- Row 2: vulnerability class label
    mk("TextLabel",{
        Size            = UDim2.new(1,0,0,14),
        BackgroundTransparency= 1,
        Text            = f.label,
        TextColor3      = sevCol,
        Font            = Enum.Font.GothamMedium,
        TextSize        = 10,
        TextXAlignment  = Enum.TextXAlignment.Left,
        Parent          = card,
    })

    -- Row 3: evidence summary
    local evText = ""
    if f.family == "NUMERIC" and f.evidence and f.evidence[1] then
        local ev = f.evidence[1]
        evText = ("Payload: %s  |  arg(1)→Δ%s  arg(10)→Δ%s  |  ratio: %.2fx"):format(
            f.wrapper,
            tostring(math.floor(ev.delta1 or 0)),
            tostring(math.floor(ev.delta10 or 0)),
            ev.ratio or 0)
    elseif f.family == "PRICE" and f.evidence and f.evidence[1] then
        local ev = f.evidence[1]
        evText = ("Payload: %s  |  price=0 accepted  |  Δ%s on %s"):format(
            f.wrapper,
            tostring(ev.delta_zero or "?"),
            ev.path or "?")
    elseif f.family == "PERMISSION" and f.evidence and f.evidence[1] then
        local ev = f.evidence[1]
        evText = ("Payload: %s=%s  |  %d state change(s) vs baseline %d"):format(
            f.wrapper,
            tostring(ev.value or "?"),
            ev.changes or 0,
            ev.baseline or 0)
    else
        evText = ("Payload: %s"):format(f.wrapper or "?")
    end

    mk("TextLabel",{
        Size            = UDim2.new(1,0,0,0),
        AutomaticSize   = Enum.AutomaticSize.Y,
        BackgroundTransparency= 1,
        Text            = evText,
        TextColor3      = Color3.fromRGB(160,180,200),
        Font            = Enum.Font.Code,
        TextSize        = 9,
        TextXAlignment  = Enum.TextXAlignment.Left,
        TextWrapped     = true,
        Parent          = card,
    })

    -- Divider
    mk("Frame",{
        Size            = UDim2.new(1,0,0,1),
        BackgroundColor3= C.BORDER,
        BorderSizePixel = 0,
        Parent          = card,
    })

    -- Row 4: description
    mk("TextLabel",{
        Size            = UDim2.new(1,0,0,0),
        AutomaticSize   = Enum.AutomaticSize.Y,
        BackgroundTransparency= 1,
        Text            = "ISSUE: " .. (f.desc or ""),
        TextColor3      = C.MUTED,
        Font            = Enum.Font.Gotham,
        TextSize        = 9,
        TextXAlignment  = Enum.TextXAlignment.Left,
        TextWrapped     = true,
        Parent          = card,
    })

    -- Row 5: fix (green — the developer action item)
    mk("TextLabel",{
        Size            = UDim2.new(1,0,0,0),
        AutomaticSize   = Enum.AutomaticSize.Y,
        BackgroundTransparency= 1,
        Text            = "FIX: " .. (f.fix or ""),
        TextColor3      = COL.CLEAN,
        Font            = Enum.Font.GothamMedium,
        TextSize        = 9,
        TextXAlignment  = Enum.TextXAlignment.Left,
        TextWrapped     = true,
        Parent          = card,
    })
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SCAN STATE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local running      = false
local findingCount = 0

local function setRunning(state, statusText, statusCol)
    running = state
    QUICK_BTN.Active = not state
    FULL_BTN.Active  = not state
    tw(QUICK_BTN, TI.fast, {
        BackgroundColor3 = state
            and Color3.fromRGB(40,60,120)
            or  Color3.fromRGB(60,100,200)
    })
    tw(FULL_BTN, TI.fast, {
        BackgroundColor3 = state
            and Color3.fromRGB(50,40,100)
            or  Color3.fromRGB(80,60,160)
    })
    STATUS.Text      = statusText or "idle"
    STATUS.TextColor3= statusCol  or C.MUTED
end

local function onProgress(i, total, name)
    local pct = i / total
    tw(PROG_BAR, TI.fast, {Size=UDim2.new(pct,0,1,0)})
    STATUS.Text      = ("[%d/%d] %s"):format(i, total, name)
    STATUS.TextColor3= COL.PROGRESS
end

local function onFinding(f)
    findingCount = findingCount + 1
    FIND_COUNT.Text      = findingCount .. " finding(s)"
    FIND_COUNT.TextColor3= findingCount > 0 and COL.CRITICAL or C.MUTED
    addFindingCard(f, findingCount)
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SCAN RUNNER — drives 36_trust.lua and streams results into UI live
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function runTrust(options, label)
    if running then return end
    clearLog()
    clearFindings()
    findingCount = 0
    FIND_COUNT.Text      = "0 findings"
    FIND_COUNT.TextColor3= C.MUTED
    tw(PROG_BAR, TI.fast, {Size=UDim2.new(0,0,1,0)})
    setRunning(true, label .. "...", COL.PROGRESS)
    addLogSep(label:upper())

    task.spawn(function()
        -- Wrap the log function to stream findings as they arrive
        local lastCount = 0
        local function logFn(level, title, detail, highlight)
            addLog(level, title, detail, highlight)
            -- Check if new findings appeared since last log call
            local findings = G.trust_getFindings()
            if #findings > lastCount then
                for i = lastCount + 1, #findings do
                    onFinding(findings[i])
                end
                lastCount = #findings
            end
        end

        local results = trust_scan(options, logFn, onProgress)

        -- Catch any findings not yet rendered
        for i = lastCount + 1, #results do
            onFinding(results[i])
        end

        tw(PROG_BAR, TI.fast, {Size=UDim2.new(1,0,1,0)})

        local confirmed = 0
        for _, f in ipairs(results) do
            if f.confirmed then confirmed = confirmed + 1 end
        end

        addLogSep(("COMPLETE — %d finding(s)  %d confirmed"):format(
            #results, confirmed))

        if #results == 0 then
            addLog("CLEAN",
                "No trust vulnerabilities found",
                "All probed remotes appear to validate or ignore client-provided values")
            setRunning(false, "clean", COL.CLEAN)
        else
            setRunning(false,
                ("%d finding(s)"):format(#results),
                confirmed > 0 and COL.CONFIRMED or COL.PROBABLE)
        end
    end)
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- BUTTON HANDLERS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

QUICK_BTN.MouseButton1Click:Connect(function()
    runTrust({quickMode=true}, "Quick Scan")
end)

FULL_BTN.MouseButton1Click:Connect(function()
    runTrust({
        families = {
            NUMERIC    = true,
            PRICE      = true,
            PERMISSION = true,
        },
    }, "Full Audit")
end)

ABORT_BTN.MouseButton1Click:Connect(function()
    if not running then return end
    trust_abort()
    setRunning(false, "aborted", C.MUTED)
    addLog("INFO","Scan aborted by user")
    tw(PROG_BAR, TI.fast, {Size=UDim2.new(0,0,1,0)})
end)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- REGISTER TAB
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

if G.addTab then
    G.addTab("trust","TRUST",P)
else
    warn("[Oracle] G.addTab not found — 37_trustui.lua loaded standalone")
end
