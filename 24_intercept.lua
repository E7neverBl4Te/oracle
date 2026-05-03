-- Oracle // 24_intercept.lua
-- INTERCEPT — Client-Side Remote Shadowing Engine
-- Sits between server→client signals and game scripts
-- Intercept · Modify · Drop · Replay · Inject false server data
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
local CON    = G.CON
local RepS   = G.RepS
local LP     = G.LP

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- INTERCEPT ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Shadow record per remote
-- Each shadow sits between OnClientEvent and all game listeners
local SHADOWS   = {}   -- [remoteName] = shadow
local INTERCEPT_LOG = {} -- [{name, action, original, modified, tick}]
local MAX_LOG   = 500

-- Actions a shadow can take on each incoming server packet
local ACTIONS = {
    PASSTHROUGH = "PASSTHROUGH",  -- let it through unmodified
    MODIFY      = "MODIFY",       -- let it through with modified args
    DROP        = "DROP",         -- swallow it — game scripts never see it
    DUPLICATE   = "DUPLICATE",    -- fire the game handlers twice
    INJECT      = "INJECT",       -- fire game handlers with synthetic args
}

-- Arg transform functions — applied when action is MODIFY or INJECT
-- Each returns a new args table
local TRANSFORMS = {
    {
        id    = "passthrough",
        label = "Pass unmodified",
        fn    = function(args) return args end,
    },
    {
        id    = "zero_numbers",
        label = "Zero all numbers",
        fn    = function(args)
            local out = {}
            for i,v in ipairs(args) do
                out[i] = type(v)=="number" and 0 or v
            end
            return out
        end,
    },
    {
        id    = "max_numbers",
        label = "Maximise all numbers",
        fn    = function(args)
            local out = {}
            for i,v in ipairs(args) do
                out[i] = type(v)=="number" and 2^53 or v
            end
            return out
        end,
    },
    {
        id    = "true_booleans",
        label = "Force all booleans true",
        fn    = function(args)
            local out = {}
            for i,v in ipairs(args) do
                out[i] = type(v)=="boolean" and true or v
            end
            return out
        end,
    },
    {
        id    = "invert_booleans",
        label = "Invert all booleans",
        fn    = function(args)
            local out = {}
            for i,v in ipairs(args) do
                out[i] = type(v)=="boolean" and not v or v
            end
            return out
        end,
    },
    {
        id    = "nan_numbers",
        label = "NaN all numbers",
        fn    = function(args)
            local out = {}
            for i,v in ipairs(args) do
                out[i] = type(v)=="number" and (0/0) or v
            end
            return out
        end,
    },
    {
        id    = "custom",
        label = "Custom (Lua script)",
        fn    = nil,  -- set per-shadow via scriptBox
    },
}

-- Log an intercept event
local function logIntercept(name, action, originalArgs, modifiedArgs)
    if #INTERCEPT_LOG >= MAX_LOG then table.remove(INTERCEPT_LOG,1) end
    local function argsStr(args)
        if not args then return "nil" end
        local p={}
        for _,v in ipairs(args) do table.insert(p,vs(v):sub(1,30)) end
        return table.concat(p,", ")
    end
    table.insert(INTERCEPT_LOG, {
        name     = name,
        action   = action,
        original = argsStr(originalArgs),
        modified = argsStr(modifiedArgs),
        tick     = tick(),
    })
end

-- Fire all game-side listeners on a remote with given args
-- Uses firesignal if available, otherwise uses a bridge RemoteEvent
local function fireGameListeners(remote, args)
    -- Method 1: firesignal (executor-level, cleanest)
    local ok1 = pcall(function()
        if firesignal then
            firesignal(remote.OnClientEvent, table.unpack(args))
            return true
        end
        error("no firesignal")
    end)
    if ok1 then return true end

    -- Method 2: hookfunction approach — call each connection's function directly
    local ok2 = pcall(function()
        if getconnections then
            local conns = getconnections(remote.OnClientEvent)
            for _, conn in ipairs(conns) do
                if conn.Function then
                    pcall(conn.Function, table.unpack(args))
                end
            end
            return true
        end
        error("no getconnections")
    end)
    if ok2 then return true end

    return false
end

