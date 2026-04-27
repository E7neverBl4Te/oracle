-- Oracle // 11_tunnel.lua
-- TUNNEL — Trusted Handshake Engine
-- Mode A: RemoteFunction conversation (UNTRUSTED ORIGIN)
-- Mode B: MarketplaceService receipt injection (TRUSTED ORIGIN SPOOFED)
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

local MktSvc = game:GetService("MarketplaceService")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TUNNEL ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- ── Shared helpers ────────────────────────────────────────────────────────────
local function findRemote(name)
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

local function parseVal(tk, raw)
    raw = raw or ""
    if tk=="str"  then return raw:gsub("\\0","\0"):gsub("\\n","\n")
    elseif tk=="num" then
        if raw=="NaN"  or raw=="nan"  then return 0/0 end
        if raw=="Inf"  or raw=="inf"  then return math.huge end
        if raw=="-Inf" or raw=="-inf" then return -math.huge end
        local n=tonumber(raw); if n then return n end
        local ok,v=pcall(function() return load("return "..raw)() end)
        return (ok and type(v)=="number") and v or 0
    elseif tk=="bool" then return raw:lower()~="false" and raw~="0" and raw~=""
    elseif tk=="V3"   then
        local x,y,z=raw:match("^([^,]+),([^,]+),([^,]+)$")
        return Vector3.new(tonumber(x) or 0,tonumber(y) or 0,tonumber(z) or 0)
    elseif tk=="CF"   then
        local x,y,z=raw:match("^([^,]+),([^,]+),([^,]+)$")
        return CFrame.new(tonumber(x) or 0,tonumber(y) or 0,tonumber(z) or 0)
    elseif tk=="nil"  then return nil end
    return raw
end

