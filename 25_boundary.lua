-- Oracle // 25_boundary.lua
-- BOUNDARY — Level 2→3 Trust Boundary Hunter
-- Finds the exact remotes where client-reported state
-- is trusted without server verification
-- Hit detection · State reporting · Client-authoritative fields
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
-- BOUNDARY ENGINE
-- Tests whether the server trusts client-reported values
-- by sending plausible-but-false state and measuring server acceptance
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Boundary finding result levels
local LEVELS = {
    L3_CONFIRMED  = {id="L3_CONFIRMED",  label="Level 3 — Server trusts client",
                     desc="Server accepted false state as authoritative",
                     col=Color3.fromRGB(255,40,40),   severity=0},
    L3_PROBABLE   = {id="L3_PROBABLE",   label="Level 3 — Probable trust",
                     desc="Server state changed on false report — likely trusted",
                     col=Color3.fromRGB(255,100,40),  severity=1},
    L2_BLEED      = {id="L2_BLEED",      label="Level 2→3 — Partial trust",
                     desc="Server partially accepts client state — some fields trusted",
                     col=Color3.fromRGB(255,160,40),  severity=2},
    L2_ONLY       = {id="L2_ONLY",       label="Level 2 — Client only",
                     desc="Server validates or ignores client state",
                     col=Color3.fromRGB(80,140,255),  severity=3},
    NO_RESPONSE   = {id="NO_RESPONSE",   label="No response",
                     desc="Server did not react to any probe",
                     col=C.MUTED,                     severity=4},
}

-- Test categories — what kind of client-reported state to test
local TEST_CATEGORIES = {
    -- Hit detection: client reports a hit on another player
    {
        id    = "hit_detection",
        label = "Hit Detection",
        desc  = "Tests if server trusts client-reported damage/hit events",
        -- Probe payloads that look like hit reports
        probes = function()
            local targets = game:GetService("Players"):GetPlayers()
            local target  = nil
            for _,p in ipairs(targets) do
                if p ~= LP then target=p; break end
            end
            local targetId = target and target.UserId or 0
            local targetName = target and target.Name or "Player"
            return {
                -- Standard hit report formats
                {tag="hit_basic",    payload={{target=targetName, damage=50}}},
                {tag="hit_userId",   payload={{userId=targetId,   damage=999}}},
                {tag="hit_instanced",payload={{target=target,     damage=999, headshot=true}}},
                {tag="hit_position", payload={{
                    target=targetName, damage=999,
                    position=LP.Character and
                        LP.Character:FindFirstChild("HumanoidRootPart") and
                        LP.Character.HumanoidRootPart.Position or Vector3.new(0,0,0),
                    direction=Vector3.new(0,-1,0),
                }}},
                {tag="hit_maxdmg",   payload={{target=targetName, damage=2^53, instant=true}}},
                -- Raycast result format (common in shooters)
                {tag="hit_raycast",  payload={{
                    Instance = target and target.Character and
                        target.Character:FindFirstChild("HumanoidRootPart") or nil,
                    Position = Vector3.new(0,0,0),
                    Distance = 1.0,
                    damage   = 999,
                }}},
            }
        end,
    },

    -- State reporting: client reports its own state
    {
        id    = "state_report",
        label = "State Reporting",
        desc  = "Tests if server trusts client self-reported state values",
        probes = function()
            return {
                -- Health reporting
                {tag="health_max",   payload={{health=math.huge, maxHealth=math.huge}}},
                {tag="health_report",payload={{health=100, maxHealth=100, shield=100}}},
                -- Position claiming
                {tag="position",     payload={{
                    position=Vector3.new(0,10000,0),
                    velocity=Vector3.new(0,0,0),
                }}},
                -- Level/XP claiming
                {tag="level_claim",  payload={{level=999, xp=999999, prestige=10}}},
                -- Inventory state
                {tag="inventory",    payload={{
                    slots=99, items={"sword","gun","potion"},
                    equipped="legendary_sword",
                }}},
                -- Currency state
                {tag="currency",     payload={{coins=999999, gems=99999, robux=9999}}},
                -- Permission state
                {tag="permission",   payload={{admin=true, vip=true, owner=true, rank=255}}},
            }
        end,
    },

    -- Completion reporting: client reports finishing something
    {
        id    = "completion",
        label = "Completion Reports",
        desc  = "Tests if server trusts client-reported task completion",
        probes = function()
            return {
                {tag="quest_done",   payload={{questId=1, completed=true, reward=true}}},
                {tag="stage_clear",  payload={{stage=999, time=0.001, perfect=true}}},
                {tag="kill_confirm", payload={{kills=999, streak=100, multikill=10}}},
                {tag="purchase_done",payload={{productId=1, success=true, granted=true}}},
                {tag="obby_finish",  payload={{checkpoints=999, finished=true, time=0}}},
                {tag="match_end",    payload={{winner=LP.Name, score=9999, mvp=true}}},
            }
        end,
    },

    -- Event claiming: client claims a game event happened
    {
        id    = "event_claim",
        label = "Event Claims",
        desc  = "Tests if server trusts client-reported game events",
        probes = function()
            local ch = LP.Character
            local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            return {
                {tag="pickup",       payload={{
                    item="legendary_sword", rarity="Legendary",
                    position=hrp and hrp.Position or Vector3.new(0,0,0),
                }}},
                {tag="npc_kill",     payload={{npcName="Boss", loot=true, xp=9999}}},
                {tag="chest_open",   payload={{chestId=1, tier="legendary", loot=true}}},
                {tag="zone_enter",   payload={{zone="vip_area", access=true}}},
                {tag="craft",        payload={{recipe="legendary_sword", success=true}}},
                {tag="trade",        payload={{partnerId=0, accepted=true, items={}}}},
            }
        end,
    },
}

