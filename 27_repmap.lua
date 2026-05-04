-- Oracle // 27_repmap.lua
-- REPMAP — Replication Surface Mapper
-- Maps every property replication direction and latency
-- Identifies physics/property seams · Differential window measurement
-- Client→Server replication surface · FE manipulation surfaces
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

local RS     = game:GetService("RunService")
local Players= game:GetService("Players")
local PhySvc = game:GetService("PhysicsService")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- REPMAP ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Replication directions
local DIR = {
    S2C      = "S2C",       -- Server to client only
    C2S      = "C2S",       -- Client to server (replicates up)
    BOTH     = "BOTH",      -- Bidirectional
    LOCAL    = "LOCAL",     -- No replication, stays local
    PHYSICS  = "PHYSICS",   -- Physics engine handles it
    UNKNOWN  = "UNKNOWN",
}

-- Property map — what we know about each property's replication behavior
-- format: {class, property, dir, notes}
local KNOWN_PROPS = {
    -- Humanoid — the most important seam
    {c="Humanoid", p="Health",         dir=DIR.BOTH,
     note="Server authoritative but client can write — sync delay exploitable"},
    {c="Humanoid", p="MaxHealth",      dir=DIR.S2C,
     note="Server sets, client reads"},
    {c="Humanoid", p="WalkSpeed",      dir=DIR.S2C,
     note="Server authoritative — client write snaps back"},
    {c="Humanoid", p="JumpPower",      dir=DIR.S2C,
     note="Server authoritative — client write snaps back"},
    {c="Humanoid", p="JumpHeight",     dir=DIR.S2C,
     note="Server authoritative"},
    {c="Humanoid", p="MoveDirection",  dir=DIR.C2S,
     note="CLIENT AUTHORITATIVE — computed from input, replicated up"},
    {c="Humanoid", p="AutoRotate",     dir=DIR.BOTH,
     note="Writable both sides"},
    {c="Humanoid", p="PlatformStand",  dir=DIR.C2S,
     note="CLIENT AUTHORITATIVE — triggers physics state change"},
    {c="Humanoid", p="Sit",            dir=DIR.BOTH,
     note="Partially client writable — seat detection server-side"},
    {c="Humanoid", p="DisplayDistanceType", dir=DIR.S2C,  note=""},
    -- HumanoidRootPart / BasePart physics
    {c="BasePart",  p="CFrame",        dir=DIR.PHYSICS,
     note="PHYSICS AUTHORITATIVE — replicates from owner"},
    {c="BasePart",  p="Velocity",      dir=DIR.PHYSICS,
     note="PHYSICS AUTHORITATIVE — replicates from owner"},
    {c="BasePart",  p="RotVelocity",   dir=DIR.PHYSICS,
     note="PHYSICS AUTHORITATIVE — replicates from owner"},
    {c="BasePart",  p="Position",      dir=DIR.PHYSICS,
     note="Computed from CFrame — physics path"},
    {c="BasePart",  p="Anchored",      dir=DIR.S2C,
     note="Server sets — affects physics ownership"},
    {c="BasePart",  p="CanCollide",    dir=DIR.S2C,    note=""},
    {c="BasePart",  p="Transparency",  dir=DIR.S2C,    note=""},
    {c="BasePart",  p="Color",         dir=DIR.S2C,    note=""},
    {c="BasePart",  p="Material",      dir=DIR.S2C,    note=""},
    -- Motor6D — animation replication surface
    {c="Motor6D",   p="Transform",     dir=DIR.C2S,
     note="CLIENT AUTHORITATIVE — drives visual pose, tool aim direction"},
    {c="Motor6D",   p="CurrentAngle",  dir=DIR.C2S,    note="Animation driven"},
    -- Character
    {c="Model",     p="PrimaryPart",   dir=DIR.S2C,    note=""},
    -- Tool
    {c="Tool",      p="Enabled",       dir=DIR.BOTH,   note="Partially writable"},
    {c="Tool",      p="RequiresHandle",dir=DIR.S2C,    note=""},
    -- Sound (on character — replicates)
    {c="Sound",     p="Playing",       dir=DIR.C2S,
     note="CLIENT AUTHORITATIVE when parented to character"},
    {c="Sound",     p="Volume",        dir=DIR.C2S,    note=""},
    -- Animations
    {c="Animation", p="AnimationId",   dir=DIR.C2S,
     note="CLIENT AUTHORITATIVE — plays on other clients"},
    -- Value objects
    {c="IntValue",  p="Value",         dir=DIR.S2C,
     note="Usually server-set — check per game"},
    {c="StringValue",p="Value",        dir=DIR.S2C,    note=""},
    {c="BoolValue", p="Value",         dir=DIR.S2C,    note=""},
}

