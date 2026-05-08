-- Oracle // 29_grant.lua
-- GRANT — Server-Side Grant Engine
-- Synthesizes all Oracle intelligence into targeted grant attempts
-- Tools · Currency · Items · Permissions · GUI · GamePass · XP · Access
-- Routes through the highest-trust channel per grant type
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

local Players = game:GetService("Players")
local MPS     = game:GetService("MarketplaceService")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- GRANT ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Grant categories — each has a different server-side handling pattern
-- and routes through a different trust channel
local CATEGORIES = {
    {
        id    = "tools",
        label = "Tools & Weapons",
        icon  = "⚔",
        col   = Color3.fromRGB(255,80,80),
        desc  = "Physical tools granted to character or backpack",
        payloads = function(name)
            local n = name or "Sword"
            return {
                {tag="give_direct",   p={{action="give",      item=n, target=LP.Name}}},
                {tag="grant_tool",    p={{action="grantTool", tool=n,  player=LP.Name}}},
                {tag="equip",         p={{action="equip",     weapon=n,userId=LP.UserId}}},
                {tag="purchase_tool", p={{type="tool",        name=n,  buy=true, amount=1}}},
                {tag="unlock_tool",   p={{unlock=n,           granted=true, permanent=true}}},
                {tag="drop",          p={{action="drop",      itemName=n, position=
                    LP.Character and LP.Character:FindFirstChild("HumanoidRootPart") and
                    LP.Character.HumanoidRootPart.Position or Vector3.new(0,0,0)}}},
                {tag="admin_give",    p={{command="give",     player=LP.Name, item=n, admin=true}}},
                {tag="reward",        p={{type="reward",      rewardType="tool", rewardId=n}}},
            }
        end,
        -- Snapshot backpack BEFORE firing — compare AFTER
        -- Only returns confirmed if something NEW appeared that wasn't there before
        snapshotFn = function()
            local snap2 = {}
            local bp = LP:FindFirstChildOfClass("Backpack")
            if bp then
                for _,item in ipairs(bp:GetChildren()) do
                    snap2[item.Name] = true
                end
            end
            local ch = LP.Character
            if ch then
                for _,item in ipairs(ch:GetChildren()) do
                    if item:IsA("Tool") then snap2[item.Name]=true end
                end
            end
            return snap2
        end,
        confirm = function(before, after, deltas, beforeSnap)
            -- beforeSnap is the pre-fire backpack state taken by snapshotFn
            -- Compare current backpack against it — only NEW items count
            local bp = LP:FindFirstChildOfClass("Backpack")
            local newItems = {}
            if bp then
                for _,item in ipairs(bp:GetChildren()) do
                    if item:IsA("Tool") and (not beforeSnap or not beforeSnap[item.Name]) then
                        table.insert(newItems, item.Name)
                    end
                end
            end
            local ch = LP.Character
            if ch then
                for _,item in ipairs(ch:GetChildren()) do
                    if item:IsA("Tool") and (not beforeSnap or not beforeSnap[item.Name]) then
                        table.insert(newItems, item.Name)
                    end
                end
            end
            if #newItems > 0 then
                return true, "Server granted new tool(s): "..table.concat(newItems, ", ")
            end
            -- Fallback: state deltas mentioning tool paths
            for _,ch2 in ipairs(deltas or {}) do
                local path = (ch2.path or ""):lower()
                if path:find("tool") or path:find("weapon") or path:find("backpack") then
                    return true, "Tool state change: "..ch2.path.." → "..ch2.av
                end
            end
            return false, nil
        end,
    },

    {
        id    = "currency",
        label = "Currency & Economy",
        icon  = "$",
        col   = Color3.fromRGB(255,200,60),
        desc  = "Coins, cash, gems, tokens — any numeric economy value",
        payloads = function(amount)
            local amt = tonumber(amount) or 99999
            return {
                {tag="add_coins",     p={{action="addCoins",   amount=amt}}},
                {tag="add_cash",      p={{action="addCash",    amount=amt}}},
                {tag="add_gems",      p={{action="addGems",    amount=amt}}},
                {tag="give_currency", p={{type="currency",     amount=amt, grant=true}}},
                {tag="set_coins",     p={{coins=amt,           userId=LP.UserId}}},
                {tag="set_cash",      p={{cash=amt,            player=LP.Name}}},
                {tag="set_gems",      p={{gems=amt,            target=LP.Name}}},
                {tag="economy_grant", p={{action="grant",      currency="coins", value=amt}}},
                {tag="purchase_coins",p={{type="purchase",     item="coins", amount=amt, success=true}}},
                {tag="reward_coins",  p={{type="reward",       rewardType="currency",
                    rewardAmount=amt, claimed=true}}},
                {tag="admin_coins",   p={{command="coins",     player=LP.Name,
                    amount=amt, admin=true}}},
                {tag="increment",     p={{action="increment",  stat="Coins", value=amt}}},
            }
        end,
        confirm = function(before, after, deltas)
            -- Look for numeric increases in leaderstats or value objects
            for _,ch in ipairs(deltas) do
                local path = ch.path:lower()
                if path:find("coins") or path:find("cash") or path:find("gems") or
                   path:find("gold") or path:find("tokens") or path:find("credits") or
                   path:find("currency") or path:find("money") or path:find("points") then
                    local bval = tonumber(ch.bv) or 0
                    local aval = tonumber(ch.av) or 0
                    if aval > bval then
                        return true, ("Currency increased: %s  %s → %s"):format(
                            ch.path, ch.bv, ch.av)
                    end
                end
            end
            return false, nil
        end,
    },

    {
        id    = "items",
        label = "Items & Inventory",
        icon  = "[I]",
        col   = Color3.fromRGB(80,210,100),
        desc  = "Inventory items, collectibles, crafting materials",
        payloads = function(name)
            local n = name or "Item"
            return {
                {tag="give_item",     p={{action="giveItem",  itemId=n, amount=1}}},
                {tag="add_inventory", p={{action="addItem",   item=n, count=1}}},
                {tag="grant_item",    p={{type="item",        name=n, grant=true}}},
                {tag="collect",       p={{action="collect",   itemName=n, collected=true}}},
                {tag="pickup",        p={{action="pickup",    item=n, position=
                    LP.Character and LP.Character:FindFirstChild("HumanoidRootPart") and
                    LP.Character.HumanoidRootPart.Position or Vector3.new(0,0,0)}}},
                {tag="craft_grant",   p={{action="craft",     result=n, success=true}}},
                {tag="chest_item",    p={{action="openChest", reward=n, tier="legendary"}}},
                {tag="daily_reward",  p={{action="claim",     day=1, reward=n, type="item"}}},
                {tag="quest_reward",  p={{questId=1, completed=true, reward={item=n, amount=1}}}},
                {tag="trade_receive", p={{action="trade",     received={n}, accepted=true}}},
            }
        end,
        confirm = function(before, after, deltas)
            for _,ch in ipairs(deltas) do
                local path=ch.path:lower()
                if path:find("item") or path:find("inventory") or
                   path:find("collect") or path:find("owned") then
                    return true, "Inventory change: "..ch.path.." → "..ch.av
                end
            end
            return false, nil
        end,
    },

    {
        id    = "permissions",
        label = "Permissions & Roles",
        icon  = "[K]",
        col   = Color3.fromRGB(255,80,80),
        desc  = "Admin, VIP, moderator, developer — authority escalation",
        payloads = function(role)
            local r = role or "admin"
            return {
                {tag="set_role",      p={{action="setRole",   role=r,  player=LP.Name}}},
                {tag="promote",       p={{action="promote",   target=LP.Name, rank=255}}},
                {tag="give_admin",    p={{admin=true,         userId=LP.UserId, permanent=true}}},
                {tag="set_rank",      p={{rank=255,           player=LP.Name, group=true}}},
                {tag="grant_vip",     p={{type="vip",         userId=LP.UserId, granted=true}}},
                {tag="permission",    p={{permission=r,       target=LP.UserId, value=true}}},
                {tag="auth",          p={{auth=r,             key="master", player=LP.Name}}},
                {tag="owner_claim",   p={{action="claim",     role="owner", verify=true}}},
                {tag="dev_mode",      p={{developer=true,     studio=true, trusted=true}}},
                {tag="whitelist",     p={{action="whitelist", userId=LP.UserId, role=r}}},
                {tag="bypass",        p={{bypass=true,        admin=true, noCheck=true}}},
            }
        end,
        confirm = function(before, after, deltas)
            for _,ch in ipairs(deltas) do
                local path=ch.path:lower()
                if path:find("admin") or path:find("rank") or path:find("role") or
                   path:find("vip") or path:find("perm") or path:find("mod") then
                    return true, "Permission change: "..ch.path.." → "..ch.av
                end
            end
            -- Also check if admin GUI appeared
            local pg=LP:FindFirstChildOfClass("PlayerGui")
            if pg then
                for _,gui in ipairs(pg:GetChildren()) do
                    if gui.Name:lower():find("admin") or
                       gui.Name:lower():find("mod") or
                       gui.Name:lower():find("dev") then
                        return true, "Admin GUI appeared: "..gui.Name
                    end
                end
            end
            return false, nil
        end,
    },

    {
        id    = "gui",
        label = "GUI & UI Unlock",
        icon  = "[G]",
        col   = Color3.fromRGB(80,140,255),
        desc  = "Unlocks hidden GUIs, menus, developer panels",
        payloads = function(name)
            local n = name or "AdminPanel"
            return {
                {tag="show_gui",      p={{action="showGui",   name=n}}},
                {tag="open_panel",    p={{action="open",      panel=n, player=LP.Name}}},
                {tag="unlock_gui",    p={{unlock=n,           gui=true, enabled=true}}},
                {tag="enable_ui",     p={{type="ui",          name=n,  enable=true}}},
                {tag="dev_panel",     p={{developer=true,     showPanel=true}}},
                {tag="admin_ui",      p={{admin=true,         openMenu=true, target=LP.Name}}},
                {tag="menu_access",   p={{access="premium",   menu=n, granted=true}}},
            }
        end,
        confirm = function(before, after, deltas)
            local pg=LP:FindFirstChildOfClass("PlayerGui")
            if pg then
                -- Check for any new ScreenGui that appeared
                for _,child in ipairs(pg:GetChildren()) do
                    if child:IsA("ScreenGui") and child.Enabled then
                        -- Check if it appeared after the fire
                        return true, "GUI appeared/enabled: "..child.Name
                    end
                end
            end
            for _,ch in ipairs(deltas) do
                if ch.path:lower():find("gui") or ch.path:lower():find("screen") then
                    return true, "GUI state change: "..ch.path
                end
            end
            return false, nil
        end,
    },

    {
        id    = "gamepass",
        label = "GamePass Features",
        icon  = "[P]",
        col   = Color3.fromRGB(168,120,255),
        desc  = "Unlocks gamepass-gated features without purchase",
        payloads = function(passId)
            local id = tonumber(passId) or 1
            return {
                {tag="mps_gamepass",  p=nil,  -- routed through Seluwia MPS
                 mps=true, mpsType="Gamepass", mpsId=id},
                {tag="grant_pass",    p={{action="grantPass",  passId=id, userId=LP.UserId}}},
                {tag="pass_owned",    p={{gamepassId=id,        owned=true, verified=true}}},
                {tag="unlock_pass",   p={{type="gamepass",      id=id, unlock=true}}},
                {tag="purchase_done", p={{passId=id,            purchased=true,
                    userId=LP.UserId, success=true}}},
                {tag="check_pass",    p={{userId=LP.UserId,     passId=id, owns=true}}},
                {tag="vip_grant",     p={{vip=true,             passId=id,
                    player=LP.Name, permanent=true}}},
            }
        end,
        confirm = function(before, after, deltas)
            -- GamePass grants typically unlock features, GUI, or items
            for _,ch in ipairs(deltas) do
                local path=ch.path:lower()
                if path:find("vip") or path:find("premium") or path:find("pass") or
                   path:find("unlock") or path:find("feature") then
                    return true, "GamePass feature unlocked: "..ch.path
                end
            end
            return false, nil
        end,
    },

    {
        id    = "xp",
        label = "XP & Progression",
        icon  = "*",
        col   = Color3.fromRGB(255,160,40),
        desc  = "Experience, levels, prestige, rank progression",
        payloads = function(amount)
            local amt = tonumber(amount) or 9999
            return {
                {tag="add_xp",        p={{action="addXP",     amount=amt}}},
                {tag="give_xp",       p={{action="giveXP",    xp=amt, player=LP.Name}}},
                {tag="level_up",      p={{action="levelUp",   levels=99, force=true}}},
                {tag="set_level",     p={{level=999,          xp=999999, player=LP.Name}}},
                {tag="prestige",      p={{action="prestige",  count=10, force=true}}},
                {tag="rank_up",       p={{action="rankUp",    rank=255, userId=LP.UserId}}},
                {tag="xp_reward",     p={{type="reward",      xp=amt, source="quest"}}},
                {tag="kill_xp",       p={{kills=999,          xpPerKill=amt, bonus=10}}},
                {tag="complete_xp",   p={{completed=true,     xp=amt, bonus=true}}},
                {tag="admin_level",   p={{command="level",    player=LP.Name,
                    value=999, admin=true}}},
            }
        end,
        confirm = function(before, after, deltas)
            for _,ch in ipairs(deltas) do
                local path=ch.path:lower()
                if path:find("xp") or path:find("exp") or path:find("level") or
                   path:find("rank") or path:find("prestige") or path:find("score") then
                    local bval=tonumber(ch.bv) or 0
                    local aval=tonumber(ch.av) or 0
                    if aval>bval then
                        return true, ("Progression increased: %s  %s → %s"):format(
                            ch.path, ch.bv, ch.av)
                    end
                end
            end
            return false, nil
        end,
    },

    {
        id    = "access",
        label = "Area & Content Access",
        icon  = "[A]",
        col   = Color3.fromRGB(80,220,180),
        desc  = "VIP areas, locked zones, restricted content, fast travel",
        payloads = function(zone)
            local z = zone or "VIPZone"
            return {
                {tag="teleport_zone", p={{action="teleport",  zone=z, player=LP.Name}}},
                {tag="zone_access",   p={{access=z,           granted=true, permanent=true}}},
                {tag="unlock_area",   p={{area=z,             unlock=true, userId=LP.UserId}}},
                {tag="enter_vip",     p={{type="vip",         zone=z, enter=true}}},
                {tag="fast_travel",   p={{action="fastTravel",destination=z}}},
                {tag="door_open",     p={{action="open",      door=z, authorized=true}}},
                {tag="whitelist_zone",p={{zone=z,             whitelist=true, player=LP.Name}}},
                {tag="warp",          p={{warp=z,             force=true, noCheck=true}}},
            }
        end,
        confirm = function(before, after, deltas)
            for _,ch in ipairs(deltas) do
                local path=ch.path:lower()
                -- Position change = teleported
                if path:find("position") or path:find("cframe") then
                    return true, "Position changed — may have been teleported"
                end
                if path:find("access") or path:find("zone") or path:find("unlock") then
                    return true, "Access state changed: "..ch.path
                end
            end
            -- Character teleport
            local ch=LP.Character
            if ch then
                local hrp=ch:FindFirstChild("HumanoidRootPart")
                if hrp then
                    -- Would need pre-fire position to compare
                end
            end
            return false, nil
        end,
    },
}