-- Fire a probe and capture everything that changes
local function fireBoundaryProbe(remote, payload, baseline)
    local ev={}
    local function col(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(ev,x) end end
    end
    col(RepS); col(workspace)

    local before = baseline or snap()
    for k in pairs(rlog) do rlog[k]=nil end
    local conns  = hookR(ev)
    local t0     = tick()

    local args = type(payload)=="table" and payload or {payload}
    local ok, ret = pcall(function()
        if remote:IsA("RemoteFunction") then
            return remote:InvokeServer(table.unpack(args))
        else
            remote:FireServer(table.unpack(args))
            return nil
        end
    end)

    local elapsed = (tick()-t0)*1000
    task.wait(math.max(0.08, CFG.RW))
    local dl=tick()+CFG.WD
    while tick()<dl do task.wait(0.05); if #rlog>0 then break end end

    local after = snap()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end

    local responses={}
    for _,r in ipairs(rlog) do table.insert(responses,r) end
    for k in pairs(rlog) do rlog[k]=nil end

    local deltas = dif(before, after)

    -- Classify server response
    local retStr
    if not ok then retStr="ERR:"..tostring(ret):sub(1,50)
    elseif ret==nil then retStr="nil"
    elseif type(ret)=="table" then
        local p={}; for k2,v2 in pairs(ret) do
            table.insert(p,tostring(k2).."="..vs(v2):sub(1,15))
        end
        retStr="{"..table.concat(p,","):sub(1,60).."}"
    else retStr=vs(ret):sub(1,60) end

    -- Score this probe: how much did the server react?
    local score = 0
    local evidence = {}

    -- Server-side state changes
    for _,ch in ipairs(deltas) do
        if ch.bad then
            score += 5
            table.insert(evidence, "PATHOLOGICAL state: "..ch.path)
        else
            score += 3
            table.insert(evidence, "state changed: "..ch.path.." → "..ch.av:sub(1,30))
        end
    end

    -- Server responses
    for _,r in ipairs(responses) do
        score += 4
        table.insert(evidence, "server replied via "..r.name)
    end

    -- Return value analysis
    if ok and ret ~= nil then
        score += 1
        if type(ret)=="boolean" and ret==true then
            score += 3
            table.insert(evidence, "server returned true — likely accepted")
        end
    end

    return {
        ok        = ok,
        retStr    = retStr,
        elapsed   = elapsed,
        responses = responses,
        deltas    = deltas,
        score     = score,
        evidence  = evidence,
    }
end

-- Run a full boundary test on one remote across all categories
local function testBoundary(remote, logFn, progressFn, onComplete)
    local results = {
        remote   = remote.Name,
        category = {},
        best     = nil,
        level    = LEVELS.NO_RESPONSE,
        allProbes= 0,
        hits     = 0,
    }

    local baseline = snap()

    for _, cat in ipairs(TEST_CATEGORIES) do
        if logFn then
            logFn("INFO",
                ("Testing [%s] on %s"):format(cat.label, remote.Name))
        end

        local catResult = {
            id     = cat.id,
            label  = cat.label,
            probes = {},
            best   = nil,
            score  = 0,
        }

        local probes = cat.probes()
        for i, probe in ipairs(probes) do
            if progressFn then
                progressFn(probe.tag)
            end
            task.wait(0.08)

            local r = fireBoundaryProbe(remote, probe.payload, baseline)
            results.allProbes += 1

            local probeResult = {
                tag      = probe.tag,
                score    = r.score,
                evidence = r.evidence,
                retStr   = r.retStr,
                ok       = r.ok,
                elapsed  = r.elapsed,
                deltas   = r.deltas,
                responses= r.responses,
            }
            table.insert(catResult.probes, probeResult)

            if r.score > catResult.score then
                catResult.score = r.score
                catResult.best  = probeResult
            end

            if r.score > 0 then
                results.hits += 1
                if logFn then
                    logFn(r.score >= 7 and "FINDING" or "DELTA",
                        ("[%s] %s — score %d"):format(cat.id, probe.tag, r.score),
                        table.concat(r.evidence, "  ·  "):sub(1,80),
                        r.score >= 7)
                end
                for _, ch in ipairs(r.deltas) do
                    if logFn then
                        logFn(ch.bad and "PATHOLOG" or "DELTA",
                            "State: "..ch.path,
                            ch.bv.." → "..ch.av, true)
                    end
                end
            end
        end

        table.insert(results.category, catResult)
        if catResult.best and
           (not results.best or catResult.score > results.best.score) then
            results.best = catResult.best
            results.bestCat = cat.label
        end
    end

    -- Classify overall level
    local topScore = results.best and results.best.score or 0
    if     topScore >= 10 then results.level = LEVELS.L3_CONFIRMED
    elseif topScore >= 7  then results.level = LEVELS.L3_PROBABLE
    elseif topScore >= 4  then results.level = LEVELS.L2_BLEED
    elseif topScore >= 1  then results.level = LEVELS.L2_ONLY
    else                       results.level = LEVELS.NO_RESPONSE end

    if logFn then
        logFn(topScore>=7 and "FINDING" or "CLEAN",
            ("BOUNDARY: %s — %s"):format(remote.Name, results.level.label),
            results.level.desc..
            ("\nBest probe: %s  Score: %d  Hits: %d/%d"):format(
                results.best and results.best.tag or "none",
                topScore, results.hits, results.allProbes),
            topScore >= 7)
    end

    if onComplete then onComplete(results) end
    return results
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- BOUNDARY PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_BND = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- top bar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_BND)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⬡  BOUNDARY — TRUST BOUNDARY HUNTER",
    TextColor3=Color3.fromRGB(255,40,40),TextSize=11,
    Size=UDim2.new(0,310,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)

