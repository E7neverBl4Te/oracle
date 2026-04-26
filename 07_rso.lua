-- Oracle // 07_rso.lua
-- Remote Signature Observation
-- Passive fingerprinting · Cadence · Chain detection · Safety Envelope
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
local vs     = G.vs
local CON    = G.CON
local RepS   = G.RepS

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- RSO ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local OBS         = {}   -- [name] = observation record
local recentFires = {}   -- rolling buffer for chain detection
local RSO_active  = false
local RSO_start   = 0
local RSO_conns   = {}
local MAX_FIRES   = 200
local CHAIN_WIN   = 0.200

local function newRec(name)
    return {
        name   = name,
        fires  = {},
        total  = 0,
        chains = {},   -- [predName] = {count, jitters, coupled}
        dirty  = true,
        sig    = nil,
        last   = 0,
    }
end

local function getOrCreate(name)
    if not OBS[name] then OBS[name] = newRec(name) end
    return OBS[name]
end

-- ── Argument helpers ──────────────────────────────────────────────────────────
local function argType(v)
    local t = typeof(v)
    if t == "number" then
        if v ~= v                       then return "NaN"
        elseif math.abs(v) == math.huge then return "Inf"
        elseif v == math.floor(v)        then return "int"
        else                              return "float" end
    end
    return t
end

local function argVal(v)
    local t = typeof(v)
    if t == "string"   then return v:sub(1, 40) end
    if t == "boolean"  then return tostring(v) end
    if t == "number"   then return vs(v) end
    if t == "Vector3"  then return ("%.1f,%.1f,%.1f"):format(v.X,v.Y,v.Z) end
    if t == "CFrame"   then return ("%.1f,%.1f,%.1f"):format(v.X,v.Y,v.Z) end
    if t == "Instance" then
        local ok, n = pcall(function() return v.Name end)
        return ok and n or "[Instance]"
    end
    return t
end

-- ── Data inheritance check ────────────────────────────────────────────────────
local function checkInheritance(argsA, argsB)
    for _, a in ipairs(argsA) do
        for _, b in ipairs(argsB) do
            if a.t == b.t and a.v == b.v
            and a.t ~= "int" and a.t ~= "float"
            and #a.v > 3 then
                return true
            end
        end
    end
    return false
end

-- ── Record a fire ─────────────────────────────────────────────────────────────
local function recordFire(name, rawArgs)
    local now = tick()
    local rec = getOrCreate(name)
    rec.last  = now

    local args = {}
    for _, v in ipairs(rawArgs) do
        table.insert(args, {t=argType(v), v=argVal(v)})
    end

    if #rec.fires >= MAX_FIRES then table.remove(rec.fires, 1) end
    table.insert(rec.fires, {time=now, args=args})
    rec.total += 1
    rec.dirty  = true

    -- Chain detection
    local cutoff    = now - CHAIN_WIN
    local surviving = {}
    for _, rf in ipairs(recentFires) do
        if rf.time >= cutoff then
            table.insert(surviving, rf)
            if rf.name ~= name then
                local c = rec.chains[rf.name]
                if not c then
                    c = {count=0, jitters={}, coupled=false}
                    rec.chains[rf.name] = c
                end
                c.count += 1
                table.insert(c.jitters, (now - rf.time) * 1000)
                if checkInheritance(rf.args, args) then c.coupled = true end
            end
        end
    end
    recentFires = surviving
    table.insert(recentFires, {name=name, time=now, args=args})
    if #recentFires > 600 then table.remove(recentFires, 1) end
end

-- ── Signature computation ─────────────────────────────────────────────────────
local function avg(t)
    if #t == 0 then return 0 end
    local s = 0; for _,v in ipairs(t) do s += v end; return s/#t