-- Per-property measurement results
local MEASUREMENTS = {}   -- [class.property] = {latency, confirmed_dir, snapback}
local OWNERSHIP    = {}   -- part instances we've tested ownership on
local DIFF_WINDOWS = {}   -- measured differential windows

-- ── Replication latency probe ─────────────────────────────────────────────────
-- Writes a property locally and measures how long before it snaps back
-- (snaps back = server authority; stays = client authority)
local function probeProperty(instance, property, testValue, originalValue)
    if not instance or not instance.Parent then return nil end

    local before = tick()
    local ok = pcall(function() instance[property] = testValue end)
    if not ok then return {writable=false} end

    -- Poll for snapback
    local snapBackMs = nil
    local stayed     = false
    for i=1,40 do  -- 40 * 25ms = 1 second
        task.wait(0.025)
        local ok2,cur = pcall(function() return instance[property] end)
        if ok2 then
            local curStr = vs(cur)
            local origStr = vs(originalValue)
            if curStr == origStr then
                snapBackMs = (tick()-before)*1000
                break
            end
        end
    end

    if not snapBackMs then
        -- Didn't snap back — either client authoritative or change wasn't significant
        stayed = true
    end

    -- Restore
    pcall(function() instance[property] = originalValue end)

    return {
        writable   = true,
        snapBackMs = snapBackMs,
        stayed     = stayed,
        direction  = stayed and DIR.C2S or DIR.S2C,
        evidence   = stayed and
            "Value persisted for >1s — likely client authoritative" or
            ("Snapped back in %.0fms — server authoritative"):format(snapBackMs or 0),
    }
end

-- ── Network ownership measurement ────────────────────────────────────────────
local function measureOwnership(part, logFn)
    if not part then return nil end

    local result = {
        part        = part.Name,
        path        = part:GetFullName(),
        currentOwner= nil,
        canRequest  = false,
        requestLatency = nil,
        physicsRepl    = false,
    }

    -- Check current owner
    local ok, owner = pcall(function()
        return part:GetNetworkOwner()
    end)
    if ok then
        result.currentOwner = owner and owner.Name or "Server"
    end

    -- Try to request ownership
    local t0 = tick()
    local ok2, err = pcall(function()
        part:SetNetworkOwner(LP)
    end)
    if ok2 then
        result.canRequest   = true
        result.requestLatency = (tick()-t0)*1000
        -- Measure how long ownership lasts before server reclaims
        task.spawn(function()
            task.wait(0.5)
            local ok3, newOwner = pcall(function()
                return part:GetNetworkOwner()
            end)
            if ok3 then
                local ownerName = newOwner and newOwner.Name or "Server"
                result.ownershipDuration = ownerName == LP.Name and ">500ms" or "<500ms"
                if logFn then
                    logFn(result.canRequest and "FINDING" or "INFO",
                        ("Ownership: %s → %s"):format(part.Name, ownerName),
                        ("Requested: %.0fms  Duration: %s"):format(
                            result.requestLatency, result.ownershipDuration or "?"),
                        result.canRequest)
                end
            end
            -- Restore server ownership
            pcall(function() part:SetNetworkOwnershipAuto() end)
        end)
    else
        result.canRequest = false
        if logFn then
            logFn("INFO",("Ownership request denied: %s"):format(part.Name),
                tostring(err):sub(1,60))
        end
    end

    return result
end