-- ── Fire a grant probe and capture everything ─────────────────────────────────
local function fireGrantProbe(remote, payload)
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
    local t0=tick()

    local args=type(payload)=="table" and payload or {payload}
    local ok,ret=pcall(function()
        if remote:IsA("RemoteFunction") then
            return remote:InvokeServer(table.unpack(args))
        else
            remote:FireServer(table.unpack(args))
        end
    end)

    local elapsed=(tick()-t0)*1000
    task.wait(math.max(0.1,CFG.RW))
    local dl=tick()+CFG.WD
    while tick()<dl do task.wait(0.05); if #rlog>0 then break end end

    local after=snap()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end

    local responses={}
    for _,r in ipairs(rlog) do table.insert(responses,r) end
    for k in pairs(rlog) do rlog[k]=nil end

    local deltas=dif(before,after)

    return {
        ok=ok, ret=ret, retStr=vs(ret or ""),
        elapsed=elapsed, responses=responses, deltas=deltas,
        before=before, after=after,
    }
end

-- Find remote by name
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

-- ── Intelligence synthesis — find best remotes for a category ─────────────────
local function findGrantRemotes(category)
    local candidates = {}

    -- 1. AVD findings — highest severity, no validation
    local avd = G.AVD_FINDINGS or {}
    for _, f in ipairs(avd) do
        if f.vuln and (f.vuln.id=="NO_VALID" or f.vuln.id=="INCON_SCHEMA") then
            local r=findR(f.remote)
            if r then
                table.insert(candidates, {
                    remote    = r,
                    name      = f.remote,
                    score     = 10 + (f.count or 1),
                    source    = "AVD:"..f.vuln.severity,
                    reason    = f.vuln.label,
                })
            end
        end
    end

    -- 2. VEX sessions — confirmed deep paths
    local vex = G.VEX_SESSIONS or {}
    for id, sess in pairs(vex) do
        if sess.finalPayload and sess.finalDepth and sess.finalDepth >= 5 then
            local r=findR(sess.remote)
            if r then
                table.insert(candidates, {
                    remote  = r,
                    name    = sess.remote,
                    score   = sess.finalDepth * 2,
                    source  = "VEX:depth"..sess.finalDepth,
                    reason  = "VEX confirmed deep execution path",
                    vexPayload = sess.finalPayload,
                })
            end
        end
    end

    -- 3. BOUNDARY results — confirmed L3 trust
    local bnd = G.BOUNDARY_RESULTS or {}
    for _, res in ipairs(bnd) do
        if res.level and res.level.severity <= 1 then
            local r=findR(res.remote)
            if r then
                table.insert(candidates, {
                    remote  = r,
                    name    = res.remote,
                    score   = 20,
                    source  = "BOUNDARY:"..res.level.id,
                    reason  = res.level.desc,
                    bestTag = res.best and res.best.tag or nil,
                })
            end
        end
    end

    -- 4. RSO observations — high fire count remotes
    local rso = G.RSO_OBS or {}
    for name, rec in pairs(rso) do
        if (rec.total or 0) >= 10 and rec.sig then
            local r=findR(name)
            if r then
                table.insert(candidates, {
                    remote  = r,
                    name    = name,
                    score   = math.min(rec.total, 30),
                    source  = "RSO:"..rec.total.."fires",
                    reason  = "Frequently observed remote",
                })
            end
        end
    end

    -- 5. Discovery map fallback
    local map = G.DISCOVERY_MAP
    if map and #candidates == 0 then
        for _, rem in ipairs(map.remoteEvents or {}) do
            if rem.instance then
                table.insert(candidates, {
                    remote = rem.instance,
                    name   = rem.name,
                    score  = 1,
                    source = "Discovery",
                    reason = "Discovered remote — no intelligence yet",
                })
            end
        end
    end

    -- Sort by score desc
    table.sort(candidates, function(a,b) return a.score > b.score end)
    return candidates
