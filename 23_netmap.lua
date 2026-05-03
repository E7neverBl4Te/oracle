-- Oracle // 23_netmap.lua
-- NETMAP — Network Topology & Timing Intelligence
-- Differential latency mapping · Queue depth inference · Server topology analysis
-- Correlated spike detection · Tick rate measurement · Instance fingerprinting
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

local RS  = game:GetService("RunService")
local Stats = game:GetService("Stats")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- NETMAP ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Measurement window
local HISTORY_SIZE  = 300    -- samples to keep per channel
local SPIKE_THRESH  = 2.5    -- stddev multiplier to flag a spike
local TICK_SAMPLES  = 120    -- heartbeat samples for tick rate
local QUEUE_SAMPLES = 8      -- simultaneous fires for queue depth probe

-- Per-channel latency series
local CHANNELS = {}   -- [name] = {samples[], mean, stddev, spikes[]}
local SPIKES   = {}   -- [{tick, channels[], magnitude}] correlated spikes
local TOPOLOGY = {}   -- inferred topology facts
local TICKDATA = {}   -- raw heartbeat deltas

-- ── Maths helpers ─────────────────────────────────────────────────────────────
local function mean(t)
    if #t == 0 then return 0 end
    local s = 0; for _,v in ipairs(t) do s += v end; return s / #t
end

local function variance(t, m)
    if #t < 2 then return 0 end
    m = m or mean(t); local s = 0
    for _,v in ipairs(t) do s += (v-m)^2 end
    return s / #t
end

local function stddev(t, m)
    return math.sqrt(variance(t, m))
end