-- ── Mode A: RemoteFunction conversation ──────────────────────────────────────
-- Returns {ok, returnValue, elapsed, stateDelta}
local function invokeRemote(remote, argFields, logFn)
    local payload = {}
    for _, f in ipairs(argFields) do
        table.insert(payload, parseVal(f.typeKey, f.value))
    end

    -- collect all remotes for response watch
    local ev = {}
    local function col(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(ev,x) end end
    end
    col(RepS); col(workspace)

    local before  = snap()
    for k in pairs(rlog) do rlog[k]=nil end
    local conns   = hookR(ev)

    local t0      = tick()
    local ok, ret = pcall(function()
        return remote:InvokeServer(table.unpack(payload))
    end)
    local elapsed = tick() - t0

    local after   = snap()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end

    local retStr
    if not ok then
        retStr = "ERROR: "..tostring(ret):sub(1,120)
    elseif ret == nil then
        retStr = "nil"
    elseif type(ret) == "table" then
        local parts = {}
        for k2,v2 in pairs(ret) do
            table.insert(parts, tostring(k2).."="..vs(v2))
        end
        retStr = "{"..table.concat(parts,", ").."}"
    else
        retStr = vs(ret)
    end

    local deltas = dif(before, after)
    local responses = {}
    for _,r in ipairs(rlog) do table.insert(responses,r) end
    for k in pairs(rlog) do rlog[k]=nil end

    return {
        ok        = ok,
        ret       = ret,
        retStr    = retStr,
        elapsed   = elapsed,
        deltas    = deltas,
        responses = responses,
    }
end

-- ── Mode B: Receipt injection ─────────────────────────────────────────────────
-- Attempts to find and call the developer's ProcessReceipt handler
-- with a crafted receiptInfo table
-- Returns {found, result, elapsed, stateDelta}

local function findProcessReceiptHandler()
    -- Search for the handler through MarketplaceService
    -- Developers bind it as:
    --   MktSvc.ProcessReceipt = function(receiptInfo) ... end
    -- We access it through the service itself
    local ok, handler = pcall(function()
        return MktSvc.ProcessReceipt
    end)
    if ok and type(handler) == "function" then
        return handler
    end

    -- Some games assign it as a property on a module or script
    -- Search workspace and ServerScriptService descendants
    -- Note: client can't see ServerScriptService contents
    -- but we can check ReplicatedStorage for shared modules
    local function searchModules(root)
        local ok2,d=pcall(function() return root:GetDescendants() end)
        if not ok2 then return nil end
        for _,x in ipairs(d) do
            if x:IsA("ModuleScript") then
                local mok, mod = pcall(require, x)
                if mok and type(mod)=="table" then
                    if type(mod.ProcessReceipt)=="function" then
                        return mod.ProcessReceipt
                    end
                    if type(mod.processReceipt)=="function" then
                        return mod.processReceipt
                    end
                end
            end
        end
        return nil
    end

    local found = searchModules(RepS)
    return found
end

local function injectReceipt(receiptInfo, logFn)
    local before  = snap()
    local t0      = tick()

    -- Build the receipt table
    local receipt = {
        PlayerId         = receiptInfo.PlayerId   or LP.UserId,
        PlaceIdWherePurchased = receiptInfo.PlaceId or game.PlaceId,
        PurchaseId       = receiptInfo.PurchaseId  or tostring(math.random(100000,999999)),
        CurrencySpent    = receiptInfo.CurrencySpent or 0,
        CurrencyType     = Enum.CurrencyType.Robux,
        ProductId        = receiptInfo.ProductId   or 0,
        Player           = LP,
    }

    logFn("INFO", "Receipt constructed",
        ("ProductId=%d  PurchaseId=%s  PlayerId=%d"):format(
            receipt.ProductId, tostring(receipt.PurchaseId), receipt.PlayerId))

    -- Attempt to call via MarketplaceService.ProcessReceipt
    local handler = findProcessReceiptHandler()

    if not handler then
        -- Cannot find handler from client — use PromptProductPurchase
        -- as the legitimate trigger path
        logFn("INFO",
            "Direct handler not accessible from client",
            "Using PromptProductPurchase as trigger — this starts the legitimate chain")

        local ok = pcall(function()
            MktSvc:PromptProductPurchase(LP, receipt.ProductId)
        end)

        local elapsed = tick() - t0
        local after   = snap()
        local deltas  = dif(before, after)

        return {
            found   = false,
            ok      = ok,
            retStr  = ok and "purchase prompt opened" or "rejected by engine",
            elapsed = elapsed,
            deltas  = deltas,
            mode    = "prompt",
        }
    end

    -- Handler found — attempt direct call
    logFn("FINDING", "ProcessReceipt handler located",
        "Calling with crafted receiptInfo — server will treat as Roblox infrastructure")

    local ok, ret = pcall(handler, receipt)
    local elapsed  = tick() - t0
    local after    = snap()
    local deltas   = dif(before, after)

    local retStr
    if not ok then
        retStr = "ERROR: "..tostring(ret):sub(1,120)
    elseif ret == nil then
        retStr = "nil — developer returned nothing (Roblox will retry)"
    elseif ret == Enum.ProductPurchaseDecision.PurchaseGranted then
        retStr = "PurchaseGranted — server accepted receipt as processed"
    elseif ret == Enum.ProductPurchaseDecision.NotProcessedYet then
        retStr = "NotProcessedYet — server will retry (loop vector open)"
    else
        retStr = tostring(ret)
    end

    return {
        found      = true,
        ok         = ok,
        ret        = ret,
        retStr     = retStr,
        elapsed    = elapsed,
        deltas     = deltas,
        mode       = "direct",
        loopOpen   = (not ok)
            or ret == nil
            or ret == Enum.ProductPurchaseDecision.NotProcessedYet,
    }
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TUNNEL PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_TUN = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.fromScale(1,1), Visible=false, ZIndex=3}, CON)

-- top bar
local TOPBAR = mk("Frame", {BackgroundColor3=C.SURFACE, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,36), ZIndex=4}, P_TUN)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
pad(12,0,TOPBAR); listH(TOPBAR,10)

mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⟳  TUNNEL — Trusted Handshake Engine",
    TextColor3=C.ACCENT,TextSize=11,
    Size=UDim2.new(1,-240,1,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=1},TOPBAR)

local TRUST_LBL = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="SELECT MODE",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,140,1,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5,LayoutOrder=2},TOPBAR)