end

-- ── Execute a grant attempt ───────────────────────────────────────────────────
local function executeGrant(category, targetValue, remoteName, logFn)
    local cat = nil
    for _,c in ipairs(CATEGORIES) do
        if c.id == category then cat=c; break end
    end
    if not cat then
        if logFn then logFn("INFO","Unknown category: "..tostring(category)) end
        return nil
    end

    -- Find best remotes
    local candidates = findGrantRemotes(cat)
    if remoteName and remoteName ~= "" then
        local r=findR(remoteName)
        if r then
            table.insert(candidates, 1, {
                remote=r, name=remoteName, score=100,
                source="Manual", reason="User-specified remote"
            })
        end
    end

    -- ── LAST RESORT: live scan ────────────────────────────────────────────────
    -- If no intelligence exists yet, scan ReplicatedStorage live right now
    -- so the user doesn't need to run Discovery first
    if #candidates == 0 then
        if logFn then
            logFn("INFO","No prior intelligence found",
                "Running live remote scan as fallback...")
        end
        local function liveAdd(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return end
            for _,x in ipairs(d) do
                if x:IsA("RemoteEvent") or x:IsA("RemoteFunction") then
                    table.insert(candidates, {
                        remote = x,
                        name   = x.Name,
                        score  = 1,
                        source = "LiveScan",
                        reason = x:GetFullName(),
                    })
                end
            end
        end
        liveAdd(RepS)
        liveAdd(workspace)
        if logFn then
            logFn("INFO",("Live scan found %d remotes"):format(#candidates),
                "For better results: run Discovery → AVD → then retry")
        end
    end

    if #candidates == 0 then
        if logFn then
            logFn("INFO","No remotes accessible",
                "The game may not have any RemoteEvents in ReplicatedStorage or Workspace")
        end
        return nil
    end

    if logFn then
        logFn("INFO",
            ("Targeting %d remote(s)"):format(math.min(#candidates,8)),
            ("Top: %s [%s] — %s"):format(
                candidates[1].name,
                candidates[1].source,
                candidates[1].reason))
    end

    local probes  = cat.payloads(targetValue)
    local results = {}
    local bestResult = nil

    -- PATH 1: Remote handler
    local maxRemotes = math.min(#candidates, 8)
    if logFn then
        logFn("INFO",
            ("Probing %d remote(s) × %d payload(s)"):format(
                maxRemotes, math.min(#probes,10)))
    end

    for ri=1,maxRemotes do
        local cand = candidates[ri]
        if logFn then
            logFn("INFO",
                ("Remote %d/%d: %s"):format(ri, maxRemotes, cand.name),
                "["..cand.source.."]  "..cand.reason)
        end

        -- First try VEX's optimal payload if we have one
        if cand.vexPayload then
            task.wait(0.1)
            local beforeSnap = cat.snapshotFn and cat.snapshotFn() or nil
            local r = fireGrantProbe(cand.remote, cand.vexPayload)
            local confirmed, evidence = cat.confirm(r.before, r.after, r.deltas, beforeSnap)
            if confirmed then
                if logFn then
                    logFn("FINDING",
                        ("✓ GRANT CONFIRMED via VEX payload on %s"):format(cand.name),
                        evidence, true)
                end
                return {confirmed=true, evidence=evidence, remote=cand.name,
                    payload=cand.vexPayload, source="VEX"}
            end
        end

        -- Try all category probes
        for _, probe in ipairs(probes) do
            if probe.mps then continue end

            task.wait(0.08)

            -- Take category-specific before snapshot (e.g. backpack for tools)
            local beforeSnap = cat.snapshotFn and cat.snapshotFn() or nil

            local r = fireGrantProbe(cand.remote, probe.p)

            -- Pass beforeSnap as 4th arg to confirm so it can diff properly
            local confirmed, evidence = cat.confirm(r.before, r.after, r.deltas, beforeSnap)

            local probeResult = {
                tag=probe.tag, remote=cand.name,
                confirmed=confirmed, evidence=evidence,
                deltas=#r.deltas, responses=#r.responses,
                retStr=r.retStr,
            }
            table.insert(results, probeResult)

            if confirmed then
                if logFn then
                    logFn("FINDING",
                        ("✓ GRANT CONFIRMED: %s via %s"):format(cat.label, cand.name),
                        ("Probe: %s  Evidence: %s"):format(probe.tag, evidence or ""),
                        true)
                    for _,ch in ipairs(r.deltas) do
                        logFn(ch.bad and "PATHOLOG" or "DELTA",
                            ch.path, ch.bv.." → "..ch.av, true)
                    end
                end
                return {confirmed=true, evidence=evidence, remote=cand.name,
                    payload=probe.p, source=probe.tag}
            elseif #r.deltas > 0 or #r.responses > 0 then
                -- Partial hit — interesting but not confirmed
                if not bestResult or
                   (#r.deltas + #r.responses) > (bestResult.deltas + bestResult.responses) then
                    bestResult = probeResult
                end
                if logFn then
                    logFn("DELTA",
                        ("[%s] %s — %d delta(s)"):format(probe.tag, cand.name, #r.deltas),
                        r.retStr:sub(1,60))
                end
            end
        end
    end

    -- Route 2: MPS Signal (for GamePass category)
    local mpsProbes = {}
    for _,p in ipairs(probes) do if p.mps then table.insert(mpsProbes,p) end end

    if #mpsProbes > 0 and G.sel_fireFakeSignal then
        if logFn then logFn("INFO","Routing through MPS signal layer") end
        for _,probe in ipairs(mpsProbes) do
            task.wait(0.1)
            local before2=snap()
            local ok=G.sel_fireFakeSignal(probe.mpsType, probe.mpsId, logFn)
            task.wait(0.3)
            local after2=snap()
            local deltas2=dif(before2,after2)
            local confirmed,evidence=cat.confirm(before2,after2,deltas2)
            if confirmed then
                if logFn then
                    logFn("FINDING",
                        ("✓ GRANT via MPS %s signal — id %d"):format(
                            probe.mpsType, probe.mpsId),
                        evidence,true)
                end
                return {confirmed=true, evidence=evidence,
                    remote="MPS:"..probe.mpsType,
                    payload={mpsType=probe.mpsType, mpsId=probe.mpsId},
                    source="MPS"}
            end
        end
    end

    -- Route 3: TeleportData carrier
    if G.CARRIER_TELEPORT_DATA then
        if logFn then
            logFn("INFO","TeleportData carrier available",
                "Carrier may have pre-loaded grant data on join")
        end
    end

    -- Summary
    if logFn then
        if bestResult then
            logFn("INFO",
                ("Best partial: %s [%s] — %d delta(s)"):format(
                    bestResult.remote, bestResult.tag, bestResult.deltas),
                "Not confirmed but server reacted — try Fire Best below")
        else
            logFn("CLEAN",
                ("No grant confirmed across %d probes"):format(#results),
                "Server validates all inputs in this category")
        end
    end

    return {confirmed=false, best=bestResult, results=results}
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- GRANT PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_GNT = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- top bar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_GNT)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⬡  GRANT — SERVER-SIDE GRANT ENGINE",
    TextColor3=Color3.fromRGB(255,200,60),TextSize=11,
    Size=UDim2.new(0,300,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local GNT_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,140,1,0),Position=UDim2.new(1,-310,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

local FIRE_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(180,140,20),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⬡ ATTEMPT GRANT",TextColor3=Color3.fromRGB(8,8,12),TextSize=10,
    Size=UDim2.new(0,130,0,22),Position=UDim2.new(1,-148,0.5,-11),ZIndex=6},TOPBAR)
corner(5,FIRE_BTN)
do local base=Color3.fromRGB(180,140,20)
    FIRE_BTN.MouseEnter:Connect(function() tw(FIRE_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    FIRE_BTN.MouseLeave:Connect(function() tw(FIRE_BTN,TI.fast,{BackgroundColor3=base}) end)
end

-- body: left=categories+config, right=log
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_GNT)

-- left panel
local GL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},GL)
local LEFT=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},GL)
pad(10,8,LEFT); listV(LEFT,8)

-- Description label — declared BEFORE category buttons so click handlers can reference it
local DESC_LBL=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text=CATEGORIES[1].desc,TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=4,LayoutOrder=11},LEFT)

-- Category selector buttons
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="GRANT CATEGORY",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=1},LEFT)

local selCat    = CATEGORIES[1]
local catBtns   = {}

for i,cat in ipairs(CATEGORIES) do
    local sel=selCat.id==cat.id
    local b=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=sel and cat.col or C.CARD,
        BorderSizePixel=0,Text="",
        Size=UDim2.new(1,0,0,28),ZIndex=4,LayoutOrder=i+1},LEFT)
    corner(5,b); if not sel then stroke(C.BORDER,1,b) end
    pad(10,0,b); listH(b,6)

    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=cat.icon,TextColor3=sel and Color3.fromRGB(8,8,12) or cat.col,TextSize=13,
        Size=UDim2.new(0,22,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=1},b)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=cat.label,TextColor3=sel and Color3.fromRGB(8,8,12) or C.MUTED,TextSize=9,
        Size=UDim2.new(1,-30,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=2},b)

    catBtns[cat.id]=b
    b.MouseButton1Click:Connect(function()
        selCat=cat
        for id,btn in pairs(catBtns) do
            local c2=nil
            for _,cc in ipairs(CATEGORIES) do if cc.id==id then c2=cc;break end end
            if c2 then
                tw(btn,TI.fast,{BackgroundColor3=id==cat.id and c2.col or C.CARD})
            end
            -- Update text colors
            for _,child in ipairs(btn:GetChildren()) do
                if child:IsA("TextLabel") then
                    child.TextColor3=id==cat.id and Color3.fromRGB(8,8,12) or C.MUTED
                end
            end
        end
        DESC_LBL.Text=cat.desc
    end)