-- ── Differential window measurement ──────────────────────────────────────────
-- Measures the gap between when a property changes on the server
-- and when each observable client-side signal reflects it
local function measureDifferentialWindow(instance, property, logFn)
    if not instance then return nil end

    local result = {
        property   = property,
        instance   = instance.Name,
        windowMs   = 0,
        samples    = {},
    }

    -- Hook the property changed signal
    local changeOk, changeConn = pcall(function()
        return instance:GetPropertyChangedSignal(property):Connect(function()
            table.insert(result.samples, {
                time     = tick(),
                value    = vs(pcall(function() return instance[property] end) and
                    instance[property] or "?"),
            })
        end)
    end)

    if not changeOk then
        if logFn then logFn("INFO",
            "Cannot hook "..property.." on "..instance.Name) end
        return nil
    end

    -- Watch for 3 seconds
    task.wait(3)
    pcall(function() changeConn:Disconnect() end)

    if #result.samples < 2 then
        result.windowMs = 0
        if logFn then
            logFn("INFO",
                ("Differential: %s.%s"):format(instance.Name, property),
                "Insufficient samples — property rarely changes")
        end
        return result
    end

    -- Compute intervals between changes
    local intervals = {}
    for i=2,#result.samples do
        table.insert(intervals, (result.samples[i].time - result.samples[i-1].time)*1000)
    end
    local sum=0; for _,v in ipairs(intervals) do sum+=v end
    result.windowMs = sum / #intervals

    if logFn then
        logFn("FINDING",
            ("Differential window: %s.%s = %.0fms"):format(
                instance.Name, property, result.windowMs),
            ("Samples: %d  Change rate: %.0fms avg"):format(
                #result.samples, result.windowMs),
            result.windowMs < 100)
    end

    return result
end

-- ── Seam finder ───────────────────────────────────────────────────────────────
-- Finds properties where physics authority and property authority diverge
-- These are the manipulation surfaces
local function findSeams(character, logFn)
    if not character then
        if logFn then logFn("INFO","No character — spawn in-game first") end
        return {}
    end

    local seams = {}
    local hrp   = character:FindFirstChild("HumanoidRootPart")
    local hum   = character:FindFirstChildOfClass("Humanoid")

    -- Test 1: Can we write HRP CFrame? (Should be physics authoritative)
    if hrp then
        local origCF = hrp.CFrame
        local testCF = origCF * CFrame.new(0, 0.01, 0)  -- tiny move
        local result = probeProperty(hrp, "CFrame", testCF, origCF)
        if result and result.stayed then
            table.insert(seams, {
                class   = "HumanoidRootPart",
                property= "CFrame",
                finding = "Client can write CFrame — physics authority confirmed",
                level   = "PHYSICS",
                exploit = "Incremental teleport within kinematic plausibility window",
            })
            if logFn then
                logFn("FINDING","HRP.CFrame — client writable",
                    "Physics authority active — incremental manipulation possible",true)
            end
        end
    end

    -- Test 2: Humanoid.Health write + measure snapback timing
    if hum then
        local origHP = hum.Health
        local result = probeProperty(hum, "Health", math.min(origHP+1, hum.MaxHealth), origHP)
        if result and result.snapBackMs then
            table.insert(seams, {
                class    = "Humanoid",
                property = "Health",
                finding  = ("Health snaps back in %.0fms — window %.0fms"):format(
                    result.snapBackMs, result.snapBackMs * 0.8),
                level    = "WINDOW",
                windowMs = result.snapBackMs,
                exploit  = ("%.0fms window before server corrects"):format(
                    result.snapBackMs),
            })
            if logFn then
                logFn("INFO",
                    ("Health seam: %.0fms correction window"):format(result.snapBackMs),
                    "Client write is acknowledged before server correction")
            end
        end

        -- Test 3: PlatformStand — client authoritative
        local origPS = hum.PlatformStand
        local result3 = probeProperty(hum, "PlatformStand", not origPS, origPS)
        if result3 and result3.stayed then
            table.insert(seams, {
                class    = "Humanoid",
                property = "PlatformStand",
                finding  = "PlatformStand CLIENT AUTHORITATIVE",
                level    = "C2S",
                exploit  = "Toggle to enter ragdoll state without server permission",
            })
            if logFn then
                logFn("FINDING","PlatformStand — client authoritative",
                    "Server cannot override this without script",true)
            end
        end
    end

    -- Test 4: Motor6D transforms on character
    local foundMotor = false
    for _, desc in ipairs(character:GetDescendants()) do
        if desc:IsA("Motor6D") and not foundMotor then
            foundMotor = true
            local origT = desc.Transform
            local testT = origT * CFrame.Angles(0, 0.01, 0)
            local result4 = probeProperty(desc, "Transform", testT, origT)
            if result4 then
                table.insert(seams, {
                    class    = "Motor6D",
                    property = "Transform",
                    finding  = result4.stayed and
                        "Motor6D.Transform CLIENT AUTHORITATIVE" or
                        ("Motor6D.Transform snaps in %.0fms"):format(
                            result4.snapBackMs or 0),
                    level    = result4.stayed and "C2S" or "WINDOW",
                    exploit  = result4.stayed and
                        "Tool aim direction manipulation — affects server-side hit detection" or
                        ("%.0fms manipulation window per frame"):format(
                            result4.snapBackMs or 0),
                })
                if logFn then
                    logFn(result4.stayed and "FINDING" or "INFO",
                        "Motor6D.Transform — "..
                        (result4.stayed and "client authoritative" or
                        ("snaps in %.0fms"):format(result4.snapBackMs or 0)),
                        result4.evidence, result4.stayed)
                end
            end
            break
        end
    end

    -- Test 5: Network ownership of character parts
    if hrp then
        local ownerResult = measureOwnership(hrp, logFn)
        if ownerResult and ownerResult.canRequest then
            table.insert(seams, {
                class    = "HumanoidRootPart",
                property = "NetworkOwnership",
                finding  = "Can request network ownership of own HRP",
                level    = "OWNERSHIP",
                exploit  = "Extended ownership window allows larger position writes",
            })
        end
    end

    return seams
end

-- ── Replication rate probe ────────────────────────────────────────────────────
-- Measures how frequently a property actually updates from the network
local function probeReplicationRate(instance, property, durationSec, logFn)
    local changes  = 0
    local lastVal  = nil
    local deadline = tick() + durationSec

    local ok,conn = pcall(function()
        return instance:GetPropertyChangedSignal(property):Connect(function()
            changes += 1
            local ok2,v = pcall(function() return instance[property] end)
            lastVal = ok2 and v or nil
        end)
    end)
    if not ok then return nil end

    while tick() < deadline do task.wait(0.05) end
    pcall(function() conn:Disconnect() end)

    local hz = changes / durationSec
    if logFn then
        logFn("INFO",
            ("%s.%s — %.1f updates/sec over %.0fs"):format(
                instance.Name, property, hz, durationSec),
            ("Total changes: %d"):format(changes))
    end

    return {hz=hz, changes=changes, duration=durationSec}
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- REPMAP PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_REP = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- top bar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_REP)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⬡  REPMAP — REPLICATION SURFACE MAPPER",
    TextColor3=Color3.fromRGB(80,220,180),TextSize=11,
    Size=UDim2.new(0,320,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local REP_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,120,1,0),Position=UDim2.new(1,-380,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- button bar below topbar
local BTNBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,0,30),ZIndex=4},P_REP)
stroke(C.BORDER,1,BTNBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},BTNBAR)
pad(8,4,BTNBAR); listH(BTNBAR,6)