-- Mode toggle buttons
local MODE_ROW = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,88,0,24),ZIndex=5,LayoutOrder=3},TOPBAR)
listH(MODE_ROW,4)

local MODE_A_BTN = mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ACCENT,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="A",
    TextColor3=C.WHITE,TextSize=11,
    Size=UDim2.new(0,40,1,0),ZIndex=6,LayoutOrder=1},MODE_ROW)
corner(5,MODE_A_BTN)

local MODE_B_BTN = mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.CARD,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="B",
    TextColor3=C.MUTED,TextSize=11,
    Size=UDim2.new(0,40,1,0),ZIndex=6,LayoutOrder=2},MODE_ROW)
corner(5,MODE_B_BTN)

-- body
local BODY = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,36),Size=UDim2.new(1,0,1,-36),ZIndex=3},P_TUN)

-- ── Left: config panel ────────────────────────────────────────────────────────
local TL = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0.44,0,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,-20),Position=UDim2.new(0.44,0,0,10),ZIndex=4},BODY)

-- bottom dock
local TL_DOCK = mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,1,-80),Size=UDim2.new(1,0,0,80),ZIndex=5},TL)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,-20,0,1),Position=UDim2.new(0,10,0,0),ZIndex=6},TL_DOCK)
pad(10,8,TL_DOCK); listV(TL_DOCK,6)

local FIRE_BTN = mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ACCENT,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⟳  OPEN TUNNEL",
    TextColor3=C.WHITE,TextSize=12,
    Size=UDim2.new(1,0,0,34),ZIndex=6,LayoutOrder=1},TL_DOCK)
corner(7,FIRE_BTN)
do local base=C.ACCENT
    FIRE_BTN.MouseEnter:Connect(function() tw(FIRE_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    FIRE_BTN.MouseLeave:Connect(function() tw(FIRE_BTN,TI.fast,{BackgroundColor3=base}) end)
end

local FIRE_STATUS = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Configure tunnel and fire.",
    TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
    Size=UDim2.new(1,0,0,26),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6,LayoutOrder=2},TL_DOCK)

-- left scroll area
local TL_SCROLL = mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,0),Size=UDim2.new(1,0,1,-80),
    ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ZIndex=4},TL)
pad(12,10,TL_SCROLL); listV(TL_SCROLL,8)

-- ── Right: conversation log ───────────────────────────────────────────────────
local TR = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0.44,1,0,0),Size=UDim2.new(0.56,-1,1,0),ZIndex=3},BODY)
local TR_SCROLL = mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=4,
    ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),
    AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},TR)
pad(10,8,TR_SCROLL); listV(TR_SCROLL,3)

local TR_EMPTY = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Tunnel conversation will appear here.\nEach exchange shows what you sent\nand what the server decided.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,60),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},TR_SCROLL)

-- ── Log helpers ───────────────────────────────────────────────────────────────
local trN = 0
local function addLog(tag,msg,detail,hi)
    TR_EMPTY.Visible=false
    trN+=1; mkRow(tag,msg,detail,hi,TR_SCROLL,trN)
    task.defer(function()
        TR_SCROLL.CanvasPosition=Vector2.new(0,TR_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt)
    trN+=1; mkSep(txt,TR_SCROLL,trN)
end
local function clearLog()
    for _,c in ipairs(TR_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    trN=0; TR_EMPTY.Visible=true
end

-- ── Mode state ────────────────────────────────────────────────────────────────
local activeMode   = "A"
local tunnelActive = false
local tunnelThread = nil
local loopActive   = false
local loopThread   = nil

-- mode A state
local modeA_argFields = {}
local modeA_argOrd    = 0

-- mode B state
local modeB_fields = {}   -- receipt info fields

local TYPES      = {"str","num","bool","V3","CF","nil"}
local TYPE_COLORS= {
    str=Color3.fromRGB(80,170,210), num=Color3.fromRGB(168,120,255),
    bool=Color3.fromRGB(80,210,100), V3=Color3.fromRGB(255,160,40),
    CF=Color3.fromRGB(255,90,150), ["nil"]=Color3.fromRGB(80,74,108),
}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MODE A PANEL — RemoteFunction conversation
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local PA = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=true,ZIndex=3},TL_SCROLL)
listV(PA,8)