end

-- Value input
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="TARGET VALUE",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=12},LEFT)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Item name / amount / zone / role",
    TextColor3=C.MUTED,TextSize=8,
    Size=UDim2.new(1,0,0,11),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=13},LEFT)
local VAL_BOX=mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text="",PlaceholderText="Sword / 99999 / VIPZone / admin",
    PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,TextSize=10,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(1,0,0,26),ZIndex=4,LayoutOrder=14},LEFT)
corner(6,VAL_BOX); stroke(C.BORDER,1,VAL_BOX); pad(8,0,VAL_BOX)

-- Remote override
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="REMOTE OVERRIDE",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=15},LEFT)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Leave blank to use Oracle intelligence",
    TextColor3=C.MUTED,TextSize=8,
    Size=UDim2.new(1,0,0,11),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=4,LayoutOrder=16},LEFT)
local REM_BOX=mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text=G.RBOX and G.RBOX.Text or "",
    PlaceholderText="remote name (optional)",
    PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,TextSize=10,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(1,0,0,26),ZIndex=4,LayoutOrder=17},LEFT)
corner(6,REM_BOX); stroke(C.BORDER,1,REM_BOX); pad(8,0,REM_BOX)

-- Intel summary
local INTEL_CARD=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
    ZIndex=4,LayoutOrder=18},LEFT)
