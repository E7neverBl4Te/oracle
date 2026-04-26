-- Oracle // 02_oracle.lua
-- Payloads · State snapshot/diff · Remote helpers · Shared log row builders
local args = {...}
local G = args[1]
if not G then error("G table not received") end
local C      = G.C
local TAGCOL = G.TAGCOL
local mk     = G.mk
local corner = G.corner
local listH  = G.listH
local listV  = G.listV
local pad    = G.pad
local LP     = G.LP
local RepS   = game:GetService("ReplicatedStorage")
G.RepS       = RepS

-- ── Config ────────────────────────────────────────────────────────────────────
local CFG = {RW = 0.15, WD = 1.5, FI = 0.25}
G.CFG = CFG

-- ── Payloads ──────────────────────────────────────────────────────────────────
local PAYLOADS = {
    {l="NaN",            v=0/0},
    {l="Inf",            v=math.huge},
    {l="-Inf",           v=-math.huge},
    {l="NaN Vector3",    v=Vector3.new(0/0, 0, 0)},
    {l="Inf Vector3",    v=Vector3.new(math.huge, 0, 0)},
    {l="NaN CFrame",     v=CFrame.new(0/0, 0/0, 0/0)},
    {l="NaN in table",   v={amount = 0/0}},
    {l="Negative large", v=-999999},
    {l="Zero",           v=0},
    {l="Null byte",      v="\0"},
    {l="200k string",    v=string.rep("X", 200000)},
    {l="Large array",    v=table.create(5000, 1)},
    {l="Bool key table", v={[true] = "x"}},
    {l="Function value", v={fn = function() end}},
    {l="Empty table",    v={}},
}
G.PAYLOADS = PAYLOADS

-- ── Value helpers ─────────────────────────────────────────────────────────────
local function isNI(v)
    if type(v) ~= "number" then return false end
    return v ~= v or v == math.huge or v == -math.huge
end

local function vs(v)
    if type(v) == "number" then
        if v ~= v            then return "NaN"
        elseif v ==  math.huge then return "+Inf"
        elseif v == -math.huge then return "-Inf"
        else                    return tostring(v) end
    elseif typeof(v) == "Vector3" then
        return ("V3(%s,%s,%s)"):format(vs(v.X), vs(v.Y), vs(v.Z))
    elseif typeof(v) == "CFrame" then
        return ("CF(%s,%s,%s)"):format(vs(v.X), vs(v.Y), vs(v.Z))
    end
    return tostring(v)
end

G.isNI = isNI
G.vs   = vs

-- ── State snapshot ────────────────────────────────────────────────────────────
local function snap()
    local s = {}
    local function rd(k, f)
        local ok, v = pcall(f); if ok then s[k] = v end
    end
    local ch = LP.Character
    if ch then
        local h = ch:FindFirstChildOfClass("Humanoid")
        if h then
            rd("Hum.Health",    function() return h.Health    end)
            rd("Hum.WalkSpeed", function() return h.WalkSpeed end)
            rd("Hum.JumpPower", function() return h.JumpPower end)
        end
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        if hrp then
            rd("HRP.Position", function() return hrp.Position end)
            rd("HRP.CFrame",   function() return hrp.CFrame   end)
        end
    end
    local function sv(root, pfx)
        local ok, d = pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _, o in ipairs(d) do
            local t = o.ClassName
            if t == "IntValue" or t == "NumberValue" or t == "StringValue"
            or t == "BoolValue" or t == "DoubleConstrainedValue" then
                rd(pfx .. "." .. o.Name, function() return o.Value end)
            end
        end
    end
    pcall(sv, LP,        "P")
    pcall(sv, workspace, "W")
    return s
end
G.snap = snap

-- ── State diff ────────────────────────────────────────────────────────────────
local function dif(b, a)
    local out = {}
    for k, av in pairs(a) do
        local bv = b[k]
        if bv ~= nil then
            local ch = false
            if typeof(av) == "Vector3" or typeof(av) == "CFrame" then
                ch = av ~= bv or isNI(av.X) or isNI(av.Y) or isNI(av.Z)
            elseif type(av) == "number" then
                local both = av ~= av and bv ~= bv
                if not both then ch = av ~= bv or isNI(av) end
            else
                ch = av ~= bv
            end
            if ch then
                local bad = isNI(av)
                    or (typeof(av) == "Vector3"
                        and (isNI(av.X) or isNI(av.Y) or isNI(av.Z)))
                table.insert(out, {path=k, bv=vs(bv), av=vs(av), bad=bad})
            end
        end
    end
    return out
end
G.dif = dif

-- ── Remote hook ───────────────────────────────────────────────────────────────
local rlog = {}
G.rlog = rlog

