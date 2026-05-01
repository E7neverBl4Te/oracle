-- Oracle // 01_core.lua
-- Helpers · Palette · Window shell · Titlebar · Tab bar skeleton · Content area
local G = ...

local Players = game:GetService("Players")
local UIS     = game:GetService("UserInputService")
local TSvc    = game:GetService("TweenService")
local RS      = game:GetService("RunService")
local LP      = Players.LocalPlayer
local PGui    = LP:WaitForChild("PlayerGui")

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function mk(cls, props, parent)
    local o = Instance.new(cls)
    for k, v in pairs(props or {}) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end
local function tw(o, i, p)   TSvc:Create(o, i, p):Play() end
local function corner(r, p)  mk("UICorner",  {CornerRadius = UDim.new(0, r)}, p) end
local function stroke(c, t, p)
    mk("UIStroke", {Color=c, Thickness=t,
        ApplyStrokeMode=Enum.ApplyStrokeMode.Border}, p)
end
local function pad(h, v, p)
    mk("UIPadding", {
        PaddingLeft   = UDim.new(0, h), PaddingRight  = UDim.new(0, h),
        PaddingTop    = UDim.new(0, v), PaddingBottom = UDim.new(0, v),
    }, p)
end
local function listV(p, g)
    mk("UIListLayout", {SortOrder=Enum.SortOrder.LayoutOrder,
        Padding=UDim.new(0, g or 0)}, p)
end
local function listH(p, g, va, ha)
    mk("UIListLayout", {
        FillDirection     = Enum.FillDirection.Horizontal,
        SortOrder         = Enum.SortOrder.LayoutOrder,
        Padding           = UDim.new(0, g or 0),
        VerticalAlignment = va or Enum.VerticalAlignment.Center,
        HorizontalAlignment = ha or Enum.HorizontalAlignment.Left,
    }, p)
end

-- ── Palette ───────────────────────────────────────────────────────────────────
local C = {
    BG      = Color3.fromRGB(10,  9, 14),
    SURFACE = Color3.fromRGB(16, 14, 22),
    CARD    = Color3.fromRGB(22, 19, 32),
    BORDER  = Color3.fromRGB(38, 34, 52),
    TEXT    = Color3.fromRGB(210,206,230),
    MUTED   = Color3.fromRGB(80, 74,108),
    ACCENT  = Color3.fromRGB(168,120,255),
    ACCDIM  = Color3.fromRGB(60, 44, 90),
    RED     = Color3.fromRGB(220, 60, 60),
    REDDIM  = Color3.fromRGB(60,  22, 22),
    WHITE   = Color3.fromRGB(255,255,255),
    -- tag pill colours
    FIRED   = Color3.fromRGB(150, 90,255),
    DELTA   = Color3.fromRGB(255,160, 40),
    PATHLOG = Color3.fromRGB(255, 55, 55),
    RESP    = Color3.fromRGB(80, 210,100),
    CLEAN   = Color3.fromRGB(55,  55, 75),
    INFO    = Color3.fromRGB(80, 170,210),
    BASE    = Color3.fromRGB(80, 140,255),
    WATCH   = Color3.fromRGB(180,130,255),
}

local TI = {
    fast   = TweenInfo.new(0.12, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out),
    med    = TweenInfo.new(0.25, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out),
    spring = TweenInfo.new(0.35, Enum.EasingStyle.Back,  Enum.EasingDirection.Out),
}

local TAGCOL = {
    FIRED    = Color3.fromRGB(150, 90,255),
    DELTA    = Color3.fromRGB(255,160, 40),
    PATHOLOG = Color3.fromRGB(255, 55, 55),
    RESPONSE = Color3.fromRGB( 80,210,100),
    CLEAN    = Color3.fromRGB( 55, 55, 75),
    INFO     = Color3.fromRGB( 80,170,210),
    BASELINE = Color3.fromRGB( 80,140,255),
    WATCH    = Color3.fromRGB(180,130,255),
}

-- ── Window constants ──────────────────────────────────────────────────────────
local DW, DH   = 820, 520
local MW, MH   = 340, 280
local XW, XH   = 960, 680
local TITLE_H  = 40
local TAB_H    = 34
local GRIP     = 10

-- ── Root GUI ──────────────────────────────────────────────────────────────────
local GUI = mk("ScreenGui", {
    Name           = "Oracal",
    ResetOnSpawn   = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    IgnoreGuiInset = true,
}, PGui)

local WIN = mk("Frame", {
    BackgroundColor3 = C.BG,
    BorderSizePixel  = 0,
    Position         = UDim2.new(0.5, -DW/2, 0.5, -DH/2),
    Size             = UDim2.new(0, DW, 0, DH),
    ClipsDescendants = true,
}, GUI)
corner(10, WIN)
stroke(C.BORDER, 1, WIN)

-- depth gradient
do
    local g = mk("Frame", {
        BackgroundColor3       = Color3.new(0,0,0),
        BackgroundTransparency = 0.85,
        BorderSizePixel        = 0,
        Size                   = UDim2.new(1, 0, 0, 60),
        ZIndex                 = 2,
    }, WIN)
    corner(10, g)
end

-- ── Titlebar ──────────────────────────────────────────────────────────────────
local TBAR = mk("Frame", {
    BackgroundColor3 = C.SURFACE,
    BorderSizePixel  = 0,
    Size             = UDim2.new(1, 0, 0, TITLE_H),
    ZIndex           = 5,
}, WIN)
stroke(C.BORDER, 1, TBAR)

-- accent line
mk("Frame", {
    BackgroundColor3 = C.ACCENT,
    BorderSizePixel  = 0,
    Position         = UDim2.new(0, 0, 1, -1),
    Size             = UDim2.new(1, 0, 0, 1),
    ZIndex           = 6,
}, TBAR)

