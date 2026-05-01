-- Oracle // 16_avd.lua
-- AVD — Adaptive Vulnerability Detector
-- Passive observer · Pattern anomaly detection · Strategist findings
local G=...; local C=G.C; local TI=G.TI; local mk=G.mk; local tw=G.tw
local corner=G.corner; local stroke=G.stroke; local pad=G.pad
local listV=G.listV; local listH=G.listH; local mkRow=G.mkRow; local mkSep=G.mkSep
local vs=G.vs; local snap=G.snap; local dif=G.dif; local isNI=G.isNI
local CON=G.CON; local RepS=G.RepS; local LP=G.LP

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- AVD ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Observation window settings
local WIN_SIZE   = 120   -- max fires to store per remote
local RACE_WIN   = 0.300 -- seconds — rapid re-fire window for race condition detection
local SHAPE_THRESH = 0.4 -- mutation rate above which schema is considered inconsistent

-- Vulnerability categories
local VULN = {
    NO_VALIDATION    = {id="NO_VALID",   label="No Server Validation",   severity="HIGH",   col=Color3.fromRGB(255,80,80)},
    INCONSISTENT_SCHEMA={id="INCON_SCHEMA",label="Inconsistent Arg Schema",severity="MEDIUM",col=Color3.fromRGB(255,160,40)},
    RACE_CONDITION   = {id="RACE",        label="Race Condition Window",  severity="HIGH",   col=Color3.fromRGB(255,80,80)},
    RAPID_STATE      = {id="RAPID_STATE", label="Rapid State Change",     severity="MEDIUM", col=Color3.fromRGB(255,160,40)},
    PATHOLOGICAL     = {id="PATHOLOG",    label="Pathological State",     severity="CRITICAL",col=Color3.fromRGB(255,40,40)},
    BLIND_BROADCAST  = {id="BLIND_BC",   label="Blind Broadcast",        severity="LOW",    col=Color3.fromRGB(80,140,255)},
    TIMING_ANOMALY   = {id="TIMING",      label="Timing Anomaly",         severity="LOW",    col=Color3.fromRGB(80,170,210)},
    HIGH_FREQUENCY   = {id="HIGH_FREQ",   label="High-Freq Fire Window",  severity="MEDIUM", col=Color3.fromRGB(255,160,40)},
}

-- Per-remote observation record
local OBS = {}    -- [name] = {fires, argShapes, lastFire, totalFires, stateChanges, conns}
local FINDINGS = {}  -- list of {remote, vuln, detail, tick}
local avdActive = false
local avdConns  = {}
local avdThread = nil
local stateBase = nil
local attached  = {}

local function getOrCreate(name)
    if not OBS[name] then
        OBS[name]={fires={},argShapes={},lastFire=0,totalFires=0,stateChanges=0,
            fireIntervals={},lastShape=nil,rapidCount=0}
    end
    return OBS[name]
end

local function argShape(args)
    local parts={}
    for _,v in ipairs(args) do table.insert(parts,typeof(v)) end
    return table.concat(parts,"|")
end

local function addFinding(remoteName, vuln, detail)
    -- Deduplicate by remote+vuln combination
    for _,f in ipairs(FINDINGS) do
        if f.remote==remoteName and f.vuln.id==vuln.id then
            f.count=(f.count or 1)+1; f.lastSeen=tick(); return
        end
    end
    table.insert(FINDINGS,{
        remote=remoteName, vuln=vuln, detail=detail,
        tick=tick(), count=1, lastSeen=tick()
    })
    -- sort by severity
    local order={CRITICAL=0,HIGH=1,MEDIUM=2,LOW=3}
    table.sort(FINDINGS,function(a,b)
        local oa=order[a.vuln.severity] or 4
        local ob=order[b.vuln.severity] or 4
        return oa<ob
    end)
end

