-- Oracle // 04_target.lua
-- Target Mode page: remote browser · payload list · result panel · fire button
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
local PAYLOADS = G.PAYLOADS
local discR  = G.discR
local CON    = G.CON

-- ── Target mode page ──────────────────────────────────────────────────────────
local P_TGT = mk("Frame", {
    BackgroundTransparency = 1,
    BorderSizePixel        = 0,
    Size                   = UDim2.fromScale(1, 1),
    Visible                = false,
    ZIndex                 = 3,
}, CON)

-- left / right columns
local TL = mk("Frame", {
    BackgroundTransparency = 1, BorderSizePixel = 0,
    Size = UDim2.new(0.42, 0, 1, 0), ZIndex = 3,
}, P_TGT)
pad(14, 12, TL); listV(TL, 8)

mk("Frame", {
    BackgroundColor3 = C.BORDER, BorderSizePixel = 0,
    Size = UDim2.new(0, 1, 1, -20), Position = UDim2.new(0.42, 0, 0, 10), ZIndex = 4,
}, P_TGT)

local TR = mk("Frame", {
    BackgroundTransparency = 1, BorderSizePixel = 0,
    Size = UDim2.new(0.58, -2, 1, 0), Position = UDim2.new(0.42, 2, 0, 0), ZIndex = 3,
}, P_TGT)
pad(10, 12, TR); listV(TR, 8)

-- ── Header ────────────────────────────────────────────────────────────────────
local THC = mk("Frame", {
    BackgroundColor3 = C.CARD, BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, 50), ZIndex = 4, LayoutOrder = 1,
}, TL)
corner(8, THC); stroke(C.BORDER, 1, THC)
mk("UIPadding", {PaddingLeft = UDim.new(0,14), PaddingTop = UDim.new(0,10)}, THC)
listV(THC, 3)

mk("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
    Text = "◎  TARGET MODE", TextColor3 = C.ACCENT, TextSize = 13,
    Size = UDim2.new(1,0,0,18), TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 5, LayoutOrder = 1,
}, THC)

local TSUB = mk("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.Code,
    Text = "no target selected", TextColor3 = C.MUTED, TextSize = 9,
    Size = UDim2.new(1,0,0,14), TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 5, LayoutOrder = 2,
}, THC)

-- ── Remote browser ────────────────────────────────────────────────────────────
local TRHDR = mk("Frame", {
    BackgroundTransparency = 1, BorderSizePixel = 0,
    Size = UDim2.new(1,0,0,18), ZIndex = 4, LayoutOrder = 2,
}, TL)
listH(TRHDR, 6)

mk("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
    Text = "SELECT REMOTE", TextColor3 = C.MUTED, TextSize = 9,
    Size = UDim2.new(1,-58,1,0), TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 4, LayoutOrder = 1,
}, TRHDR)

local RFSCAN = mk("TextButton", {
    AutoButtonColor = false, BackgroundColor3 = C.CARD, BorderSizePixel = 0,
    Font = Enum.Font.GothamBold, Text = "⟳  Scan", TextColor3 = C.ACCENT,
    TextSize = 9, Size = UDim2.new(0, 52, 1, 0), ZIndex = 5, LayoutOrder = 2,
}, TRHDR)
corner(4, RFSCAN); stroke(C.BORDER, 1, RFSCAN)
RFSCAN.MouseEnter:Connect(function() tw(RFSCAN, TI.fast, {BackgroundColor3 = C.ACCDIM}) end)
RFSCAN.MouseLeave:Connect(function() tw(RFSCAN, TI.fast, {BackgroundColor3 = C.CARD})   end)

local REMSCR = mk("ScrollingFrame", {
    BackgroundColor3 = C.CARD, BorderSizePixel = 0,
    Size = UDim2.new(1,0,0,130), ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.ACCDIM, CanvasSize = UDim2.fromScale(0,0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, ZIndex = 4, LayoutOrder = 3,
}, TL)
corner(6, REMSCR); stroke(C.BORDER, 1, REMSCR); pad(5, 4, REMSCR); listV(REMSCR, 2)

local REMEPTY = mk("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.Code,
    Text = "Press  ⟳ Scan  to discover remotes",
    TextColor3 = C.MUTED, TextSize = 9, TextWrapped = true,
    Size = UDim2.new(1,0,0,0), AutomaticSize = Enum.AutomaticSize.Y,
    TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 5, LayoutOrder = 1,
}, REMSCR)

