-- Oracle // 35_scripttoggle.lua
-- SCRIPTTOGGLE — Disabled Script Toggle Probe
-- Finds remotes that can set Script.Disabled = false, re-executing server scripts
-- Detects three attack surfaces: direct instance, name/path, config+reload
-- Vector 5: Client toggles Script.Disabled → script re-runs from top
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

local RS = game:GetService("RunService")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SCRIPTTOGGLE ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Reinitialization detection window (ms)
-- When a script re-runs it typically fires client events within this window
local REINIT_WINDOW_MS = 4000

-- Common script names that are worth targeting
-- These are frequently used as game controller or admin scripts
local COMMON_SCRIPT_NAMES = {
    "GameManager",    "GameController",  "ServerManager",
    "AdminScript",    "AdminHandler",    "AdminSystem",
    "MainScript",     "Main",            "Server",
    "GameScript",     "GameHandler",     "ServerScript",
    "DataManager",    "DataHandler",     "PlayerManager",
    "LoadScript",     "Loader",          "Init",
    "Setup",          "Config",          "Settings",
    "AntiCheat",      "SecurityScript",  "Guard",
    "EventHandler",   "RemoteHandler",   "NetworkScript",
}

-- Properties worth targeting on Script instances
local SCRIPT_PROPERTIES = {
    "Disabled",        -- Main toggle — re-executes script when set false
    "LinkedSource",    -- URL-linked scripts reload when cleared/changed
}

-- ── Surface A: Direct instance property setter ────────────────────────────────
-- Payload formats for "set property on this instance to this value"
local function buildDirectPayloads(scriptInstance, property, value)
    return {
        -- Positional instance + property + value
        {tag="positional",    args={scriptInstance, property, value}},
        -- Named fields
        {tag="named",         args={{instance=scriptInstance, property=property, value=value}}},
        {tag="named_target",  args={{target=scriptInstance, prop=property, val=value}}},
        -- Action style
        {tag="action_set",    args={{action="set", object=scriptInstance, key=property, value=value}}},
        {tag="action_prop",   args={{action="setProperty", instance=scriptInstance, property=property, value=value}}},
        -- Object wrapper
        {tag="obj_prop",      args={{obj=scriptInstance, [property]=value}}},
    }
end

-- ── Surface B: Name/path-based toggle ────────────────────────────────────────
-- Payload formats for "enable script by name or path"
local function buildNamePayloads(scriptName)
    return {
        -- Direct name
        {tag="name_direct",    args={scriptName}},
        -- Enable action
        {tag="enable_name",    args={{action="enable",       script=scriptName}}},
        {tag="enable_name2",   args={{action="enableScript", name=scriptName}}},
        -- Reload/restart
        {tag="reload_name",    args={{action="reload",       script=scriptName}}},
        {tag="reload_name2",   args={{action="reloadScript", scriptName=scriptName}}},
        {tag="restart_name",   args={{action="restart",      target=scriptName}}},
        -- Load
        {tag="load_name",      args={{action="load",         name=scriptName}}},
        {tag="run_name",       args={{action="run",          script=scriptName}}},
        -- Toggle pattern
        {tag="toggle_name",    args={{action="toggle",       name=scriptName, enabled=true}}},
        -- Path patterns
        {tag="path_enable",    args={{path="ServerScriptService."..scriptName, enabled=true}}},
        {tag="path_reload",    args={{scriptPath=scriptName, reload=true}}},
        -- Admin command style
        {tag="admin_enable",   args={{command="enableScript", target=scriptName}}},
    }
end

-- ── Surface C: Config inject + reload trigger ─────────────────────────────────
-- Payload formats for "reload config / restart systems"
local RELOAD_PAYLOADS = {
    {tag="reload",         args={{action="reload"}}},
    {tag="reload_config",  args={{action="reloadConfig"}}},
    {tag="restart",        args={{action="restart"}}},
    {tag="reinit",         args={{action="reinitialize"}}},
    {tag="refresh",        args={{action="refresh"}}},
    {tag="reload_all",     args={{action="reload", all=true}}},
    {tag="hot_reload",     args={{action="hotReload"}}},
    {tag="update",         args={{action="update", reload=true}}},
}

