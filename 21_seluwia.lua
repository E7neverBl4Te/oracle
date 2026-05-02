-- Oracle // 21_seluwia.lua
-- Seluwia Bridge — MarketplaceService Signal Layer
-- Passive purchase signal capture · fireFakeSignal engine
-- Bridges captured signals to AVD, GSE, and TUNNEL Mode B
-- Core signal logic adapted from Seluwia.xyz v0.4
local G   = ...
local C   = G.C
local TI  = G.TI
local mk  = G.mk
local tw  = G.tw
local corner = G.corner
local stroke = G.stroke
local pad    = G.pad
local listV  = G.listV
local listH  = G.listH
local mkRow  = G.mkRow
local mkSep  = G.mkSep
local vs     = G.vs
local CON    = G.CON
local LP     = G.LP

local MPS      = game:GetService("MarketplaceService")
local Players  = game:GetService("Players")
local RS       = game:GetService("RunService")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SIGNAL ENGINE
-- Mirrors Seluwia's fireFakeSignal with Oracle observation hooks
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local CAPTURED  = {}   -- [{sigType, id, tick, fired, autoActive}]
local SUPPRESS  = 0    -- re-entrancy guard (same pattern as Seluwia)
local nameCache = {}

local SIG_COL = {
    Product  = Color3.fromRGB(100,200,255),
    Gamepass = Color3.fromRGB(61, 255,160),
    Bulk     = Color3.fromRGB(255,190, 60),
    Purchase = Color3.fromRGB(200,200,200),
}

-- Resolve product name (cached)
local function resolveName(id, sigType)
    local key = tostring(id).."|"..tostring(sigType)
    if nameCache[key] then return nameCache[key] end
    local name = nil
    pcall(function()
        local itype = Enum.InfoType.Product
        if sigType=="Gamepass" then itype=Enum.InfoType.GamePass end
        local info = MPS:GetProductInfo(id, itype)
        if info and info.Name then name=info.Name end
    end)
    if name then nameCache[key]=name end
    return name
end

-- Fire the MarketplaceService client-side purchase completion signal
-- This is the exact mechanism Seluwia uses — fires the signal the
-- server-side developer hooks to trigger grants
local function fireFakeSignal(sigType, id, logFn)
    if SUPPRESS > 0 then return end
    SUPPRESS += 1
    local ok, err = pcall(function()
        local uid = LP.UserId
        if     sigType == "Product"  then MPS:SignalPromptProductPurchaseFinished(uid, id, true)
        elseif sigType == "Gamepass" then MPS:SignalPromptGamePassPurchaseFinished(LP, id, true)
        elseif sigType == "Bulk"     then MPS:SignalPromptBulkPurchaseFinished(uid, id, true)
        elseif sigType == "Purchase" then MPS:SignalPromptPurchaseFinished(uid, id, true)
        end
    end)
    SUPPRESS -= 1

    -- Bridge to GSE call log
    if G.GSE_CALL_LOG then
        table.insert(G.GSE_CALL_LOG, {
            service = "MarketplaceService",
            method  = "Signal"..sigType.."PurchaseFinished",
            args    = tostring(id).." uid="..tostring(LP.UserId),
            result  = ok and "fired" or tostring(err):sub(1,40),
            tick    = tick(),
        })
    end

    if logFn then
        logFn(ok and "FIRED" or "INFO",
            ("Signal%sPurchaseFinished — id %d"):format(sigType, id),
            ok and "signal sent through MPS trust channel" or tostring(err):sub(1,60),
            ok)
    end

    return ok, err
end

-- Passive listener — hooks both MPS prompt methods AND completion signals
-- Method hooks capture the ID the moment the game initiates a purchase prompt
-- Signal hooks capture the final confirmed/cancelled result
local listenerConns  = {}
local hookedMethods  = {}
local listenerActive = false
local captureCallback = nil  -- current onCapture function