end
local function std(t, m)
    if #t < 2 then return 0 end
    m = m or avg(t); local s = 0
    for _,v in ipairs(t) do s += (v-m)^2 end
    return math.sqrt(s/#t)
end

local function computeSig(rec)
    local fires = rec.fires
    if #fires < 2 then return nil end

    -- Schema
    local raw = {}
    for _, fire in ipairs(fires) do
        for i, arg in ipairs(fire.args) do
            if not raw[i] then raw[i] = {types={}, vals={}, count=0} end
            local s = raw[i]
            s.count += 1
            s.types[arg.t] = (s.types[arg.t] or 0) + 1
            s.vals[arg.v]  = (s.vals[arg.v]  or 0) + 1
        end
    end

    local schema = {}
    for i, s in pairs(raw) do
        local domT, domN = "?", 0
        for t, n in pairs(s.types) do if n > domN then domT,domN = t,n end end
        local card = 0; for _ in pairs(s.vals) do card += 1 end
        local sorted = {}
        for v, n in pairs(s.vals) do table.insert(sorted, {v=v, n=n}) end
        table.sort(sorted, function(a,b) return a.n > b.n end)
        schema[i] = {
            domType  = domT,
            card     = card,
            mutRate  = card / math.max(s.count, 1),
            topVals  = sorted,
            coverage = s.count / #fires,
        }
    end

    -- Cadence
    local intervals = {}
    for i = 2, #fires do
        table.insert(intervals, fires[i].time - fires[i-1].time)
    end
    local iMean = avg(intervals)
    local iStd  = std(intervals, iMean)
    local cv    = iMean > 0 and (iStd/iMean) or 0
    local pattern
    if     iMean < 0.05 and cv < 0.4  then pattern = "burst"
    elseif iMean < 0.5  and cv < 0.35 then pattern = "steady"
    elseif cv > 1.2                    then pattern = "input-driven"
    else                                    pattern = "sporadic" end
    local cadence = {mean=iMean, std=iStd, cv=cv, pattern=pattern, total=rec.total}

    -- Chains
    local chains = {}
    for predName, c in pairs(rec.chains) do
        if c.count >= 3 then
            local predTotal = OBS[predName] and OBS[predName].total or c.count
            local prob      = c.count / math.max(predTotal, 1)
            local jMean     = avg(c.jitters)
            local jStd      = std(c.jitters, jMean)
            local stable    = jStd < 15
            local causal    = prob > 0.75 and (c.coupled or stable)
            table.insert(chains, {
                pred=predName, count=c.count, prob=prob,
                coupled=c.coupled, jMean=jMean, jStd=jStd,
                stable=stable, causal=causal,
            })
        end
    end
    table.sort(chains, function(a,b) return a.prob > b.prob end)

    -- Role prediction
    local argCount = 0; for _ in pairs(schema) do argCount += 1 end
    local role = "Unknown"
    if     #chains > 0 and chains[1].causal then
        role = "Response Event — replies to "..chains[1].pred
    elseif pattern == "steady" then
        role = "State Sync / Heartbeat"
    elseif pattern == "burst" then
        role = "Input Action / Event Trigger"
    elseif argCount > 0 and schema[1] and schema[1].domType == "string"
    and schema[1].card <= 6 then
        role = "Command Dispatch"
    elseif argCount >= 3 then
        role = "Data Stream / Broadcast"
    elseif argCount == 0 then
        role = "Signal / Ping (no args)"
    else
        role = "State Event"
    end

    -- Constraints
    local constraints = {}
    for i, s in pairs(schema) do
        if s.card == 1 then
            constraints[i] = {kind="constant",
                note="always " .. (s.topVals[1] and '"'..s.topVals[1].v..'"' or "?")}
        elseif s.card <= 7 then
            local opts = {}
            for j = 1, math.min(7, #s.topVals) do
                table.insert(opts, '"'..s.topVals[j].v..'"')
            end
            constraints[i] = {kind="enum", note=table.concat(opts, "  ·  ")}
        else
            constraints[i] = {kind="dynamic",
                note=s.card.." unique values observed"}
        end
    end

    return {schema=schema, cadence=cadence, chains=chains,
            role=role, constraints=constraints, argCount=argCount}
end

-- ── Passive listener ──────────────────────────────────────────────────────────
local attached = {}

local function attachRemote(r)
    if not r:IsA("RemoteEvent") then return end
    if attached[r] then return end
    attached[r] = true
    local ok, conn = pcall(function()
        return r.OnClientEvent:Connect(function(...)
            if RSO_active then recordFire(r.Name, {...}) end
        end)
    end)
    if ok then table.insert(RSO_conns, conn) end
end

local function startRSO()
    if RSO_active then return end
    RSO_active = true; RSO_start = tick()
    local function scan(root)
        local ok, d = pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _, x in ipairs(d) do attachRemote(x) end
    end
    scan(RepS); scan(workspace)
    local function onNew(inst) attachRemote(inst) end
    table.insert(RSO_conns, RepS.DescendantAdded:Connect(onNew))
    table.insert(RSO_conns, workspace.DescendantAdded:Connect(onNew))
end

local function stopRSO()
    RSO_active = false
    for _, c in ipairs(RSO_conns) do pcall(function() c:Disconnect() end) end
    RSO_conns = {}; attached = {}
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- RSO PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_RSO = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.fromScale(1,1), Visible=false, ZIndex=3}, CON)