-- ── Script instance discovery ─────────────────────────────────────────────────
-- Finds Script and LocalScript instances visible from the client
-- These can be passed as instance arguments to remotes
local function discoverAccessibleScripts()
    local scripts = {}
    local seen    = {}

    local function scan(root, prefix)
        local ok, children = pcall(function() return root:GetChildren() end)
        if not ok then return end
        for _, child in ipairs(children) do
            if not seen[child] then
                seen[child] = true
                local isScript = child:IsA("Script") or
                                 child:IsA("LocalScript") or
                                 child:IsA("ModuleScript")
                if isScript then
                    local ok2, disabled = pcall(function()
                        return child.Disabled
                    end)
                    table.insert(scripts, {
                        instance    = child,
                        name        = child.Name,
                        class       = child.ClassName,
                        path        = prefix.."."..child.Name,
                        disabled    = ok2 and disabled or nil,
                        -- Prioritize already-disabled scripts as toggle targets
                        priority    = ok2 and disabled and 10 or 5,
                    })
                end
                -- Recurse into non-player containers
                local parentName = root.Name:lower()
                local skip = parentName == "players" or
                             parentName == "serverstorage" or
                             parentName == "serverscriptservice"
                if not skip then
                    scan(child, prefix.."."..child.Name)
                end
            end
        end
    end

    scan(game.Workspace,         "Workspace")
    scan(RepS,                   "ReplicatedStorage")
    scan(game:GetService("StarterGui"),    "StarterGui")
    scan(game:GetService("StarterPack"),   "StarterPack")
    scan(game:GetService("StarterPlayer"), "StarterPlayer")
    pcall(function()
        scan(game:GetService("ReplicatedFirst"), "ReplicatedFirst")
    end)

    -- Sort: disabled scripts first (better toggle targets), then by name
    table.sort(scripts, function(a,b) return a.priority > b.priority end)
    return scripts
end

-- ── Reinitiation event monitor ────────────────────────────────────────────────
-- When a Script re-runs it typically fires setup events to the client
-- We intercept all server→client events and look for:
--   1. Duplicate events (same event fires twice in the window)
--   2. State-reset patterns (values returning to initial/default state)
--   3. Any new events we hadn't seen before

local function watchForReinit(remotesToWatch, windowMs, logFn)
    local seenEvents   = {}  -- events we've already seen before the probe
    local newFires     = {}  -- events that fired during the window
    local connections  = {}

    -- Capture baseline event set (events that fire without our trigger)
    local function connectWatchers()
        for _, remote in ipairs(remotesToWatch) do
            if remote:IsA("RemoteEvent") then
                local ok, conn = pcall(function()
                    return remote.OnClientEvent:Connect(function(...)
                        local args = {...}
                        local sig  = remote.Name..":"..vs(args):sub(1,40)
                        table.insert(newFires, {
                            name = remote.Name,
                            sig  = sig,
                            args = args,
                            time = tick(),
                            duplicate = seenEvents[sig] ~= nil,
                        })
                        seenEvents[sig] = true
                    end)
                end)
                if ok then table.insert(connections, conn) end
            end
        end
    end

    connectWatchers()

    -- Wait for the window
    task.wait(windowMs / 1000)

    -- Disconnect watchers
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end

    -- Analyse what we saw
    local reinitSignals = {}
    local duplicates    = 0
    for _, fire in ipairs(newFires) do
        if fire.duplicate then
            duplicates = duplicates + 1
            table.insert(reinitSignals, fire)
            if logFn then
                logFn("FINDING",
                    ("Re-init signal: %s fired again"):format(fire.name),
                    ("Duplicate event — server script re-ran and re-fired setup events"):format(),
                    true)
            end
        end
    end

    return {
        totalFires   = #newFires,
        duplicates   = duplicates,
        reinitSigs   = reinitSignals,
        confirmed    = duplicates > 0,
    }
end