local function median(t)
    if #t == 0 then return 0 end
    local s = {}; for _,v in ipairs(t) do table.insert(s,v) end
    table.sort(s); return s[math.ceil(#s/2)]
end

local function percentile(t, p)
    if #t == 0 then return 0 end
    local s = {}; for _,v in ipairs(t) do table.insert(s,v) end
    table.sort(s)
    local idx = math.ceil(#s * p / 100)
    return s[math.min(idx, #s)]
end

local function pearson(xs, ys)
    -- Pearson correlation coefficient between two series
    if #xs ~= #ys or #xs < 2 then return 0 end
    local mx,my = mean(xs), mean(ys)
    local num,dx,dy = 0,0,0
    for i=1,#xs do
        local xi,yi = xs[i]-mx, ys[i]-my
        num += xi*yi; dx += xi*xi; dy += yi*yi
    end
    local denom = math.sqrt(dx*dy)
    return denom == 0 and 0 or num/denom
end

-- ── Channel management ────────────────────────────────────────────────────────
local function getChannel(name)
    if not CHANNELS[name] then
        CHANNELS[name] = {
            name    = name,
            samples = {},
            spikes  = {},
            mean    = 0,
            stddev  = 0,
            median  = 0,
            p95     = 0,
            p99     = 0,
            min     = math.huge,
            max     = 0,
            count   = 0,
        }
    end
    return CHANNELS[name]
end

local function recordSample(name, latencyMs)
    local ch = getChannel(name)
    if #ch.samples >= HISTORY_SIZE then table.remove(ch.samples, 1) end
    table.insert(ch.samples, latencyMs)
    ch.count += 1
    ch.min = math.min(ch.min, latencyMs)
    ch.max = math.max(ch.max, latencyMs)

    -- Recompute stats every 10 samples
    if ch.count % 10 == 0 or #ch.samples < 10 then
        ch.mean   = mean(ch.samples)
        ch.stddev = stddev(ch.samples, ch.mean)
        ch.median = median(ch.samples)
        ch.p95    = percentile(ch.samples, 95)
        ch.p99    = percentile(ch.samples, 99)
    end

    -- Spike detection
    local threshold = ch.mean + SPIKE_THRESH * ch.stddev
    if ch.stddev > 0 and latencyMs > threshold and #ch.samples > 20 then
        table.insert(ch.spikes, {tick=tick(), latency=latencyMs,
            zscore=(latencyMs-ch.mean)/ch.stddev})
        if #ch.spikes > 100 then table.remove(ch.spikes, 1) end
    end

    return ch
end

-- ── Latency probe engine ──────────────────────────────────────────────────────
local function probeLatency(remote)
    local t0 = tick()
    local ok, _ = pcall(function()
        if remote:IsA("RemoteFunction") then
            remote:InvokeServer()
        else
            -- For RemoteEvents use hookR to detect response
            remote:FireServer()
        end
    end)
    local elapsed = (tick() - t0) * 1000
    return ok and elapsed or nil
end

-- Simultaneous multi-probe for queue depth measurement
-- Fires N remotes at the same instant and measures how latency
-- scales with queue depth — linear scaling = shared queue
local function probeQueueDepth(remotes, logFn)
    if #remotes < 2 then
        if logFn then logFn("INFO","Queue depth probe needs ≥2 remotes") end
        return nil
    end

    local results = {}

    -- Baseline: probe each remote individually
    local baselines = {}
    for _, r in ipairs(remotes) do
        local lat = probeLatency(r)
        if lat then
            baselines[r.Name] = lat
            table.insert(results, {remote=r.Name, baseline=lat})
        end
        task.wait(0.1)
    end

    task.wait(0.5)

    -- Simultaneous probe: fire all at once, measure each
    local concurrent = {}
    local threads = {}
    for _, r in ipairs(remotes) do
        local rname = r.Name
        table.insert(threads, task.spawn(function()
            local t0 = tick()
            local ok,_ = pcall(function()
                if r:IsA("RemoteFunction") then r:InvokeServer()
                else r:FireServer() end
            end)
            local lat = (tick()-t0)*1000
            concurrent[rname] = lat
        end))
    end
    -- Wait for all
    task.wait(3)

    -- Compute queue pressure: ratio of concurrent to baseline
    local pressureRatios = {}
    for _, r in ipairs(remotes) do
        local base = baselines[r.Name]
        local conc = concurrent[r.Name]
        if base and conc and base > 0 then
            table.insert(pressureRatios, conc / base)
        end
    end

    local avgPressure = mean(pressureRatios)

    -- Interpretation
    local queueType
    if avgPressure < 1.1 then
        queueType = "PARALLEL — handlers run concurrently, independent queues"
    elseif avgPressure < 1.5 then
        queueType = "PARTIAL — some shared queue pressure detected"
    elseif avgPressure < 2.5 then
        queueType = "SHARED — remotes share a processing queue"
    else
        queueType = "SERIAL — single queue, remotes processed one at a time"
    end

    return {
        baselines     = baselines,
        concurrent    = concurrent,
        pressureRatios= pressureRatios,
        avgPressure   = avgPressure,
        queueType     = queueType,
    }
end

-- ── Tick rate measurement ─────────────────────────────────────────────────────
local function measureTickRate(logFn)
    TICKDATA = {}
    local done = false
    local conn = RS.Heartbeat:Connect(function(dt)
        table.insert(TICKDATA, dt)
        if #TICKDATA >= TICK_SAMPLES then done=true end
    end)
    local timeout = tick() + 15
    while not done and tick() < timeout do task.wait() end
    conn:Disconnect()

    if #TICKDATA < 10 then
        if logFn then logFn("INFO","Insufficient tick data") end
        return nil
    end

    local deltas = TICKDATA
    local mn  = mean(deltas)
    local sd  = stddev(deltas, mn)
    local med = median(deltas)
    local p95 = percentile(deltas, 95)
    local p99 = percentile(deltas, 99)

    -- Detect server tick rate from client heartbeat
    -- Client runs at ~60hz client-side but syncs to server tick
    local nominalHz  = 1 / mn
    local stability  = 1 - (sd / mn)  -- 1.0 = perfect, lower = jittery

    -- Detect spike clusters — correlated with server GC or network events
    local spikeTicks = {}
    local spikeThresh = mn + 2.5*sd
    for i,dt in ipairs(deltas) do
        if dt > spikeThresh then
            table.insert(spikeTicks, {idx=i, dt=dt, zscore=(dt-mn)/sd})
        end
    end

    -- Cluster spikes — spikes within 5 frames of each other = same event
    local clusters = {}
    local currentCluster = nil
    for _, sp in ipairs(spikeTicks) do
        if not currentCluster or sp.idx - currentCluster.last > 5 then
            currentCluster = {start=sp.idx, last=sp.idx, count=1, maxZ=sp.zscore}
            table.insert(clusters, currentCluster)
        else
            currentCluster.last  = sp.idx
            currentCluster.count += 1
            currentCluster.maxZ   = math.max(currentCluster.maxZ, sp.zscore)
        end
    end

    -- Infer server load from spike frequency and magnitude
    local spikeRate = #spikeTicks / #deltas
    local serverLoad
    if     spikeRate < 0.01 then serverLoad = "IDLE — clean tick, minimal load"
    elseif spikeRate < 0.05 then serverLoad = "NORMAL — occasional spikes, healthy"
    elseif spikeRate < 0.15 then serverLoad = "ELEVATED — frequent spikes, active load"
    else                         serverLoad = "STRESSED — sustained spikes, heavy load" end

    -- Infer shared vs dedicated hardware from spike pattern regularity
    -- Periodic spikes at fixed intervals = scheduled GC on shared host
    local periodicScore = 0
    if #clusters >= 3 then
        local intervals = {}
        for i=2,#clusters do
            table.insert(intervals, clusters[i].start - clusters[i-1].start)
        end
        local intervalSD = stddev(intervals, mean(intervals))
        local intervalMean = mean(intervals)
        if intervalMean > 0 then
            periodicScore = 1 - math.min(intervalSD/intervalMean, 1)
        end
    end

    local hostType
    if     periodicScore > 0.75 then hostType = "SHARED HOST — periodic GC pattern detected"
    elseif periodicScore > 0.40 then hostType = "LIKELY SHARED — semi-regular spike pattern"
    else                              hostType = "DEDICATED or ISOLATED — irregular spikes" end

    return {
        samples     = #deltas,
        mean        = mn,
        stddev      = sd,
        median      = med,
        p95         = p95,
        p99         = p99,
        nominalHz   = nominalHz,
        stability   = stability,
        spikes      = #spikeTicks,
        clusters    = clusters,
        spikeRate   = spikeRate,
        serverLoad  = serverLoad,
        periodicScore= periodicScore,
        hostType    = hostType,
    }
end

-- ── Correlated spike detection across channels ────────────────────────────────
-- If two channels spike at the same time they likely share infrastructure
local function detectCorrelatedSpikes(logFn)
    local names = {}
    for name in pairs(CHANNELS) do table.insert(names, name) end
    if #names < 2 then return {} end

    local correlations = {}

    for i=1,#names do
        for j=i+1,#names do
            local a = CHANNELS[names[i]]
            local b = CHANNELS[names[j]]
            if #a.samples >= 20 and #b.samples >= 20 then
                -- Use shorter length
                local len = math.min(#a.samples, #b.samples)
                local as  = {}; for k=#a.samples-len+1,#a.samples do table.insert(as,a.samples[k]) end
                local bs  = {}; for k=#b.samples-len+1,#b.samples do table.insert(bs,b.samples[k]) end
                local r   = pearson(as, bs)
                if math.abs(r) > 0.3 then
                    table.insert(correlations, {
                        a=names[i], b=names[j], r=r,
                        shared = r > 0.5,
                        anti   = r < -0.3,
                    })
                    if logFn then
                        logFn(math.abs(r)>0.5 and "FINDING" or "INFO",
                            ("Correlation: %s ↔ %s"):format(names[i],names[j]),
                            ("r=%.2f — %s"):format(r,
                                r>0.5 and "SHARED QUEUE likely" or
                                r<-0.3 and "COMPETING for resource" or
                                "weak correlation"),
                            math.abs(r)>0.5)
                    end
                end
            end
        end
    end

    table.sort(correlations, function(a,b) return math.abs(a.r)>math.abs(b.r) end)
    return correlations
end

-- ── Continuous monitoring ─────────────────────────────────────────────────────
local monitorActive  = false
local monitorThread  = nil
local monitorRemotes = {}

local function startMonitor(remotes, logFn)
    if monitorActive then return end
    monitorActive = true
    monitorRemotes = remotes

    monitorThread = task.spawn(function()
        while monitorActive do
            -- Round-robin probe each monitored remote
            for _, r in ipairs(monitorRemotes) do
                if not monitorActive then break end
                local lat = probeLatency(r)
                if lat then
                    local ch = recordSample(r.Name, lat)
                    -- Flag spike to UI
                    local threshold = ch.mean + SPIKE_THRESH * ch.stddev
                    if ch.stddev > 0 and lat > threshold and #ch.samples > 20 then
                        if logFn then
                            logFn("FINDING",
                                ("SPIKE: %s — %.0fms"):format(r.Name, lat),
                                ("z=%.1f  mean=%.0f  p95=%.0f"):format(
                                    (lat-ch.mean)/ch.stddev, ch.mean, ch.p95),
                                true)
                        end
                    end
                end
                task.wait(0.3)
            end
        end
    end)
end

local function stopMonitor()
    monitorActive = false
    if monitorThread then task.cancel(monitorThread); monitorThread=nil end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- NETMAP PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_NET = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- top bar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_NET)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⬡  NETMAP — NETWORK TOPOLOGY",
    TextColor3=Color3.fromRGB(80,180,255),TextSize=11,
    Size=UDim2.new(0,280,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local NET_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,140,1,0),Position=UDim2.new(1,-390,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- Buttons
local TICK_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(30,60,120),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⏱ Tick",TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,54,0,22),Position=UDim2.new(1,-376,0.5,-11),ZIndex=6},TOPBAR)
corner(5,TICK_BTN); stroke(Color3.fromRGB(80,140,255),1,TICK_BTN)

local QUEUE_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(30,60,120),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⬡ Queue",TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,62,0,22),Position=UDim2.new(1,-308,0.5,-11),ZIndex=6},TOPBAR)
corner(5,QUEUE_BTN); stroke(Color3.fromRGB(80,140,255),1,QUEUE_BTN)

local CORR_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(30,60,120),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⟳ Correlate",TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,80,0,22),Position=UDim2.new(1,-234,0.5,-11),ZIndex=6},TOPBAR)
corner(5,CORR_BTN); stroke(Color3.fromRGB(80,140,255),1,CORR_BTN)

local MON_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(20,80,40),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="● Monitor",TextColor3=C.WHITE,TextSize=9,
    Size=UDim2.new(0,76,0,22),Position=UDim2.new(1,-144,0.5,-11),ZIndex=6},TOPBAR)
corner(5,MON_BTN); stroke(Color3.fromRGB(80,210,100),1,MON_BTN)

local FULL_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(80,140,255),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⬡ FULL",TextColor3=Color3.fromRGB(8,8,12),TextSize=10,
    Size=UDim2.new(0,56,0,22),Position=UDim2.new(1,-68,0.5,-11),ZIndex=6},TOPBAR)
corner(5,FULL_BTN)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_NET)

-- left: topology panel
local NL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,230,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},NL)
local TOPO_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},NL)
pad(8,8,TOPO_SCROLL); listV(TOPO_SCROLL,6)