corner(6,INTEL_CARD); pad(10,6,INTEL_CARD); listV(INTEL_CARD,4)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="ORACLE INTELLIGENCE",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=1},INTEL_CARD)

local function buildIntelSummary()
    for _,c in ipairs(INTEL_CARD:GetChildren()) do
        if c:IsA("GuiObject") and c.LayoutOrder > 1 then c:Destroy() end
    end
    local avdCount=0
    for _,f in ipairs(G.AVD_FINDINGS or {}) do
        if f.vuln and f.vuln.severity=="HIGH" then avdCount+=1 end
    end
    local vexCount=0
    for _ in pairs(G.VEX_SESSIONS or {}) do vexCount+=1 end
    local bndCount=0
    for _,r in ipairs(G.BOUNDARY_RESULTS or {}) do
        if r.level and r.level.severity<=1 then bndCount+=1 end
    end
    local rsoCount=0
    for _ in pairs(G.RSO_OBS or {}) do rsoCount+=1 end

    local function row(label,count,col2,ord)
        local r=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,14),ZIndex=5,LayoutOrder=ord},INTEL_CARD)
        listH(r,6)
        local dot=mk("Frame",{BackgroundColor3=count>0 and col2 or C.MUTED,
            BorderSizePixel=0,Size=UDim2.fromOffset(8,8),ZIndex=6,LayoutOrder=1},r)
        corner(4,dot)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=label.." — "..count,TextColor3=count>0 and C.TEXT or C.MUTED,TextSize=9,
            Size=UDim2.new(1,-16,1,0),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=6,LayoutOrder=2},r)
    end

    row("AVD HIGH findings",  avdCount, Color3.fromRGB(255,80,80),  2)
    row("VEX sessions",       vexCount, Color3.fromRGB(255,200,60), 3)
    row("L3 boundaries",      bndCount, Color3.fromRGB(255,80,80),  4)
    row("RSO signatures",     rsoCount, Color3.fromRGB(80,210,100), 5)

    local total=avdCount+vexCount*3+bndCount*5+math.min(rsoCount,10)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=("Intelligence score: %d"):format(total),
        TextColor3=total>5 and Color3.fromRGB(255,200,60) or C.MUTED,TextSize=9,
        Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=6},INTEL_CARD)
