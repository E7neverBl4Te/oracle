-- Oracle // 13_generator.lua
-- Script Generator — Dynamic Arg Generation
-- Write Lua that runs locally before fire · RSO-aware context · Live preview
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

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- GENERATOR ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Context table injected into every user script
-- Scripts access it as the global "Oracle"
local function buildContext(remoteName, callIndex)
    local ctx = {}

    -- RSO observation data
    ctx.rso = G.RSO_OBS or {}

    -- Convenience: top observed value for a remote arg
    ctx.topVal = function(remote, argIdx)
        local obs = ctx.rso[remote]
        if not obs or not obs.sig then return nil end
        local s = obs.sig.schema and obs.sig.schema[argIdx]
        if not s or not s.topVals or #s.topVals == 0 then return nil end
        return s.topVals[1].v
    end

    -- Live player state
    ctx.player    = LP
    ctx.userId    = LP.UserId
    ctx.name      = LP.Name
    ctx.character = LP.Character

    local ch = LP.Character
    if ch then
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        local hum = ch:FindFirstChildOfClass("Humanoid")
        ctx.position  = hrp and hrp.Position  or Vector3.new(0,0,0)
        ctx.cframe    = hrp and hrp.CFrame    or CFrame.new(0,0,0)
        ctx.health    = hum and hum.Health    or 0
        ctx.maxHealth = hum and hum.MaxHealth or 100
        ctx.walkSpeed = hum and hum.WalkSpeed or 16
        ctx.tool      = ch:FindFirstChildOfClass("Tool")
        ctx.toolName  = ctx.tool and ctx.tool.Name or nil
    else
        ctx.position  = Vector3.new(0,0,0)
        ctx.cframe    = CFrame.new(0,0,0)
        ctx.health    = 0
        ctx.maxHealth = 100
        ctx.walkSpeed = 16
        ctx.tool      = nil
        ctx.toolName  = nil
    end

    -- All players
    ctx.players = game:GetService("Players"):GetPlayers()
    ctx.nearestPlayer = function()
        if not ch then return nil end
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        if not hrp then return nil end
        local best, bestDist = nil, math.huge
        for _, p in ipairs(ctx.players) do
            if p ~= LP and p.Character then
                local oh = p.Character:FindFirstChild("HumanoidRootPart")
                if oh then
                    local d = (oh.Position - hrp.Position).Magnitude
                    if d < bestDist then best,bestDist=p,d end
                end
            end
        end
        return best
    end

    -- Call metadata
    ctx.callIndex  = callIndex  -- which repeat this is (1-based)
    ctx.tick       = tick()
    ctx.remoteName = remoteName
    ctx.placeId    = game.PlaceId
    ctx.jobId      = game.JobId

    -- Utility functions
    ctx.random = math.random
    ctx.rand   = function(min2, max2) return math.random(min2, max2) end
    ctx.lerp   = function(a, b, t) return a + (b-a)*t end
    ctx.v3     = function(x,y,z) return Vector3.new(x or 0,y or 0,z or 0) end
    ctx.cf     = function(x,y,z) return CFrame.new(x or 0,y or 0,z or 0) end
    ctx.NaN    = 0/0
    ctx.Inf    = math.huge

    return ctx
end

-- Execute a user script and return the payload
-- Script must return either:
--   A single value         → passed as one arg
--   A table with array part → unpacked as multiple args
--   nil                    → fires with no args (signal)
local function runGeneratorScript(src, remoteName, callIndex)
    local ctx    = buildContext(remoteName, callIndex)

    -- Wrap user script so it has access to Oracle context
    -- and standard globals
    local wrapped = [[
local Oracle = ...
local player    = Oracle.player
local character = Oracle.character
local position  = Oracle.position
local cframe    = Oracle.cframe
local health    = Oracle.health
local toolName  = Oracle.toolName
local tool      = Oracle.tool
local userId    = Oracle.userId
local name      = Oracle.name
local tick      = Oracle.tick
local callIndex = Oracle.callIndex
local rso       = Oracle.rso
local topVal    = Oracle.topVal
local players   = Oracle.players
local nearest   = Oracle.nearestPlayer
local NaN       = Oracle.NaN
local Inf       = Oracle.Inf
local v3        = Oracle.v3
local cf        = Oracle.cf
local rand      = Oracle.rand
]] .. "\n" .. src

    local fn, compileErr = loadstring(wrapped)
    if not fn then
        return nil, "Compile error: "..tostring(compileErr)
    end

    local ok, result = pcall(fn, ctx)
    if not ok then
        return nil, "Runtime error: "..tostring(result)
    end

    return result, nil