-- trust label
local PA_TRUST = mk("Frame",{BackgroundColor3=Color3.fromRGB(60,35,10),
    BorderSizePixel=0,Size=UDim2.new(1,0,0,22),ZIndex=4,LayoutOrder=1},PA)
corner(5,PA_TRUST); stroke(Color3.fromRGB(255,160,40),1,PA_TRUST)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⚑  UNTRUSTED ORIGIN — server knows this is a client",
    TextColor3=Color3.fromRGB(255,160,40),TextSize=9,
    Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5},PA_TRUST)

-- remote name input
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="REMOTE FUNCTION",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=2},PA)
local PA_REMOTE = mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text="",PlaceholderText="RemoteFunction name",
    PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,
    TextSize=11,Font=Enum.Font.Code,ClearTextOnFocus=false,
    TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(1,0,0,28),ZIndex=4,LayoutOrder=3},PA)
corner(6,PA_REMOTE); stroke(C.BORDER,1,PA_REMOTE); pad(8,0,PA_REMOTE)

-- repeat settings
local PA_OPT = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,22),ZIndex=4,LayoutOrder=4},PA)
listH(PA_OPT,8)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="Rounds",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,48,1,0),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=1},PA_OPT)
local PA_ROUNDS = mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text="1",PlaceholderText="1",PlaceholderColor3=C.MUTED,
    TextColor3=C.WHITE,TextSize=11,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Center,
    Size=UDim2.new(0,36,0,20),ZIndex=5,LayoutOrder=2},PA_OPT)
corner(4,PA_ROUNDS); stroke(C.BORDER,1,PA_ROUNDS)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="Delay ms",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,58,1,0),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=3},PA_OPT)
local PA_DELAY = mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text="0",PlaceholderText="0",PlaceholderColor3=C.MUTED,
    TextColor3=C.WHITE,TextSize=11,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Center,
    Size=UDim2.new(0,48,0,20),ZIndex=5,LayoutOrder=4},PA_OPT)
corner(4,PA_DELAY); stroke(C.BORDER,1,PA_DELAY)

-- arg builder
local PA_ARGHDR = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,18),ZIndex=4,LayoutOrder=5},PA)
listH(PA_ARGHDR,6)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="ARGUMENTS",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,-64,1,0),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=1},PA_ARGHDR)
local PA_ADD = mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ACCDIM,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="＋ Add",TextColor3=C.ACCENT,TextSize=9,
    Size=UDim2.new(0,56,1,0),ZIndex=5,LayoutOrder=2},PA_ARGHDR)
corner(4,PA_ADD); stroke(C.BORDER,1,PA_ADD)
PA_ADD.MouseEnter:Connect(function() tw(PA_ADD,TI.fast,{BackgroundColor3=C.ACCENT,TextColor3=Color3.fromRGB(8,8,12)}) end)
PA_ADD.MouseLeave:Connect(function() tw(PA_ADD,TI.fast,{BackgroundColor3=C.ACCDIM,TextColor3=C.ACCENT}) end)

local PA_ARGS = mk("ScrollingFrame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,120),ScrollBarThickness=3,
    ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),
    AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4,LayoutOrder=6},PA)
corner(6,PA_ARGS); stroke(C.BORDER,1,PA_ARGS); pad(5,4,PA_ARGS); listV(PA_ARGS,3)

local PA_ARGS_EMPTY = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="No args — fires as signal",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,22),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},PA_ARGS)