local function mkRBtn(txt,bg,bord)
    local b=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=bg,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text=txt,TextColor3=C.WHITE,TextSize=9,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=5},BTNBAR)
    corner(5,b); stroke(bord or bg,1,b)
    mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},b)
    return b
end

local SEAM_BTN = mkRBtn("⚡ Find Seams",Color3.fromRGB(30,90,70),  Color3.fromRGB(80,220,180))
local OWN_BTN  = mkRBtn("⬡ Ownership", Color3.fromRGB(30,60,90),  Color3.fromRGB(80,140,255))
local RATE_BTN = mkRBtn("⏱ Rep Rates", Color3.fromRGB(60,40,90),  Color3.fromRGB(168,120,255))
local FULL_BTN = mkRBtn("⬡ FULL",      Color3.fromRGB(80,220,180),Color3.fromRGB(80,220,180))
do tw(FULL_BTN,TI.fast,{TextColor3=Color3.fromRGB(8,8,12)}) end

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,62),Size=UDim2.new(1,0,1,-62),ZIndex=3},P_REP)

-- left: property map + seam list
local RL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},RL)

local MAP_HDR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,22),ZIndex=4},RL)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},MAP_HDR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="REPLICATION MAP",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5},MAP_HDR)

local MAP_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,22),Size=UDim2.new(1,0,1,-22),
    ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},RL)
pad(6,6,MAP_SCROLL); listV(MAP_SCROLL,3)