end

-- Fire the remote with generated payload
local function fireWithPayload(remoteName, payload, logFn, onComplete)
    -- Find remote
    local remote = nil
    local function sc(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do
            if (x:IsA("RemoteEvent") or x:IsA("RemoteFunction"))
            and x.Name==remoteName then remote=x; return end
        end
    end
    sc(RepS); if not remote then sc(workspace) end

    if not remote then
        logFn("INFO","Remote not found: "..remoteName)
        if onComplete then onComplete(false,{}) end
        return
    end

    -- Collect remotes for response watch
    local ev={}
    local function col(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(ev,x) end end
    end
    col(RepS); col(workspace)

    local before=snap()
    for k in pairs(rlog) do rlog[k]=nil end
    local conns=hookR(ev)

    -- Build args from payload
    local args={}
    if type(payload)=="table" then
        -- check if it's array-style (args to unpack) or a single table arg
        local isArray=true
        for k in pairs(payload) do
            if type(k)~="number" then isArray=false; break end
        end
        if isArray and #payload>0 then
            args=payload
        else
            args={payload}  -- single table arg
        end
    elseif payload~=nil then
        args={payload}
    end

    local ok2,err=pcall(function()
        if remote:IsA("RemoteEvent") then
            remote:FireServer(table.unpack(args))
        else
            remote:InvokeServer(table.unpack(args))
        end
    end)

    logFn(ok2 and "FIRED" or "INFO",
        remote.Name.." ← "..#args.." arg(s)",
        ok2 and nil or tostring(err))

    if not ok2 then
        for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        if onComplete then onComplete(false,{}) end
        return
    end

    task.wait(CFG.RW)
    local dl=tick()+CFG.WD
    while tick()<dl do task.wait(0.05); if #rlog>0 then break end end

    local after=snap()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end

    local hits={}
    for _,r in ipairs(rlog) do
        table.insert(hits,{type="response",name=r.name,args=r.args})
        logFn("RESPONSE","Server replied via "..r.name,r.args,true)
    end
    for k in pairs(rlog) do rlog[k]=nil end

    for _,ch in ipairs(dif(before,after)) do
        table.insert(hits,{type="delta",path=ch.path,bv=ch.bv,av=ch.av,bad=ch.bad})
        logFn(ch.bad and "PATHOLOG" or "DELTA",
            (ch.bad and "⚑ " or "")..ch.path,
            ch.bv.." → "..ch.av,true)
    end

    if #hits==0 then
        logFn("CLEAN","No observable server response")
    end

    if onComplete then onComplete(true,hits) end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- GENERATOR PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_GEN = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- top bar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_GEN)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)

mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⬡  SCRIPT GENERATOR",TextColor3=C.ACCENT,TextSize=11,
    Size=UDim2.new(0,180,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)

-- Remote input lives in the topbar — always visible, never covered
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="Remote",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,48,1,0),Position=UDim2.new(0,196,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local GEN_REMOTE=mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text=G.RBOX and G.RBOX.Text or "",
    PlaceholderText="remote name",
    PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,TextSize=10,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(0,180,0,22),Position=UDim2.new(0,246,0.5,-11),ZIndex=6},TOPBAR)
corner(5,GEN_REMOTE); stroke(C.BORDER,1,GEN_REMOTE); pad(6,0,GEN_REMOTE)

mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="×",TextColor3=C.MUTED,TextSize=11,
    Size=UDim2.new(0,14,1,0),Position=UDim2.new(0,430,0,0),
    TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5},TOPBAR)
local GEN_REPS=mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text="1",PlaceholderText="1",PlaceholderColor3=C.MUTED,
    TextColor3=C.WHITE,TextSize=10,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Center,
    Size=UDim2.new(0,30,0,22),Position=UDim2.new(0,446,0.5,-11),ZIndex=6},TOPBAR)
corner(4,GEN_REPS); stroke(C.BORDER,1,GEN_REPS)

local GEN_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,80,1,0),Position=UDim2.new(1,-158,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)
local RUN_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ACCENT,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="▶  RUN",
    TextColor3=C.WHITE,TextSize=10,
    Size=UDim2.new(0,64,0,22),Position=UDim2.new(1,-76,0.5,-11),
    ZIndex=6},TOPBAR)
corner(5,RUN_BTN)
do local base=C.ACCENT
    RUN_BTN.MouseEnter:Connect(function() tw(RUN_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    RUN_BTN.MouseLeave:Connect(function() tw(RUN_BTN,TI.fast,{BackgroundColor3=base}) end)
end

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_GEN)

-- ── Left: editor + controls ───────────────────────────────────────────────────
local GL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0.5,0,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,-20),Position=UDim2.new(0.5,0,0,10),ZIndex=4},BODY)

-- ── Code editor area ──────────────────────────────────────────────────────────
local EDITOR_AREA=mk("Frame",{BackgroundColor3=Color3.fromRGB(8,7,12),
    BorderSizePixel=0,
    Position=UDim2.new(0,0,0,0),Size=UDim2.new(1,0,1,-182),
    ClipsDescendants=true,ZIndex=4},GL)
stroke(C.BORDER,1,EDITOR_AREA)

-- Line numbers column
local LINE_COL=mk("Frame",{BackgroundColor3=Color3.fromRGB(12,10,18),
    BorderSizePixel=0,Size=UDim2.new(0,28,1,0),ZIndex=5},EDITOR_AREA)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=6},LINE_COL)

local LINE_NUMS=mk("TextLabel",{BackgroundTransparency=1,
    Font=Enum.Font.Code,
    Text="1\n2\n3\n4\n5\n6\n7\n8\n9\n10",
    TextColor3=Color3.fromRGB(55,52,75),TextSize=11,
    Size=UDim2.new(1,0,1,0),
    TextXAlignment=Enum.TextXAlignment.Center,
    TextYAlignment=Enum.TextYAlignment.Top,
    ZIndex=6},LINE_COL)
mk("UIPadding",{PaddingTop=UDim.new(0,8)},LINE_COL)

-- Code input
local CODE_BOX=mk("TextBox",{BackgroundTransparency=1,BorderSizePixel=0,
    Font=Enum.Font.Code,TextSize=11,
    TextColor3=Color3.fromRGB(210,206,230),
    PlaceholderColor3=Color3.fromRGB(55,52,75),
    PlaceholderText="-- return value(s) to fire as payload\n-- Oracle context is injected automatically",
    Text="",
    Size=UDim2.new(1,-32,1,0),Position=UDim2.new(0,32,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,
    TextYAlignment=Enum.TextYAlignment.Top,
    MultiLine=true,ClearTextOnFocus=false,
    TextWrapped=false,ZIndex=5},EDITOR_AREA)
mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8),
    PaddingRight=UDim.new(0,8)},CODE_BOX)

-- Update line numbers as user types
CODE_BOX:GetPropertyChangedSignal("Text"):Connect(function()
    local lines=#CODE_BOX.Text:split("\n")
    local nums={}
    for i=1,math.max(lines,10) do table.insert(nums,tostring(i)) end
    LINE_NUMS.Text=table.concat(nums,"\n")
end)