-- logo pip
mk("TextLabel", {
    BackgroundTransparency = 1,
    Font           = Enum.Font.GothamBold,
    Text           = "✦",
    TextColor3     = C.ACCENT,
    TextSize       = 14,
    Size           = UDim2.new(0, 20, 1, 0),
    Position       = UDim2.new(0, 14, 0, 0),
    ZIndex         = 6,
    TextXAlignment = Enum.TextXAlignment.Center,
}, TBAR)

mk("TextLabel", {
    BackgroundTransparency = 1,
    Font           = Enum.Font.GothamBold,
    Text           = "Oracal",
    TextColor3     = C.TEXT,
    TextSize       = 13,
    Size           = UDim2.new(0, 120, 1, 0),
    Position       = UDim2.new(0, 38, 0, 0),
    ZIndex         = 6,
    TextXAlignment = Enum.TextXAlignment.Left,
}, TBAR)

local SUB = mk("TextLabel", {
    BackgroundTransparency = 1,
    Font           = Enum.Font.Code,
    Text           = "Engine Probe  ·  idle",
    TextColor3     = C.MUTED,
    TextSize       = 9,
    Size           = UDim2.new(1, -200, 1, 0),
    Position       = UDim2.new(0, 160, 0, 0),
    ZIndex         = 6,
    TextXAlignment = Enum.TextXAlignment.Left,
}, TBAR)

-- window buttons
local WBC = mk("Frame", {
    BackgroundTransparency = 1,
    BorderSizePixel  = 0,
    Position         = UDim2.new(1, -88, 0, 0),
    Size             = UDim2.new(0, 84, 1, 0),
    ZIndex           = 6,
}, TBAR)
listH(WBC, 6, Enum.VerticalAlignment.Center, Enum.HorizontalAlignment.Right)
mk("UIPadding", {PaddingRight = UDim.new(0, 10)}, WBC)

local function winBtn(icon, bg, hov, tc)
    local b = mk("TextButton", {
        AutoButtonColor  = false,
        BackgroundColor3 = bg,
        BorderSizePixel  = 0,
        Font             = Enum.Font.GothamBold,
        Text             = icon,
        TextColor3       = tc,
        TextSize         = 11,
        Size             = UDim2.new(0, 26, 0, 26),
        ZIndex           = 7,
    }, WBC)
    corner(6, b)
    b.MouseEnter:Connect(function() tw(b, TI.fast, {BackgroundColor3 = hov}) end)
    b.MouseLeave:Connect(function() tw(b, TI.fast, {BackgroundColor3 = bg})  end)
    return b
end

local MINBTN  = winBtn("─", C.CARD, C.ACCDIM, C.MUTED)
local CLSBTN  = winBtn("✕", C.CARD, C.REDDIM, C.RED)

-- ── Tab bar ───────────────────────────────────────────────────────────────────
local TBBAR = mk("Frame", {
    BackgroundColor3 = C.SURFACE,
    BorderSizePixel  = 0,
    Position         = UDim2.new(0, 0, 0, TITLE_H),
    Size             = UDim2.new(1, 0, 0, TAB_H),
    ZIndex           = 5,
    ClipsDescendants = true,
}, WIN)
stroke(C.BORDER, 1, TBBAR)

-- ScrollingFrame so tabs never overflow — scrolls horizontally as tabs are added
local TBROW = mk("ScrollingFrame", {
    BackgroundTransparency    = 1,
    BorderSizePixel           = 0,
    Size                      = UDim2.new(1, 0, 1, 0),
    ZIndex                    = 6,
    ScrollingDirection        = Enum.ScrollingDirection.X,
    ScrollBarThickness        = 2,
    ScrollBarImageColor3      = C.ACCDIM,
    CanvasSize                = UDim2.fromScale(0, 0),
    AutomaticCanvasSize       = Enum.AutomaticSize.X,
    -- Hide scrollbar most of the time — appears only when needed
    ScrollBarImageTransparency = 0.6,
}, TBBAR)
mk("UIPadding", {
    PaddingLeft   = UDim.new(0, 10),
    PaddingTop    = UDim.new(0, 5),
    PaddingBottom = UDim.new(0, 5),
}, TBROW)
listH(TBROW, 4)

-- ── Content area ──────────────────────────────────────────────────────────────
local CON = mk("Frame", {
    BackgroundTransparency = 1,
    BorderSizePixel  = 0,
    Position         = UDim2.new(0, 0, 0, TITLE_H + TAB_H),
    Size             = UDim2.new(1, 0, 1, -(TITLE_H + TAB_H)),
    ClipsDescendants = true,
    ZIndex           = 3,
}, WIN)

-- ── Export to G ───────────────────────────────────────────────────────────────
G.Players  = Players
G.UIS      = UIS
G.TSvc     = TSvc
G.RS       = RS
G.LP       = LP
G.PGui     = PGui
G.mk       = mk
G.tw       = tw
G.corner   = corner
G.stroke   = stroke
G.pad      = pad
G.listV    = listV
G.listH    = listH
G.C        = C
G.TI       = TI
G.TAGCOL   = TAGCOL
G.DW       = DW;  G.DH      = DH
G.MW       = MW;  G.MH      = MH
G.XW       = XW;  G.XH      = XH
G.TITLE_H  = TITLE_H
G.TAB_H    = TAB_H
G.GRIP     = GRIP
G.GUI      = GUI
G.WIN      = WIN
G.TBAR     = TBAR
G.SUB      = SUB
G.WBC      = WBC
G.MINBTN   = MINBTN
G.CLSBTN   = CLSBTN
G.TBBAR    = TBBAR
G.TBROW    = TBROW
G.CON      = CON