local function analyseRemote(name, rec)
    -- Pattern 1: No validation signal
    -- Fires a lot but never triggers a state change or server response
    if rec.totalFires >= 5 and rec.stateChanges == 0 then
        addFinding(name, VULN.NO_VALIDATION,
            ("Fired %d times — zero observable server response or state change"):format(rec.totalFires))
    end

    -- Pattern 2: Inconsistent schema
    if #rec.argShapes >= 5 then
        local shapeCounts={}
        for _,s in ipairs(rec.argShapes) do shapeCounts[s]=(shapeCounts[s] or 0)+1 end
        local dominant,domCount="",0
        for s,c in pairs(shapeCounts) do if c>domCount then dominant,domCount=s,c end end
        local mutRate=1-(domCount/#rec.argShapes)
        if mutRate > SHAPE_THRESH then
            addFinding(name, VULN.INCONSISTENT_SCHEMA,
                ("Arg schema mutates %.0f%% of fires — server may accept any structure"):format(mutRate*100))
        end
    end

    -- Pattern 3: High frequency fires (>5/sec average)
    if rec.totalFires >= 10 and #rec.fireIntervals >= 5 then
        local sum=0
        for _,t in ipairs(rec.fireIntervals) do sum+=t end
        local avgInterval=sum/#rec.fireIntervals
        if avgInterval < 0.2 then
            addFinding(name, VULN.HIGH_FREQUENCY,
                ("Average interval: %.0fms — rapid fire may bypass cooldown"):format(avgInterval*1000))
        end
    end

    -- Pattern 4: Race condition window
    if rec.rapidCount >= 3 then
        addFinding(name, VULN.RACE_CONDITION,
            ("Fired %d times within %.0fms window — race condition timing confirmed"):format(
                rec.rapidCount, RACE_WIN*1000))
    end
end

local function analyseBroadcast(name, rec, rlog_entry)
    -- If server fires back with args that include other player names → blind broadcast
    if rlog_entry and rlog_entry.args then
        local args = rlog_entry.args
        local players = game:GetService("Players"):GetPlayers()
        for _, p in ipairs(players) do
            if p ~= LP and args:find(p.Name) then
                addFinding(name, VULN.BLIND_BROADCAST,
                    ("Server broadcast includes player data for %s — not targeted"):format(p.Name))
                break
            end
        end
    end
end

local function recordFire(name, rawArgs)
    local now = tick()
    local rec = getOrCreate(name)
    local shape = argShape(rawArgs)

    -- Store fire
    if #rec.fires >= WIN_SIZE then table.remove(rec.fires,1) end
    table.insert(rec.fires, {time=now, shape=shape, argc=#rawArgs})
    if #rec.argShapes >= WIN_SIZE then table.remove(rec.argShapes,1) end
    table.insert(rec.argShapes, shape)

    -- Interval tracking
    if rec.lastFire > 0 then
        local interval = now - rec.lastFire
        if #rec.fireIntervals >= 60 then table.remove(rec.fireIntervals,1) end
        table.insert(rec.fireIntervals, interval)
        -- Race window check
        if interval < RACE_WIN then
            rec.rapidCount += 1
        else
            rec.rapidCount = 0
        end
    end

    rec.lastFire = now
    rec.totalFires += 1
    rec.lastShape = shape
end

local function startAVD()
    if avdActive then return end
    avdActive = true
    stateBase = snap()
    attached  = {}

    -- Hook all remotes
    local function hookRemote(r)
        if not r:IsA("RemoteEvent") then return end
        if attached[r] then return end
        attached[r]=true
        local ok,conn=pcall(function()
            return r.OnClientEvent:Connect(function(...)
                if not avdActive then return end
                recordFire(r.Name, {...})
                -- Check for pathological values
                for _,v in ipairs({...}) do
                    if type(v)=="number" and (v~=v or math.abs(v)==math.huge) then
                        addFinding(r.Name, VULN.PATHOLOGICAL,
                            ("Server sent %s in arg"):format(vs(v)))
                    end
                end
            end)
        end)
        if ok then table.insert(avdConns,conn) end
    end

    local function scanHook(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do hookRemote(x) end
    end
    scanHook(RepS); scanHook(workspace)
    table.insert(avdConns, RepS.DescendantAdded:Connect(hookRemote))
    table.insert(avdConns, workspace.DescendantAdded:Connect(hookRemote))

    -- State watcher thread
    avdThread = task.spawn(function()
        local lastState = stateBase
        while avdActive do
            task.wait(0.5)
            local cur = snap()
            local deltas = dif(lastState, cur)
            for _, ch in ipairs(deltas) do
                if ch.bad then
                    addFinding("STATE", VULN.PATHOLOGICAL,
                        ("Pathological value in %s: %s → %s"):format(ch.path,ch.bv,ch.av))
                end
                -- Find which remote fired most recently
                local recentRemote = nil
                local recentTime   = 0
                for name, rec in pairs(OBS) do
                    if rec.lastFire > recentTime and (tick()-rec.lastFire) < 1.0 then
                        recentTime   = rec.lastFire
                        recentRemote = name
                    end
                end
                if recentRemote then
                    local rec = OBS[recentRemote]
                    rec.stateChanges += 1
                    if not ch.bad then
                        local elapsed = tick() - recentTime
                        if elapsed < 0.1 then
                            addFinding(recentRemote, VULN.RAPID_STATE,
                                ("State change %.0fms after fire: %s"):format(
                                    elapsed*1000, ch.path))
                        end
                    end
                end
                lastState[ch.path] = cur[ch.path]
            end
            -- Periodically analyse all remotes
            for name, rec in pairs(OBS) do
                if rec.totalFires >= 5 then analyseRemote(name, rec) end
            end
        end
    end)
end

local function stopAVD()
    avdActive=false
    for _,c in ipairs(avdConns) do pcall(function() c:Disconnect() end) end
    avdConns={}; attached={}
    if avdThread then task.cancel(avdThread); avdThread=nil end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- AVD PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_AVD=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,Size=UDim2.new(1,0,0,32),ZIndex=4},P_AVD)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="⬡  AVD — VULNERABILITY DETECTOR",TextColor3=C.ACCENT,TextSize=11,Size=UDim2.new(0,280,1,0),Position=UDim2.new(0,14,0,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local AVD_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="inactive",TextColor3=C.MUTED,TextSize=9,Size=UDim2.new(0,140,1,0),Position=UDim2.new(1,-306,0,0),TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)
local WATCH_BTN=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.ACCENT,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="● WATCH",TextColor3=C.WHITE,TextSize=10,Size=UDim2.new(0,80,0,22),Position=UDim2.new(1,-160,0.5,-11),ZIndex=6},TOPBAR)
corner(5,WATCH_BTN)
do local base=C.ACCENT
    WATCH_BTN.MouseEnter:Connect(function() tw(WATCH_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    WATCH_BTN.MouseLeave:Connect(function() tw(WATCH_BTN,TI.fast,{BackgroundColor3=base}) end)
end
local CLEAR_BTN=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.CARD,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="⌫ CLR",TextColor3=C.MUTED,TextSize=9,Size=UDim2.new(0,50,0,22),Position=UDim2.new(1,-68,0.5,-11),ZIndex=6},TOPBAR)
corner(5,CLEAR_BTN); stroke(C.BORDER,1,CLEAR_BTN)