-- Disable a connection (suppresses it without disconnecting)
local function disableConn(conn)
    local ok = pcall(function()
        if conn.Disable then conn:Disable() end
    end)
    return ok
end

local function enableConn(conn)
    local ok = pcall(function()
        if conn.Enable then conn:Enable() end
    end)
    return ok
end

-- Create a shadow on a remote
local function createShadow(remote, onEvent)
    local name = remote.Name
    if SHADOWS[name] then return SHADOWS[name] end

    local shadow = {
        name          = name,
        remote        = remote,
        action        = ACTIONS.PASSTHROUGH,
        transformId   = "passthrough",
        customScript  = nil,
        active        = false,
        capturedConns = {},   -- disabled game listener connections
        ourConn       = nil,  -- our interceptor connection
        fireCount     = 0,
        dropCount     = 0,
        modCount      = 0,
        lastArgs      = nil,
        onEvent       = onEvent,  -- UI callback
    }

    SHADOWS[name] = shadow
    return shadow
end

-- Arm a shadow — intercepts the remote
local function armShadow(shadow)
    if shadow.active then return end
    local remote = shadow.remote

    -- Step 1: Capture and disable existing game listeners
    local ok1 = pcall(function()
        if getconnections then
            local conns = getconnections(remote.OnClientEvent)
            for _, conn in ipairs(conns) do
                -- Don't disable our own future conn (it doesn't exist yet)
                disableConn(conn)
                table.insert(shadow.capturedConns, conn)
            end
        end
    end)

    -- Step 2: Install our interceptor
    shadow.ourConn = remote.OnClientEvent:Connect(function(...)
        if not shadow.active then return end
        local originalArgs = {...}
        shadow.lastArgs = originalArgs
        shadow.fireCount += 1

        local action = shadow.action

        if action == ACTIONS.DROP then
            -- Swallow entirely — game never sees this
            shadow.dropCount += 1
            logIntercept(shadow.name, "DROP", originalArgs, nil)
            if shadow.onEvent then shadow.onEvent("DROP", originalArgs, nil) end

        elseif action == ACTIONS.PASSTHROUGH then
            -- Re-enable connections, let signal through naturally
            for _, conn in ipairs(shadow.capturedConns) do
                enableConn(conn)
            end
            -- Signal already fired naturally since we didn't consume it
            -- Disable again for next event
            task.defer(function()
                for _, conn in ipairs(shadow.capturedConns) do
                    disableConn(conn)
                end
            end)
            logIntercept(shadow.name, "PASS", originalArgs, originalArgs)
            if shadow.onEvent then shadow.onEvent("PASS", originalArgs, originalArgs) end

        elseif action == ACTIONS.MODIFY then
            -- Apply transform and fire modified args to game listeners
            local transform = nil
            for _, t in ipairs(TRANSFORMS) do
                if t.id == shadow.transformId then transform=t; break end
            end

            local modifiedArgs = originalArgs
            if transform and transform.fn then
                local ok,result = pcall(transform.fn, originalArgs)
                if ok then modifiedArgs=result end
            elseif shadow.customScript then
                local ok,fn = pcall(loadstring,
                    "local args=...\n"..shadow.customScript.."\nreturn args")
                if ok and fn then
                    local ok2,result=pcall(fn,originalArgs)
                    if ok2 then modifiedArgs=result end
                end
            end

            fireGameListeners(remote, modifiedArgs)
            shadow.modCount += 1
            logIntercept(shadow.name, "MODIFY", originalArgs, modifiedArgs)
            if shadow.onEvent then shadow.onEvent("MODIFY", originalArgs, modifiedArgs) end

        elseif action == ACTIONS.INJECT then
            -- Ignore original args, fire custom synthetic args
            local syntheticArgs = {}
            if shadow.customScript then
                local ok,fn=pcall(loadstring,
                    "local Oracle={player=game:GetService('Players').LocalPlayer}\n"..
                    shadow.customScript)
                if ok and fn then
                    local ok2,result=pcall(fn)
                    if ok2 and type(result)=="table" then syntheticArgs=result end
                end
            end
            fireGameListeners(remote, syntheticArgs)
            shadow.modCount += 1
            logIntercept(shadow.name, "INJECT", originalArgs, syntheticArgs)
            if shadow.onEvent then shadow.onEvent("INJECT", originalArgs, syntheticArgs) end

        elseif action == ACTIONS.DUPLICATE then
            -- Fire game listeners twice with original args
            fireGameListeners(remote, originalArgs)
            task.wait(0.05)
            fireGameListeners(remote, originalArgs)
            logIntercept(shadow.name, "DUPE", originalArgs, originalArgs)
            if shadow.onEvent then shadow.onEvent("DUPE", originalArgs, originalArgs) end
        end
    end)

    shadow.active = true
