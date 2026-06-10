-- Oracle // 36_trust.lua
-- TRUST — Numeric Argument Trust Engine
-- ─────────────────────────────────────────────────────────────────────────────
-- ASM  — Argument Signature Mapper     maps what each remote accepts
-- ME   — Mutation Engine               six vulnerability families
-- SCE  — State Correlation Engine      proportionality proof
-- CE   — Confirmation Engine           two-shot verification
-- CLF  — Classifier                    severity + fix generation
-- ─────────────────────────────────────────────────────────────────────────────
-- Entry point for 38_chain.lua — findings feed the chain automatically

local G      = ...
local vs     = G.vs
local snap   = G.snap
local dif    = G.dif
local LP     = G.LP
local RepS   = G.RepS

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CONSTANTS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local RATIO_MULTIPLIER   = 10    -- arg step: fire(1) then fire(10)
local RATIO_TOLERANCE    = 0.35  -- 35% — allows for server caps/taxes/rounding
local PROBE_WAIT         = 0.18  -- seconds between fires
local SNAP_WAIT          = 0.30  -- seconds after fire before snapshot
local CONFIRM_SHOTS      = 2     -- independent re-fires needed to certify
local MAX_REMOTES_QUICK  = 10    -- quick scan remote cap
local MAX_REMOTES_FULL   = 30    -- full audit remote cap

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- VULNERABILITY FAMILY DEFINITIONS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local FAMILIES = {
    NUMERIC = {
        label    = "Numeric Argument Trust",
        severity = "CRITICAL",
        desc     = "Server accepts and applies a client-provided numeric value "
                .. "without validation. Sending an inflated number directly "
                .. "inflates the resulting stat or reward.",
        fix      = "Never use a client-provided amount to modify server state. "
                .. "Calculate all rewards, costs, and stat changes entirely "
                .. "server-side and ignore the client's suggested value.",
    },
    PRICE = {
        label    = "Free Purchase / Price Override",
        severity = "CRITICAL",
        desc     = "Server accepts a client-provided price, allowing items to "
                .. "be purchased at an arbitrary cost including zero.",
        fix      = "Store all item prices in a server-side table keyed by "
                .. "item ID. Ignore any price value sent by the client.",
    },
    PERMISSION = {
        label    = "Privilege Escalation",
        severity = "CRITICAL",
        desc     = "Server accepts a client-provided role, rank, or permission "
                .. "claim and acts on it without server-side verification.",
        fix      = "Never accept role or rank values from the client. Resolve "
                .. "all permissions server-side from a trusted DataStore or "
                .. "GroupService call.",
    },
    IDENTITY = {
        label    = "Player Identity Spoofing",
        severity = "HIGH",
        desc     = "Server acts on a player name or UserId supplied by the "
                .. "client rather than the authenticated sender.",
        fix      = "Always use the player parameter Roblox injects into "
                .. "OnServerEvent/OnServerInvoke. Never trust a client-sent "
                .. "identity string or ID.",
    },
    COORDINATE = {
        label    = "Position Injection",
        severity = "MEDIUM",
        desc     = "Server teleports or moves the player to a position "
                .. "provided by the client without boundary validation.",
        fix      = "Validate destination against a server-side list of "
                .. "allowed zones or waypoints. Never apply a raw "
                .. "client-provided CFrame or Vector3 directly.",
    },
    DATA = {
        label    = "DataStore Write Trust",
        severity = "HIGH",
        desc     = "Server writes arbitrary client-provided data to "
                .. "persistent storage without sanitisation or schema "
                .. "validation.",
        fix      = "Define a strict schema for what is allowed in each "
                .. "DataStore key. Validate and sanitise every field "
                .. "before writing. Reject anything outside the schema.",
    },
}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PRIORITY SCORING
-- Remotes whose names signal economy/stat/admin targets are probed first.
-- Higher score = earlier in the queue.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local PRIORITY_PATTERNS = {
    {pat="[Cc]oin",       w=10}, {pat="[Cc]ash",       w=10},
    {pat="[Gg]em",        w=10}, {pat="[Bb]ux",        w=10},
    {pat="[Bb]uy",        w=9},  {pat="[Pp]urchase",   w=9},
    {pat="[Ss]hop",       w=9},  {pat="[Ss]ell",       w=8},
    {pat="[Rr]eward",     w=8},  {pat="[Cc]laim",      w=8},
    {pat="[Ee]arn",       w=7},  {pat="[Gg]ive",       w=7},
    {pat="[Xx][Pp]",      w=9},  {pat="[Ll]evel",      w=8},
    {pat="[Ss]tat",       w=7},  {pat="[Ss]core",      w=7},
    {pat="[Kk]ill",       w=6},  {pat="[Dd]amage",     w=6},
    {pat="[Hh]ealth",     w=6},  {pat="[Ss]peed",      w=5},
    {pat="[Aa]dmin",      w=9},  {pat="[Cc]ommand",    w=8},
    {pat="[Ee]xec",       w=7},  {pat="[Rr]ank",       w=7},
    {pat="[Rr]ole",       w=7},  {pat="[Pp]erm",       w=7},
    {pat="[Ss]ave",       w=6},  {pat="[Ll]oad",       w=5},
    {pat="[Dd]ata",       w=5},  {pat="[Tt]ele",       w=6},
    {pat="[Mm]ove",       w=5},  {pat="[Tt]p",         w=6},
}