-- ── State reset detection ─────────────────────────────────────────────────────
-- When a script re-runs it resets its own state
-- Observable as: counters going back to 0, booleans flipping to initial values
-- We use snap()/dif() to catch these

local function fireAndWatchReset(remote, payload, logFn)
    local ev = {}
    local function col(root)
        local ok, d = pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _, x in ipairs(d) do
            if x:IsA("RemoteEvent") then table.insert(ev, x) end
        end
    end
    col(RepS); col(game.Workspace)

    local before   = snap()
    local beforeSS = snapshotStats()
    for k in pairs(rlog) do rlog[k] = nil end
    local conns    = hookR(ev)
    local t0       = tick()

    pcall(function()
        if remote:IsA("RemoteFunction") then
            remote:InvokeServer(table.unpack(payload))
        else
            remote:FireServer(table.unpack(payload))
        end
    end)

    task.wait(math.max(0.1, CFG.RW))
    local dl = tick() + (REINIT_WINDOW_MS/1000)
    while tick() < dl do task.wait(0.2) end

    local after = snap()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end

    local responses = {}
    for _, r in ipairs(rlog) do table.insert(responses, r) end
    for k in pairs(rlog) do rlog[k] = nil end

    local deltas = dif(before, after)

    -- Look specifically for RESETS — values going DOWN or back to 0/defaults
    local resetSignals = {}
    for _, ch in ipairs(deltas) do
        local bnum = tonumber(ch.bv)
        local anum = tonumber(ch.av)
        if bnum and anum then
            -- Value decreased significantly — possible reset
            if bnum > 10 and anum < bnum * 0.5 then
                table.insert(resetSignals, {
                    path   = ch.path,
                    before = ch.bv,
                    after  = ch.av,
                    reset  = true,
                })
            end
        end
        -- Boolean flipped to false — possible reset
        if ch.bv == "true" and ch.av == "false" then
            table.insert(resetSignals, {
                path   = ch.path,
                before = ch.bv,
                after  = ch.av,
                reset  = true,
            })
        end
    end

    return {
        responses    = responses,
        deltas       = deltas,
        resetSignals = resetSignals,
        elapsed      = (tick()-t0)*1000,
        reinitLikely = #responses > 2 or #resetSignals > 0,
    }
end

local function snapshotStats()
    local s = {}
    local function cap(parent, prefix)
        if not parent then return end
        local ok, ch = pcall(function() return parent:GetChildren() end)
        if not ok then return end
        for _, v in ipairs(ch) do
            local ok2, val = pcall(function() return v.Value end)
            if ok2 and type(val) == "number" then
                s[prefix.."."..v.Name] = val
            end
        end
    end
    cap(LP:FindFirstChild("leaderstats"), "leaderstats")
    cap(LP, "player")
    return s
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SCRIPTTOGGLE PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_ST = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- topbar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_ST)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="SCRIPTTOGGLE — DISABLED SCRIPT TOGGLE",
    TextColor3=Color3.fromRGB(255,160,40),TextSize=11,
    Size=UDim2.new(0,330,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local ST_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,-344,1,0),Position=UDim2.new(0,340,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- control bar
local CTRLBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,0,30),ZIndex=4},P_ST)
stroke(C.BORDER,1,CTRLBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=4},CTRLBAR)

local function mkBtn(txt,col,x)
    local b=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=col,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text=txt,
        TextColor3=Color3.fromRGB(8,8,12),TextSize=9,
        Size=UDim2.new(0,0,0,22),AutomaticSize=Enum.AutomaticSize.X,
        Position=UDim2.new(0,x,0.5,-11),ZIndex=5},CTRLBAR)
    corner(5,b)
    mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},b)
    return b
end