end

-- Disarm a shadow — restores original listener state
local function disarmShadow(shadow)
    if not shadow.active then return end

    -- Disconnect our interceptor
    if shadow.ourConn then
        pcall(function() shadow.ourConn:Disconnect() end)
        shadow.ourConn = nil
    end

    -- Re-enable all captured game connections
    for _, conn in ipairs(shadow.capturedConns) do
        enableConn(conn)
    end
    shadow.capturedConns = {}
    shadow.active = false
end

-- Inject a synthetic server event — fires game listeners as if server sent it
local function injectEvent(remoteName, args, logFn)
    local remote = nil
    local function sc(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do
            if x:IsA("RemoteEvent") and x.Name==remoteName then remote=x; return end
        end
    end
    sc(RepS); if not remote then sc(workspace) end

    if not remote then
        if logFn then logFn("INFO","Remote not found: "..remoteName) end
        return false
    end

    local ok = fireGameListeners(remote, args)
    if logFn then
        logFn(ok and "FIRED" or "INFO",
            ("Injected synthetic event → %s"):format(remoteName),
            ok and ("args: "..table.concat((function()
                local p={}; for _,v in ipairs(args) do
                    table.insert(p,vs(v):sub(1,20)) end; return p
            end)(),", ")) or "injection failed — executor may not support firesignal/getconnections",
            ok)
    end
    return ok
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- INTERCEPT PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_INT = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- top bar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_INT)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)

mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⬡  INTERCEPT — SIGNAL SHADOW ENGINE",
    TextColor3=Color3.fromRGB(255,130,40),TextSize=11,
    Size=UDim2.new(0,310,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)

local INT_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="0 shadows",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,120,1,0),Position=UDim2.new(1,-380,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

local AUTO_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ACCDIM,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⟳ Shadow All",TextColor3=C.ACCENT,TextSize=9,
    Size=UDim2.new(0,92,0,22),Position=UDim2.new(1,-262,0.5,-11),ZIndex=6},TOPBAR)
corner(5,AUTO_BTN); stroke(C.BORDER,1,AUTO_BTN)
AUTO_BTN.MouseEnter:Connect(function() tw(AUTO_BTN,TI.fast,{BackgroundColor3=C.ACCENT,TextColor3=Color3.fromRGB(8,8,12)}) end)
AUTO_BTN.MouseLeave:Connect(function() tw(AUTO_BTN,TI.fast,{BackgroundColor3=C.ACCDIM,TextColor3=C.ACCENT}) end)

local ARM_ALL=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(40,80,20),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="▶ Arm All",TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,72,0,22),Position=UDim2.new(1,-160,0.5,-11),ZIndex=6},TOPBAR)
corner(5,ARM_ALL); stroke(Color3.fromRGB(80,210,100),1,ARM_ALL)

local DISARM_ALL=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(60,20,20),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="■ Disarm All",TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,84,0,22),Position=UDim2.new(1,-78,0.5,-11),ZIndex=6},TOPBAR)
corner(5,DISARM_ALL); stroke(Color3.fromRGB(255,80,80),1,DISARM_ALL)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_INT)

-- left: shadow list
local IL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},IL)
local SH_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},IL)
pad(6,6,SH_SCROLL); listV(SH_SCROLL,4)
local SH_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="No shadows yet.\n\nPress ⟳ Shadow All to intercept\nevery discovered RemoteEvent,\nor add one manually.",
    TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
    Size=UDim2.new(1,0,0,70),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},SH_SCROLL)

-- middle: config panel for selected shadow
local IC=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,241,0,0),Size=UDim2.new(0,220,1,0),ZIndex=3},BODY)
stroke(C.BORDER,1,IC)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},IC)