local function hookR(remotes)
    local conns = {}
    for _, r in ipairs(remotes) do
        local ok, c = pcall(function()
            return r.OnClientEvent:Connect(function(...)
                local args, s = {...}, ""
                for i, a in ipairs(args) do
                    s = s .. (i > 1 and ", " or "") .. vs(a)
                end
                table.insert(rlog, {name = r.Name, args = s})
            end)
        end)
        if ok then table.insert(conns, c) end
    end
    return conns
end
G.hookR = hookR

-- ── Remote discovery ─────────────────────────────────────────────────────────
local function discR()
    local ev, fn = {}, {}
    local function sc(root)
        local ok, d = pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _, x in ipairs(d) do
            if x:IsA("RemoteEvent")        then table.insert(ev, x)
            elseif x:IsA("RemoteFunction") then table.insert(fn, x) end
        end
    end
    sc(RepS); sc(workspace)
    return ev, fn
end
G.discR = discR

-- ── Shared log row builders ───────────────────────────────────────────────────
local function mkPill(tag, parent)
    local tc = TAGCOL[tag] or C.MUTED
    local p  = mk("Frame", {
        BackgroundColor3 = tc,
        BorderSizePixel  = 0,
        Size             = UDim2.fromOffset(64, 14),
        ZIndex           = 6,
    }, parent)
    corner(3, p)
    mk("TextLabel", {
        BackgroundTransparency = 1,
        Font           = Enum.Font.GothamBold,
        Text           = tag,
        TextColor3     = Color3.fromRGB(8, 8, 12),
        TextSize       = 8,
        Size           = UDim2.fromScale(1, 1),
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex         = 7,
    }, p)
end

local function mkRow(tag, msg, detail, hi, scroll, idx)
    local row = mk("Frame", {
        Size             = UDim2.new(1, 0, 0, 0),
        AutomaticSize    = Enum.AutomaticSize.Y,
        BackgroundColor3 = hi and Color3.fromRGB(26, 14, 6) or C.BG,
        BackgroundTransparency = hi and 0 or 1,
        BorderSizePixel  = 0,
        ZIndex           = 5,
        LayoutOrder      = idx,
    }, scroll)
    if hi then corner(4, row) end
    pad(hi and 6 or 0, hi and 3 or 1, row)
    listV(row, 1)

    local mrow = mk("Frame", {
        Size          = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex        = 5,
        LayoutOrder   = 1,
    }, row)
    listH(mrow, 5, Enum.VerticalAlignment.Top)

    mkPill(tag, mrow)
    mk("TextLabel", {
        BackgroundTransparency = 1,
        Font           = Enum.Font.Code,
        Text           = msg,
        TextColor3     = hi and C.WHITE or C.TEXT,
        TextSize       = 11,
        TextWrapped    = true,
        Size           = UDim2.new(1, -74, 0, 0),
        AutomaticSize  = Enum.AutomaticSize.Y,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex         = 6,
        LayoutOrder    = 2,
    }, mrow)

    if detail and detail ~= "" then
        mk("TextLabel", {
            BackgroundTransparency = 1,
            Font           = Enum.Font.Code,
            Text           = "  → " .. detail,
            TextColor3     = hi and Color3.fromRGB(255, 175, 70) or C.MUTED,
            TextSize       = 10,
            TextWrapped    = true,
            Size           = UDim2.new(1, 0, 0, 0),
            AutomaticSize  = Enum.AutomaticSize.Y,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex         = 5,
            LayoutOrder    = 2,
        }, row)
    end
end

local function mkSep(txt, scroll, idx)
    local f = mk("Frame", {
        Size            = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex          = 4,
        LayoutOrder     = idx,
    }, scroll)
    mk("Frame", {
        BackgroundColor3 = C.BORDER,
        BorderSizePixel  = 0,
        Size             = UDim2.new(1, 0, 0, 1),
        Position         = UDim2.new(0, 0, 0.5, 0),
        ZIndex           = 4,
    }, f)
    if txt then
        local bg = mk("Frame", {
            BackgroundColor3 = C.BG,
            BorderSizePixel  = 0,
            Size             = UDim2.fromOffset(#txt * 6 + 14, 14),
            Position         = UDim2.new(0.5, 0, 0.5, -7),
            AnchorPoint      = Vector2.new(0.5, 0),
            ZIndex           = 5,
        }, f)
        mk("TextLabel", {
            BackgroundTransparency = 1,
            Font           = Enum.Font.GothamBold,
            Text           = txt,
            TextColor3     = C.MUTED,
            TextSize       = 9,
            Size           = UDim2.fromScale(1, 1),
            TextXAlignment = Enum.TextXAlignment.Center,
            ZIndex         = 6,
        }, bg)
    end
end

G.mkPill = mkPill
G.mkRow  = mkRow
G.mkSep  = mkSep