local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_AVD)

-- left: findings
local FL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.new(0.46,0,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(0,1,1,-20),Position=UDim2.new(0.46,0,0,10),ZIndex=4},BODY)

local FL_HDR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,Size=UDim2.new(1,0,0,24),ZIndex=4},FL)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},FL_HDR)
local FIND_COUNT=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="FINDINGS (0)",TextColor3=C.MUTED,TextSize=9,Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5},FL_HDR)

local FIND_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,0,0,24),Size=UDim2.new(1,0,1,-24),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},FL)
pad(6,6,FIND_SCROLL); listV(FIND_SCROLL,5)

local FIND_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="No findings yet.\nPress ● WATCH and play normally.\nAVD observes traffic passively.",TextColor3=C.MUTED,TextSize=9,TextWrapped=true,Size=UDim2.new(1,0,0,50),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5,LayoutOrder=1},FIND_SCROLL)

-- right: remote observation stats
local FR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0.46,1,0,0),Size=UDim2.new(0.54,-1,1,0),ZIndex=3},BODY)
local FR_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},FR)
pad(10,8,FR_SCROLL); listV(FR_SCROLL,4)
local FR_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="Remote observation data will appear here\nas traffic is captured.",TextColor3=C.MUTED,TextSize=10,TextWrapped=true,Size=UDim2.new(1,0,0,40),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5,LayoutOrder=1},FR_SCROLL)

-- SEVERITY colours
local SEV_COL={CRITICAL=Color3.fromRGB(255,40,40),HIGH=Color3.fromRGB(255,80,80),MEDIUM=Color3.fromRGB(255,160,40),LOW=Color3.fromRGB(80,140,255)}