local CFG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},IC)
pad(10,10,CFG_SCROLL); listV(CFG_SCROLL,8)

local CFG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Select a shadow to configure",
    TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
    Size=UDim2.new(1,0,0,30),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},CFG_SCROLL)

-- right: live intercept log
local IR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,462,0,0),Size=UDim2.new(1,-462,1,0),ZIndex=3},BODY)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},IR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Intercepted server signals will\nappear here in real time.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,40),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- ── Log helpers ───────────────────────────────────────────────────────────────
local iN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; iN+=1; mkRow(tag,msg,detail,hi,LOG_SCROLL,iN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) iN+=1; mkSep(txt,LOG_SCROLL,iN) end

-- ── Shadow list UI ────────────────────────────────────────────────────────────
local selShadow = nil

local ACTION_COL = {
    PASSTHROUGH = Color3.fromRGB(80,140,255),
    MODIFY      = Color3.fromRGB(255,160,40),
    DROP        = Color3.fromRGB(255,80,80),
    DUPLICATE   = Color3.fromRGB(168,120,255),
    INJECT      = Color3.fromRGB(80,210,100),
}

local function rebuildShadowList()
    for _,c in ipairs(SH_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    local names={}; for n in pairs(SHADOWS) do table.insert(names,n) end
    table.sort(names)

    local activeCount=0
    for _,s in pairs(SHADOWS) do if s.active then activeCount+=1 end end
    INT_STATUS.Text=activeCount.." armed / "..#names.." shadows"

    if #names==0 then SH_EMPTY.Visible=true; return end
    SH_EMPTY.Visible=false

    for i,name in ipairs(names) do
        local sh=SHADOWS[name]; local sel=selShadow==name
        local actionCol=ACTION_COL[sh.action] or C.MUTED

        local card=mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=sel and C.ACCDIM or C.CARD,
            BorderSizePixel=0,Text="",
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=i},SH_SCROLL)
        corner(5,card)
        if sh.active then stroke(actionCol,1,card) end
        pad(8,6,card); listV(card,3)

        local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
        listH(hrow,4)

        -- armed indicator dot
        local dot=mk("Frame",{
            BackgroundColor3=sh.active and actionCol or C.MUTED,
            BorderSizePixel=0,Size=UDim2.fromOffset(8,8),ZIndex=6,LayoutOrder=1},hrow)
        corner(4,dot)

        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=name,TextColor3=sel and C.WHITE or C.TEXT,TextSize=10,
            Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=6,LayoutOrder=2},hrow)

        -- action chip
        if sh.active then
            local ac=mk("Frame",{BackgroundColor3=actionCol,BorderSizePixel=0,
                Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
            corner(3,ac); mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4)},ac)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text=sh.action,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
                Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},ac)
        end

        -- stats
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=("fires:%d  drops:%d  mods:%d"):format(
                sh.fireCount,sh.dropCount,sh.modCount),
            TextColor3=C.MUTED,TextSize=8,
            Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2},card)

        card.MouseButton1Click:Connect(function()
            selShadow=name; rebuildShadowList()
            buildConfigPanel(sh)
        end)
    end
end