-- RBOX: hidden text box holding the selected remote name
-- read by fire logic and Compose page
local RBOX = mk("TextBox", {
    BackgroundTransparency = 1, BorderSizePixel = 0,
    Text = "", TextColor3 = C.TEXT, TextSize = 1,
    Font = Enum.Font.Code, ClearTextOnFocus = false,
    Size = UDim2.fromOffset(0, 0), Visible = false,
}, TL)

local selRB = nil

local function popR()
    for _, c in ipairs(REMSCR:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") and c ~= REMEPTY then
            c:Destroy()
        end
    end
    selRB = nil; RBOX.Text = ""

    local ev, fn = discR()
    local all = {}
    for _, r in ipairs(ev) do table.insert(all, {r=r, k="Event"}) end
    for _, r in ipairs(fn) do table.insert(all, {r=r, k="Func"})  end

    if #all == 0 then
        REMEPTY.Visible = true
        REMEPTY.Text    = "No remotes found — run inside a live game"
        TSUB.Text       = "none discovered"
        return
    end
    REMEPTY.Visible = false

    for i, e in ipairs(all) do
        local r, k = e.r, e.k
        local row = mk("TextButton", {
            AutoButtonColor = false, BackgroundColor3 = C.SURFACE,
            BackgroundTransparency = 0.4, BorderSizePixel = 0,
            Text = "", Size = UDim2.new(1,0,0,26), ZIndex = 5, LayoutOrder = i,
        }, REMSCR)
        corner(4, row); pad(8, 0, row)

        local kp = mk("Frame", {
            BackgroundColor3 = k == "Event" and C.ACCDIM or Color3.fromRGB(40,70,50),
            BorderSizePixel = 0, Size = UDim2.fromOffset(34,14),
            Position = UDim2.new(0,0,0.5,-7), ZIndex = 6,
        }, row)
        corner(3, kp)
        mk("TextLabel", {
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, Text = k,
            TextColor3 = k == "Event" and C.ACCENT or Color3.fromRGB(80,210,120),
            TextSize = 7, Size = UDim2.fromScale(1,1),
            TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 7,
        }, kp)

        mk("TextLabel", {
            BackgroundTransparency = 1, Font = Enum.Font.Code, Text = r.Name,
            TextColor3 = C.TEXT, TextSize = 10,
            Size = UDim2.new(1,-44,1,0), Position = UDim2.new(0,42,0,0),
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 6,
        }, row)

        row.MouseEnter:Connect(function()
            if selRB ~= row then
                tw(row, TI.fast, {BackgroundTransparency=0.1, BackgroundColor3=C.CARD})
            end
        end)
        row.MouseLeave:Connect(function()
            if selRB ~= row then
                tw(row, TI.fast, {BackgroundTransparency=0.4, BackgroundColor3=C.SURFACE})
            end
        end)
        row.MouseButton1Click:Connect(function()
            if selRB and selRB ~= row then
                tw(selRB, TI.fast, {BackgroundColor3=C.SURFACE, BackgroundTransparency=0.4})
                local ps = selRB:FindFirstChildOfClass("UIStroke")
                if ps then ps:Destroy() end
            end
            selRB = row
            RBOX.Text = r.Name
            tw(row, TI.fast, {BackgroundColor3=C.ACCDIM, BackgroundTransparency=0})
            if not row:FindFirstChildOfClass("UIStroke") then
                stroke(C.ACCENT, 1, row)
            end
            TSUB.Text = r.Name .. "  ·  " .. k .. "  ·  selected"
        end)
    end
    TSUB.Text = #all .. " remotes — select one"
end

RFSCAN.MouseButton1Click:Connect(popR)

-- ── Payload list ──────────────────────────────────────────────────────────────
mk("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
    Text = "PAYLOAD", TextColor3 = C.MUTED, TextSize = 9,
    Size = UDim2.new(1,0,0,13), TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 4, LayoutOrder = 4,
}, TL)