local function addModeAArg(dk,dt,dv)
    modeA_argOrd+=1; PA_ARGS_EMPTY.Visible=false
    local f={typeKey=dt or "str", value=dv or ""}
    local row=mk("Frame",{BackgroundColor3=C.SURFACE,BackgroundTransparency=0.4,
        BorderSizePixel=0,Size=UDim2.new(1,0,0,26),
        ZIndex=5,LayoutOrder=modeA_argOrd},PA_ARGS)
    corner(4,row)
    local kb=mk("TextBox",{BackgroundColor3=C.BG,BorderSizePixel=0,
        Text=dk or "",PlaceholderText="key/label",
        PlaceholderColor3=C.MUTED,TextColor3=C.MUTED,
        TextSize=9,Font=Enum.Font.Code,ClearTextOnFocus=false,
        TextXAlignment=Enum.TextXAlignment.Left,
        Size=UDim2.new(0,60,0,20),Position=UDim2.new(0,4,0.5,-10),ZIndex=6},row)
    corner(3,kb)
    local typBtn=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=TYPE_COLORS[f.typeKey] or C.MUTED,
        BorderSizePixel=0,Font=Enum.Font.GothamBold,Text=f.typeKey,
        TextColor3=Color3.fromRGB(8,8,12),TextSize=8,
        Size=UDim2.new(0,28,0,18),Position=UDim2.new(0,68,0.5,-9),ZIndex=6},row)
    corner(3,typBtn)
    typBtn.MouseButton1Click:Connect(function()
        local idx=1
        for ti,t in ipairs(TYPES) do if t==f.typeKey then idx=ti;break end end
        idx=(idx % #TYPES)+1; f.typeKey=TYPES[idx]
        typBtn.Text=f.typeKey
        tw(typBtn,TI.fast,{BackgroundColor3=TYPE_COLORS[f.typeKey] or C.MUTED})
    end)
    local vb=mk("TextBox",{BackgroundColor3=C.BG,BorderSizePixel=0,
        Text=dv or "",PlaceholderText="value",
        PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,
        TextSize=10,Font=Enum.Font.Code,ClearTextOnFocus=false,
        TextXAlignment=Enum.TextXAlignment.Left,
        Size=UDim2.new(1,-130,0,20),Position=UDim2.new(0,100,0.5,-10),ZIndex=6},row)
    corner(3,vb)
    vb:GetPropertyChangedSignal("Text"):Connect(function() f.value=vb.Text end)
    local rb=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=C.REDDIM,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text="✕",TextColor3=C.RED,TextSize=9,
        Size=UDim2.new(0,20,0,18),Position=UDim2.new(1,-24,0.5,-9),ZIndex=6},row)
    corner(3,rb)
    rb.MouseButton1Click:Connect(function()
        for i,af in ipairs(modeA_argFields) do
            if af==f then table.remove(modeA_argFields,i);break end
        end
        row:Destroy()
        if #modeA_argFields==0 then PA_ARGS_EMPTY.Visible=true end
    end)
    f.row=row; table.insert(modeA_argFields,f)
end

PA_ADD.MouseButton1Click:Connect(function() addModeAArg() end)

-- return watcher
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="RETURN WATCHER",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=7},PA)
local PA_RETURN = mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,40),ZIndex=4,LayoutOrder=8},PA)
corner(6,PA_RETURN); stroke(C.BORDER,1,PA_RETURN); pad(8,0,PA_RETURN)
local PA_RETURN_LBL = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="waiting for server...",TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},PA_RETURN)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MODE B PANEL — MarketplaceService receipt injection
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local PB = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},TL_SCROLL)
listV(PB,8)

-- trust label
local PB_TRUST = mk("Frame",{BackgroundColor3=Color3.fromRGB(8,35,12),
    BorderSizePixel=0,Size=UDim2.new(1,0,0,22),ZIndex=4,LayoutOrder=1},PB)
corner(5,PB_TRUST); stroke(Color3.fromRGB(80,210,100),1,PB_TRUST)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⚑  TRUSTED ORIGIN (SPOOFED) — server thinks this is Roblox",
    TextColor3=Color3.fromRGB(80,210,100),TextSize=9,
    Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5},PB_TRUST)

-- ProductId selector
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="PRODUCT ID  —  logic branch selector",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=2},PB)
local PB_PID = mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text="",PlaceholderText="e.g. 12345  (the developer's product ID)",
    PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,
    TextSize=11,Font=Enum.Font.Code,ClearTextOnFocus=false,
    TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(1,0,0,28),ZIndex=4,LayoutOrder=3},PB)
corner(6,PB_PID); stroke(C.BORDER,1,PB_PID); pad(8,0,PB_PID)

