-- Oracle // 05_compose.lua
-- Compose page: field builder · type cycler · templates · preview · build & fire
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
local CON    = G.CON

-- ── Compose page ──────────────────────────────────────────────────────────────
local P_CMP = mk("Frame", {
    BackgroundTransparency = 1, BorderSizePixel = 0,
    Size = UDim2.fromScale(1,1), Visible = false, ZIndex = 3,
}, CON)

local CL = mk("Frame", {
    BackgroundTransparency = 1, BorderSizePixel = 0,
    Size = UDim2.new(0.44,0,1,0), ZIndex = 3,
}, P_CMP)
pad(14, 12, CL); listV(CL, 7)

mk("Frame", {
    BackgroundColor3 = C.BORDER, BorderSizePixel = 0,
    Size = UDim2.new(0,1,1,-20), Position = UDim2.new(0.44,0,0,10), ZIndex = 4,
}, P_CMP)

local CR = mk("Frame", {
    BackgroundTransparency = 1, BorderSizePixel = 0,
    Size = UDim2.new(0.56,-2,1,0), Position = UDim2.new(0.44,2,0,0), ZIndex = 3,
}, P_CMP)
pad(10, 12, CR); listV(CR, 7)

-- ── Header ────────────────────────────────────────────────────────────────────
local CHC = mk("Frame", {
    BackgroundColor3 = C.CARD, BorderSizePixel = 0,
    Size = UDim2.new(1,0,0,50), ZIndex = 4, LayoutOrder = 1,
}, CL)
corner(8, CHC); stroke(C.BORDER, 1, CHC)
mk("UIPadding", {PaddingLeft=UDim.new(0,14), PaddingTop=UDim.new(0,10)}, CHC)
listV(CHC, 3)
mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.GothamBold, Text="⬡  COMPOSE MODE",
    TextColor3=C.ACCENT, TextSize=13, Size=UDim2.new(1,0,0,18),
    TextXAlignment=Enum.TextXAlignment.Left, ZIndex=5, LayoutOrder=1,
}, CHC)
local CSUB = mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="build a table payload and fire it", TextColor3=C.MUTED, TextSize=9,
    Size=UDim2.new(1,0,0,14), TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5, LayoutOrder=2,
}, CHC)

-- ── Remote display (mirrors RBOX from Target Mode) ────────────────────────────
mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.GothamBold, Text="REMOTE",
    TextColor3=C.MUTED, TextSize=9, Size=UDim2.new(1,0,0,13),
    TextXAlignment=Enum.TextXAlignment.Left, ZIndex=4, LayoutOrder=2,
}, CL)
local CRDISP = mk("Frame", {
    BackgroundColor3=C.CARD, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,28), ZIndex=4, LayoutOrder=3,
}, CL)
corner(6, CRDISP); stroke(C.BORDER, 1, CRDISP); pad(10, 0, CRDISP)
local CRNAME = mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="no remote selected — pick one in Target Mode",
    TextColor3=C.MUTED, TextSize=10, Size=UDim2.fromScale(1,1),
    TextXAlignment=Enum.TextXAlignment.Left,
    TextTruncate=Enum.TextTruncate.AtEnd, ZIndex=5,
}, CRDISP)

-- ── COMPOSE LOGIC  (all defined before any UI that calls them) ────────────────
local TYPES = {"str","num","bool","V3","CF","nil"}
local TCOL  = {
    str  = Color3.fromRGB(80,170,210),
    num  = Color3.fromRGB(168,120,255),
    bool = Color3.fromRGB(80, 210,100),
    V3   = Color3.fromRGB(255,160, 40),
    CF   = Color3.fromRGB(255, 90,150),
    ["nil"] = Color3.fromRGB(80, 74,108),
}

local fRows = {}; local fOrd = 0

-- forward refs (filled once UI is created)
local PTREF = {}   -- [1] = PREVTEXT
local FSREF = {}   -- [1] = FSCROLL
local FEREF = {}   -- [1] = FEMPTY

local function parseVal(tk, raw)
    raw = raw or ""
    if tk == "str"  then
        return raw:gsub("\\0","\0"):gsub("\\n","\n"):gsub("\\t","\t")
    elseif tk == "num" then
        if raw=="NaN"  or raw=="nan"  then return 0/0        end
        if raw=="Inf"  or raw=="inf"  then return math.huge  end
        if raw=="-Inf" or raw=="-inf" then return -math.huge end
        local n = tonumber(raw); if n then return n end
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