local BND_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,160,1,0),Position=UDim2.new(1,-376,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- remote input in topbar
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="Target",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,46,1,0),Position=UDim2.new(1,-362,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

local TARGET_BOX=mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text=G.RBOX and G.RBOX.Text or "",
    PlaceholderText="remote name",
    PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,TextSize=10,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(0,160,0,22),Position=UDim2.new(1,-300,0.5,-11),ZIndex=6},TOPBAR)
corner(5,TARGET_BOX); stroke(C.BORDER,1,TARGET_BOX); pad(6,0,TARGET_BOX)

local TEST_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(180,30,30),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⬡ TEST",TextColor3=C.WHITE,TextSize=10,
    Size=UDim2.new(0,62,0,22),Position=UDim2.new(1,-130,0.5,-11),ZIndex=6},TOPBAR)
corner(5,TEST_BTN)
do local base=Color3.fromRGB(180,30,30)
    TEST_BTN.MouseEnter:Connect(function() tw(TEST_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    TEST_BTN.MouseLeave:Connect(function() tw(TEST_BTN,TI.fast,{BackgroundColor3=base}) end)
end

local SCAN_ALL=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.CARD,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⚡ All Remotes",TextColor3=C.TEXT,TextSize=9,
    Size=UDim2.new(0,96,0,22),Position=UDim2.new(1,-60,0.5,-11),ZIndex=6},TOPBAR)
corner(5,SCAN_ALL); stroke(C.BORDER,1,SCAN_ALL)
SCAN_ALL.MouseEnter:Connect(function() tw(SCAN_ALL,TI.fast,{BackgroundColor3=C.SURFACE}) end)
SCAN_ALL.MouseLeave:Connect(function() tw(SCAN_ALL,TI.fast,{BackgroundColor3=C.CARD}) end)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_BND)