-- Receipt simulator fields
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="RECEIPT SIMULATOR",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=4},PB)

local RECEIPT_FIELDS = {
    {k="PlayerId",      v=tostring(LP.UserId), hint="your UserId"},
    {k="PurchaseId",    v="auto",              hint="unique per transaction"},
    {k="CurrencySpent", v="0",                 hint="Robux — 0 = free product"},
    {k="PlaceId",       v=tostring(game.PlaceId), hint="current place"},
}

local PB_RECEIPT = mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
    ZIndex=4,LayoutOrder=5},PB)
corner(6,PB_RECEIPT); stroke(C.BORDER,1,PB_RECEIPT); pad(8,6,PB_RECEIPT); listV(PB_RECEIPT,4)

for _, rf in ipairs(RECEIPT_FIELDS) do
    local frow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,22),ZIndex=5},PB_RECEIPT)
    listH(frow,6)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=rf.k,TextColor3=C.MUTED,TextSize=9,
        Size=UDim2.new(0,110,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=1},frow)
    local vb=mk("TextBox",{BackgroundColor3=C.BG,BorderSizePixel=0,
        Text=rf.v,PlaceholderText=rf.hint,
        PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,
        TextSize=10,Font=Enum.Font.Code,ClearTextOnFocus=false,
        TextXAlignment=Enum.TextXAlignment.Left,
        Size=UDim2.new(1,-120,0,18),ZIndex=6,LayoutOrder=2},frow)
    corner(3,vb); stroke(C.BORDER,1,vb); pad(5,0,vb)
    rf.box=vb
    table.insert(modeB_fields,rf)
end

-- Handshake status display
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="HANDSHAKE STATUS",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=6},PB)
local PB_STATUS = mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,36),ZIndex=4,LayoutOrder=7},PB)
corner(6,PB_STATUS); stroke(C.BORDER,1,PB_STATUS); pad(8,0,PB_STATUS)
local PB_STATUS_LBL = mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="awaiting injection...",TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},PB_STATUS)

-- Retry loop toggle + safety breaker
local PB_LOOP_ROW = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,26),ZIndex=4,LayoutOrder=8},PB)
listH(PB_LOOP_ROW,8)

local LOOP_CHK = mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.CARD,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="",TextColor3=C.ACCENT,TextSize=9,
    Size=UDim2.new(0,20,0,20),ZIndex=5,LayoutOrder=1},PB_LOOP_ROW)
corner(4,LOOP_CHK); stroke(C.BORDER,1,LOOP_CHK)
local loopEnabled=false
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Retry loop (NotProcessedYet)",TextColor3=C.TEXT,TextSize=9,
    Size=UDim2.new(1,-120,1,0),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=2},PB_LOOP_ROW)

local BREAK_BTN = mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(160,40,40),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⬛ BREAK",
    TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,64,0,22),ZIndex=5,LayoutOrder=3},PB_LOOP_ROW)
corner(5,BREAK_BTN); BREAK_BTN.Visible=false

LOOP_CHK.MouseButton1Click:Connect(function()
    loopEnabled=not loopEnabled
    LOOP_CHK.Text=loopEnabled and "✓" or ""
    tw(LOOP_CHK,TI.fast,{BackgroundColor3=loopEnabled and C.ACCDIM or C.CARD})
end)

BREAK_BTN.MouseButton1Click:Connect(function()
    loopActive=false
    if loopThread then task.cancel(loopThread); loopThread=nil end
    BREAK_BTN.Visible=false
    PB_STATUS_LBL.Text="loop broken — safety breaker engaged"
    PB_STATUS_LBL.TextColor3=Color3.fromRGB(255,160,40)
    addLog("INFO","⬛ Safety breaker engaged","Retry loop terminated")
end)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MODE SWITCHING
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function setMode(mode)
    activeMode=mode
    PA.Visible=(mode=="A"); PB.Visible=(mode=="B")
    tw(MODE_A_BTN,TI.fast,{
        BackgroundColor3=mode=="A" and C.ACCENT or C.CARD,
        TextColor3=mode=="A" and C.WHITE or C.MUTED})
    tw(MODE_B_BTN,TI.fast,{
        BackgroundColor3=mode=="B" and C.ACCENT or C.CARD,
        TextColor3=mode=="B" and C.WHITE or C.MUTED})
    if mode=="A" then
        TRUST_LBL.Text="UNTRUSTED ORIGIN"
        TRUST_LBL.TextColor3=Color3.fromRGB(255,160,40)
        FIRE_BTN.Text="⟳  INVOKE SERVER"
    else
        TRUST_LBL.Text="TRUSTED ORIGIN (SPOOFED)"
        TRUST_LBL.TextColor3=Color3.fromRGB(80,210,100)
        FIRE_BTN.Text="⟳  INJECT RECEIPT"
    end