-- ── Config panel for selected shadow ─────────────────────────────────────────
function buildConfigPanel(shadow)
    for _,c in ipairs(CFG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    CFG_EMPTY.Visible=false

    local ord=0; local function o() ord+=1; return ord end

    -- Name header
    local hdr=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=o()},CFG_SCROLL)
    corner(6,hdr); pad(10,6,hdr); listV(hdr,3)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=shadow.name,TextColor3=Color3.fromRGB(255,130,40),TextSize=12,
        Size=UDim2.new(1,0,0,16),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=1},hdr)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=shadow.active and "ARMED — intercepting" or "disarmed",
        TextColor3=shadow.active and Color3.fromRGB(80,210,100) or C.MUTED,TextSize=9,
        Size=UDim2.new(1,0,0,14),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=2},hdr)

    -- Arm / Disarm button
    local armBtn=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=shadow.active and Color3.fromRGB(60,20,20) or Color3.fromRGB(30,60,20),
        BorderSizePixel=0,Font=Enum.Font.GothamBold,
        Text=shadow.active and "■ Disarm" or "▶ Arm",
        TextColor3=C.WHITE,TextSize=10,
        Size=UDim2.new(1,0,0,28),ZIndex=4,LayoutOrder=o()},CFG_SCROLL)
    corner(7,armBtn)
    armBtn.MouseButton1Click:Connect(function()
        if shadow.active then
            disarmShadow(shadow)
            addLog("INFO","Disarmed: "..shadow.name)
        else
            armShadow(shadow)
            addLog("INFO","Armed: "..shadow.name,
                "Action: "..shadow.action)
        end
        rebuildShadowList()
        buildConfigPanel(shadow)
    end)

    -- Action selector
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="ACTION",TextColor3=C.MUTED,TextSize=9,
        Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=4,LayoutOrder=o()},CFG_SCROLL)

    for _, actionName in ipairs({
        ACTIONS.PASSTHROUGH,
        ACTIONS.MODIFY,
        ACTIONS.DROP,
        ACTIONS.DUPLICATE,
        ACTIONS.INJECT,
    }) do
        local sel2 = shadow.action == actionName
        local col2  = ACTION_COL[actionName] or C.MUTED
        local ab=mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=sel2 and col2 or C.CARD,
            BorderSizePixel=0,Font=Enum.Font.GothamBold,
            Text=actionName,
            TextColor3=sel2 and Color3.fromRGB(8,8,12) or C.MUTED,
            TextSize=9,
            Size=UDim2.new(1,0,0,22),ZIndex=4,LayoutOrder=o()},CFG_SCROLL)
        corner(4,ab)
        if not sel2 then stroke(C.BORDER,1,ab) end
        ab.MouseButton1Click:Connect(function()
            shadow.action=actionName
            buildConfigPanel(shadow)
            rebuildShadowList()
            addLog("INFO",shadow.name.." → "..actionName)
        end)
    end

    -- Transform selector (only relevant for MODIFY)
    if shadow.action == ACTIONS.MODIFY then
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text="TRANSFORM",TextColor3=C.MUTED,TextSize=9,
            Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=4,LayoutOrder=o()},CFG_SCROLL)

        for _, t in ipairs(TRANSFORMS) do
            local tsel = shadow.transformId == t.id
            local tb=mk("TextButton",{AutoButtonColor=false,
                BackgroundColor3=tsel and C.ACCDIM or C.CARD,
                BorderSizePixel=0,Font=Enum.Font.Code,
                Text=t.label,TextColor3=tsel and C.ACCENT or C.MUTED,TextSize=8,
                Size=UDim2.new(1,0,0,20),ZIndex=4,LayoutOrder=o()},CFG_SCROLL)
            corner(4,tb)
            if not tsel then stroke(C.BORDER,1,tb) end
            tb.MouseButton1Click:Connect(function()
                shadow.transformId=t.id
                buildConfigPanel(shadow)
            end)
        end
    end

    -- Custom script editor (for MODIFY custom / INJECT)
    if shadow.action == ACTIONS.INJECT or
       (shadow.action == ACTIONS.MODIFY and shadow.transformId == "custom") then
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text="SCRIPT",TextColor3=C.MUTED,TextSize=9,
            Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=4,LayoutOrder=o()},CFG_SCROLL)

        local scriptBox=mk("TextBox",{
            BackgroundColor3=Color3.fromRGB(8,7,12),BorderSizePixel=0,
            Text=shadow.customScript or
                (shadow.action==ACTIONS.INJECT and
                    "-- return table of args to inject\nreturn {true, 99999}" or
                    "-- modify args table\nargs[1] = 99999\nreturn args"),
            TextColor3=Color3.fromRGB(210,206,230),TextSize=10,
            Font=Enum.Font.Code,ClearTextOnFocus=false,MultiLine=true,
            TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Top,
            TextWrapped=false,
            Size=UDim2.new(1,0,0,100),ZIndex=4,LayoutOrder=o()},CFG_SCROLL)
        corner(5,scriptBox); stroke(C.BORDER,1,scriptBox)
        mk("UIPadding",{PaddingLeft=UDim.new(0,6),PaddingTop=UDim.new(0,6)},scriptBox)
        scriptBox:GetPropertyChangedSignal("Text"):Connect(function()
            shadow.customScript=scriptBox.Text
        end)
    end

    -- Last captured args display
    if shadow.lastArgs and #shadow.lastArgs > 0 then
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text="LAST CAPTURED",TextColor3=C.MUTED,TextSize=9,
            Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=4,LayoutOrder=o()},CFG_SCROLL)
        local argCard=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=o()},CFG_SCROLL)
        corner(5,argCard); pad(8,6,argCard); listV(argCard,3)
        for i,v in ipairs(shadow.lastArgs) do
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                Text=("Arg %d: %s"):format(i,vs(v):sub(1,60)),
                TextColor3=Color3.fromRGB(255,175,70),TextSize=9,TextWrapped=true,
                Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=i},argCard)
        end

        -- Replay button
        local replayBtn=mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=C.ACCDIM,BorderSizePixel=0,
            Font=Enum.Font.GothamBold,Text="⟳ Replay Last",
            TextColor3=C.ACCENT,TextSize=9,
            Size=UDim2.new(1,0,0,22),ZIndex=4,LayoutOrder=o()},CFG_SCROLL)
        corner(5,replayBtn); stroke(C.BORDER,1,replayBtn)
        replayBtn.MouseButton1Click:Connect(function()
            local ok=fireGameListeners(shadow.remote, shadow.lastArgs)
            addLog(ok and "FIRED" or "INFO",
                "Replayed last capture → "..shadow.name,
                ok and "injected into game listeners" or "injection failed",ok)
        end)
    end