-- top bar
local TOPBAR = mk("Frame", {BackgroundColor3=C.SURFACE, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32), ZIndex=4}, P_RSO)
stroke(C.BORDER, 1, TOPBAR)
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1), Position=UDim2.new(0,0,1,-1), ZIndex=5}, TOPBAR)
pad(12, 0, TOPBAR); listH(TOPBAR, 10)
mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
    Text="⬡  REMOTE SIGNATURE OBSERVATION", TextColor3=C.ACCENT, TextSize=11,
    Size=UDim2.new(1,-210,1,0), TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5, LayoutOrder=1}, TOPBAR)
local DUR_LBL = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="not watching", TextColor3=C.MUTED, TextSize=9,
    Size=UDim2.new(0,110,1,0), TextXAlignment=Enum.TextXAlignment.Right,
    ZIndex=5, LayoutOrder=2}, TOPBAR)
local WATCH_BTN = mk("TextButton", {AutoButtonColor=false,
    BackgroundColor3=C.ACCENT, BorderSizePixel=0, Font=Enum.Font.GothamBold,
    Text="● WATCH", TextColor3=C.WHITE, TextSize=10,
    Size=UDim2.new(0,80,0,22), ZIndex=5, LayoutOrder=3}, TOPBAR)
corner(5, WATCH_BTN)
do local base=C.ACCENT
    WATCH_BTN.MouseEnter:Connect(function() tw(WATCH_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    WATCH_BTN.MouseLeave:Connect(function() tw(WATCH_BTN,TI.fast,{BackgroundColor3=base}) end)
end

-- body
local BODY = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32), Size=UDim2.new(1,0,1,-32), ZIndex=3}, P_RSO)

-- left: remote list
local RL = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.new(0,212,1,0), ZIndex=3}, BODY)
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0), Position=UDim2.new(1,-1,0,0), ZIndex=4}, RL)
local RL_HDR = mk("Frame", {BackgroundColor3=C.SURFACE, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,24), ZIndex=4}, RL)
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1), Position=UDim2.new(0,0,1,-1), ZIndex=5}, RL_HDR)
local RL_COUNT = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
    Text="OBSERVED (0)", TextColor3=C.MUTED, TextSize=9,
    Size=UDim2.fromScale(1,1), TextXAlignment=Enum.TextXAlignment.Center, ZIndex=5}, RL_HDR)
local RL_SCROLL = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0,0,0,24), Size=UDim2.new(1,0,1,-24),
    ScrollBarThickness=3, ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ZIndex=4}, RL)
pad(5,4,RL_SCROLL); listV(RL_SCROLL, 2)
local RL_EMPTY = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="Press ● WATCH to begin\npassive observation",
    TextColor3=C.MUTED, TextSize=9, TextWrapped=true,
    Size=UDim2.new(1,0,0,40), TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5, LayoutOrder=1}, RL_SCROLL)

-- right: signature panel
local SR = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0,212,0,0), Size=UDim2.new(1,-212,1,0), ZIndex=3}, BODY)
local SIG_SCROLL = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.fromScale(1,1), ScrollBarThickness=4,
    ScrollBarImageColor3=C.ACCDIM, CanvasSize=UDim2.fromScale(0,0),
    AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y, ZIndex=4}, SR)
pad(12, 8, SIG_SCROLL); listV(SIG_SCROLL, 8)
local SIG_EMPTY = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="Select a remote from the list\nto view its behavioral signature",
    TextColor3=C.MUTED, TextSize=10, TextWrapped=true,
    Size=UDim2.new(1,0,0,50), TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5, LayoutOrder=1}, SIG_SCROLL)