end

buildIntelSummary()

-- right: log
local GR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,241,0,0),Size=UDim2.new(1,-241,1,0),ZIndex=3},BODY)

-- result card pinned to bottom
local RESULT_CARD=mk("Frame",{BackgroundColor3=Color3.fromRGB(8,20,8),
    BorderSizePixel=0,
    Position=UDim2.new(0,0,1,-90),Size=UDim2.new(1,0,0,90),
    ZIndex=6,Visible=false},GR)
mk("Frame",{BackgroundColor3=Color3.fromRGB(80,210,100),BorderSizePixel=0,
    Size=UDim2.new(1,0,0,2),ZIndex=7},RESULT_CARD)
pad(10,8,RESULT_CARD); listV(RESULT_CARD,4)
local RES_TITLE=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="GRANT CONFIRMED",TextColor3=Color3.fromRGB(80,210,100),TextSize=12,
    Size=UDim2.new(1,0,0,16),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=7,LayoutOrder=1},RESULT_CARD)
local RES_EVIDENCE=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="",TextColor3=Color3.fromRGB(255,175,70),TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,24),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=7,LayoutOrder=2},RESULT_CARD)
local RES_BTNS=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,26),ZIndex=7,LayoutOrder=3},RESULT_CARD)
listH(RES_BTNS,6)
local COPY_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(30,80,30),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="Copy Payload",TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,100,1,0),ZIndex=8,LayoutOrder=1},RES_BTNS)
corner(5,COPY_BTN)
local IMGUI_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(60,40,120),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⬡ Show IMGUI",TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,100,1,0),ZIndex=8,LayoutOrder=2},RES_BTNS)
corner(5,IMGUI_BTN)
local AGAIN_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(20,70,20),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="▶ Fire Again",TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,100,1,0),ZIndex=8,LayoutOrder=3},RES_BTNS)
corner(5,AGAIN_BTN)