-- ── Preview panel ─────────────────────────────────────────────────────────────
local PREV_AREA=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Position=UDim2.new(0,0,1,-182),Size=UDim2.new(1,0,0,100),
    ZIndex=4},GL)
stroke(C.BORDER,1,PREV_AREA)
mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,20),ZIndex=5},PREV_AREA)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="  LIVE PREVIEW",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,-80,0,20),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6},PREV_AREA)

local PREV_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ACCDIM,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⟳ Preview",
    TextColor3=C.ACCENT,TextSize=8,
    Size=UDim2.new(0,64,0,16),Position=UDim2.new(1,-70,0,2),ZIndex=6},PREV_AREA)
corner(4,PREV_BTN)

local PREV_TEXT=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="",TextColor3=Color3.fromRGB(255,175,70),TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,1,-22),Position=UDim2.new(0,0,0,22),
    TextXAlignment=Enum.TextXAlignment.Left,
    TextYAlignment=Enum.TextYAlignment.Top,
    ZIndex=5},PREV_AREA)
mk("UIPadding",{PaddingLeft=UDim.new(0,10),PaddingTop=UDim.new(0,4)},PREV_TEXT)

-- ── Template picker ───────────────────────────────────────────────────────────
local TMPL_BAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,1,-82),Size=UDim2.new(1,0,0,82),ZIndex=4},GL)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),ZIndex=5},TMPL_BAR)
pad(8,6,TMPL_BAR); listV(TMPL_BAR,5)

mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="TEMPLATES",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=1},TMPL_BAR)

local TMPL_ROW=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,20),ZIndex=5,LayoutOrder=2},TMPL_BAR)
listH(TMPL_ROW,5)

local TEMPLATES = {
    {
        label = "Live Position",
        code  = [[-- Fire with your current world position
return position]],
    },
    {
        label = "RSO Top Values",
        code  = [[-- Use top RSO-observed values for this remote
local arg1 = topVal(remoteName, 1) or "default"
local arg2 = topVal(remoteName, 2) or 0
return {arg1, arg2}]],
    },
    {
        label = "NaN Injection",
        code  = [[-- Inject NaN into a position-bearing remote
return {
    action   = topVal(remoteName, 1) or "attack",
    position = v3(NaN, NaN, NaN),
    target   = name,
}]],
    },
    {
        label = "Nearest Player",
        code  = [[-- Target the nearest player
local np = nearest()
return {
    target   = np and np.Name or name,
    position = position,
    damage   = rand(1, 50),
}]],
    },
    {
        label = "Sequence Counter",
        code  = [[-- Each repeat fires a different value
-- callIndex increments each repeat
return {
    flags  = 2^(callIndex - 1),  -- 1, 2, 4, 8...
    tick   = tick,
    player = name,
}]],
    },
    {
        label = "Overflow Test",
        code  = [[-- Integer overflow boundary probe
return {
    amount = 2^53 + callIndex,
    target = name,
    id     = userId,
}]],
    },
    {
        label = "Raw Signal",
        code  = [[-- Fire with no args (pure signal)
-- Just remove the return or return nil
return nil]],
    },
    {
        label = "Full Context",
        code  = [[-- Print full Oracle context to preview
-- then fire with live state
return {
    player   = name,
    userId   = userId,
    position = position,
    health   = health,
    tool     = toolName,
    tick     = tick,
    call     = callIndex,
}]],
    },
}

for i, tmpl in ipairs(TEMPLATES) do
    if i > 4 then break end  -- first row, 4 templates
    local tb=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=C.SURFACE,BackgroundTransparency=0.3,BorderSizePixel=0,
        Font=Enum.Font.Code,Text=tmpl.label,TextColor3=C.TEXT,TextSize=8,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
        ZIndex=6},TMPL_ROW)
    corner(3,tb); mk("UIPadding",{PaddingLeft=UDim.new(0,6),PaddingRight=UDim.new(0,6)},tb)
    tb.MouseEnter:Connect(function() tw(tb,TI.fast,{BackgroundTransparency=0,BackgroundColor3=C.CARD}) end)
    tb.MouseLeave:Connect(function() tw(tb,TI.fast,{BackgroundTransparency=0.3,BackgroundColor3=C.SURFACE}) end)
    tb.MouseButton1Click:Connect(function()
        CODE_BOX.Text=tmpl.code
    end)