local function startListener(onCapture)
    -- Always register the render callback — this is what was broken.
    -- The guard was blocking renderCapture from being registered
    -- when auto-start had already set listenerActive=true.
    captureCallback = onCapture

    -- Only attach hooks once
    if listenerActive then return end
    listenerActive = true

    -- Helper: record a capture and call onCapture
    local function doCapture(sigType, id, uid, purchased, source)
        if SUPPRESS > 0 then return end
        -- Deduplicate — same id+type within 1 second = same event
        for _, existing in ipairs(CAPTURED) do
            if existing.id == id and existing.sigType == sigType
            and (tick() - existing.tick) < 1.0 then
                if source == "signal" then
                    existing.purchased = purchased
                    existing.completed = true
                end
                return
            end
        end
        local rec = {
            sigType   = sigType,
            id        = id,
            uid       = uid or LP.UserId,
            purchased = purchased,
            source    = source,
            tick      = tick(),
            fired     = 0,
            autoActive= false,
            completed = source == "signal",
        }
        table.insert(CAPTURED, rec)
        -- Use captureCallback so re-registration via LISTEN button works
        if captureCallback then captureCallback(rec) end

        if G.AVD_OBS then
            local obsName = "MPS:"..sigType
            if not G.AVD_OBS[obsName] then
                G.AVD_OBS[obsName] = {
                    fires={},argShapes={},lastFire=0,totalFires=0,
                    stateChanges=0,fireIntervals={},rapidCount=0
                }
            end
            G.AVD_OBS[obsName].totalFires += 1
            G.AVD_OBS[obsName].lastFire    = tick()
        end
    end

    -- ── Hook MPS PROMPT METHODS (fires when game initiates purchase UI) ────────
    -- This is the primary capture path — catches the ID before the dialog appears
    local promptHooks = {
        {method="PromptGamePassPurchase",  sigType="Gamepass",
         idArg=2},  -- PromptGamePassPurchase(player, gamePassId)
        {method="PromptProductPurchase",   sigType="Product",
         idArg=2},  -- PromptProductPurchase(player, productId)
        {method="PromptPurchase",          sigType="Purchase",
         idArg=2},  -- PromptPurchase(player, assetId)
        {method="PromptBulkPurchase",      sigType="Bulk",
         idArg=2},  -- PromptBulkPurchase(player, productId)
    }

    for _, hook in ipairs(promptHooks) do
        local methodName = hook.method
        local sigType    = hook.sigType
        local idArg      = hook.idArg

        -- Try hookfunction (executor-level) first, fall back to method replacement
        local orig = nil
        local hooked = false

        -- Method 1: hookfunction (available in Synapse/Xeno/etc.)
        local ok1 = pcall(function()
            if hookfunction then
                orig = MPS[methodName]
                hookfunction(orig, function(self, ...)
                    local args = {...}
                    local id   = args[idArg - 1]  -- -1 because self is implicit
                    if type(id) == "number" then
                        doCapture(sigType, id, LP.UserId, nil, "prompt")
                    end
                    return orig(self, ...)
                end)
                hooked = true
            end
        end)

        -- Method 2: Replace via __newindex if hookfunction unavailable
        if not hooked then
            local ok2 = pcall(function()
                local origMethod = MPS[methodName]
                if type(origMethod) == "function" then
                    orig = origMethod
                    MPS[methodName] = function(self, ...)
                        local args = {...}
                        local id   = args[idArg - 1]
                        if type(id) == "number" then
                            doCapture(sigType, id, LP.UserId, nil, "prompt")
                        end
                        return origMethod(self, ...)
                    end
                    hookedMethods[methodName] = {orig=origMethod}
                    hooked = true
                end
            end)
        end

        -- Method 3: getconnections / firesignal approach via executor
        if not hooked then
            -- Last resort — scan existing connections on the method's signal
            local ok3 = pcall(function()
                if getconnections then
                    -- Hook any connection that calls this method
                    local conns2 = getconnections(MPS[methodName])
                    if conns2 then
                        for _, c in ipairs(conns2) do
                            if c.Function then
                                local origFn = c.Function
                                c.Function = function(...)
                                    local args = {...}
                                    local id = args[idArg]
                                    if type(id) == "number" then
                                        doCapture(sigType, id, LP.UserId, nil, "prompt")
                                    end
                                    return origFn(...)
                                end
                            end
                        end
                    end
                end
            end)
        end
    end

    -- ── Hook COMPLETION SIGNALS (fires after dialog dismissed) ────────────────
    local function hookSig(sigName, sigType)
        local ok, conn = pcall(function()
            return MPS[sigName]:Connect(function(uidOrPlayer, id, purchased)
                -- PromptGamePassPurchaseFinished passes Player obj not userId
                local uid
                if type(uidOrPlayer) == "number" then
                    uid = uidOrPlayer
                elseif typeof(uidOrPlayer) == "Instance" then
                    local ok2,n=pcall(function() return uidOrPlayer.UserId end)
                    uid = ok2 and n or LP.UserId
                else
                    uid = LP.UserId
                end
                doCapture(sigType, id, uid, purchased, "signal")
            end)
        end)
        if ok and conn then table.insert(listenerConns, conn) end
    end

    hookSig("PromptProductPurchaseFinished",  "Product")
    hookSig("PromptGamePassPurchaseFinished",  "Gamepass")
    hookSig("PromptBulkPurchaseFinished",      "Bulk")
    hookSig("PromptPurchaseFinished",          "Purchase")