-- right: analysis log
local RR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,241,0,0),Size=UDim2.new(1,-241,1,0),ZIndex=3},BODY)

local PROG_BG=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,3),ZIndex=5},RR)
local PROG_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(80,220,180),
    BorderSizePixel=0,Size=UDim2.new(0,0,1,0),ZIndex=6},PROG_BG)
corner(2,PROG_BAR)

local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,3),Size=UDim2.new(1,0,1,-3),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},RR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="REPMAP systematically maps every\nreplication surface in the game.\n\n"..
         "⚡ Find Seams — probes your character for\n"..
         "   physics/property authority boundaries\n\n"..
         "⬡ Ownership — measures network ownership\n"..
         "   of all parts near you\n\n"..
         "⏱ Rep Rates — measures replication frequency\n"..
         "   for key character properties\n\n"..
         "⬡ FULL — runs all three in sequence",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,180),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- ── Log helpers ───────────────────────────────────────────────────────────────
local rN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; rN+=1; mkRow(tag,msg,detail,hi,LOG_SCROLL,rN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) rN+=1; mkSep(txt,LOG_SCROLL,rN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    rN=0; LOG_EMPTY.Visible=true
    tw(PROG_BAR,TI.fast,{Size=UDim2.new(0,0,1,0)})
end

-- ── Build static property map on left panel ───────────────────────────────────
local DIR_COL = {
    S2C     = Color3.fromRGB(80,140,255),
    C2S     = Color3.fromRGB(255,80,80),
    BOTH    = Color3.fromRGB(255,160,40),
    LOCAL   = C.MUTED,
    PHYSICS = Color3.fromRGB(80,220,180),
    UNKNOWN = C.MUTED,
}

local function buildStaticMap()
    for _,c in ipairs(MAP_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end

    local currentClass = nil
    local ord = 0

    for _, prop in ipairs(KNOWN_PROPS) do
        if prop.c ~= currentClass then
            currentClass = prop.c
            ord+=1
            local sep=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
                Size=UDim2.new(1,0,0,16),ZIndex=4,LayoutOrder=ord},MAP_SCROLL)
            mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
                Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,0.5,0),ZIndex=4},sep)
            local bg=mk("Frame",{BackgroundColor3=C.BG,BorderSizePixel=0,
                Size=UDim2.fromOffset(#prop.c*7+10,12),
                Position=UDim2.new(0,0,0.5,-6),ZIndex=5},sep)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text=prop.c,TextColor3=C.TEXT,TextSize=8,
                Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Center,
                ZIndex=6},bg)
        end

        ord+=1
        local col = DIR_COL[prop.dir] or C.MUTED
        local row=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=ord},MAP_SCROLL)
        listH(row,4)

        -- Direction badge
        local badge=mk("Frame",{BackgroundColor3=col,BorderSizePixel=0,
            Size=UDim2.new(0,0,0,14),AutomaticSize=Enum.AutomaticSize.X,
            ZIndex=5},row)
        corner(3,badge)
        mk("UIPadding",{PaddingLeft=UDim.new(0,3),PaddingRight=UDim.new(0,3)},badge)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=prop.dir,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
            Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},badge)

        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=prop.p,TextColor3=
                prop.dir==DIR.C2S and Color3.fromRGB(255,120,80) or
                prop.dir==DIR.PHYSICS and Color3.fromRGB(80,220,180) or
                C.MUTED,
            TextSize=9,
            Size=UDim2.new(1,-60,1,0),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5},row)

        -- Measurement overlay if available
        local key = prop.c.."."..prop.p
        local meas = MEASUREMENTS[key]
        if meas then
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                Text=meas.stayed and "✓C2S" or
                    (("%.0f"):format(meas.snapBackMs or 0).."ms"),
                TextColor3=meas.stayed and Color3.fromRGB(255,80,80) or C.MUTED,
                TextSize=8,Size=UDim2.new(0,40,1,0),
                TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},row)
        end
    end
end

-- ── Seam cards ────────────────────────────────────────────────────────────────
local SEAM_RESULTS = {}