end

MODE_A_BTN.MouseButton1Click:Connect(function() setMode("A") end)
MODE_B_BTN.MouseButton1Click:Connect(function() setMode("B") end)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- FIRE BUTTON
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

FIRE_BTN.MouseButton1Click:Connect(function()
    if tunnelActive then return end

    -- Kill any existing loop first
    if loopActive then
        loopActive=false
        if loopThread then task.cancel(loopThread); loopThread=nil end
    end

    if activeMode=="A" then
        -- ── Mode A: RemoteFunction ────────────────────────────────────────────
        local name=PA_REMOTE.Text:match("^%s*(.-)%s*$")
        if name=="" then
            FIRE_STATUS.Text="Enter a RemoteFunction name"
            FIRE_STATUS.TextColor3=Color3.fromRGB(255,80,80); return
        end

        local remote=findRemote(name)
        if not remote or not remote:IsA("RemoteFunction") then
            FIRE_STATUS.Text="RemoteFunction not found: "..name
            FIRE_STATUS.TextColor3=Color3.fromRGB(255,80,80); return
        end

        local rounds=math.clamp(math.floor(tonumber(PA_ROUNDS.Text) or 1),1,20)
        local delay =(tonumber(PA_DELAY.Text) or 0) / 1000

        tunnelActive=true
        tw(FIRE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
        FIRE_STATUS.Text="tunnel open..."; FIRE_STATUS.TextColor3=C.DELTA
        PA_RETURN_LBL.Text="waiting..."; PA_RETURN_LBL.TextColor3=C.MUTED

        tunnelThread=task.spawn(function()
            addLogSep("TUNNEL A — "..name.." × "..rounds)

            for round=1,rounds do
                if round>1 and delay>0 then task.wait(delay) end

                addLog("INFO",
                    ("Round %d/%d — invoking %s"):format(round,rounds,name))

                local result=invokeRemote(remote, modeA_argFields, addLog)

                -- Update return watcher
                PA_RETURN_LBL.Text=result.retStr
                PA_RETURN_LBL.TextColor3=result.ok
                    and Color3.fromRGB(80,210,100)
                    or  Color3.fromRGB(255,80,80)

                addLog(
                    result.ok and "RESPONSE" or "INFO",
                    ("Round %d  ·  %.0fms  ·  return: %s"):format(
                        round, result.elapsed*1000, result.retStr),
                    nil, result.ok)

                -- State deltas
                for _,ch in ipairs(result.deltas) do
                    addLog(ch.bad and "PATHOLOG" or "DELTA",
                        (ch.bad and "⚑ " or "")..ch.path,
                        ch.bv.." → "..ch.av, true)
                end

                -- Side responses
                for _,r in ipairs(result.responses) do
                    addLog("RESPONSE","Side response via "..r.name,r.args,true)
                end
            end

            addLogSep("TUNNEL CLOSED — "..rounds.." round(s)")
            FIRE_STATUS.Text="tunnel closed"
            FIRE_STATUS.TextColor3=C.MUTED
            tw(FIRE_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
            tunnelActive=false
        end)

    else
        -- ── Mode B: MarketplaceService receipt injection ───────────────────────
        local pidStr=PB_PID.Text:match("^%s*(.-)%s*$")
        local pid=tonumber(pidStr)
        if not pid then
            FIRE_STATUS.Text="Enter a numeric Product ID"
            FIRE_STATUS.TextColor3=Color3.fromRGB(255,80,80); return
        end

        -- Build receipt info from fields
        local receiptInfo={ProductId=pid}
        for _,rf in ipairs(modeB_fields) do
            local k=rf.k
            local v=rf.box and rf.box.Text or rf.v
            if k=="PurchaseId" and v=="auto" then
                v=tostring(math.random(100000,999999))
            end
            receiptInfo[k]=tonumber(v) or v
        end

        tunnelActive=true
        tw(FIRE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
        FIRE_STATUS.Text="injecting receipt..."
        FIRE_STATUS.TextColor3=Color3.fromRGB(80,210,100)
        PB_STATUS_LBL.Text="injecting..."
        PB_STATUS_LBL.TextColor3=C.DELTA
        BREAK_BTN.Visible=loopEnabled

        tunnelThread=task.spawn(function()
            addLogSep("TUNNEL B — ProductId "..tostring(pid))
            addLog("INFO","Spoofed origin: Roblox infrastructure",
                "Server's ProcessReceipt handler will receive this as ground truth")

            local result=injectReceipt(receiptInfo,addLog)

            -- Update status display
            PB_STATUS_LBL.Text=result.retStr
            PB_STATUS_LBL.TextColor3=result.ok
                and Color3.fromRGB(80,210,100)
                or  Color3.fromRGB(255,80,80)

            addLog(
                result.found and "FINDING" or "INFO",
                result.mode=="direct"
                    and "Direct handler call — server processed as Roblox"
                    or  "Prompt triggered — legitimate chain initiated",
                result.retStr, result.found)

            for _,ch in ipairs(result.deltas) do
                addLog(ch.bad and "PATHOLOG" or "DELTA",
                    (ch.bad and "⚑ CORRELATED — " or "")..ch.path,
                    ch.bv.." → "..ch.av, true)
            end

            -- Retry loop
            if loopEnabled and result.loopOpen and result.found then
                loopActive=true
                local loopCount=0
                addLog("INFO","⟳ Retry loop active — server returned NotProcessedYet",
                    "Roblox infrastructure will keep calling handler — monitoring...")

                loopThread=task.spawn(function()
                    while loopActive do
                        task.wait(2)
                        loopCount+=1
                        receiptInfo.PurchaseId=tostring(math.random(100000,999999))

                        local lr=injectReceipt(receiptInfo,function() end)
                        addLog("INFO",
                            ("Loop %d — server returned: %s"):format(
                                loopCount,lr.retStr),
                            nil, lr.ok)

                        PB_STATUS_LBL.Text=("loop %d — %s"):format(loopCount,lr.retStr)

                        -- Auto-break if server grants
                        if lr.ret==Enum.ProductPurchaseDecision.PurchaseGranted then
                            loopActive=false
                            addLog("FINDING","⬛ Auto-break — server granted on loop "..loopCount,
                                "ProcessReceipt returned PurchaseGranted",true)
                            BREAK_BTN.Visible=false
                            PB_STATUS_LBL.TextColor3=Color3.fromRGB(80,210,100)
                            break
                        end

                        for _,ch in ipairs(lr.deltas) do
                            addLog(ch.bad and "PATHOLOG" or "DELTA",
                                (ch.bad and "⚑ " or "")..ch.path,
                                ch.bv.." → "..ch.av,true)
                        end
                    end
                end)
            else
                BREAK_BTN.Visible=false
            end

            addLogSep("INJECTION COMPLETE")
            FIRE_STATUS.Text="injection complete"
            FIRE_STATUS.TextColor3=C.MUTED
            tw(FIRE_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
            tunnelActive=false
        end)
    end
end)

-- ── Init ──────────────────────────────────────────────────────────────────────
setMode("A")

-- Auto-populate Mode A remote name from RBOX if available
if G.RBOX and G.RBOX.Text ~= "" then
    PA_REMOTE.Text = G.RBOX.Text
end

-- Register tab
if G.addTab then
    G.addTab("tunnel", "Tunnel", P_TUN)
else
    warn("[Oracle] G.addTab not found — ensure 06_init.lua is up to date")
end