end

local function stopListener()
    listenerActive  = false
    captureCallback = nil
    for _, c in ipairs(listenerConns) do pcall(function() c:Disconnect() end) end
    listenerConns = {}
    for methodName, data in pairs(hookedMethods) do
        pcall(function() MPS[methodName] = data.orig end)
    end
    hookedMethods = {}
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_SEL = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- top bar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_SEL)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⬡  SELUWIA — MPS SIGNAL LAYER",
    TextColor3=C.ACCENT,TextSize=11,
    Size=UDim2.new(0,280,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)

local SEL_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="inactive",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,140,1,0),Position=UDim2.new(1,-380,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- LISTEN button
local LISTEN_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ACCENT,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="● LISTEN",TextColor3=C.WHITE,TextSize=10,
    Size=UDim2.new(0,80,0,22),Position=UDim2.new(1,-238,0.5,-11),ZIndex=6},TOPBAR)
corner(5,LISTEN_BTN)
do local base=C.ACCENT
    LISTEN_BTN.MouseEnter:Connect(function() tw(LISTEN_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    LISTEN_BTN.MouseLeave:Connect(function() tw(LISTEN_BTN,TI.fast,{BackgroundColor3=base}) end)
end

-- CLEAR button
local CLEAR_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.CARD,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⌫ CLR",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,50,0,22),Position=UDim2.new(1,-148,0.5,-11),ZIndex=6},TOPBAR)
corner(5,CLEAR_BTN); stroke(C.BORDER,1,CLEAR_BTN)
CLEAR_BTN.MouseEnter:Connect(function() tw(CLEAR_BTN,TI.fast,{BackgroundColor3=C.SURFACE}) end)
CLEAR_BTN.MouseLeave:Connect(function() tw(CLEAR_BTN,TI.fast,{BackgroundColor3=C.CARD}) end)

-- STOP ALL button
local STOPALL_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.CARD,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="■ STOP ALL",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,80,0,22),Position=UDim2.new(1,-84,0.5,-11),ZIndex=6},TOPBAR)
corner(5,STOPALL_BTN); stroke(C.BORDER,1,STOPALL_BTN)
STOPALL_BTN.MouseEnter:Connect(function() tw(STOPALL_BTN,TI.fast,{BackgroundColor3=C.SURFACE}) end)
STOPALL_BTN.MouseLeave:Connect(function() tw(STOPALL_BTN,TI.fast,{BackgroundColor3=C.CARD}) end)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_SEL)

-- left: manual fire panel
local ML=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,230,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},ML)

local ML_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},ML)
pad(10,10,ML_SCROLL); listV(ML_SCROLL,8)