-- ── UI helpers ────────────────────────────────────────────────────────────────
local ROLE_COL = {
    ["Response Event"]  = Color3.fromRGB(80,210,100),
    ["State Sync"]      = Color3.fromRGB(80,140,255),
    ["Input Action"]    = Color3.fromRGB(255,160,40),
    ["Command Dispatch"]= Color3.fromRGB(168,120,255),
    ["Data Stream"]     = Color3.fromRGB(80,170,210),
    ["Signal"]          = Color3.fromRGB(80,74,108),
}
local PAT_COL = {
    steady         = Color3.fromRGB(80,210,100),
    burst          = Color3.fromRGB(255,160,40),
    ["input-driven"] = Color3.fromRGB(168,120,255),
    sporadic       = Color3.fromRGB(80,74,108),
}
local MUT_COL = {
    constant = Color3.fromRGB(80,210,100),
    enum     = Color3.fromRGB(255,160,40),
    dynamic  = Color3.fromRGB(255,90,90),
}
local function roleCol(role)
    for k,col in pairs(ROLE_COL) do if role:find(k) then return col end end
    return C.MUTED
end
local function chip(txt, col, parent, order)
    local f = mk("Frame", {BackgroundColor3=col, BorderSizePixel=0,
        Size=UDim2.new(0,0,0,17), AutomaticSize=Enum.AutomaticSize.X,
        ZIndex=6, LayoutOrder=order or 99}, parent)
    corner(4, f)
    mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5)},f)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=txt,TextColor3=Color3.fromRGB(8,8,12),TextSize=8,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
        TextXAlignment=Enum.TextXAlignment.Center,ZIndex=7},f)
    return f
end
local function secLabel(txt, parent, order)
    local f = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,16),ZIndex=4,LayoutOrder=order},parent)
    mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,0.5,0),ZIndex=4},f)
    local bg=mk("Frame",{BackgroundColor3=C.BG,BorderSizePixel=0,
        Size=UDim2.fromOffset(#txt*7+12,14),
        Position=UDim2.new(0,0,0.5,-7),ZIndex=5},f)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=txt,TextColor3=C.MUTED,TextSize=9,Size=UDim2.fromScale(1,1),
        TextXAlignment=Enum.TextXAlignment.Center,ZIndex=6},bg)
end
local function infoCard(parent, order)
    local c=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=order},parent)
    corner(6,c); stroke(C.BORDER,1,c)
    return c
end
local function kv(lbl, val, col, parent, order)
    local row=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,14),ZIndex=5,LayoutOrder=order},parent)
    listH(row,6)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=lbl,TextColor3=C.MUTED,TextSize=9,
        Size=UDim2.new(0,120,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=1},row)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=val,TextColor3=col or C.TEXT,TextSize=9,TextWrapped=true,
        Size=UDim2.new(1,-130,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=2},row)
end

-- ── Signature renderer ────────────────────────────────────────────────────────
local selRemote = nil
local remRowMap = {}