local function updatePreview()
    local pt = PTREF[1]; if not pt then return end
    if #fRows == 0 then pt.Text = "{ }"; pt.TextColor3 = C.MUTED; return end
    local lines = {"{"}
    for _, f in ipairs(fRows) do
        local key = f.kb.Text ~= "" and f.kb.Text or "?"
        local tk  = TYPES[f.ti]
        local raw = f.vb.Text
        local vs2
        if tk=="nil"  then vs2 = "nil"
        elseif tk=="str"  then vs2 = ('"%s"'):format(raw:sub(1,24)..(#raw>24 and"…"or""))
        elseif tk=="bool" then vs2 = (raw:lower()~="false" and raw~="0" and raw~="") and"true"or"false"
        elseif tk=="V3"   then vs2 = "V3("..raw..")"
        elseif tk=="CF"   then vs2 = "CF("..raw..")"
        else                   vs2 = raw~="" and raw or "0" end
        table.insert(lines, ("  %s = %s,"):format(key, vs2))
    end
    table.insert(lines, "}")
    pt.Text = table.concat(lines, "\n"); pt.TextColor3 = C.TEXT
end

local function buildTable()
    local t = {}
    for _, f in ipairs(fRows) do
        local k  = f.kb.Text
        local tk = TYPES[f.ti]
        if k ~= "" and tk ~= "nil" then t[k] = parseVal(tk, f.vb.Text) end
    end
    return t
end

local function addField(dk, dt, dv)
    local fs = FSREF[1]; local fe = FEREF[1]
    if not fs then return end
    fOrd += 1
    if fe then fe.Visible = false end

    local f   = {ti = dt or 1}
    local row = mk("Frame", {
        BackgroundColor3 = C.SURFACE, BackgroundTransparency = 0.3,
        BorderSizePixel = 0, Size = UDim2.new(1,0,0,28),
        ZIndex = 5, LayoutOrder = fOrd,
    }, fs)
    corner(4, row); f.row = row

    -- key box
    local kb = mk("TextBox", {
        BackgroundColor3 = C.BG, BorderSizePixel = 0,
        Text = dk or "", PlaceholderText = "key",
        PlaceholderColor3 = C.MUTED, TextColor3 = C.WHITE,
        TextSize = 10, Font = Enum.Font.Code, ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.new(0,70,0,20), Position = UDim2.new(0,4,0.5,-10), ZIndex = 6,
    }, row)
    corner(3, kb); f.kb = kb

    -- type cycle button
    local ti2  = dt or 1
    local tb2  = mk("TextButton", {
        AutoButtonColor = false, BackgroundColor3 = TCOL[TYPES[ti2]],
        BorderSizePixel = 0, Font = Enum.Font.GothamBold, Text = TYPES[ti2],
        TextColor3 = Color3.fromRGB(8,8,12), TextSize = 8,
        Size = UDim2.new(0,32,0,18), Position = UDim2.new(0,78,0.5,-9), ZIndex = 6,
    }, row)
    corner(3, tb2); f.tb = tb2; f.ti = ti2

    tb2.MouseButton1Click:Connect(function()
        f.ti = (f.ti % #TYPES) + 1
        local tk = TYPES[f.ti]
        tb2.Text = tk; tw(tb2, TI.fast, {BackgroundColor3 = TCOL[tk]})
        local ph = {V3="x,y,z",CF="x,y,z",bool="true/false",
                    num="0  NaN  Inf  2^53",str="value",["nil"]=""}
        f.vb.PlaceholderText = ph[tk] or ""
        f.vb.TextEditable  = (tk ~= "nil")
        f.vb.TextColor3    = (tk == "nil") and C.MUTED or C.WHITE
        updatePreview()
    end)

    -- value box
    local vb = mk("TextBox", {
        BackgroundColor3 = C.BG, BorderSizePixel = 0,
        Text = dv or "", PlaceholderText = "value",
        PlaceholderColor3 = C.MUTED, TextColor3 = C.WHITE,
        TextSize = 10, Font = Enum.Font.Code, ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Left,
        Size = UDim2.new(1,-150,0,20), Position = UDim2.new(0,114,0.5,-10), ZIndex = 6,
    }, row)
    corner(3, vb); f.vb = vb
    vb:GetPropertyChangedSignal("Text"):Connect(updatePreview)
    kb:GetPropertyChangedSignal("Text"):Connect(updatePreview)

    -- remove button
    local rb = mk("TextButton", {
        AutoButtonColor = false, BackgroundColor3 = C.REDDIM, BorderSizePixel = 0,
        Font = Enum.Font.GothamBold, Text = "✕", TextColor3 = C.RED, TextSize = 9,
        Size = UDim2.new(0,20,0,18), Position = UDim2.new(1,-24,0.5,-9), ZIndex = 6,
    }, row)
    corner(3, rb)
    rb.MouseButton1Click:Connect(function()
        for i, rf in ipairs(fRows) do
            if rf == f then table.remove(fRows, i); break end
        end
        row:Destroy()
        local fe2 = FEREF[1]
        if #fRows == 0 and fe2 then fe2.Visible = true end
        updatePreview()
    end)

    table.insert(fRows, f)
    updatePreview()
end

-- ── Templates ─────────────────────────────────────────────────────────────────
local TMPLS = {
    {l="Hit Register", f={
        {k="action",t=1,v="hit"},{k="target",t=1,v="PlayerName"},
        {k="damage",t=2,v="10"},{k="position",t=4,v="0,0,0"}}},
    {l="NaN Position", f={
        {k="position",t=4,v="NaN,NaN,NaN"},{k="velocity",t=4,v="NaN,0,0"}}},
    {l="Overflow Dmg", f={
        {k="damage",t=2,v="2^53"},{k="target",t=1,v="PlayerName"}}},
    {l="Flag Blast",   f={
        {k="flags",t=2,v="255"},{k="action",t=1,v=""},{k="id",t=2,v="0"}}},
    {l="Empty Shell",  f={
        {k="type",t=1,v=""},{k="data",t=1,v=""}}},
}

-- ── Field header + Add button ─────────────────────────────────────────────────
local CFHDR = mk("Frame", {
    BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,18), ZIndex=4, LayoutOrder=4,
}, CL)
listH(CFHDR, 6)
mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.GothamBold, Text="FIELDS",
    TextColor3=C.MUTED, TextSize=9, Size=UDim2.new(1,-64,1,0),
    TextXAlignment=Enum.TextXAlignment.Left, ZIndex=4, LayoutOrder=1,
}, CFHDR)
local ADDBTN = mk("TextButton", {
    AutoButtonColor=false, BackgroundColor3=C.CARD, BorderSizePixel=0,
    Font=Enum.Font.GothamBold, Text="＋ Add", TextColor3=C.ACCENT, TextSize=9,
    Size=UDim2.new(0,58,1,0), ZIndex=5, LayoutOrder=2,
}, CFHDR)
corner(4, ADDBTN); stroke(C.BORDER, 1, ADDBTN)
ADDBTN.MouseEnter:Connect(function() tw(ADDBTN, TI.fast, {BackgroundColor3=C.ACCDIM}) end)
ADDBTN.MouseLeave:Connect(function() tw(ADDBTN, TI.fast, {BackgroundColor3=C.CARD})   end)
ADDBTN.MouseButton1Click:Connect(function() addField() end)