-- left: results list
local BL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},BL)
local RES_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},BL)
pad(6,8,RES_SCROLL); listV(RES_SCROLL,5)
local RES_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Results will appear here.\n\nBOUNDARY finds the exact remotes\nwhere client-reported state\nis trusted by the server.",
    TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
    Size=UDim2.new(1,0,0,80),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},RES_SCROLL)

-- right: probe log
local BR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,241,0,0),Size=UDim2.new(1,-241,1,0),ZIndex=3},BODY)

-- progress bar
local PROG_BG=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,3),ZIndex=5},BR)
local PROG_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,40,40),
    BorderSizePixel=0,Size=UDim2.new(0,0,1,0),ZIndex=6},PROG_BG)
corner(2,PROG_BAR)

local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,3),Size=UDim2.new(1,0,1,-3),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},BR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="BOUNDARY hunts the exact line between\nLevel 2 (client-only) and Level 3 (server-trusted).\n\n"..
         "It fires structured false-state probes\nacross four categories:\n\n"..
         "  Hit Detection · State Reporting\n  Completion Events · Event Claims\n\n"..
         "Enter a remote and press ⬡ TEST.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,140),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- ── Log helpers ───────────────────────────────────────────────────────────────
local bN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; bN+=1; mkRow(tag,msg,detail,hi,LOG_SCROLL,bN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) bN+=1; mkSep(txt,LOG_SCROLL,bN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    bN=0; LOG_EMPTY.Visible=true
    tw(PROG_BAR,TI.fast,{Size=UDim2.new(0,0,1,0)})
end

-- ── Result card builder ───────────────────────────────────────────────────────
local allResults = {}

local function addResultCard(result)
    RES_EMPTY.Visible=false
    local level=result.level
    local ord=#allResults

    local card=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=ord},RES_SCROLL)
    corner(6,card); stroke(level.col,1,card); pad(8,6,card); listV(card,4)

    -- level badge + name
    local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
    listH(hrow,5)
    local badge=mk("Frame",{BackgroundColor3=level.col,BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
    corner(3,badge); mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4)},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=level.id:gsub("_"," "),TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=result.remote,TextColor3=level.col,TextSize=10,
        Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=2},hrow)

    -- description
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=level.desc,TextColor3=C.TEXT,TextSize=9,TextWrapped=true,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},card)

    -- best probe
    if result.best then
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=("Best: %s  [%s]  score:%d"):format(
                result.best.tag, result.bestCat or "?",
                result.best.score),
            TextColor3=Color3.fromRGB(255,175,70),TextSize=8,
            Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=3},card)
    end

    -- exploit button for L3 results
    if level.severity <= 1 and result.best then
        local exBtn=mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=Color3.fromRGB(180,30,30),BorderSizePixel=0,
            Font=Enum.Font.GothamBold,Text="▶ Fire Best Payload",
            TextColor3=C.WHITE,TextSize=9,
            Size=UDim2.new(1,0,0,22),ZIndex=5,LayoutOrder=4},card)
        corner(5,exBtn)
        exBtn.MouseButton1Click:Connect(function()
            addLogSep("FIRING BEST PAYLOAD — "..result.remote)
            local remote=nil
            local function sc(root)
                local ok,d=pcall(function() return root:GetDescendants() end)
                if not ok then return end
                for _,x in ipairs(d) do
                    if (x:IsA("RemoteEvent") or x:IsA("RemoteFunction"))
                    and x.Name==result.remote then remote=x; return end
                end
            end
            sc(RepS); if not remote then sc(workspace) end
            if not remote then
                addLog("INFO","Remote not found"); return
            end
            -- Find the probe that produced this result
            local bestPayload = nil
            for _,cat in ipairs(TEST_CATEGORIES) do
                if cat.label == result.bestCat then
                    local probes=cat.probes()
                    for _,p in ipairs(probes) do
                        if p.tag == result.best.tag then
                            bestPayload=p.payload; break
                        end
                    end
                end
            end
            if bestPayload then
                local r=fireBoundaryProbe(remote,bestPayload)
                addLog(r.score>=7 and "FINDING" or "CLEAN",
                    result.remote.." — score "..r.score,
                    "ret: "..r.retStr..
                    (#r.deltas>0 and "  delta: "..r.deltas[1].path or ""),
                    r.score>=7)
                for _,ch in ipairs(r.deltas) do
                    addLog(ch.bad and "PATHOLOG" or "DELTA",
                        ch.path,ch.bv.." → "..ch.av,true)
                end
            end
        end)
    end
end

-- ── Find remote by name ───────────────────────────────────────────────────────
local function findR(name)
    local t=nil
    local function sc(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do
            if (x:IsA("RemoteEvent") or x:IsA("RemoteFunction"))
            and x.Name==name then t=x; return end
        end
    end
    sc(RepS); if not t then sc(workspace) end
    return t
end

-- ── TEST button ───────────────────────────────────────────────────────────────
local testing=false

local function runTest(remoteName)
    if testing then return end
    local remote=findR(remoteName)
    if not remote then
        BND_STATUS.Text="remote not found"
        BND_STATUS.TextColor3=Color3.fromRGB(255,80,80)
        return
    end

    testing=true
    clearLog()
    tw(TEST_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(60,10,10)})
    BND_STATUS.Text="testing "..remoteName.."..."
    BND_STATUS.TextColor3=Color3.fromRGB(255,80,80)

    local totalProbes = 0
    for _,cat in ipairs(TEST_CATEGORIES) do
        totalProbes += #cat.probes()
    end

    addLogSep("BOUNDARY TEST — "..remoteName)
    addLog("INFO",
        ("Testing across %d categories  %d probes"):format(
            #TEST_CATEGORIES, totalProbes))

    local probeCount=0
    testBoundary(remote,
        addLog,
        function(tag)
            probeCount+=1
            local pct=probeCount/totalProbes
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(pct,0,1,0)})
            BND_STATUS.Text=("probe %d/%d — %s"):format(probeCount,totalProbes,tag)
        end,
        function(result)
            table.insert(allResults,result)
            addResultCard(result)
            local level=result.level
            BND_STATUS.Text=level.label:sub(1,28)
            BND_STATUS.TextColor3=level.col
            tw(TEST_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(180,30,30)})
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
            testing=false
        end)