local function clearSig()
    for _, c in ipairs(SIG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    SIG_EMPTY.Parent = SIG_SCROLL; SIG_EMPTY.LayoutOrder = 1
end

local function renderSig(name)
    local rec = OBS[name]; if not rec then clearSig(); return end
    if rec.dirty or not rec.sig then rec.sig = computeSig(rec); rec.dirty = false end
    local sig = rec.sig; if not sig then clearSig(); return end

    for _, c in ipairs(SIG_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end

    local ord = 0
    local function o() ord+=1; return ord end

    -- Header card
    local hdr = infoCard(SIG_SCROLL, o()); pad(12,10,hdr); listV(hdr,4)
    local nrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=5,LayoutOrder=1},hdr)
    listH(nrow,7)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=name,TextColor3=C.WHITE,TextSize=13,
        Size=UDim2.new(0,0,0,20),AutomaticSize=Enum.AutomaticSize.X,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6,LayoutOrder=1},nrow)
    chip(sig.cadence.pattern, PAT_COL[sig.cadence.pattern] or C.MUTED, nrow, 2)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=sig.role,TextColor3=roleCol(sig.role),TextSize=10,TextWrapped=true,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},hdr)
    local dur = RSO_active and (tick()-RSO_start) or 0
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=("Fires: %d   Avg interval: %.0fms   Watching: %.0fs"):format(
            rec.total, sig.cadence.mean*1000, dur),
        TextColor3=C.MUTED,TextSize=9,
        Size=UDim2.new(1,0,0,14),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=3},hdr)

    -- Argument schema
    if sig.argCount > 0 then
        secLabel("ARGUMENT SCHEMA", SIG_SCROLL, o())
        for i = 1, sig.argCount do
            local s = sig.schema[i]; local cs = sig.constraints[i]
            if s then
                local ac = infoCard(SIG_SCROLL, o()); pad(10,7,ac); listV(ac,3)
                local arow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
                    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                    ZIndex=5,LayoutOrder=1},ac)
                listH(arow,6)
                mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                    Text="Arg "..i,TextColor3=C.TEXT,TextSize=11,
                    Size=UDim2.new(0,40,0,17),TextXAlignment=Enum.TextXAlignment.Left,
                    ZIndex=6,LayoutOrder=1},arow)
                chip(s.domType, C.ACCDIM, arow, 2)
                if cs then chip(cs.kind:upper(), MUT_COL[cs.kind] or C.MUTED, arow, 3) end
                mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                    Text=("card:%d  mut:%.0f%%"):format(s.card,s.mutRate*100),
                    TextColor3=C.MUTED,TextSize=8,
                    Size=UDim2.new(1,-160,0,17),TextXAlignment=Enum.TextXAlignment.Right,
                    ZIndex=6,LayoutOrder=4},arow)
                if cs then
                    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                        Text=cs.note,TextColor3=Color3.fromRGB(255,175,70),
                        TextSize=9,TextWrapped=true,
                        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                        TextXAlignment=Enum.TextXAlignment.Left,
                        ZIndex=5,LayoutOrder=2},ac)
                end
            end
        end
    end

    -- Chain analysis
    if #sig.chains > 0 then
        secLabel("CHAIN ANALYSIS", SIG_SCROLL, o())
        for _, ch in ipairs(sig.chains) do
            local cc = infoCard(SIG_SCROLL, o()); pad(10,7,cc); listV(cc,4)
            local chrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                ZIndex=5,LayoutOrder=1},cc)
            listH(chrow,6)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text="← "..ch.pred,TextColor3=C.TEXT,TextSize=11,
                Size=UDim2.new(1,-180,0,17),TextXAlignment=Enum.TextXAlignment.Left,
                ZIndex=6,LayoutOrder=1},chrow)
            chip(ch.causal and "CAUSAL" or "CORRELATED",
                 ch.causal and Color3.fromRGB(80,210,100) or C.MUTED, chrow, 2)
            if ch.coupled then chip("VALUE COUPLED", Color3.fromRGB(255,160,40), chrow, 3) end
            if ch.stable  then chip("FRAME ALIGNED", Color3.fromRGB(80,170,210), chrow, 4) end
            kv("Succession",
                ("%.0f%%  (%d/%d)"):format(ch.prob*100, ch.count,
                    OBS[ch.pred] and OBS[ch.pred].total or ch.count),
                C.TEXT, cc, 2)
            kv("Jitter",
                ("%.0f ± %.0f ms"):format(ch.jMean, ch.jStd),
                ch.stable and Color3.fromRGB(80,210,100) or Color3.fromRGB(255,160,40),
                cc, 3)
            if ch.causal then
                mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                    Text="⚑  Server expects "..ch.pred.." first — firing independently may be flagged",
                    TextColor3=Color3.fromRGB(255,90,90),TextSize=9,TextWrapped=true,
                    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                    TextXAlignment=Enum.TextXAlignment.Left,
                    ZIndex=5,LayoutOrder=4},cc)
            end
        end
    end

    -- Safety Envelope
    secLabel("SAFETY ENVELOPE", SIG_SCROLL, o())
    local se = infoCard(SIG_SCROLL, o()); pad(10,8,se); listV(se,5)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="Predicted Role  →  "..sig.role,
        TextColor3=roleCol(sig.role),TextSize=11,
        Size=UDim2.new(1,0,0,16),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=1},se)
    local hasC = false; for _ in pairs(sig.constraints) do hasC=true; break end
    if hasC then
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text="Argument Constraints:",TextColor3=C.TEXT,TextSize=10,
            Size=UDim2.new(1,0,0,14),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2},se)
        for i, cs in pairs(sig.constraints) do
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                Text=("  Arg %d  [%s]   %s"):format(i, cs.kind, cs.note),
                TextColor3=MUT_COL[cs.kind] or C.MUTED,TextSize=9,TextWrapped=true,
                Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                TextXAlignment=Enum.TextXAlignment.Left,
                ZIndex=5,LayoutOrder=2+i},se)
        end
    else
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text="Accumulating observations — check back after more natural fires.",
            TextColor3=C.MUTED,TextSize=9,
            Size=UDim2.new(1,0,0,14),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2},se)
    end