-- header card
do
    local hdr=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=1},ML_SCROLL)
    corner(6,hdr); stroke(C.BORDER,1,hdr); pad(10,8,hdr); listV(hdr,3)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="MANUAL FIRE",TextColor3=C.ACCENT,TextSize=11,
        Size=UDim2.new(1,0,0,15),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=1},hdr)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text="Fire MPS purchase completion\nsignals directly through the\ntrusted client channel.",
        TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},hdr)
end

-- Signal type selector
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="SIGNAL TYPE",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=2},ML_SCROLL)

local SIG_TYPES = {"Product","Gamepass","Bulk","Purchase","Auto"}
local selSigType = "Product"
local sigTypeBtns = {}

-- Two-row signal type selector
local SIGTYPE_ROW1=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,24),ZIndex=4,LayoutOrder=3},ML_SCROLL)
listH(SIGTYPE_ROW1,3)
local SIGTYPE_ROW2=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,24),ZIndex=4,LayoutOrder=4},ML_SCROLL)
listH(SIGTYPE_ROW2,3)

local function updateSigTypeBtns(sel)
    for st2,btn in pairs(sigTypeBtns) do
        local c2 = SIG_COL[st2] or Color3.fromRGB(168,120,255)
        tw(btn,TI.fast,{
            BackgroundColor3 = st2==sel and c2 or C.CARD,
            TextColor3       = st2==sel and Color3.fromRGB(8,8,12) or C.MUTED,
        })
    end
end

for i, st in ipairs(SIG_TYPES) do
    local col = SIG_COL[st] or Color3.fromRGB(168,120,255)
    local parent = i <= 4 and SIGTYPE_ROW1 or SIGTYPE_ROW2
    local b=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=st==selSigType and col or C.CARD,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text=st,
        TextColor3=st==selSigType and Color3.fromRGB(8,8,12) or C.MUTED,
        TextSize=8,Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
        ZIndex=5},parent)
    corner(4,b); mk("UIPadding",{PaddingLeft=UDim.new(0,7),PaddingRight=UDim.new(0,7)},b)
    b.MouseButton1Click:Connect(function()
        selSigType=st; updateSigTypeBtns(st)
    end)
    sigTypeBtns[st]=b
end

-- Product ID input
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="PRODUCT ID",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=5},ML_SCROLL)
local ID_BOX=mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text="",PlaceholderText="numeric ID",
    PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,TextSize=11,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(1,0,0,28),ZIndex=4,LayoutOrder=6},ML_SCROLL)
corner(6,ID_BOX); stroke(C.BORDER,1,ID_BOX); pad(8,0,ID_BOX)

-- Repeat count
local REPT_ROW=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,22),ZIndex=4,LayoutOrder=7},ML_SCROLL)
listH(REPT_ROW,8)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="Repeat",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,48,1,0),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=1},REPT_ROW)
local REPT_BOX=mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text="1",PlaceholderText="1",PlaceholderColor3=C.MUTED,
    TextColor3=C.WHITE,TextSize=10,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Center,
    Size=UDim2.new(0,36,0,20),ZIndex=5,LayoutOrder=2},REPT_ROW)
corner(4,REPT_BOX); stroke(C.BORDER,1,REPT_BOX)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="Delay ms",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,56,1,0),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=3},REPT_ROW)
local DELAY_BOX=mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text="0",PlaceholderText="0",PlaceholderColor3=C.MUTED,
    TextColor3=C.WHITE,TextSize=10,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Center,
    Size=UDim2.new(0,40,0,20),ZIndex=5,LayoutOrder=4},REPT_ROW)
corner(4,DELAY_BOX); stroke(C.BORDER,1,DELAY_BOX)

-- FIRE button
local FIRE_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ACCENT,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="▶  FIRE SIGNAL",TextColor3=C.WHITE,TextSize=12,
    Size=UDim2.new(1,0,0,34),ZIndex=4,LayoutOrder=8},ML_SCROLL)
corner(7,FIRE_BTN)
do local base=C.ACCENT
    FIRE_BTN.MouseEnter:Connect(function() tw(FIRE_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    FIRE_BTN.MouseLeave:Connect(function() tw(FIRE_BTN,TI.fast,{BackgroundColor3=base}) end)
end

-- From GSE button
local GSE_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ACCDIM,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⟳ Load GSE IDs",TextColor3=C.ACCENT,TextSize=9,
    Size=UDim2.new(1,0,0,26),ZIndex=4,LayoutOrder=9},ML_SCROLL)