local function scoreRemote(remote)
    local score = 0
    for _, p in ipairs(PRIORITY_PATTERNS) do
        if remote.Name:find(p.pat) then score = score + p.w end
    end
    -- RemoteFunctions return values, making proportionality clearer
    if remote:IsA("RemoteFunction") then score = score + 3 end
    return score
end

local function prioritiseRemotes(remotes)
    local t = {}
    for _, r in ipairs(remotes) do
        table.insert(t, {r=r, s=scoreRemote(r)})
    end
    table.sort(t, function(a,b) return a.s > b.s end)
    local out = {}
    for _, x in ipairs(t) do table.insert(out, x.r) end
    return out
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- UTIL
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local _aborted = false

local function fire(remote, args)
    local ok, ret = pcall(function()
        if remote:IsA("RemoteFunction") then
            return remote:InvokeServer(table.unpack(args))
        else
            remote:FireServer(table.unpack(args))
            return nil
        end
    end)
    return ok, ret
end

-- Extended snapshot — wraps G.snap() and adds character state
local function xsnap()
    local s  = snap()
    local ch = LP.Character
    if ch then
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        if hrp then
            s["__pos_x"] = math.floor(hrp.Position.X)
            s["__pos_y"] = math.floor(hrp.Position.Y)
            s["__pos_z"] = math.floor(hrp.Position.Z)
        end
        local hum = ch:FindFirstChildOfClass("Humanoid")
        if hum then
            s["__health"]    = math.floor(hum.Health)
            s["__walkspeed"] = hum.WalkSpeed
            s["__jumppower"] = hum.JumpPower
        end
    end
    return s
end

-- Returns only numeric deltas as { [path] = delta }
local function numericDeltas(before, after)
    local out = {}
    for _, entry in ipairs(dif(before, after)) do
        local b = tonumber(entry.bv)
        local a = tonumber(entry.av)
        if b and a and b ~= a then
            out[entry.path] = a - b
        end
    end
    return out
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ASM — ARGUMENT SIGNATURE MAPPER
-- Fires structured type probes to determine what each remote accepts.
-- Output feeds ME so mutations target the right arg shape.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local ASM_PROBES = {
    {args={},                              tag="empty"       },
    {args={0},                             tag="zero"        },
    {args={1},                             tag="one"         },
    {args={"test"},                        tag="string"      },
    {args={true},                          tag="bool"        },
    {args={{}},                            tag="table_empty" },
    {args={{action="get"}},               tag="action_get"  },
    {args={{value=1}},                    tag="value_one"   },
    {args={"key",1},                      tag="key_val"     },
    {args={1,1},                           tag="two_nums"    },
    {args={{action="buy",price=1}},       tag="buy_price"   },
    {args={{action="add",amount=1}},      tag="add_amount"  },
    {args={{type="query"}},               tag="type_query"  },
}