local PAYSCR = mk("ScrollingFrame", {
    BackgroundColor3 = C.CARD, BorderSizePixel = 0,
    Size = UDim2.new(1,0,1,-212), ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.ACCDIM, CanvasSize = UDim2.fromScale(0,0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, ZIndex = 4, LayoutOrder = 5,
}, TL)
corner(6, PAYSCR); stroke(C.BORDER, 1, PAYSCR); pad(5, 4, PAYSCR); listV(PAYSCR, 2)

local sP = 1; local pB = {}
for i, p in ipairs(PAYLOADS) do
    local b = mk("TextButton", {
        AutoButtonColor = false,
        BackgroundColor3 = i == 1 and C.ACCDIM or C.CARD,
        BackgroundTransparency = i == 1 and 0 or 1,
        BorderSizePixel = 0, Font = Enum.Font.Code, Text = p.l,
        TextColor3 = i == 1 and C.WHITE or C.TEXT, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.new(1,0,0,22), ZIndex = 5, LayoutOrder = i,
    }, PAYSCR)
    corner(4, b); pad(8, 0, b); pB[i] = b
    b.MouseButton1Click:Connect(function()
        for _, x in ipairs(pB) do
            x.BackgroundTransparency = 1; x.TextColor3 = C.TEXT
        end
        b.BackgroundTransparency = 0
        b.BackgroundColor3 = C.ACCDIM
        b.TextColor3 = C.WHITE
        sP = i
    end)
end

-- ── Result area ───────────────────────────────────────────────────────────────
mk("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
    Text = "RESULT", TextColor3 = C.MUTED, TextSize = 9,
    Size = UDim2.new(1,0,0,13), TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 4, LayoutOrder = 1,
}, TR)

local TRSCR = mk("ScrollingFrame", {
    BackgroundColor3 = C.CARD, BorderSizePixel = 0,
    Size = UDim2.new(1,0,1,-108), ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.ACCDIM, CanvasSize = UDim2.fromScale(0,0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y, ZIndex = 4, LayoutOrder = 2,
}, TR)
corner(6, TRSCR); stroke(C.BORDER, 1, TRSCR); pad(8, 6, TRSCR); listV(TRSCR, 3)

local FBTN = mk("TextButton", {
    AutoButtonColor = false, BackgroundColor3 = C.ACCENT, BorderSizePixel = 0,
    Font = Enum.Font.GothamBold, Text = "⚡  FIRE ONCE", TextColor3 = C.WHITE,
    TextSize = 12, Size = UDim2.new(1,0,0,34), ZIndex = 4, LayoutOrder = 3,
}, TR)
corner(7, FBTN)
do
    local base = C.ACCENT
    FBTN.MouseEnter:Connect(function()
        tw(FBTN, TI.fast, {BackgroundColor3 = Color3.new(
            math.min(base.R+.08,1), math.min(base.G+.08,1), math.min(base.B+.08,1))})
    end)
    FBTN.MouseLeave:Connect(function() tw(FBTN, TI.fast, {BackgroundColor3 = base}) end)
end

local FSTAT = mk("TextLabel", {
    BackgroundTransparency = 1, Font = Enum.Font.Code,
    Text = "Select a remote · pick a payload · fire.",
    TextColor3 = C.MUTED, TextSize = 9, TextWrapped = true,
    Size = UDim2.new(1,0,0,30), TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 4, LayoutOrder = 4,
}, TR)

-- row helpers
local trN = 0
local function addTR(t, m, d, h)
    trN += 1; mkRow(t, m, d, h, TRSCR, trN)
    task.defer(function() TRSCR.CanvasPosition = Vector2.new(0, TRSCR.AbsoluteCanvasSize.Y) end)
end
local function clrTR()
    for _, c in ipairs(TRSCR:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    trN = 0
end

-- ── Export ────────────────────────────────────────────────────────────────────
G.P_TGT  = P_TGT
G.TSUB   = TSUB
G.RBOX   = RBOX
G.sP_ref = {sP}   -- boxed ref so 06_init can read sP
G.pB     = pB
G.FBTN   = FBTN
G.FSTAT  = FSTAT
G.TRSCR  = TRSCR
G.addTR  = addTR
G.clrTR  = clrTR
G.popR   = popR

-- sP getter/setter (avoids stale upvalue issues)
G.getSelPay = function() return sP end
