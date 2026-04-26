-- Oracle // 03_dashboard.lua
-- Dashboard page: stats column · log scroll · scan/stop/clear buttons
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
local CON    = G.CON

-- ── Dashboard page ────────────────────────────────────────────────────────────
local P_DASH = mk("Frame", {
    BackgroundTransparency = 1,
    BorderSizePixel        = 0,
    Size                   = UDim2.fromScale(1, 1),
    Visible                = true,
    ZIndex                 = 3,
}, CON)

-- ── Left column ───────────────────────────────────────────────────────────────
local DL = mk("Frame", {
    BackgroundTransparency = 1,
    BorderSizePixel        = 0,
    Size                   = UDim2.new(0, 196, 1, 0),
    ZIndex                 = 3,
}, P_DASH)

-- right border
mk("Frame", {
    BackgroundColor3 = C.BORDER,
    BorderSizePixel  = 0,
    Size             = UDim2.new(0, 1, 1, 0),
    Position         = UDim2.new(1, -1, 0, 0),
    ZIndex           = 4,
}, DL)

-- ── Button dock (pinned to bottom) ────────────────────────────────────────────
local DOCK = mk("Frame", {
    BackgroundColor3 = C.SURFACE,
    BorderSizePixel  = 0,
    Position         = UDim2.new(0, 0, 1, -142),
    Size             = UDim2.new(1, 0, 0, 142),
    ZIndex           = 5,
}, DL)

mk("Frame", {
    BackgroundColor3 = C.BORDER,
    BorderSizePixel  = 0,
    Size             = UDim2.new(1, -20, 0, 1),
    Position         = UDim2.new(0, 10, 0, 0),
    ZIndex           = 6,
}, DOCK)

pad(10, 10, DOCK)
listV(DOCK, 7)

local function dBtn(txt, bg, order)
    local b = mk("TextButton", {
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        Font             = Enum.Font.GothamBold,
        Text             = txt,
        TextColor3       = C.WHITE,
        TextSize         = 11,
        Size             = UDim2.new(1, 0, 0, 32),
        ZIndex           = 7,
        LayoutOrder      = order,
    }, DOCK)
    corner(6, b)
    local base = bg
    b.MouseEnter:Connect(function()
        tw(b, TI.fast, {BackgroundColor3 = Color3.new(
            math.min(base.R + .08, 1),
            math.min(base.G + .08, 1),
            math.min(base.B + .08, 1))})
    end)
    b.MouseLeave:Connect(function() tw(b, TI.fast, {BackgroundColor3 = base}) end)
    return b
end

local SCANBTN  = dBtn("▶  SCAN",  C.ACCENT,                   1)
local STOPBTN  = dBtn("■  STOP",  Color3.fromRGB(40, 40, 55), 2)
local CLEARBTN = dBtn("⌫  CLEAR", Color3.fromRGB(25, 22, 38), 3)

-- ── Stats scroll (above dock) ─────────────────────────────────────────────────
local DSS = mk("ScrollingFrame", {
    BackgroundTransparency = 1,
    BorderSizePixel        = 0,
    Position               = UDim2.new(0, 0, 0, 0),
    Size                   = UDim2.new(1, 0, 1, -142),
    ScrollBarThickness     = 0,
    CanvasSize             = UDim2.fromScale(0, 0),
    AutomaticCanvasSize    = Enum.AutomaticSize.Y,
    ZIndex                 = 4,
}, DL)
pad(10, 12, DSS)
listV(DSS, 6)

local sR = {}; local sO = 0

local function sHdr(txt)
    sO += 1
    mk("TextLabel", {
        BackgroundTransparency = 1,
        Font           = Enum.Font.GothamBold,
        Text           = txt,
        TextColor3     = C.MUTED,
        TextSize       = 9,
        Size           = UDim2.new(1, 0, 0, 14),
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 5,
        LayoutOrder    = sO,
    }, DSS)
end