local function mapSignature(remote)
    local sig = {
        acceptsNumeric = false,
        acceptsTable   = false,
        acceptsString  = false,
        acceptsEmpty   = false,
        returnsValue   = false,
        accepted       = {},
        errors         = {},
    }
    for _, probe in ipairs(ASM_PROBES) do
        if _aborted then break end
        task.wait(PROBE_WAIT * 0.4)
        local ok, ret = fire(remote, probe.args)
        if ok then
            table.insert(sig.accepted, probe.tag)
            local t = probe.tag
            if t=="empty"                    then sig.acceptsEmpty   = true end
            if t=="zero" or t=="one"
            or t=="two_nums"                 then sig.acceptsNumeric = true end
            if t:find("table") or t:find("action")
            or t:find("value") or t:find("buy")
            or t:find("add")                 then sig.acceptsTable   = true end
            if t=="string"                   then sig.acceptsString  = true end
            if ret ~= nil and ret ~= true    then sig.returnsValue   = true end
        else
            table.insert(sig.errors, tostring(ret):sub(1,60))
        end
    end
    return sig
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SCE — STATE CORRELATION ENGINE
-- The proof mechanism. Fires wrapper(1) and wrapper(10).
-- If state change scales proportionally → trust confirmed mathematically.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function probeProportionality(remote, wrapperFn)
    -- Step A: fire with arg=1
    local b1 = xsnap()
    task.wait(PROBE_WAIT)
    fire(remote, wrapperFn(1))
    task.wait(SNAP_WAIT)
    local d1 = numericDeltas(b1, xsnap())

    if not next(d1) then return nil end -- no state change, skip

    -- Step B: fire with arg=RATIO_MULTIPLIER (10)
    local b10 = xsnap()
    task.wait(PROBE_WAIT)
    fire(remote, wrapperFn(RATIO_MULTIPLIER))
    task.wait(SNAP_WAIT)
    local d10 = numericDeltas(b10, xsnap())

    -- Step C: check proportionality across every changed path
    local evidence = {}
    for path, delta1 in pairs(d1) do
        if delta1 ~= 0 then
            local delta10 = d10[path]
            if delta10 and delta10 ~= 0 then
                local ratio     = delta10 / delta1
                local deviation = math.abs(ratio - RATIO_MULTIPLIER)
                                / RATIO_MULTIPLIER
                if deviation <= RATIO_TOLERANCE then
                    table.insert(evidence, {
                        path      = path,
                        arg1      = 1,
                        delta1    = delta1,
                        arg10     = RATIO_MULTIPLIER,
                        delta10   = delta10,
                        ratio     = ratio,
                        deviation = deviation,
                    })
                end
            end
        end
    end

    if #evidence == 0 then return nil end
    return evidence
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CE — CONFIRMATION ENGINE
-- Re-runs the proportionality probe independently CONFIRM_SHOTS times.
-- A finding is only CONFIRMED if it holds on at least one re-run.
-- Prevents false positives from server noise or natural state drift.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function confirmFinding(remote, wrapperFn, evidence)
    local path = evidence[1].path
    local hits = 0

    for _ = 1, CONFIRM_SHOTS do
        if _aborted then break end
        task.wait(PROBE_WAIT)

        local b1 = xsnap()
        fire(remote, wrapperFn(1))
        task.wait(SNAP_WAIT)
        local d1 = numericDeltas(b1, xsnap())

        task.wait(PROBE_WAIT)

        local b10 = xsnap()
        fire(remote, wrapperFn(RATIO_MULTIPLIER))
        task.wait(SNAP_WAIT)
        local d10 = numericDeltas(b10, xsnap())

        local delta1  = d1[path]
        local delta10 = d10[path]

        if delta1 and delta10 and delta1 ~= 0 then
            local ratio     = delta10 / delta1
            local deviation = math.abs(ratio - RATIO_MULTIPLIER)
                            / RATIO_MULTIPLIER
            if deviation <= RATIO_TOLERANCE then
                hits = hits + 1
            end
        end
    end

    return hits >= 1
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ME — MUTATION ENGINE
-- Wrapper tables for each vulnerability family.
-- Each wrapper is a function: (value) → args[]
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local NUMERIC_WRAPPERS = {
    {tag="raw",            fn=function(v) return {v}                                    end},
    {tag="amount",         fn=function(v) return {{amount=v}}                           end},
    {tag="value",          fn=function(v) return {{value=v}}                            end},
    {tag="quantity",       fn=function(v) return {{quantity=v}}                         end},
    {tag="count",          fn=function(v) return {{count=v}}                            end},
    {tag="reward",         fn=function(v) return {{reward=v}}                           end},
    {tag="coins",          fn=function(v) return {{coins=v}}                            end},
    {tag="cash",           fn=function(v) return {{cash=v}}                             end},
    {tag="xp",             fn=function(v) return {{xp=v}}                              end},
    {tag="damage",         fn=function(v) return {{damage=v}}                           end},
    {tag="score",          fn=function(v) return {{score=v}}                            end},
    {tag="points",         fn=function(v) return {{points=v}}                           end},
    {tag="action_add",     fn=function(v) return {{action="add",    amount=v}}          end},
    {tag="action_reward",  fn=function(v) return {{action="reward", amount=v}}          end},
    {tag="action_give",    fn=function(v) return {{action="give",   amount=v}}          end},
    {tag="action_earn",    fn=function(v) return {{action="earn",   xp=v}}             end},
    {tag="action_grant",   fn=function(v) return {{action="grant",  value=v}}           end},
    {tag="price_qty",      fn=function(v) return {{price=1, quantity=v}}                end},
}