-- UI update loop
local uiThread=nil
local function startUILoop()
    if uiThread then return end
    uiThread=task.spawn(function()
        while avdActive do
            task.wait(2)
            if not P_AVD.Visible then continue end

            -- Update findings panel
            for _,c in ipairs(FIND_SCROLL:GetChildren()) do
                if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
            end
            FIND_COUNT.Text="FINDINGS ("..#FINDINGS..")"
            if #FINDINGS==0 then
                FIND_EMPTY.Visible=true
            else
                FIND_EMPTY.Visible=false
                for i,f in ipairs(FINDINGS) do
                    local sev=f.vuln.severity
                    local card=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
                        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                        ZIndex=4,LayoutOrder=i},FIND_SCROLL)
                    corner(5,card); stroke(f.vuln.col,1,card); pad(8,5,card); listV(card,3)

                    local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
                        Size=UDim2.new(1,0,0,15),ZIndex=5,LayoutOrder=1},card)
                    listH(hrow,5)
                    -- severity chip
                    local sc=mk("Frame",{BackgroundColor3=SEV_COL[sev] or C.MUTED,BorderSizePixel=0,
                        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6,LayoutOrder=1},hrow)
                    corner(3,sc); mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4)},sc)
                    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text=sev,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},sc)
                    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text=f.remote,TextColor3=f.vuln.col,TextSize=10,Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6,LayoutOrder=2},hrow)
                    if f.count>1 then
                        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="×"..f.count,TextColor3=C.MUTED,TextSize=8,Size=UDim2.new(0,25,1,0),TextXAlignment=Enum.TextXAlignment.Right,ZIndex=6,LayoutOrder=3},hrow)
                    end
                    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text=f.vuln.label,TextColor3=C.TEXT,TextSize=10,Size=UDim2.new(1,0,0,14),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},card)
                    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text=f.detail,TextColor3=C.MUTED,TextSize=9,TextWrapped=true,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=3},card)
                end
            end

            -- Update remote observation panel
            for _,c in ipairs(FR_SCROLL:GetChildren()) do
                if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
            end
            local obsNames={}
            for name in pairs(OBS) do table.insert(obsNames,name) end
            table.sort(obsNames,function(a,b) return(OBS[a].totalFires or 0)>(OBS[b].totalFires or 0) end)

            if #obsNames==0 then
                FR_EMPTY.Visible=true
            else
                FR_EMPTY.Visible=false
                for i,name in ipairs(obsNames) do
                    local rec=OBS[name]
                    -- find finding count for this remote
                    local fCount=0
                    for _,f in ipairs(FINDINGS) do if f.remote==name then fCount+=1 end end
                    local row=mk("Frame",{BackgroundColor3=fCount>0 and Color3.fromRGB(26,14,6) or C.CARD,
                        BorderSizePixel=0,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                        ZIndex=4,LayoutOrder=i},FR_SCROLL)
                    corner(5,row); pad(8,5,row); listV(row,3)
                    if fCount>0 then stroke(Color3.fromRGB(255,80,80),1,row) end
                    local hrow2=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
                        Size=UDim2.new(1,0,0,15),ZIndex=5,LayoutOrder=1},row)
                    listH(hrow2,6)
                    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                        Text=name,TextColor3=fCount>0 and Color3.fromRGB(255,160,40) or C.TEXT,TextSize=10,
                        Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6,LayoutOrder=1},hrow2)
                    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                        Text="fires:"..rec.totalFires.."  changes:"..rec.stateChanges,
                        TextColor3=C.MUTED,TextSize=8,
                        Size=UDim2.new(0,75,1,0),TextXAlignment=Enum.TextXAlignment.Right,ZIndex=6,LayoutOrder=2},hrow2)
                    -- Schema uniqueness
                    local shapes={}; for _,s in ipairs(rec.argShapes) do shapes[s]=(shapes[s] or 0)+1 end
                    local shapeCount=0; for _ in pairs(shapes) do shapeCount+=1 end
                    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                        Text=("shapes:%d  rapid:%d  %s"):format(shapeCount,rec.rapidCount,rec.lastShape or "?"),
                        TextColor3=C.MUTED,TextSize=8,TextWrapped=true,
                        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},row)
                end
            end
        end
        uiThread=nil
    end)
end

-- Watch toggle
local watching=false
WATCH_BTN.MouseButton1Click:Connect(function()
    if not watching then
        watching=true; WATCH_BTN.Text="■ STOP"
        tw(WATCH_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(160,40,40)})
        AVD_STATUS.Text="watching — passive"; AVD_STATUS.TextColor3=Color3.fromRGB(80,210,100)
        startAVD(); startUILoop()
    else
        watching=false; WATCH_BTN.Text="● WATCH"
        tw(WATCH_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
        AVD_STATUS.Text="stopped"; AVD_STATUS.TextColor3=C.MUTED
        stopAVD()
    end
end)

CLEAR_BTN.MouseButton1Click:Connect(function()
    for k in pairs(FINDINGS) do FINDINGS[k]=nil end
    for k in pairs(OBS) do OBS[k]=nil end
    FIND_COUNT.Text="FINDINGS (0)"
    FIND_EMPTY.Visible=true
    FR_EMPTY.Visible=true
end)

-- Auto-start when tab becomes visible
P_AVD:GetPropertyChangedSignal("Visible"):Connect(function()
    if P_AVD.Visible and not watching then
        watching=true; WATCH_BTN.Text="■ STOP"
        tw(WATCH_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(160,40,40)})
        AVD_STATUS.Text="watching — passive"; AVD_STATUS.TextColor3=Color3.fromRGB(80,210,100)
        startAVD(); startUILoop()
    end
end)

-- Export for other modules
G.AVD_FINDINGS = FINDINGS
G.AVD_OBS      = OBS

if G.addTab then G.addTab("avd","AVD",P_AVD)
else warn("[Oracle] G.addTab not found") end

-- Auto-start passively from load so data accumulates before tab is opened
startAVD()