end

local TMPL_ROW2=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,20),ZIndex=5,LayoutOrder=3},TMPL_BAR)
listH(TMPL_ROW2,5)

for i, tmpl in ipairs(TEMPLATES) do
    if i <= 4 then continue end  -- second row, remaining templates
    local tb=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=C.SURFACE,BackgroundTransparency=0.3,BorderSizePixel=0,
        Font=Enum.Font.Code,Text=tmpl.label,TextColor3=C.TEXT,TextSize=8,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
        ZIndex=6},TMPL_ROW2)
    corner(3,tb); mk("UIPadding",{PaddingLeft=UDim.new(0,6),PaddingRight=UDim.new(0,6)},tb)
    tb.MouseEnter:Connect(function() tw(tb,TI.fast,{BackgroundTransparency=0,BackgroundColor3=C.CARD}) end)
    tb.MouseLeave:Connect(function() tw(tb,TI.fast,{BackgroundTransparency=0.3,BackgroundColor3=C.SURFACE}) end)
    tb.MouseButton1Click:Connect(function()
        CODE_BOX.Text=tmpl.code
    end)
end

-- ── Right: execution log ──────────────────────────────────────────────────────
local GR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0.5,1,0,0),Size=UDim2.new(0.5,-1,1,0),ZIndex=3},BODY)

-- context reference card at top of right panel
local CTX_CARD=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
    ZIndex=4},GR)
stroke(C.BORDER,1,CTX_CARD)
mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,20),ZIndex=5},CTX_CARD)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="  ORACLE CONTEXT",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,20),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6},CTX_CARD)

local CTX_BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,20),
    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
    ZIndex=5},CTX_CARD)
pad(10,4,CTX_BODY); listV(CTX_BODY,2)

local CTX_VARS = {
    {"position",   "Vector3 — HumanoidRootPart position"},
    {"health",     "number — current health"},
    {"name",       "string — player display name"},
    {"userId",     "number — numeric user ID"},
    {"toolName",   "string — held tool name or nil"},
    {"callIndex",  "number — which repeat (1-based)"},
    {"tick",       "number — current timestamp"},
    {"rso",        "table  — RSO observation data"},
    {"topVal(r,i)","returns top observed value for remote r, arg i"},
    {"nearest()",  "returns nearest Player or nil"},
    {"v3(x,y,z)",  "Vector3.new shorthand"},
    {"NaN / Inf",  "special number constants"},
    {"rand(min,max)","math.random shorthand"},
}

for i, v in ipairs(CTX_VARS) do
    local row=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,13),ZIndex=6,LayoutOrder=i},CTX_BODY)
    listH(row,6)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=v[1],TextColor3=C.ACCENT,TextSize=8,
        Size=UDim2.new(0,110,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=7,LayoutOrder=1},row)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=v[2],TextColor3=C.MUTED,TextSize=8,
        Size=UDim2.new(1,-120,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=7,LayoutOrder=2},row)
end

-- execution log below context card
local GR_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,0),
    Size=UDim2.fromScale(1,1),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},GR)