local function addSeamCard(seam)
    local ord=#SEAM_RESULTS+100
    local levelCol
    if     seam.level=="C2S"       then levelCol=Color3.fromRGB(255,80,80)
    elseif seam.level=="PHYSICS"   then levelCol=Color3.fromRGB(80,220,180)
    elseif seam.level=="OWNERSHIP" then levelCol=Color3.fromRGB(168,120,255)
    elseif seam.level=="WINDOW"    then levelCol=Color3.fromRGB(255,160,40)
    else                                levelCol=C.MUTED end

    local card=mk("Frame",{BackgroundColor3=Color3.fromRGB(10,20,15),
        BorderSizePixel=0,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=ord},MAP_SCROLL)
    corner(6,card); stroke(levelCol,1,card); pad(8,6,card); listV(card,4)

    local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,15),ZIndex=5,LayoutOrder=1},card)
    listH(hrow,5)
    local badge=mk("Frame",{BackgroundColor3=levelCol,BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
    corner(3,badge); mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4)},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=seam.level,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=seam.class.."."..seam.property,
        TextColor3=levelCol,TextSize=10,
        Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=2},hrow)

    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=seam.finding,TextColor3=C.TEXT,TextSize=9,TextWrapped=true,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},card)

    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text="⚡ "..seam.exploit,
        TextColor3=Color3.fromRGB(255,175,70),TextSize=8,TextWrapped=true,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=3},card)
end

-- ── FIND SEAMS button ─────────────────────────────────────────────────────────
local scanning=false
SEAM_BTN.MouseButton1Click:Connect(function()
    if scanning then return end
    local ch = LP.Character
    if not ch then
        addLog("INFO","No character — spawn in a live game first"); return
    end
    scanning=true
    clearLog()
    tw(SEAM_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(10,40,30)})
    REP_STATUS.Text="scanning seams..."; REP_STATUS.TextColor3=Color3.fromRGB(80,220,180)
    addLogSep("SEAM DETECTION — "..LP.Name)

    task.spawn(function()
        local seams = findSeams(ch, addLog)
        SEAM_RESULTS = seams

        -- Add seam cards to left panel
        for _,seam in ipairs(seams) do
            addSeamCard(seam)
        end

        local c2sCount = 0
        for _,s in ipairs(seams) do
            if s.level=="C2S" or s.level=="PHYSICS" then c2sCount+=1 end
        end

        addLogSep(("SEAMS FOUND: %d  Client-authoritative: %d"):format(
            #seams, c2sCount))
        REP_STATUS.Text=c2sCount.." client-auth surfaces"
        REP_STATUS.TextColor3=c2sCount>0 and Color3.fromRGB(255,80,80) or C.MUTED
        tw(SEAM_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(30,90,70)})
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        scanning=false
    end)
end)

-- ── OWNERSHIP button ──────────────────────────────────────────────────────────
OWN_BTN.MouseButton1Click:Connect(function()
    if scanning then return end
    scanning=true
    clearLog()
    tw(OWN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(10,30,50)})
    REP_STATUS.Text="measuring ownership..."; REP_STATUS.TextColor3=Color3.fromRGB(80,140,255)
    addLogSep("NETWORK OWNERSHIP SCAN")

    task.spawn(function()
        local ch = LP.Character
        if not ch then
            addLog("INFO","No character — spawn in a live game first")
            scanning=false; return
        end

        -- Scan parts near the character
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        local parts = {}

        -- Own character parts
        for _,desc in ipairs(ch:GetDescendants()) do
            if desc:IsA("BasePart") then
                table.insert(parts,desc)
            end
        end

        -- Nearby workspace parts
        if hrp then
            for _,desc in ipairs(workspace:GetDescendants()) do
                if desc:IsA("BasePart") and desc ~= hrp then
                    local ok,dist=pcall(function()
                        return (desc.Position-hrp.Position).Magnitude
                    end)
                    if ok and dist < 50 then
                        table.insert(parts,desc)
                    end
                end
                if #parts > 30 then break end
            end
        end

        addLog("INFO",("Probing %d parts"):format(#parts))

        local owned=0; local total=#parts
        for i,part in ipairs(parts) do
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(i/total,0,1,0)})
            measureOwnership(part, addLog)
            task.wait(0.05)
        end

        addLogSep(("OWNERSHIP SCAN COMPLETE — %d parts"):format(total))
        REP_STATUS.Text="ownership scan done"
        REP_STATUS.TextColor3=Color3.fromRGB(80,140,255)
        tw(OWN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(30,60,90)})
        scanning=false
    end)
end)