local DISC_BTN  = mkBtn("Discover Scripts", Color3.fromRGB(80,140,255),  8)
local SURF_A    = mkBtn("Surface A: Direct",Color3.fromRGB(255,160,40),  158)
local SURF_B    = mkBtn("Surface B: Name",  Color3.fromRGB(255,120,40),  292)
local SURF_C    = mkBtn("Surface C: Reload",Color3.fromRGB(255,80,80),   416)
local STOP_BTN  = mkBtn("Stop",             Color3.fromRGB(60,15,15),    538)
STOP_BTN.TextColor3=Color3.fromRGB(255,80,80)
stroke(Color3.fromRGB(255,80,80),1,STOP_BTN)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,62),Size=UDim2.new(1,0,1,-62),ZIndex=3},P_ST)

-- left: script list + findings
local SL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},SL)
local LEFT_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},SL)
pad(6,8,LEFT_SCROLL); listV(LEFT_SCROLL,5)

local LEFT_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Run Discover Scripts to\nscan for accessible Script\ninstances visible from\nthe client.",
    TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
    Size=UDim2.new(1,0,0,60),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LEFT_SCROLL)

-- right: log
local SR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,241,0,0),Size=UDim2.new(1,-241,1,0),ZIndex=3},BODY)
local PROG_BG=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,3),ZIndex=5},SR)
local PROG_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,160,40),
    BorderSizePixel=0,Size=UDim2.new(0,0,1,0),ZIndex=6},PROG_BG)
corner(2,PROG_BAR)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,3),Size=UDim2.new(1,0,1,-3),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},SR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="SCRIPTTOGGLE hunts the Disabled toggle vector.\n\n"..
         "When Script.Disabled flips false, the script\n"..
         "re-executes from the top. Three surfaces:\n\n"..
         "A — Direct instance setter\n"..
         "   Client passes Script instance + Disabled + false\n"..
         "   to a remote that sets it directly.\n\n"..
         "B — Name/path toggle\n"..
         "   Remote accepts a script name string and\n"..
         "   enables it server-side by name.\n\n"..
         "C — Config inject + reload trigger\n"..
         "   Client writes config, then triggers a\n"..
         "   system reload, causing scripts to re-run\n"..
         "   with client-controlled startup data.\n\n"..
         "Detection: duplicate init events, state resets,\n"..
         "and behavioral changes after toggle attempts.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,230),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- log helpers
local sN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; sN=sN+1; mkRow(tag,msg,detail,hi,LOG_SCROLL,sN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) sN=sN+1; mkSep(txt,LOG_SCROLL,sN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    sN=0; LOG_EMPTY.Visible=true
    tw(PROG_BAR,TI.fast,{Size=UDim2.new(0,0,1,0)})
end

-- state
local running         = false
local aborted         = false
local discoveredScripts = {}
local selScript       = nil
local ST_RESULTS      = {}

STOP_BTN.MouseButton1Click:Connect(function()
    aborted=true; running=false
    ST_STATUS.Text="stopped"; ST_STATUS.TextColor3=C.MUTED
end)

-- collect remotes
local function collectRemotes(limit)
    local remotes={}
    local map=G.DISCOVERY_MAP
    if map then
        for _,r in ipairs(map.remoteEvents or {}) do
            if r.instance then table.insert(remotes,r.instance) end
        end
        for _,r in ipairs(map.remoteFunctions or {}) do
            if r.instance then table.insert(remotes,r.instance) end
        end
    end
    if #remotes==0 then
        local function sc(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return end
            for _,x in ipairs(d) do
                if x:IsA("RemoteEvent") or x:IsA("RemoteFunction") then
                    table.insert(remotes,x)
                end
            end
        end
        sc(RepS); sc(game.Workspace)
    end
    if limit then
        local cut={}
        for i=1,math.min(limit,#remotes) do table.insert(cut,remotes[i]) end
        return cut
    end
    return remotes
end

-- rebuild left panel
local function rebuildScriptList()
    for _,c in ipairs(LEFT_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    LEFT_EMPTY.Visible = #discoveredScripts == 0

    for i, script in ipairs(discoveredScripts) do
        local isSel = selScript == script
        local col2  = script.disabled == true  and Color3.fromRGB(255,160,40) or
                      script.class=="Script"    and Color3.fromRGB(80,140,255) or
                      C.MUTED

        local card=mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=isSel and Color3.fromRGB(18,14,5) or C.CARD,
            BorderSizePixel=0,Text="",
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=i},LEFT_SCROLL)
        corner(5,card); stroke(col2,1,card); pad(8,5,card); listV(card,3)

        local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,15),ZIndex=5,LayoutOrder=1},card)
        listH(hrow,5)

        -- Class badge
        local clsBadge=mk("Frame",{BackgroundColor3=col2,BorderSizePixel=0,
            Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
        corner(3,clsBadge)
        mk("UIPadding",{PaddingLeft=UDim.new(0,3),PaddingRight=UDim.new(0,3)},clsBadge)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=script.class:sub(1,1),  -- "S", "L", "M"
            TextColor3=Color3.fromRGB(8,8,12),TextSize=8,
            Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},clsBadge)

        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=script.name,TextColor3=isSel and col2 or C.TEXT,TextSize=9,
            Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=6,LayoutOrder=2},hrow)

        -- Disabled indicator
        if script.disabled == true then
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                Text="DISABLED",TextColor3=Color3.fromRGB(255,160,40),TextSize=7,
                Size=UDim2.new(0,52,1,0),TextXAlignment=Enum.TextXAlignment.Right,
                ZIndex=6,LayoutOrder=3},hrow)
        end

        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=script.path:sub(1,40),TextColor3=C.MUTED,TextSize=7,TextWrapped=true,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},card)

        local capturedScript = script
        card.MouseButton1Click:Connect(function()
            selScript = capturedScript
            rebuildScriptList()
            ST_STATUS.Text="selected: "..script.name
            ST_STATUS.TextColor3=Color3.fromRGB(255,160,40)
        end)
    end