local PRICE_WRAPPERS = {
    {tag="price",          fn=function(v) return {{price=v}}                            end},
    {tag="cost",           fn=function(v) return {{cost=v}}                             end},
    {tag="action_buy",     fn=function(v) return {{action="buy",     price=v, itemId=1}}end},
    {tag="action_purchase",fn=function(v) return {{action="purchase",cost=v}}           end},
    {tag="shop",           fn=function(v) return {{action="shop",    price=v, item=1}}  end},
    {tag="buy_free",       fn=function(v) return {{buy=true, price=v}}                  end},
}

local PERM_WRAPPERS = {
    {tag="role",           fn=function(v) return {{role=v}}                             end},
    {tag="rank",           fn=function(v) return {{rank=v}}                             end},
    {tag="admin",          fn=function(v) return {{admin=v}}                            end},
    {tag="permission",     fn=function(v) return {{permission=v}}                       end},
    {tag="isAdmin",        fn=function(v) return {{isAdmin=v}}                          end},
    {tag="auth",           fn=function(v) return {{auth=v}}                             end},
    {tag="action_admin",   fn=function(v) return {{action="admin",   role=v}}           end},
    {tag="level",          fn=function(v) return {{level=v}}                            end},
}

local PERM_VALUES = {
    "admin","owner","developer","staff","moderator",
    "superadmin","vip","premium","root","operator",
    true, 999, 100, 9999,
}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PROBE REMOTE
-- Runs all applicable families against one remote.
-- Returns a list of findings (empty = clean).
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function makeFinding(family, remote, wrapperTag, evidence, confirmed)
    local fam = FAMILIES[family]
    return {
        family    = family,
        remote    = remote.Name,
        wrapper   = wrapperTag,
        evidence  = evidence,
        confirmed = confirmed,
        severity  = fam.severity,
        label     = fam.label,
        desc      = fam.desc,
        fix       = fam.fix,
        timestamp = tick(),
    }
end