end

-- ── Remote list ───────────────────────────────────────────────────────────────
local function rebuildList()
    for _, c in ipairs(RL_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    remRowMap = {}

    local names = {}
    for name in pairs(OBS) do table.insert(names, name) end
    table.sort(names, function(a,b)
        return (OBS[a] and OBS[a].total or 0) > (OBS[b] and OBS[b].total or 0)
    end)

    RL_COUNT.Text = "OBSERVED ("..#names..")"
    if #names == 0 then RL_EMPTY.Visible = true; return end
    RL_EMPTY.Visible = false

    for i, name in ipairs(names) do
        local rec = OBS[name]
        local age = tick() - rec.last
        local actCol
        if     age < 1  then actCol = Color3.fromRGB(80,210,100)
        elseif age < 5  then actCol = Color3.fromRGB(255,160,40)
        elseif age < 30 then actCol = C.MUTED
        else                 actCol = Color3.fromRGB(40,40,55) end

        local sel = selRemote == name
        local row = mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=sel and C.ACCDIM or C.SURFACE,
            BackgroundTransparency=sel and 0 or 0.4,
            BorderSizePixel=0,Text="",
            Size=UDim2.new(1,0,0,28),ZIndex=4,LayoutOrder=i},RL_SCROLL)
        corner(4,row); pad(8,0,row)

        local dot=mk("Frame",{BackgroundColor3=actCol,BorderSizePixel=0,
            Size=UDim2.fromOffset(7,7),Position=UDim2.new(0,0,0.5,-3.5),ZIndex=6},row)
        corner(4,dot)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=name,TextColor3=sel and C.WHITE or C.TEXT,TextSize=10,
            Size=UDim2.new(1,-50,1,0),Position=UDim2.new(0,14,0,0),
            TextXAlignment=Enum.TextXAlignment.Left,
            TextTruncate=Enum.TextTruncate.AtEnd,ZIndex=6},row)

        local badge=mk("Frame",{BackgroundColor3=C.ACCDIM,BorderSizePixel=0,
            Size=UDim2.fromOffset(34,16),Position=UDim2.new(1,-38,0.5,-8),ZIndex=6},row)
        corner(8,badge)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=tostring(math.min(rec.total,9999)),TextColor3=C.ACCENT,TextSize=8,
            Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=7},badge)

        row.MouseEnter:Connect(function()
            if selRemote~=name then tw(row,TI.fast,{BackgroundTransparency=0.1,BackgroundColor3=C.CARD}) end
        end)
        row.MouseLeave:Connect(function()
            if selRemote~=name then tw(row,TI.fast,{BackgroundTransparency=0.4,BackgroundColor3=C.SURFACE}) end
        end)
        row.MouseButton1Click:Connect(function()
            selRemote=name; rebuildList(); renderSig(name)
        end)
        remRowMap[name]=row
    end
end

-- ── Update loop ───────────────────────────────────────────────────────────────
local updateThr = nil
local function startLoop()
    if updateThr then return end
    updateThr = task.spawn(function()
        while RSO_active do
            task.wait(2)
            if P_RSO.Visible then
                rebuildList()
                if selRemote then renderSig(selRemote) end
            end
            local dur=tick()-RSO_start
            DUR_LBL.Text=("watching %02d:%02d"):format(math.floor(dur/60),math.floor(dur%60))
        end
        DUR_LBL.Text="stopped"
        updateThr=nil
    end)
end

-- ── Watch toggle ──────────────────────────────────────────────────────────────
local watching = false
WATCH_BTN.MouseButton1Click:Connect(function()
    if not watching then
        watching=true
        WATCH_BTN.Text="■ STOP"
        tw(WATCH_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(160,40,40)})
        startRSO(); startLoop(); rebuildList()
    else
        watching=false
        WATCH_BTN.Text="● WATCH"
        tw(WATCH_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
        stopRSO(); rebuildList()
    end
end)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- REGISTER TAB
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if G.addTab then
    G.addTab("rso", "Signatures", P_RSO)
else
    warn("[Oracle] G.addTab not found — update 06_init.lua")
end

-- Auto-start passive listening immediately so data accumulates
-- from the moment Oracle loads regardless of which tab is visible
startRSO()
startLoop()