end

-- ── DISCOVER SCRIPTS ──────────────────────────────────────────────────────────
DISC_BTN.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog()
    tw(DISC_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(20,40,80)})
    ST_STATUS.Text="discovering..."
    ST_STATUS.TextColor3=Color3.fromRGB(80,140,255)

    addLogSep("SCRIPT DISCOVERY — scanning accessible containers")
    task.spawn(function()
        discoveredScripts = discoverAccessibleScripts()

        local disabledCount = 0
        local scriptCount   = 0
        for _, s in ipairs(discoveredScripts) do
            if s.class == "Script" then scriptCount = scriptCount + 1 end
            if s.disabled == true  then disabledCount = disabledCount + 1 end
        end

        rebuildScriptList()

        addLog("INFO",
            ("Found %d script(s) — %d disabled, %d Script class"):format(
                #discoveredScripts, disabledCount, scriptCount),
            "Disabled scripts are the highest-priority toggle targets")

        for _, s in ipairs(discoveredScripts) do
            addLog(s.disabled and "FINDING" or "INFO",
                ("[%s] %s%s"):format(
                    s.class, s.name,
                    s.disabled and " — DISABLED" or ""),
                s.path,
                s.disabled == true)
        end

        addLogSep(("DISCOVERY COMPLETE — %d script(s)"):format(#discoveredScripts))
        ST_STATUS.Text=#discoveredScripts.." script(s) found"
        ST_STATUS.TextColor3=Color3.fromRGB(255,160,40)
        tw(DISC_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,140,255)})
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        running=false
    end)
end)