end

-- ── Auto shadow all ───────────────────────────────────────────────────────────
AUTO_BTN.MouseButton1Click:Connect(function()
    local map = G.DISCOVERY_MAP
    local remotes = {}
    if map then
        for _,r in ipairs(map.remoteEvents or {}) do
            if r.instance then table.insert(remotes,r.instance) end
        end
    end
    -- Also scan live
    local function sc(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do
            if x:IsA("RemoteEvent") and not SHADOWS[x.Name] then
                table.insert(remotes,x)
            end
        end
    end
    if #remotes==0 then sc(RepS); sc(workspace) end

    local count=0
    for _,r in ipairs(remotes) do
        if not SHADOWS[r.Name] then
            local sh=createShadow(r, function(action,orig,mod)
                addLog(
                    action=="DROP" and "INFO" or
                    action=="MODIFY" and "DELTA" or
                    action=="INJECT" and "FINDING" or "INFO",
                    ("← %s [%s]"):format(r.Name,action),
                    orig and ("orig: "..table.concat((function()
                        local p={}; for _,v in ipairs(orig) do
                            table.insert(p,vs(v):sub(1,20)) end; return p
                    end)(),", ")) or "dropped",
                    action~="PASSTHROUGH" and action~="PASS")
                rebuildShadowList()
            end)
            count+=1
        end
    end
    rebuildShadowList()
    addLog("INFO",("Created %d shadow(s)"):format(count),
        "Configure action then press ▶ Arm")
    INT_STATUS.Text=count.." shadows created"
    INT_STATUS.TextColor3=Color3.fromRGB(255,130,40)
end)

-- Arm all
ARM_ALL.MouseButton1Click:Connect(function()
    local count=0
    for _,sh in pairs(SHADOWS) do
        if not sh.active then armShadow(sh); count+=1 end
    end
    rebuildShadowList()
    addLog("INFO",("Armed %d shadow(s)"):format(count))
end)

-- Disarm all
DISARM_ALL.MouseButton1Click:Connect(function()
    local count=0
    for _,sh in pairs(SHADOWS) do
        if sh.active then disarmShadow(sh); count+=1 end
    end
    rebuildShadowList()
    addLog("INFO",("Disarmed %d shadow(s)"):format(count))
end)

-- Export
G.INT_SHADOWS      = SHADOWS
G.INT_LOG          = INTERCEPT_LOG
G.int_injectEvent  = injectEvent
G.int_createShadow = createShadow
G.int_armShadow    = armShadow
G.int_disarmShadow = disarmShadow

if G.addTab then
    G.addTab("intercept","Intercept",P_INT)
else
    warn("[Oracle] G.addTab not found")
end