end

TEST_BTN.MouseButton1Click:Connect(function()
    local name=TARGET_BOX.Text:match("^%s*(.-)%s*$")
    if name=="" then
        BND_STATUS.Text="enter a remote name"
        BND_STATUS.TextColor3=Color3.fromRGB(255,80,80)
        return
    end
    runTest(name)
end)

-- ── Scan all remotes ──────────────────────────────────────────────────────────
local scanning=false
SCAN_ALL.MouseButton1Click:Connect(function()
    if scanning or testing then return end
    local map=G.DISCOVERY_MAP
    if not map then
        addLog("INFO","Run Discovery scan first")
        return
    end
    scanning=true
    tw(SCAN_ALL,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
    clearLog()
    allResults={}

    local remotes={}
    for _,r in ipairs(map.remoteEvents or {}) do
        if r.instance then table.insert(remotes,r.instance) end
    end
    for _,r in ipairs(map.remoteFunctions or {}) do
        if r.instance then table.insert(remotes,r.instance) end
    end

    addLogSep(("BOUNDARY SCAN — %d remotes"):format(#remotes))

    task.spawn(function()
        for i,remote in ipairs(remotes) do
            BND_STATUS.Text=("testing %d/%d: %s"):format(i,#remotes,remote.Name)
            BND_STATUS.TextColor3=Color3.fromRGB(255,80,80)
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(i/#remotes,0,1,0)})

            addLogSep(remote.Name)
            local result=testBoundary(remote,addLog,nil,nil)
            table.insert(allResults,result)
            addResultCard(result)
            task.wait(0.3)
        end

        -- Sort results by severity
        table.sort(allResults,function(a,b)
            return a.level.severity < b.level.severity
        end)

        -- Summary
        local l3count=0
        for _,r in ipairs(allResults) do
            if r.level.severity<=1 then l3count+=1 end
        end

        addLogSep(("SCAN COMPLETE — %d L3 boundaries found / %d tested"):format(
            l3count,#remotes))
        BND_STATUS.Text=l3count.." L3 found / "..#remotes.." tested"
        BND_STATUS.TextColor3=l3count>0 and Color3.fromRGB(255,40,40) or C.MUTED
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        tw(SCAN_ALL,TI.fast,{BackgroundColor3=C.CARD})
        scanning=false
    end)
end)

-- Auto-populate target from AVD selection
P_BND:GetPropertyChangedSignal("Visible"):Connect(function()
    if P_BND.Visible and G.RBOX and G.RBOX.Text ~= "" then
        TARGET_BOX.Text = G.RBOX.Text
    end
end)

-- Export
G.BOUNDARY_RESULTS = allResults
G.boundary_test    = testBoundary

if G.addTab then
    G.addTab("boundary","Boundary",P_BND)
else
    warn("[Oracle] G.addTab not found")
end