-- ── SURFACE A: DIRECT INSTANCE SETTER ─────────────────────────────────────────
SURF_A.MouseButton1Click:Connect(function()
    if running then return end
    if #discoveredScripts == 0 then
        addLog("INFO","Run Discover Scripts first","Need script instances to probe")
        return
    end

    running=true; aborted=false
    clearLog()
    tw(SURF_A,TI.fast,{BackgroundColor3=Color3.fromRGB(80,50,10)})
    ST_STATUS.Text="Surface A: direct..."
    ST_STATUS.TextColor3=Color3.fromRGB(255,160,40)

    local remotes  = collectRemotes(12)
    -- Target disabled scripts first; also all Script class instances
    local targets = {}
    for _, s in ipairs(discoveredScripts) do
        if s.disabled == true or s.class == "Script" then
            table.insert(targets, s)
        end
        if #targets >= 8 then break end
    end
    if #targets == 0 then targets = discoveredScripts end

    addLogSep(("SURFACE A — %d script target(s) x %d remote(s)"):format(
        #targets, #remotes))
    addLog("INFO",
        "Testing: remote:FireServer(scriptInstance, 'Disabled', false)",
        "Also testing 5 other payload formats per remote x script combination")

    task.spawn(function()
        local total  = #targets * #remotes
        local count  = 0
        local allRemoteEvents = {}
        local function scanRE(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return end
            for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(allRemoteEvents,x) end end
        end
        scanRE(RepS); scanRE(game.Workspace)

        for _, target in ipairs(targets) do
            if aborted then break end
            for _, remote in ipairs(remotes) do
                if aborted then break end
                count = count + 1
                tw(PROG_BAR,TI.fast,{Size=UDim2.new(count/total,0,1,0)})
                ST_STATUS.Text=("A: %s via %s"):format(target.name, remote.Name)

                local payloads = buildDirectPayloads(
                    target.instance, "Disabled", false)

                for _, payload in ipairs(payloads) do
                    task.wait(0.03)
                    local before  = snap()
                    local beforeStats = snapshotStats()
                    for k in pairs(rlog) do rlog[k]=nil end
                    local conns = hookR(allRemoteEvents)

                    local ok = pcall(function()
                        if remote:IsA("RemoteFunction") then
                            remote:InvokeServer(table.unpack(payload.args))
                        else
                            remote:FireServer(table.unpack(payload.args))
                        end
                    end)

                    task.wait(0.3)
                    local after = snap()
                    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
                    local responses={}
                    for _,r in ipairs(rlog) do table.insert(responses,r) end
                    for k in pairs(rlog) do rlog[k]=nil end

                    local deltas = dif(before,after)
                    local score  = #responses*3 + #deltas*4

                    if score >= 4 then
                        local finding = {
                            surface   = "A",
                            remote    = remote.Name,
                            script    = target.name,
                            payload   = payload.tag,
                            score     = score,
                            responses = #responses,
                            deltas    = deltas,
                        }
                        table.insert(ST_RESULTS, finding)
                        addLog("FINDING",
                            ("Surface A hit: %s disabled %s"):format(
                                remote.Name, target.name),
                            ("Payload: %s  Score: %d  Responses: %d"):format(
                                payload.tag, score, #responses),
                            true)
                        for _,ch in ipairs(deltas) do
                            addLog(ch.bad and "PATHOLOG" or "DELTA",
                                ch.path, ch.bv.." -> "..ch.av, true)
                        end
                    end
                end
            end
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        local found = 0
        for _,r in ipairs(ST_RESULTS) do if r.surface=="A" then found=found+1 end end
        addLogSep(("SURFACE A COMPLETE — %d finding(s)"):format(found))
        ST_STATUS.Text=found>0 and ("A: "..found.." finding(s)") or "A: nothing found"
        ST_STATUS.TextColor3=found>0 and Color3.fromRGB(255,160,40) or C.MUTED
        tw(SURF_A,TI.fast,{BackgroundColor3=Color3.fromRGB(255,160,40)})
        running=false
    end)
end)

-- ── SURFACE B: NAME/PATH TOGGLE ────────────────────────────────────────────────
SURF_B.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog()
    tw(SURF_B,TI.fast,{BackgroundColor3=Color3.fromRGB(80,40,10)})
    ST_STATUS.Text="Surface B: name toggle..."
    ST_STATUS.TextColor3=Color3.fromRGB(255,120,40)

    local remotes = collectRemotes(12)

    -- Build name list: discovered script names + common names
    local names = {}
    local namesSeen = {}
    for _, s in ipairs(discoveredScripts) do
        if not namesSeen[s.name] then
            namesSeen[s.name] = true
            table.insert(names, s.name)
        end
    end
    for _, n in ipairs(COMMON_SCRIPT_NAMES) do
        if not namesSeen[n] then
            namesSeen[n] = true
            table.insert(names, n)
        end
    end

    addLogSep(("SURFACE B — %d name(s) x %d remote(s)"):format(
        #names, #remotes))
    addLog("INFO",
        "Testing: remote:FireServer({action='enableScript', name=scriptName})",
        "Tries 12 payload formats per remote x script name combination")

    task.spawn(function()
        local total  = #names * #remotes
        local count  = 0
        local allRE  = {}
        local function scanRE(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return end
            for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(allRE,x) end end
        end
        scanRE(RepS); scanRE(game.Workspace)

        for _, name in ipairs(names) do
            if aborted then break end
            for _, remote in ipairs(remotes) do
                if aborted then break end
                count = count + 1
                tw(PROG_BAR,TI.fast,{Size=UDim2.new(count/total,0,1,0)})
                ST_STATUS.Text=("B: %s via %s"):format(name, remote.Name)

                local payloads = buildNamePayloads(name)

                for _, payload in ipairs(payloads) do
                    task.wait(0.03)
                    local before = snap()
                    for k in pairs(rlog) do rlog[k]=nil end
                    local conns  = hookR(allRE)

                    local ok = pcall(function()
                        if remote:IsA("RemoteFunction") then
                            remote:InvokeServer(table.unpack(payload.args))
                        else
                            remote:FireServer(table.unpack(payload.args))
                        end
                    end)

                    task.wait(0.5)
                    local after = snap()
                    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
                    local responses={}
                    for _,r in ipairs(rlog) do table.insert(responses,r) end
                    for k in pairs(rlog) do rlog[k]=nil end

                    local deltas = dif(before, after)
                    local score  = #responses*3 + #deltas*4

                    if score >= 4 then
                        table.insert(ST_RESULTS,{
                            surface="B", remote=remote.Name,
                            script=name, payload=payload.tag,
                            score=score, responses=#responses, deltas=deltas,
                        })
                        addLog("FINDING",
                            ("Surface B hit: %s enabled '%s'"):format(
                                remote.Name, name),
                            ("Payload: %s  Score: %d"):format(payload.tag, score),
                            true)
                    end
                end
            end
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        local found=0
        for _,r in ipairs(ST_RESULTS) do if r.surface=="B" then found=found+1 end end
        addLogSep(("SURFACE B COMPLETE — %d finding(s)"):format(found))
        ST_STATUS.Text=found>0 and ("B: "..found.." finding(s)") or "B: nothing found"
        ST_STATUS.TextColor3=found>0 and Color3.fromRGB(255,120,40) or C.MUTED
        tw(SURF_B,TI.fast,{BackgroundColor3=Color3.fromRGB(255,120,40)})
        running=false
    end)
end)

-- ── SURFACE C: CONFIG INJECT + RELOAD ─────────────────────────────────────────
SURF_C.MouseButton1Click:Connect(function()
    if running then return end
    running=true; aborted=false
    clearLog()
    tw(SURF_C,TI.fast,{BackgroundColor3=Color3.fromRGB(80,20,20)})
    ST_STATUS.Text="Surface C: reload..."
    ST_STATUS.TextColor3=Color3.fromRGB(255,80,80)

    local remotes = collectRemotes(12)
    local allRE   = {}
    local function scanRE(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(allRE,x) end end
    end
    scanRE(RepS); scanRE(game.Workspace)

    addLogSep(("SURFACE C — reload trigger probe on %d remote(s)"):format(#remotes))
    addLog("INFO",
        "Testing: reload/restart/reinit payloads then watching for reinit signals",
        "Detection: duplicate init events, state resets, behavioral changes")

    -- Capture baseline event signatures BEFORE any trigger
    local eventBaseline = {}
    local watchConns    = {}
    for _, r in ipairs(allRE) do
        local ok, conn = pcall(function()
            return r.OnClientEvent:Connect(function(...)
                local sig = r.Name..":"..vs({...}):sub(1,30)
                eventBaseline[sig] = (eventBaseline[sig] or 0) + 1
            end)
        end)
        if ok then table.insert(watchConns, conn) end
    end
    task.wait(1)  -- 1s baseline window
    for _,c in ipairs(watchConns) do pcall(function() c:Disconnect() end) end

    task.spawn(function()
        local total = #remotes * #RELOAD_PAYLOADS
        local count = 0

        for _, remote in ipairs(remotes) do
            if aborted then break end
            for _, payload in ipairs(RELOAD_PAYLOADS) do
                if aborted then break end
                count = count + 1
                tw(PROG_BAR,TI.fast,{Size=UDim2.new(count/total,0,1,0)})
                ST_STATUS.Text=("C: %s [%s]"):format(remote.Name, payload.tag)

                -- Track events fired in the reinit window
                local eventsFired = {}
                local triggerConns = {}
                for _, r in ipairs(allRE) do
                    local ok, conn = pcall(function()
                        return r.OnClientEvent:Connect(function(...)
                            local sig = r.Name..":"..vs({...}):sub(1,30)
                            table.insert(eventsFired, {
                                name=r.Name, sig=sig,
                                duplicate=eventBaseline[sig] ~= nil,
                            })
                        end)
                    end)
                    if ok then table.insert(triggerConns, conn) end
                end

                local before = snap()
                pcall(function()
                    if remote:IsA("RemoteFunction") then
                        remote:InvokeServer(table.unpack(payload.args))
                    else
                        remote:FireServer(table.unpack(payload.args))
                    end
                end)

                task.wait(REINIT_WINDOW_MS/1000)
                for _,c in ipairs(triggerConns) do pcall(function() c:Disconnect() end) end
                local after = snap()

                -- Score: duplicate events are the strongest signal
                local duplicateCount = 0
                for _, ev in ipairs(eventsFired) do
                    if ev.duplicate then duplicateCount = duplicateCount + 1 end
                end

                local deltas = dif(before, after)
                -- Look for resets (values going DOWN)
                local resetCount = 0
                for _, ch in ipairs(deltas) do
                    local b = tonumber(ch.bv)
                    local a = tonumber(ch.av)
                    if b and a and b > 10 and a < b * 0.5 then
                        resetCount = resetCount + 1
                    end
                end

                local score = duplicateCount*8 + resetCount*5 + #deltas*2

                if score >= 5 then
                    table.insert(ST_RESULTS,{
                        surface="C", remote=remote.Name,
                        payload=payload.tag, score=score,
                        duplicates=duplicateCount, resets=resetCount,
                        deltas=deltas,
                    })
                    addLog("FINDING",
                        ("Surface C: reload trigger on %s"):format(remote.Name),
                        ("Payload: %s  Score: %d  Duplicate events: %d  State resets: %d"):format(
                            payload.tag, score, duplicateCount, resetCount),
                        true)
                    for _,ch in ipairs(deltas) do
                        if tonumber(ch.bv) and tonumber(ch.av) then
                            local bnum = tonumber(ch.bv) or 0
                            local anum = tonumber(ch.av) or 0
                            if anum < bnum*0.5 then
                                addLog("DELTA",
                                    "RESET: "..ch.path,
                                    ch.bv.." -> "..ch.av.." (script re-init resets this value)",
                                    true)
                            end
                        end
                    end
                end
            end
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        local found=0
        for _,r in ipairs(ST_RESULTS) do if r.surface=="C" then found=found+1 end end
        addLogSep(("SURFACE C COMPLETE — %d finding(s)"):format(found))
        ST_STATUS.Text=found>0 and ("C: "..found.." finding(s)") or "C: nothing found"
        ST_STATUS.TextColor3=found>0 and Color3.fromRGB(255,80,80) or C.MUTED
        tw(SURF_C,TI.fast,{BackgroundColor3=Color3.fromRGB(255,80,80)})
        running=false
    end)
end)

-- export
G.ST_RESULTS        = ST_RESULTS
G.st_discoverScripts = discoverAccessibleScripts

if G.addTab then
    G.addTab("scripttoggle","ScriptToggle",P_ST)
else
    warn("[Oracle] G.addTab not found")
end