corner(6,GSE_BTN); stroke(C.BORDER,1,GSE_BTN)
GSE_BTN.MouseEnter:Connect(function() tw(GSE_BTN,TI.fast,{BackgroundColor3=C.ACCENT,TextColor3=Color3.fromRGB(8,8,12)}) end)
GSE_BTN.MouseLeave:Connect(function() tw(GSE_BTN,TI.fast,{BackgroundColor3=C.ACCDIM,TextColor3=C.ACCENT}) end)

-- right: listener log
local MR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,230,0,0),Size=UDim2.new(1,-230,1,0),ZIndex=3},BODY)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},MR)
pad(8,6,LOG_SCROLL); listV(LOG_SCROLL,4)

local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Press ● LISTEN to capture MarketplaceService\npurchase completion signals in real time.\n\n"..
         "Every signal captured can be replayed through\nthe same trusted MPS channel.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,80),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- log helpers
local lN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; lN+=1; mkRow(tag,msg,detail,hi,LOG_SCROLL,lN)
    task.defer(function() LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y) end)
end
local function addLogSep(txt) lN+=1; mkSep(txt,LOG_SCROLL,lN) end

-- ── Render a captured signal entry ───────────────────────────────────────────
local activeAutos = {}  -- {btn, thread, active}

local function renderCapture(rec)
    LOG_EMPTY.Visible = false
    lN += 1

    local sigCol = SIG_COL[rec.sigType] or C.MUTED

    -- Card is taller — info rows on top, button row pinned to bottom
    local card=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,-2,0,68),ZIndex=4,LayoutOrder=lN},LOG_SCROLL)
    corner(7,card); stroke(sigCol,1,card)

    -- ── Row 1: dot + type + ID label (y=5) ────────────────────────────────
    local dot=mk("Frame",{BackgroundColor3=sigCol,BorderSizePixel=0,
        Size=UDim2.fromOffset(8,8),Position=UDim2.new(0,8,0,8),ZIndex=5},card)
    corner(4,dot)

    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=string.upper(rec.sigType),TextColor3=sigCol,TextSize=9,
        Size=UDim2.new(0,68,0,16),Position=UDim2.new(0,22,0,4),
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},card)

    local idLbl=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=tostring(rec.id),TextColor3=C.WHITE,TextSize=12,
        Size=UDim2.new(1,-100,0,16),Position=UDim2.new(0,92,0,4),
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},card)

    task.spawn(function()
        local name=resolveName(rec.id,rec.sigType)
        if name and idLbl.Parent then
            idLbl.Text=tostring(rec.id).."  "..name:sub(1,20)
            idLbl.TextColor3=Color3.fromRGB(255,175,70)
        end
    end)

    -- ── Row 2: source badge + fire count (y=24) ────────────────────────────
    local sourceCol = rec.source=="prompt"
        and Color3.fromRGB(255,160,40)
        or  Color3.fromRGB(80,210,100)
    local sourceTxt = rec.source=="prompt" and "PROMPT" or
        (rec.purchased and "BOUGHT" or "CANCELLED")
    local sb=mk("Frame",{BackgroundColor3=sourceCol,BorderSizePixel=0,
        Size=UDim2.fromOffset(0,14),AutomaticSize=Enum.AutomaticSize.X,
        Position=UDim2.new(0,22,0,24),ZIndex=5},card)
    corner(3,sb); mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4)},sb)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=sourceTxt,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},sb)

    local fcLbl=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text="fired: 0",TextColor3=C.MUTED,TextSize=8,
        Size=UDim2.new(0,55,0,14),Position=UDim2.new(0,92,0,25),
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},card)

    local tsLbl=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=os.date("%H:%M:%S",math.floor(rec.tick)),TextColor3=C.MUTED,TextSize=8,
        Size=UDim2.new(0,55,0,14),Position=UDim2.new(0,150,0,25),
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},card)

    -- ── Row 3: button bar (y=44, h=20) ─────────────────────────────────────
    -- Use a horizontal frame at the bottom so buttons never overlap content
    local BTNROW=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Position=UDim2.new(0,6,1,-24),Size=UDim2.new(1,-12,0,20),ZIndex=5},card)
    listH(BTNROW,4)

    local function mkB(txt, col2, tcol)
        local b=mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=col2 or C.SURFACE,BorderSizePixel=0,
            Font=Enum.Font.GothamBold,Text=txt,
            TextColor3=tcol or C.MUTED,TextSize=8,
            Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
            ZIndex=6},BTNROW)
        corner(4,b)
        mk("UIPadding",{PaddingLeft=UDim.new(0,6),PaddingRight=UDim.new(0,6)},b)
        stroke(C.BORDER,1,b)
        b.MouseEnter:Connect(function() tw(b,TI.fast,{BackgroundColor3=C.CARD}) end)
        b.MouseLeave:Connect(function() tw(b,TI.fast,{BackgroundColor3=col2 or C.SURFACE}) end)
        return b
    end

    local runBtn    = mkB("▶ Fire")
    local copyBtn   = mkB("Copy")
    local autoBtn   = mkB("Auto")
    local tunnelBtn = mkB("Tunnel", C.ACCDIM, C.ACCENT)

    -- ▶ Fire
    runBtn.MouseButton1Click:Connect(function()
        local ok2=fireFakeSignal(rec.sigType,rec.id,addLog)
        if ok2 then
            rec.fired+=1; fcLbl.Text="fired: "..rec.fired
            runBtn.Text="Sent ✓"; runBtn.TextColor3=C.ACCENT
            task.delay(1.5,function()
                if runBtn.Parent then runBtn.Text="▶ Fire"; runBtn.TextColor3=C.MUTED end
            end)
        end
    end)

    -- Copy
    copyBtn.MouseButton1Click:Connect(function()
        pcall(setclipboard,tostring(rec.id))
        copyBtn.Text="Copied!"; copyBtn.TextColor3=C.ACCENT
        task.delay(1.5,function()
            if copyBtn.Parent then copyBtn.Text="Copy"; copyBtn.TextColor3=C.MUTED end
        end)
    end)

    -- Auto — continuous fire loop
    local autoData={active=false,thread=nil}
    autoBtn.MouseButton1Click:Connect(function()
        if autoData.active then
            autoData.active=false
            if autoData.thread then task.cancel(autoData.thread) end
            autoBtn.Text="Auto"
            autoBtn.TextColor3=C.MUTED
            autoBtn.BackgroundColor3=C.SURFACE
            tw(card,TI.fast,{BackgroundColor3=C.CARD})
        else
            autoData.active=true
            autoBtn.Text="■ Stop"
            autoBtn.TextColor3=Color3.fromRGB(255,80,80)
            autoBtn.BackgroundColor3=Color3.fromRGB(40,15,15)
            tw(card,TI.fast,{BackgroundColor3=Color3.fromRGB(18,8,4)})
            autoData.thread=task.spawn(function()
                while autoData.active and card.Parent do
                    fireFakeSignal(rec.sigType,rec.id,nil)
                    rec.fired+=1; fcLbl.Text="fired: "..rec.fired
                    task.wait(0.1)
                end
            end)
            table.insert(activeAutos,autoData)
        end
    end)

    -- Tunnel — pre-fills TUNNEL Mode B
    tunnelBtn.MouseButton1Click:Connect(function()
        addLog("INFO","TUNNEL Mode B pre-filled",
            ("ProductId=%d  Type=%s"):format(rec.id,rec.sigType),true)
        _G.ORACLE_SEL_PREFILL = {productId=rec.id, sigType=rec.sigType}
        if G.SwitchTab then G.SwitchTab("tunnel") end
    end)

    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end