-- ── REPLICATION RATES button ──────────────────────────────────────────────────
RATE_BTN.MouseButton1Click:Connect(function()
    if scanning then return end
    local ch = LP.Character
    if not ch then addLog("INFO","No character"); return end
    scanning=true
    clearLog()
    tw(RATE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(30,20,50)})
    REP_STATUS.Text="measuring rep rates..."; REP_STATUS.TextColor3=Color3.fromRGB(168,120,255)
    addLogSep("REPLICATION RATE MEASUREMENT — 3s window per property")

    task.spawn(function()
        local hum = ch:FindFirstChildOfClass("Humanoid")
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        local propsToRate = {}

        if hum then
            table.insert(propsToRate,{obj=hum,    prop="Health"})
            table.insert(propsToRate,{obj=hum,    prop="MoveDirection"})
            table.insert(propsToRate,{obj=hum,    prop="WalkSpeed"})
        end
        if hrp then
            table.insert(propsToRate,{obj=hrp,    prop="CFrame"})
            table.insert(propsToRate,{obj=hrp,    prop="Velocity"})
        end

        for i,entry in ipairs(propsToRate) do
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(i/#propsToRate,0,1,0)})
            REP_STATUS.Text="measuring "..entry.prop.."..."
            probeReplicationRate(entry.obj, entry.prop, 3, addLog)
        end

        addLogSep("RATE MEASUREMENT COMPLETE")
        REP_STATUS.Text="rates measured"
        REP_STATUS.TextColor3=Color3.fromRGB(168,120,255)
        tw(RATE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(60,40,90)})
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        scanning=false
    end)
end)

-- ── FULL button ───────────────────────────────────────────────────────────────
local fullRunning=false
FULL_BTN.MouseButton1Click:Connect(function()
    if fullRunning or scanning then return end
    fullRunning=true; scanning=true
    tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(30,80,60)})
    clearLog()
    REP_STATUS.Text="full analysis..."; REP_STATUS.TextColor3=Color3.fromRGB(80,220,180)

    local ch = LP.Character
    if not ch then
        addLog("INFO","No character — spawn in-game first")
        fullRunning=false; scanning=false; return
    end

    task.spawn(function()
        -- Phase 1: Seams
        addLogSep("PHASE 1 — SEAM DETECTION")
        local seams=findSeams(ch,addLog)
        SEAM_RESULTS=seams
        for _,seam in ipairs(seams) do addSeamCard(seam) end
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(0.33,0,1,0)})
        task.wait(0.5)

        -- Phase 2: Key property rates
        addLogSep("PHASE 2 — REPLICATION RATES")
        local hum=ch:FindFirstChildOfClass("Humanoid")
        local hrp=ch:FindFirstChild("HumanoidRootPart")
        if hum then probeReplicationRate(hum,"MoveDirection",2,addLog) end
        if hrp then probeReplicationRate(hrp,"CFrame",2,addLog) end
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(0.66,0,1,0)})
        task.wait(0.5)

        -- Phase 3: HRP ownership
        addLogSep("PHASE 3 — OWNERSHIP")
        if hrp then measureOwnership(hrp,addLog) end
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})

        -- Summary
        addLogSep("REPMAP COMPLETE")
        local c2s=0
        for _,s in ipairs(seams) do
            if s.level=="C2S" or s.level=="PHYSICS" then c2s+=1 end
        end
        addLog(c2s>0 and "FINDING" or "CLEAN",
            ("%d seam(s)  %d client-authoritative surface(s)"):format(#seams,c2s),
            c2s>0 and "Client-authoritative properties confirmed — see seam cards" or
            "No exploitable seams detected",c2s>0)

        buildStaticMap()
        REP_STATUS.Text=c2s.." C2S surfaces found"
        REP_STATUS.TextColor3=c2s>0 and Color3.fromRGB(255,80,80) or C.MUTED
        tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,220,180)})
        fullRunning=false; scanning=false
    end)
end)

-- Build static map on load
buildStaticMap()

-- Export
G.REPMAP_SEAMS   = SEAM_RESULTS
G.REPMAP_MEASURE = MEASUREMENTS
G.repmap_seams   = findSeams
G.repmap_ownership = measureOwnership

if G.addTab then
    G.addTab("repmap","REPMAP",P_REP)
else
    warn("[Oracle] G.addTab not found")
end