local function probeRemote(remote, families, logFn)
    if _aborted then return {} end
    local findings = {}
    families = families or {
        NUMERIC=true, PRICE=true, PERMISSION=true,
        IDENTITY=false, COORDINATE=false, DATA=false,
    }

    -- ── NUMERIC ──────────────────────────────────────────────────────────────
    if families.NUMERIC then
        for _, w in ipairs(NUMERIC_WRAPPERS) do
            if _aborted then break end
            task.wait(PROBE_WAIT)
            local evidence = probeProportionality(remote, w.fn)
            if evidence then
                local confirmed = confirmFinding(remote, w.fn, evidence)
                local f = makeFinding("NUMERIC", remote, w.tag, evidence, confirmed)
                table.insert(findings, f)
                if logFn then
                    logFn(
                        confirmed and "FINDING" or "INFO",
                        ("[NUMERIC%s] %s — wrapper: %s"):format(
                            confirmed and " ✓" or " ~", remote.Name, w.tag),
                        ("ratio %.2fx on %s  (dev %.0f%%)"):format(
                            evidence[1].ratio,
                            evidence[1].path,
                            evidence[1].deviation * 100),
                        confirmed
                    )
                end
                -- One confirmed wrapper per family is sufficient
                if confirmed then break end
            end
        end
    end

    -- ── PRICE ────────────────────────────────────────────────────────────────
    if families.PRICE and not _aborted then
        for _, w in ipairs(PRICE_WRAPPERS) do
            if _aborted then break end

            -- Baseline: what happens at normal price
            local b_norm = xsnap()
            task.wait(PROBE_WAIT)
            fire(remote, w.fn(100))
            task.wait(SNAP_WAIT)
            local d_norm = numericDeltas(b_norm, xsnap())

            -- Attack: what happens at price=0
            local b_zero = xsnap()
            task.wait(PROBE_WAIT)
            fire(remote, w.fn(0))
            task.wait(SNAP_WAIT)
            local d_zero = numericDeltas(b_zero, xsnap())

            -- If a positive stat/inventory change occurred at price=0
            -- the server accepted a free purchase
            for path, dz in pairs(d_zero) do
                if dz > 0 then
                    local evidence = {{
                        path        = path,
                        price_normal= 100,
                        price_attack= 0,
                        delta_zero  = dz,
                    }}
                    local f = makeFinding("PRICE", remote, w.tag, evidence, true)
                    table.insert(findings, f)
                    if logFn then
                        logFn("FINDING",
                            ("[PRICE ✓] %s — free purchase via %s"):format(
                                remote.Name, w.tag),
                            ("price=0 → +%s on [%s]"):format(
                                tostring(dz), path),
                            true)
                    end
                    break
                end
            end

            if #findings > 0 then break end
        end
    end

    -- ── PERMISSION ───────────────────────────────────────────────────────────
    if families.PERMISSION and not _aborted then
        -- Baseline: fire with no role claim
        local b_base = xsnap()
        task.wait(PROBE_WAIT)
        fire(remote, {{}})
        task.wait(SNAP_WAIT)
        local base_count = #dif(b_base, xsnap())

        for _, w in ipairs(PERM_WRAPPERS) do
            if _aborted then break end
            for _, val in ipairs(PERM_VALUES) do
                if _aborted then break end
                task.wait(PROBE_WAIT)
                local b = xsnap()
                fire(remote, w.fn(val))
                task.wait(SNAP_WAIT)
                local changes = dif(b, xsnap())

                -- More state changes after elevated claim = escalation
                if #changes > base_count + 1 then
                    local evidence = {{
                        wrapper    = w.tag,
                        value      = tostring(val),
                        changes    = #changes,
                        baseline   = base_count,
                    }}
                    local f = makeFinding("PERMISSION", remote, w.tag, evidence, true)
                    table.insert(findings, f)
                    if logFn then
                        logFn("FINDING",
                            ("[PERMISSION ✓] %s — escalation: %s=%s"):format(
                                remote.Name, w.tag, tostring(val)),
                            ("%d state change(s) vs baseline %d"):format(
                                #changes, base_count),
                            true)
                    end
                    break
                end
            end
            if #findings > 0 then break end
        end
    end

    return findings
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SCAN RUNNER
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local TRUST_FINDINGS = {}

local function runScan(options, logFn, progressFn)
    -- options = {
    --   quickMode  : bool    top-10 remotes, NUMERIC+PRICE only
    --   families   : table   { NUMERIC=bool, PRICE=bool, PERMISSION=bool, ... }
    --   maxRemotes : number  override remote cap
    -- }
    options        = options or {}
    _aborted       = false
    TRUST_FINDINGS = {}

    local ev, fn = G.discR()
    local all    = {}
    for _, r in ipairs(ev) do table.insert(all, r) end
    for _, r in ipairs(fn) do table.insert(all, r) end

    all = prioritiseRemotes(all)

    local cap = options.maxRemotes
        or (options.quickMode and MAX_REMOTES_QUICK or MAX_REMOTES_FULL)

    local remotes = {}
    for i = 1, math.min(cap, #all) do
        table.insert(remotes, all[i])
    end

    local families = options.families
    if options.quickMode and not families then
        families = {NUMERIC=true, PRICE=true}
    end

    for i, remote in ipairs(remotes) do
        if _aborted then break end
        if progressFn then progressFn(i, #remotes, remote.Name) end
        if logFn then
            logFn("INFO",
                ("[%d/%d] %s"):format(i, #remotes, remote.Name),
                "ASM signature map → ME mutation → SCE proportionality → CE confirm")
        end

        local findings = probeRemote(remote, families, logFn)
        for _, f in ipairs(findings) do
            table.insert(TRUST_FINDINGS, f)
        end

        task.wait(PROBE_WAIT)
    end

    -- Sort output: CRITICAL confirmed first
    table.sort(TRUST_FINDINGS, function(a, b)
        local sev = {CRITICAL=0, HIGH=1, MEDIUM=2, LOW=3}
        local as  = (sev[a.severity] or 9) * 2 + (a.confirmed and 0 or 1)
        local bs  = (sev[b.severity] or 9) * 2 + (b.confirmed and 0 or 1)
        return as < bs
    end)

    return TRUST_FINDINGS
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- EXPORTS
-- Everything 37_trustui.lua and 38_chain.lua need
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

G.TRUST_FINDINGS        = TRUST_FINDINGS
G.TRUST_FAMILIES        = FAMILIES

G.trust_scan            = runScan
G.trust_probeRemote     = probeRemote
G.trust_mapSignature    = mapSignature
G.trust_scoreRemote     = scoreRemote
G.trust_prioritise      = prioritiseRemotes
G.trust_abort           = function() _aborted = true end
G.trust_isAborted       = function() return _aborted end
G.trust_getFindings     = function() return TRUST_FINDINGS end

-- Chain entry point — 38_chain.lua reads confirmed findings from here
-- and uses the remote reference + wrapper tag to probe downstream systems
G.trust_confirmedOnly   = function()
    local out = {}
    for _, f in ipairs(TRUST_FINDINGS) do
        if f.confirmed then table.insert(out, f) end
    end
    return out
end