-- anchor below context card via padding from its actual size
-- context card floats above, log fills remaining space
local CTX_CARD_H = 20 + (#CTX_VARS * 13) + 8  -- header + rows + padding
GR_SCROLL.Position = UDim2.new(0,0,0,CTX_CARD_H)
GR_SCROLL.Size     = UDim2.new(1,0,1,-CTX_CARD_H)
pad(10,8,GR_SCROLL); listV(GR_SCROLL,3)

local GR_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Results will appear here after RUN",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,30),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},GR_SCROLL)

-- log helpers
local grN=0
local function addLog(tag,msg,detail,hi)
    GR_EMPTY.Visible=false
    grN+=1; mkRow(tag,msg,detail,hi,GR_SCROLL,grN)
    task.defer(function()
        GR_SCROLL.CanvasPosition=Vector2.new(0,GR_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) grN+=1; mkSep(txt,GR_SCROLL,grN) end
local function clearLog()
    for _,c in ipairs(GR_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    grN=0; GR_EMPTY.Visible=true
end

-- ── Preview button ────────────────────────────────────────────────────────────
PREV_BTN.MouseButton1Click:Connect(function()
    local src=CODE_BOX.Text
    if src=="" then PREV_TEXT.Text="-- (empty script)"; return end

    local remoteName=GEN_REMOTE.Text:match("^%s*(.-)%s*$")
    local result,err=runGeneratorScript(src,remoteName,1)

    if err then
        PREV_TEXT.Text="ERROR: "..err
        PREV_TEXT.TextColor3=Color3.fromRGB(255,80,80)
        return
    end

    local preview
    if result==nil then
        preview="nil  (fires as signal)"
    elseif type(result)=="table" then
        local parts={}
        for k,v2 in pairs(result) do
            table.insert(parts,tostring(k).." = "..vs(v2))
        end
        preview="{\n  "..table.concat(parts,"\n  ").."\n}"
    else
        preview=vs(result)
    end

    PREV_TEXT.Text=preview
    PREV_TEXT.TextColor3=Color3.fromRGB(255,175,70)
end)

-- ── RUN button ────────────────────────────────────────────────────────────────
local running=false

RUN_BTN.MouseButton1Click:Connect(function()
    if running then return end

    local remoteName=GEN_REMOTE.Text:match("^%s*(.-)%s*$")
    if remoteName=="" then
        GEN_STATUS.Text="enter a remote name"
        GEN_STATUS.TextColor3=Color3.fromRGB(255,80,80); return
    end

    local src=CODE_BOX.Text
    if src=="" then
        GEN_STATUS.Text="script is empty"
        GEN_STATUS.TextColor3=Color3.fromRGB(255,80,80); return
    end

    local reps=math.clamp(math.floor(tonumber(GEN_REPS.Text) or 1),1,50)

    running=true
    tw(RUN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
    GEN_STATUS.Text="running..."; GEN_STATUS.TextColor3=C.DELTA
    clearLog()

    task.spawn(function()
        addLogSep("GENERATOR RUN — "..remoteName.." × "..reps)

        local totalHits=0

        for call=1,reps do
            -- Generate payload fresh each call
            local payload,err=runGeneratorScript(src,remoteName,call)

            if err then
                addLog("INFO",("Call %d — script error"):format(call),err)
                break
            end

            -- Show what was generated
            local genStr
            if payload==nil then
                genStr="nil (signal)"
            elseif type(payload)=="table" then
                local parts={}
                for k,v2 in pairs(payload) do
                    table.insert(parts,tostring(k).."="..vs(v2):sub(1,20))
                end
                genStr="{"..table.concat(parts,", ").."}"
            else
                genStr=vs(payload)
            end

            addLog("INFO",("Call %d — generated: %s"):format(call,genStr:sub(1,80)))

            -- Fire
            fireWithPayload(remoteName, payload, addLog, function(ok,hits)
                totalHits += #hits
            end)

            if call < reps then task.wait(0.25) end
        end

        addLogSep(("COMPLETE — %d total hit(s)"):format(totalHits))
        GEN_STATUS.Text=totalHits.." hit(s) in "..reps.." call(s)"
        GEN_STATUS.TextColor3=totalHits>0 and C.RESP or C.MUTED
        tw(RUN_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
        running=false
    end)
end)

-- ── Register tab ─────────────────────────────────────────────────────────────
if G.addTab then
    G.addTab("generator","Generator",P_GEN)
else
    warn("[Oracle] G.addTab not found — ensure 06_init.lua is up to date")
end