local function sCard(lbl, key)
    sO += 1
    local card = mk("Frame", {
        BackgroundColor3 = C.CARD,
        BorderSizePixel  = 0,
        Size             = UDim2.new(1, 0, 0, 42),
        ZIndex           = 5,
        LayoutOrder      = sO,
    }, DSS)
    corner(7, card)
    stroke(C.BORDER, 1, card)
    mk("UIPadding", {
        PaddingLeft = UDim.new(0, 10),
        PaddingTop  = UDim.new(0, 6),
    }, card)
    listV(card, 2)

    local val = mk("TextLabel", {
        BackgroundTransparency = 1,
        Font           = Enum.Font.GothamBold,
        Text           = "—",
        TextColor3     = C.TEXT,
        TextSize       = 15,
        Size           = UDim2.new(1, 0, 0, 20),
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 6,
        LayoutOrder    = 1,
    }, card)

    mk("TextLabel", {
        BackgroundTransparency = 1,
        Font           = Enum.Font.Code,
        Text           = lbl,
        TextColor3     = C.MUTED,
        TextSize       = 9,
        Size           = UDim2.new(1, 0, 0, 13),
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 6,
        LayoutOrder    = 2,
    }, card)

    sR[key] = val
end

local function setStat(k, v, c)
    local r = sR[k]
    if r then
        r.Text = tostring(v)
        if c then r.TextColor3 = c end
    end
end

sHdr("STATUS")
sCard("State",        "state")
sCard("Remotes",      "remotes")
sCard("Probes Sent",  "probes")
sHdr("FINDINGS")
sCard("Deltas",       "deltas")
sCard("Responses",    "responses")
sCard("Pathological", "path")

-- watch indicator
sO += 1
mk("TextLabel", {
    BackgroundTransparency = 1,
    Font           = Enum.Font.GothamBold,
    Text           = "WATCH",
    TextColor3     = C.MUTED,
    TextSize       = 9,
    Size           = UDim2.new(1, 0, 0, 14),
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex         = 5,
    LayoutOrder    = sO,
}, DSS)

sO += 1
local WR = mk("Frame", {
    BackgroundColor3 = C.CARD,
    BorderSizePixel  = 0,
    Size             = UDim2.new(1, 0, 0, 30),
    ZIndex           = 5,
    LayoutOrder      = sO,
}, DSS)
corner(7, WR)
stroke(C.BORDER, 1, WR)

mk("TextLabel", {
    BackgroundTransparency = 1,
    Font           = Enum.Font.Code,
    Text           = "Continuous",
    TextColor3     = C.TEXT,
    TextSize       = 11,
    Size           = UDim2.new(1, -30, 1, 0),
    Position       = UDim2.new(0, 10, 0, 0),
    ZIndex         = 6,
    TextXAlignment = Enum.TextXAlignment.Left,
}, WR)

local WDOT = mk("Frame", {
    BackgroundColor3 = C.CLEAN,
    BorderSizePixel  = 0,
    Size             = UDim2.fromOffset(10, 10),
    Position         = UDim2.new(1, -18, 0.5, -5),
    ZIndex           = 6,
}, WR)
corner(5, WDOT)

-- ── Right column: log ─────────────────────────────────────────────────────────
local DR = mk("Frame", {
    BackgroundTransparency = 1,
    BorderSizePixel        = 0,
    Position               = UDim2.new(0, 196, 0, 0),
    Size                   = UDim2.new(1, -196, 1, 0),
    ZIndex                 = 3,
}, P_DASH)

local LS = mk("ScrollingFrame", {
    BackgroundTransparency = 1,
    BorderSizePixel        = 0,
    Size                   = UDim2.fromScale(1, 1),
    ScrollBarThickness     = 4,
    ScrollBarImageColor3   = C.ACCDIM,
    CanvasSize             = UDim2.fromScale(0, 0),
    AutomaticCanvasSize    = Enum.AutomaticSize.Y,
    ScrollingDirection     = Enum.ScrollingDirection.Y,
    ZIndex                 = 4,
}, DR)
pad(10, 8, LS)
listV(LS, 2)

local logN = 0

local function addLog(tag, msg, detail, hi)
    logN += 1
    mkRow(tag, msg, detail, hi, LS, logN)
    task.defer(function()
        LS.CanvasPosition = Vector2.new(0, LS.AbsoluteCanvasSize.Y)
    end)
end

local function addSep(txt)
    logN += 1
    mkSep(txt, LS, logN)
end

-- ── Export ────────────────────────────────────────────────────────────────────
G.P_DASH   = P_DASH
G.SCANBTN  = SCANBTN
G.STOPBTN  = STOPBTN
G.CLEARBTN = CLEARBTN
G.WDOT     = WDOT
G.LS       = LS
G.setStat  = setStat
G.addLog   = addLog
G.addSep   = addSep
G.logN_ref = {logN}  -- boxed so 06_init can read if needed