-- ── LISTEN toggle ─────────────────────────────────────────────────────────────
local listening = false

LISTEN_BTN.MouseButton1Click:Connect(function()
    if not listening then
        listening = true
        LISTEN_BTN.Text = "■ STOP"
        tw(LISTEN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(160,40,40)})
        SEL_STATUS.Text = "listening — passive"
        SEL_STATUS.TextColor3 = Color3.fromRGB(80,210,100)
        addLogSep("LISTENER STARTED")
        startListener(function(rec)
            renderCapture(rec)
            SEL_STATUS.Text = (#CAPTURED).." captured"
        end)
    else
        listening = false
        LISTEN_BTN.Text = "● LISTEN"
        tw(LISTEN_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
        SEL_STATUS.Text = "stopped"
        SEL_STATUS.TextColor3 = C.MUTED
        stopListener()
    end
end)

-- ── CLEAR ─────────────────────────────────────────────────────────────────────
CLEAR_BTN.MouseButton1Click:Connect(function()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    lN=0; LOG_EMPTY.Visible=true
    for k in pairs(CAPTURED) do CAPTURED[k]=nil end
end)

-- ── STOP ALL ──────────────────────────────────────────────────────────────────
STOPALL_BTN.MouseButton1Click:Connect(function()
    for _, ad in ipairs(activeAutos) do
        ad.active=false
        if ad.thread then task.cancel(ad.thread) end
    end
    for k in pairs(activeAutos) do activeAutos[k]=nil end
    addLog("INFO","All auto-fire loops stopped")
end)

-- ── FIRE SIGNAL button ────────────────────────────────────────────────────────
FIRE_BTN.MouseButton1Click:Connect(function()
    local idStr = ID_BOX.Text:match("^%s*(.-)%s*$")
    local id    = tonumber(idStr)
    if not id then
        SEL_STATUS.Text = "enter a numeric ID"
        SEL_STATUS.TextColor3 = Color3.fromRGB(255,80,80)
        return
    end
    local reps  = math.clamp(math.floor(tonumber(REPT_BOX.Text) or 1),1,50)
    local delay = (tonumber(DELAY_BOX.Text) or 0) / 1000

    -- Auto fires all four signal types
    local typesToFire = selSigType == "Auto"
        and {"Product","Gamepass","Bulk","Purchase"}
        or  {selSigType}

    addLogSep(("MANUAL FIRE — %s  %d  × %d"):format(selSigType,id,reps))
    task.spawn(function()
        for i=1,reps do
            if i>1 and delay>0 then task.wait(delay) end
            for _, st in ipairs(typesToFire) do
                fireFakeSignal(st, id, addLog)
                if #typesToFire > 1 then task.wait(0.05) end
            end
        end
        SEL_STATUS.Text = ("fired %d × %d"):format(id, reps * #typesToFire)
        SEL_STATUS.TextColor3 = Color3.fromRGB(80,210,100)
    end)
end)

-- ── Load IDs from GSE ─────────────────────────────────────────────────────────
GSE_BTN.MouseButton1Click:Connect(function()
    local log = G.GSE_CALL_LOG
    if not log or #log == 0 then
        addLog("INFO","GSE call log is empty","Run GSE → ⬡ SCAN IDs first")
        return
    end
    addLogSep("GSE ID IMPORT")
    local seen = {}
    for _, entry in ipairs(log) do
        if entry.args then
            for id in tostring(entry.args):gmatch("%d+") do
                local num = tonumber(id)
                if num and num > 10000 and not seen[num] then
                    seen[num] = true
                    addLog("FINDING",
                        ("Product ID %d"):format(num),
                        "Imported from GSE call log — click ▶ to fire",
                        true)
                end
            end
        end
    end
end)

-- ── Export ────────────────────────────────────────────────────────────────────
G.SEL_CAPTURED       = CAPTURED
G.sel_fireFakeSignal = fireFakeSignal

-- Do NOT auto-start here — the onCapture callback that renders cards
-- is defined below (renderCapture). Auto-starting with a no-op here
-- sets listenerActive=true and blocks the real callback from registering.

if G.addTab then
    G.addTab("seluwia","Seluwia",P_SEL)
else
    warn("[Oracle] G.addTab not found")
end