-- right: live log
local NR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,230,0,0),Size=UDim2.new(1,-230,1,0),ZIndex=3},BODY)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},NR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)

local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="NETMAP measures what no other tool does —\n"..
         "the network layer beneath your Remotes.\n\n"..
         "⏱ Tick  — measures server tick rate + host type\n"..
         "⬡ Queue — maps Remote processing queue topology\n"..
         "⟳ Correlate — finds shared infrastructure channels\n"..
         "● Monitor — continuous latency surveillance\n"..
         "⬡ FULL — runs all analyses in sequence",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,120),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- ── Log helpers ───────────────────────────────────────────────────────────────
local nN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; nN+=1; mkRow(tag,msg,detail,hi,LOG_SCROLL,nN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) nN+=1; mkSep(txt,LOG_SCROLL,nN) end
local function clearLog()
    for _,c in ipairs(LOG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    nN=0; LOG_EMPTY.Visible=true
end

-- ── Topology panel builder ────────────────────────────────────────────────────
local function buildTopologyPanel()
    for _,c in ipairs(TOPO_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    local ord=0; local function o() ord+=1; return ord end

    local function statCard(title, val, col, sub)
        local card=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=o()},TOPO_SCROLL)
        corner(6,card); stroke(C.BORDER,1,card); pad(8,6,card); listV(card,3)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=title,TextColor3=C.MUTED,TextSize=8,
            Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=1},card)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=tostring(val),TextColor3=col or C.WHITE,TextSize=11,
            Size=UDim2.new(1,0,0,16),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2},card)
        if sub then
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                Text=sub,TextColor3=C.MUTED,TextSize=8,TextWrapped=true,
                Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=3},card)
        end
    end

    -- Server info from Stats service
    local serverHz = "--"
    local ping     = "--"
    pcall(function()
        local net=Stats:FindFirstChild("Network")
        if net then
            local pingStat=net:FindFirstChild("ServerStatsItem")
            if pingStat then ping=tostring(math.floor(pingStat.Value)).."ms" end
        end
    end)
    local ok,p=pcall(function() return Stats.Network.ServerStatsItem.Value end)
    if not ok then pcall(function() ping=tostring(math.floor(Stats.Network.Ping)).."ms" end) end

    statCard("SERVER PING", ping, Color3.fromRGB(80,180,255))
    statCard("JOB ID", game.JobId:sub(1,16).."...", C.MUTED,
        "Unique server instance identifier")
    statCard("PLACE ID", tostring(game.PlaceId), C.MUTED)
    statCard("PLAYERS", tostring(#game:GetService("Players"):GetPlayers()), C.TEXT,
        "Current server population")

    -- Channel data
    local chNames={}; for n in pairs(CHANNELS) do table.insert(chNames,n) end
    table.sort(chNames,function(a,b) return CHANNELS[a].mean < CHANNELS[b].mean end)

    if #chNames > 0 then
        local sep=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,14),ZIndex=4,LayoutOrder=o()},TOPO_SCROLL)
        mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,0.5,0),ZIndex=4},sep)
        local bg=mk("Frame",{BackgroundColor3=C.BG,BorderSizePixel=0,
            Size=UDim2.fromOffset(90,12),Position=UDim2.new(0,0,0.5,-6),ZIndex=5},sep)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text="CHANNELS",TextColor3=C.MUTED,TextSize=8,
            Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=6},bg)

        for _,name in ipairs(chNames) do
            local ch=CHANNELS[name]
            local col2
            if     ch.p99 < 80  then col2=Color3.fromRGB(80,210,100)
            elseif ch.p99 < 200 then col2=Color3.fromRGB(255,160,40)
            else                      col2=Color3.fromRGB(255,80,80) end

            statCard(name,
                ("%.0f ms"):format(ch.median),
                col2,
                ("min:%.0f  p95:%.0f  p99:%.0f  spikes:%d"):format(
                    ch.min==math.huge and 0 or ch.min,
                    ch.p95, ch.p99, #ch.spikes))
        end
    end
end

-- ── Button handlers ───────────────────────────────────────────────────────────

-- ⏱ Tick rate analysis
TICK_BTN.MouseButton1Click:Connect(function()
    tw(TICK_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(10,30,80)})
    NET_STATUS.Text="measuring tick rate..."; NET_STATUS.TextColor3=C.DELTA
    addLogSep("TICK RATE ANALYSIS — "..TICK_SAMPLES.." samples")
    addLog("INFO","Collecting heartbeat data","Measuring "..TICK_SAMPLES.." frames...")

    task.spawn(function()
        local result = measureTickRate(addLog)
        if result then
            addLog("INFO",
                ("Tick rate: %.1f Hz  stability: %.0f%%"):format(
                    result.nominalHz, result.stability*100),
                ("median: %.2fms  p95: %.2fms  p99: %.2fms"):format(
                    result.median*1000, result.p95*1000, result.p99*1000))
            addLog(result.spikeRate>0.05 and "FINDING" or "CLEAN",
                result.serverLoad,
                ("spike rate: %.1f%%  clusters: %d"):format(
                    result.spikeRate*100, #result.clusters),
                result.spikeRate>0.05)
            addLog(result.periodicScore>0.5 and "FINDING" or "INFO",
                result.hostType,
                ("periodicity score: %.2f"):format(result.periodicScore),
                result.periodicScore>0.5)

            TOPOLOGY.tickRate   = result.nominalHz
            TOPOLOGY.serverLoad = result.serverLoad
            TOPOLOGY.hostType   = result.hostType
            buildTopologyPanel()
        end
        NET_STATUS.Text = result and
            ("%.1fHz — %s"):format(result.nominalHz,
                result.hostType:sub(1,20)) or "measurement failed"
        NET_STATUS.TextColor3 = Color3.fromRGB(80,180,255)
        tw(TICK_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(30,60,120)})
    end)
end)

-- ⬡ Queue depth probe
QUEUE_BTN.MouseButton1Click:Connect(function()
    local map = G.DISCOVERY_MAP
    if not map then
        addLog("INFO","Run Discovery scan first","Need remote list for queue depth probe")
        return
    end
    -- Use RemoteFunctions for queue probe (synchronous = measurable)
    local rfuncs = {}
    for _,r in ipairs(map.remoteFunctions or {}) do
        if r.instance then
            table.insert(rfuncs, r.instance)
        end
        if #rfuncs >= QUEUE_SAMPLES then break end
    end
    if #rfuncs < 2 then
        addLog("INFO","Need ≥2 RemoteFunctions for queue probe",
            "Run Discovery scan first or ensure game has RemoteFunctions")
        return
    end

    tw(QUEUE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(10,30,80)})
    NET_STATUS.Text="probing queue depth..."; NET_STATUS.TextColor3=C.DELTA
    addLogSep(("QUEUE DEPTH PROBE — %d RemoteFunctions"):format(#rfuncs))

    task.spawn(function()
        local result = probeQueueDepth(rfuncs, addLog)
        if result then
            addLog(result.avgPressure>1.3 and "FINDING" or "CLEAN",
                result.queueType,
                ("avg pressure ratio: %.2f×"):format(result.avgPressure),
                result.avgPressure>1.3)
            TOPOLOGY.queueType = result.queueType
            buildTopologyPanel()
        end
        NET_STATUS.Text = result and result.queueType:sub(1,20) or "probe failed"
        NET_STATUS.TextColor3 = Color3.fromRGB(80,180,255)
        tw(QUEUE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(30,60,120)})
    end)
end)

-- ⟳ Correlate channels
CORR_BTN.MouseButton1Click:Connect(function()
    addLogSep("CHANNEL CORRELATION ANALYSIS")
    task.spawn(function()
        local correlations = detectCorrelatedSpikes(addLog)
        if #correlations == 0 then
            addLog("INFO","No significant correlations found",
                "Run Monitor to collect more samples first")
        else
            addLog("INFO",
                ("Found %d correlation(s)"):format(#correlations),
                "Correlated channels share server infrastructure")
            TOPOLOGY.correlations = correlations
            buildTopologyPanel()
        end
    end)
end)

-- ● Monitor toggle
local monitoring = false
MON_BTN.MouseButton1Click:Connect(function()
    if not monitoring then
        local map = G.DISCOVERY_MAP
        local remotes = {}
        if map then
            for _,r in ipairs(map.remoteEvents or {}) do
                if r.instance then table.insert(remotes,r.instance) end
                if #remotes>=6 then break end
            end
        end
        if #remotes==0 then
            addLog("INFO","Run Discovery scan first","Need remotes to monitor")
            return
        end
        monitoring=true
        MON_BTN.Text="■ Stop"
        tw(MON_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(160,40,40)})
        NET_STATUS.Text="monitoring "..#remotes.." channels"
        NET_STATUS.TextColor3=Color3.fromRGB(80,210,100)
        addLogSep("MONITOR STARTED — "..#remotes.." channels")
        startMonitor(remotes, addLog)

        -- UI refresh loop
        task.spawn(function()
            while monitoring do
                task.wait(5)
                buildTopologyPanel()
            end
        end)
    else
        monitoring=false
        MON_BTN.Text="● Monitor"
        tw(MON_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(20,80,40)})
        NET_STATUS.Text="monitor stopped"; NET_STATUS.TextColor3=C.MUTED
        stopMonitor()
    end
end)

-- ⬡ FULL analysis
local fullRunning=false
FULL_BTN.MouseButton1Click:Connect(function()
    if fullRunning then return end; fullRunning=true
    tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(30,60,120)})
    clearLog()
    NET_STATUS.Text="full analysis running..."; NET_STATUS.TextColor3=C.DELTA
    addLogSep("NETMAP FULL ANALYSIS")

    task.spawn(function()
        -- Phase 1: Tick rate
        addLog("INFO","Phase 1 — Tick Rate & Host Fingerprint")
        local tickResult = measureTickRate(addLog)
        if tickResult then
            addLog(tickResult.periodicScore>0.5 and "FINDING" or "INFO",
                tickResult.hostType,
                ("%.1fHz  stability:%.0f%%  spikes:%.1f%%"):format(
                    tickResult.nominalHz,
                    tickResult.stability*100,
                    tickResult.spikeRate*100),
                tickResult.periodicScore>0.5)
            TOPOLOGY.tickRate=tickResult.nominalHz
            TOPOLOGY.hostType=tickResult.hostType
        end
        task.wait(0.5)

        -- Phase 2: Queue depth
        local map = G.DISCOVERY_MAP
        if map and map.remoteFunctions and #map.remoteFunctions >= 2 then
            addLog("INFO","Phase 2 — Queue Depth Topology")
            local rfuncs={}
            for _,r in ipairs(map.remoteFunctions) do
                if r.instance then table.insert(rfuncs,r.instance) end
                if #rfuncs>=QUEUE_SAMPLES then break end
            end
            local qResult = probeQueueDepth(rfuncs, addLog)
            if qResult then
                addLog(qResult.avgPressure>1.3 and "FINDING" or "CLEAN",
                    qResult.queueType,
                    ("pressure: %.2f×"):format(qResult.avgPressure),
                    qResult.avgPressure>1.3)
                TOPOLOGY.queueType=qResult.queueType
            end
        else
            addLog("INFO","Phase 2 skipped","Need Discovery scan + RemoteFunctions")
        end
        task.wait(0.5)

        -- Phase 3: Correlation (needs monitor data)
        addLog("INFO","Phase 3 — Channel Correlation")
        if next(CHANNELS) then
            local corrs = detectCorrelatedSpikes(addLog)
            TOPOLOGY.correlations = corrs
        else
            addLog("INFO","No channel data yet","Run Monitor first to collect latency data")
        end

        -- Summary
        addLogSep("NETMAP COMPLETE")
        if tickResult then
            addLog("INFO","Host: "..tickResult.hostType)
            addLog("INFO","Server load: "..tickResult.serverLoad)
        end
        if TOPOLOGY.queueType then
            addLog("INFO","Queue: "..TOPOLOGY.queueType)
        end

        buildTopologyPanel()
        NET_STATUS.Text="analysis complete"
        NET_STATUS.TextColor3=Color3.fromRGB(80,210,100)
        tw(FULL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,140,255)})
        fullRunning=false
    end)
end)

-- Initial topology panel
buildTopologyPanel()

-- Export
G.NETMAP_CHANNELS  = CHANNELS
G.NETMAP_TOPOLOGY  = TOPOLOGY
G.netmap_probe     = probeLatency
G.netmap_record    = recordSample

if G.addTab then
    G.addTab("netmap","NETMAP",P_NET)
else
    warn("[Oracle] G.addTab not found")
end