-- ── Template row ─────────────────────────────────────────────────────────────
local CTPL = mk("Frame", {
    BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,18), ZIndex=4, LayoutOrder=5,
}, CL)
listH(CTPL, 4)
mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.GothamBold, Text="TEMPLATES",
    TextColor3=C.MUTED, TextSize=9, Size=UDim2.new(0,70,1,0),
    TextXAlignment=Enum.TextXAlignment.Left, ZIndex=4, LayoutOrder=1,
}, CTPL)

for _, tpl in ipairs(TMPLS) do
    local tb = mk("TextButton", {
        AutoButtonColor=false, BackgroundColor3=C.SURFACE, BackgroundTransparency=0.3,
        BorderSizePixel=0, Font=Enum.Font.Code, Text=tpl.l, TextColor3=C.TEXT, TextSize=8,
        Size=UDim2.new(0,0,1,0), AutomaticSize=Enum.AutomaticSize.X, ZIndex=5,
    }, CTPL)
    corner(3, tb); mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5)},tb)
    tb.MouseEnter:Connect(function() tw(tb,TI.fast,{BackgroundColor3=C.CARD,BackgroundTransparency=0}) end)
    tb.MouseLeave:Connect(function() tw(tb,TI.fast,{BackgroundColor3=C.SURFACE,BackgroundTransparency=0.3}) end)
    tb.MouseButton1Click:Connect(function()
        for _, ff in ipairs(fRows) do ff.row:Destroy() end
        fRows = {}; fOrd = 0
        local fe = FEREF[1]; if fe then fe.Visible = false end
        for _, fd in ipairs(tpl.f) do addField(fd.k, fd.t, fd.v) end
        CSUB.Text = "template: " .. tpl.l
    end)
end