local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,1,-90),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},GR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="GRANT synthesizes all Oracle intelligence\nto attempt server-side grants.\n\n"..
         "Select a category, set a target value,\nand press ⬡ ATTEMPT GRANT.\n\n"..
         "Oracle automatically routes through\nthe highest-trust channel:\n"..
         "AVD → VEX → BOUNDARY → RSO → MPS",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,140),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- log helpers
local gN=0
local lastResult=nil
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; gN+=1; mkRow(tag,msg,detail,hi,LOG_SCROLL,gN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) gN+=1; mkSep(txt,LOG_SCROLL,gN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    gN=0; LOG_EMPTY.Visible=true
    RESULT_CARD.Visible=false
end

-- ── ATTEMPT GRANT ─────────────────────────────────────────────────────────────
local running=false
FIRE_BTN.MouseButton1Click:Connect(function()
    if running then return end
    running=true
    clearLog()
    buildIntelSummary()

    local cat    = selCat
    local val    = VAL_BOX.Text:match("^%s*(.-)%s*$")
    local remOvr = REM_BOX.Text:match("^%s*(.-)%s*$")

    tw(FIRE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(60,46,6)})
    GNT_STATUS.Text="attempting "..cat.label.."..."
    GNT_STATUS.TextColor3=Color3.fromRGB(255,200,60)

    addLogSep(cat.icon.." GRANT ATTEMPT — "..cat.label)
    if val~="" then addLog("INFO","Target value: "..val) end

    task.spawn(function()
        local result=executeGrant(cat.id, val~="" and val or nil,
            remOvr~="" and remOvr or nil, addLog)
        lastResult=result

        if result and result.confirmed then
            -- Show result card
            RESULT_CARD.Visible=true
            LOG_SCROLL.Size=UDim2.new(1,0,1,-90)
            RES_TITLE.Text=cat.icon.." GRANT CONFIRMED — "..cat.label
            RES_EVIDENCE.Text=result.evidence or ""

            GNT_STATUS.Text="✓ GRANTED"
            GNT_STATUS.TextColor3=Color3.fromRGB(80,210,100)

            -- Wire buttons
            local payloadStr2=""
            if result.payload then
                if type(result.payload)=="table" then
                    local p={}; for k,v in pairs(result.payload) do
                        table.insert(p,tostring(k).."="..vs(v):sub(1,20))
                    end
                    payloadStr2=table.concat(p,", ")
                else
                    payloadStr2=vs(result.payload)
                end
            end

            -- Capture category snapshot so closures don't capture stale selCat
            local thisCat    = cat
            local thisResult = result
            local thisPayloadStr = payloadStr2

            -- Store connections in a table (Roblox Instances don't support
            -- arbitrary property assignment like btn._conn)
            if not G._grantBtnConns then G._grantBtnConns = {} end
            local conns = G._grantBtnConns
            if conns.copy  then pcall(function() conns.copy:Disconnect()  end) end
            if conns.imgui then pcall(function() conns.imgui:Disconnect() end) end
            if conns.again then pcall(function() conns.again:Disconnect() end) end

            conns.copy = COPY_BTN.MouseButton1Click:Connect(function()
                pcall(setclipboard, thisPayloadStr)
                COPY_BTN.Text="Copied!"; task.delay(1.5,function()
                    if COPY_BTN.Parent then COPY_BTN.Text="Copy Payload" end
                end)
            end)

            conns.imgui = IMGUI_BTN.MouseButton1Click:Connect(function()
                if G.showGrantUI then
                    local safeResult = {
                        confirmed = thisResult and thisResult.confirmed,
                        evidence  = thisResult and thisResult.evidence or "",
                        remote    = thisResult and thisResult.remote or "",
                        payload   = thisResult and thisResult.payload or {},
                        source    = thisResult and thisResult.source or "",
                        deltas    = {},
                        responses = {},
                        category  = thisCat.id,
                    }
                    if G.GRANT_RESULTS then
                        for _,gr in ipairs(G.GRANT_RESULTS) do
                            if gr.category == thisCat.id then
                                for _,hit in ipairs(gr.hits or {}) do
                                    for _,d in ipairs(hit.deltas or {}) do
                                        table.insert(safeResult.deltas, d)
                                    end
                                end
                            end
                        end
                    end
                    G.showGrantUI(thisCat.id, safeResult)
                else
                    addLog("INFO","GRANT UI not loaded — check loader")
                end
            end)

            conns.again = AGAIN_BTN.MouseButton1Click:Connect(function()
                if not thisResult.payload or not thisResult.remote then return end
                addLogSep("FIRING CONFIRMED GRANT PATH AGAIN")
                local remote=findR(thisResult.remote)
                if remote and thisResult.payload then
                    local r2=fireGrantProbe(remote,
                        type(thisResult.payload)=="table" and
                        (thisResult.payload[1] and thisResult.payload
                         or {thisResult.payload}) or
                        {thisResult.payload})
                    local conf2,ev2=thisCat.confirm(r2.before,r2.after,r2.deltas)
                    addLog(conf2 and "FINDING" or "INFO",
                        conf2 and "Grant re-confirmed" or "No confirmation this time",
                        ev2 or ("Deltas: "..#r2.deltas.."  Responses: "..#r2.responses),
                        conf2)
                end
            end)
        else
            GNT_STATUS.Text=result and result.best and
                "partial hit — see log" or "no grant path found"
            GNT_STATUS.TextColor3=result and result.best and
                Color3.fromRGB(255,160,40) or C.MUTED
        end

        tw(FIRE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(180,140,20)})
        running=false
    end)
end)

-- Auto-refresh intel on tab open
P_GNT:GetPropertyChangedSignal("Visible"):Connect(function()
    if P_GNT.Visible then
        buildIntelSummary()
        if G.RBOX and G.RBOX.Text~="" and REM_BOX.Text=="" then
            REM_BOX.Text=G.RBOX.Text
        end
    end
end)

-- Export for GRANT UI and other modules
G.GRANT_RESULTS  = GRANT_RESULTS
G.grant_attempt  = executeGrant
G.grant_payloads = buildGrantPayloads  -- so 30_grantui can call it

if G.addTab then
    G.addTab("grant","GRANT",P_GNT)
else
    warn("[Oracle] G.addTab not found")
end