-- ── Field scroll ─────────────────────────────────────────────────────────────
local FSCROLL = mk("ScrollingFrame", {
    BackgroundColor3=C.CARD, BorderSizePixel=0, Size=UDim2.new(1,0,1,-191),
    ScrollBarThickness=3, ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ZIndex=4, LayoutOrder=6,
}, CL)
corner(6, FSCROLL); stroke(C.BORDER, 1, FSCROLL); pad(6, 5, FSCROLL); listV(FSCROLL, 4)

local FEMPTY = mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="Press  ＋ Add  to add a field",
    TextColor3=C.MUTED, TextSize=9, Size=UDim2.new(1,0,0,24),
    TextXAlignment=Enum.TextXAlignment.Center, ZIndex=5, LayoutOrder=1,
}, FSCROLL)

-- wire forward refs
FSREF[1] = FSCROLL
FEREF[1] = FEMPTY

-- ── Right: preview ────────────────────────────────────────────────────────────
mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.GothamBold, Text="PAYLOAD PREVIEW",
    TextColor3=C.MUTED, TextSize=9, Size=UDim2.new(1,0,0,13),
    TextXAlignment=Enum.TextXAlignment.Left, ZIndex=4, LayoutOrder=1,
}, CR)

local PREVBOX = mk("ScrollingFrame", {
    BackgroundColor3=C.CARD, BorderSizePixel=0, Size=UDim2.new(1,0,0,100),
    ScrollBarThickness=3, ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ZIndex=4, LayoutOrder=2,
}, CR)
corner(6, PREVBOX); stroke(C.BORDER, 1, PREVBOX)
mk("UIPadding",{PaddingLeft=UDim.new(0,10),PaddingTop=UDim.new(0,6),PaddingBottom=UDim.new(0,6)},PREVBOX)
listV(PREVBOX, 0)

local PREVTEXT = mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.Code, Text="{ }",
    TextColor3=C.MUTED, TextSize=10, TextWrapped=true,
    Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
    TextXAlignment=Enum.TextXAlignment.Left, ZIndex=5, LayoutOrder=1,
}, PREVBOX)

PTREF[1] = PREVTEXT  -- wire preview ref

-- ── Right: result + fire ──────────────────────────────────────────────────────
mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.GothamBold, Text="RESULT",
    TextColor3=C.MUTED, TextSize=9, Size=UDim2.new(1,0,0,13),
    TextXAlignment=Enum.TextXAlignment.Left, ZIndex=4, LayoutOrder=3,
}, CR)

local CRSCR = mk("ScrollingFrame", {
    BackgroundColor3=C.CARD, BorderSizePixel=0, Size=UDim2.new(1,0,1,-182),
    ScrollBarThickness=3, ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ZIndex=4, LayoutOrder=4,
}, CR)
corner(6, CRSCR); stroke(C.BORDER, 1, CRSCR); pad(8, 6, CRSCR); listV(CRSCR, 3)

local BBTN = mk("TextButton", {
    AutoButtonColor=false, BackgroundColor3=C.ACCENT, BorderSizePixel=0,
    Font=Enum.Font.GothamBold, Text="⬡  BUILD & FIRE", TextColor3=C.WHITE,
    TextSize=12, Size=UDim2.new(1,0,0,34), ZIndex=4, LayoutOrder=5,
}, CR)
corner(7, BBTN)
do
    local base = C.ACCENT
    BBTN.MouseEnter:Connect(function()
        tw(BBTN, TI.fast, {BackgroundColor3=Color3.new(
            math.min(base.R+.08,1), math.min(base.G+.08,1), math.min(base.B+.08,1))})
    end)
    BBTN.MouseLeave:Connect(function() tw(BBTN, TI.fast, {BackgroundColor3=base}) end)
end

local BSTAT = mk("TextLabel", {
    BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="Select a remote in Target Mode · add fields · fire.",
    TextColor3=C.MUTED, TextSize=9, TextWrapped=true,
    Size=UDim2.new(1,0,0,28), TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4, LayoutOrder=6,
}, CR)

local crN = 0
local function addCR(t, m, d, h)
    crN += 1; mkRow(t, m, d, h, CRSCR, crN)
    task.defer(function() CRSCR.CanvasPosition=Vector2.new(0,CRSCR.AbsoluteCanvasSize.Y) end)
end
local function clrCR()
    for _, c in ipairs(CRSCR:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    crN = 0
end

-- ── Export ────────────────────────────────────────────────────────────────────
G.P_CMP     = P_CMP
G.CSUB      = CSUB
G.CRNAME    = CRNAME
G.BBTN      = BBTN
G.BSTAT     = BSTAT
G.addCR     = addCR
G.clrCR     = clrCR
G.buildTable= buildTable
G.addField  = addField
G.fRows     = fRows
