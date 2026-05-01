-- Oracle // 19_sarp.lua
-- SARP — Synthetic APC Response Protocol
-- Response timing model · Sync vs async detection · Latency profiling
local G=...; local C=G.C; local TI=G.TI; local mk=G.mk; local tw=G.tw
local corner=G.corner; local stroke=G.stroke; local pad=G.pad
local listV=G.listV; local listH=G.listH; local mkRow=G.mkRow; local mkSep=G.mkSep
local vs=G.vs; local snap=G.snap; local dif=G.dif; local hookR=G.hookR
local rlog=G.rlog; local CFG=G.CFG; local CON=G.CON; local RepS=G.RepS; local LP=G.LP

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SARP ENGINE
-- Fires calibrated probe sequences and measures response latency
-- Builds a timing model: sync (<50ms) vs async (>50ms) vs no-response
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local MODELS  = {}   -- [remoteName] = timing model
local SAMPLES = 8    -- probes per calibration run

local function avg(t)
    if #t==0 then return 0 end
    local s=0; for _,v in ipairs(t) do s+=v end; return s/#t
end
local function stddev(t,m)
    if #t<2 then return 0 end
    m=m or avg(t); local s=0
    for _,v in ipairs(t) do s+=(v-m)^2 end
    return math.sqrt(s/#t)
end
local function median(t)
    if #t==0 then return 0 end
    local s={}; for _,v in ipairs(t) do table.insert(s,v) end
    table.sort(s); return s[math.ceil(#s/2)]
end

-- Classify a timing model
local function classify(model)
    local med=model.median
    if med<=0 then return "NO_RESPONSE","No response observed","danger" end
    if med<30  then return "SYNC_IMMEDIATE","Synchronous — handler responds inline (<30ms)","safe" end
    if med<80  then return "SYNC_LIGHT","Synchronous with light computation (30-80ms)","safe" end
    if med<200 then return "ASYNC_FAST","Asynchronous — likely DataStore or HTTP (80-200ms)","warning" end
    if med<500 then return "ASYNC_SLOW","Asynchronous with heavy computation (200-500ms)","warning" end
    return "ASYNC_HEAVY","Very slow response — DataStore/network bound (>500ms)","danger"
end

-- Run calibration on a remote
local function calibrate(remoteName, args, progressFn, logFn)
    local function findR(name)
        local t=nil
        local function sc(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return end
            for _,x in ipairs(d) do
                if (x:IsA("RemoteEvent") or x:IsA("RemoteFunction")) and x.Name==name then
                    t=x; return
                end
            end
        end
        sc(RepS); if not t then sc(workspace) end; return t
    end

    local remote=findR(remoteName)
    if not remote then
        if logFn then logFn("INFO",remoteName,"Remote not found") end
        return nil
    end

    local latencies    = {}
    local stateDeltas  = {}
    local responses    = 0
    local rejections   = 0

    local ev={}
    local function col(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(ev,x) end end
    end
    col(RepS); col(workspace)

    for probe=1,SAMPLES do
        if progressFn then progressFn(probe,SAMPLES) end
        task.wait(0.15)

        local before=snap()
        for k in pairs(rlog) do rlog[k]=nil end
        local conns=hookR(ev)

        local t0=tick()
        local ok,err=pcall(function()
            if remote:IsA("RemoteFunction") then
                remote:InvokeServer(table.unpack(args or {}))
            else
                remote:FireServer(table.unpack(args or {}))
            end
        end)

        if not ok then
            rejections+=1
            for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
            if logFn then logFn("INFO",("Probe %d rejected"):format(probe),tostring(err):sub(1,50)) end
            continue
        end

        -- Wait for first response signal
        local dl=tick()+1.5
        while tick()<dl do
            task.wait(0.016)
            if #rlog>0 then break end
        end

        local elapsed=(tick()-t0)*1000  -- ms

        local after=snap()
        for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end

        local gotResponse=#rlog>0
        local deltas=dif(before,after)

        if gotResponse then
            responses+=1
            table.insert(latencies,elapsed)
        elseif #deltas>0 then
            -- State change counts as implicit response
            responses+=1
            table.insert(latencies,elapsed)
            table.insert(stateDeltas,elapsed)
        end

        for k in pairs(rlog) do rlog[k]=nil end

        if logFn then
            logFn(gotResponse and "RESPONSE" or (#deltas>0 and "DELTA" or "CLEAN"),
                ("Probe %d/%d — %.1fms"):format(probe,SAMPLES,elapsed),
                gotResponse and "server replied" or (#deltas>0 and "state changed" or "no signal"),
                gotResponse or #deltas>0)
        end
    end

    if #latencies==0 then
        local model={
            remoteName=remoteName, samples=SAMPLES, responses=0,
            rejections=rejections, latencies={}, median=0, mean=0,
            stddev=0, min=0, max=0, stateDeltas=#stateDeltas,
        }
        local cls,desc,risk=classify(model)
        model.class=cls; model.description=desc; model.risk=risk
        MODELS[remoteName]=model
        return model
    end

    local med=median(latencies)
    local mn=avg(latencies)
    local sd=stddev(latencies,mn)
    local lo=math.huge; local hi=0
    for _,v in ipairs(latencies) do
        if v<lo then lo=v end
        if v>hi then hi=v end
    end

    local model={
        remoteName=remoteName, samples=SAMPLES,
        responses=responses, rejections=rejections,
        latencies=latencies, median=med, mean=mn,
        stddev=sd, min=lo, max=hi,
        stateDeltas=#stateDeltas,
        responseRate=responses/SAMPLES,
    }
    local cls,desc,risk=classify(model)
    model.class=cls; model.description=desc; model.risk=risk
    MODELS[remoteName]=model
    return model
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SARP PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_SARP=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,Size=UDim2.new(1,0,0,32),ZIndex=4},P_SARP)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="⬡  SARP — RESPONSE TIMING MODEL",TextColor3=C.ACCENT,TextSize=11,Size=UDim2.new(0,280,1,0),Position=UDim2.new(0,14,0,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local SARP_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="idle",TextColor3=C.MUTED,TextSize=9,Size=UDim2.new(0,120,1,0),Position=UDim2.new(1,-310,0,0),TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

local CAL_BTN=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.ACCENT,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="⟳ Calibrate",TextColor3=C.WHITE,TextSize=10,Size=UDim2.new(0,90,0,22),Position=UDim2.new(1,-188,0.5,-11),ZIndex=6},TOPBAR)
corner(5,CAL_BTN)
do local base=C.ACCENT
    CAL_BTN.MouseEnter:Connect(function() tw(CAL_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    CAL_BTN.MouseLeave:Connect(function() tw(CAL_BTN,TI.fast,{BackgroundColor3=base}) end)
end

local ALL_BTN=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.CARD,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="⚡ All",TextColor3=C.TEXT,TextSize=9,Size=UDim2.new(0,46,0,22),Position=UDim2.new(1,-86,0.5,-11),ZIndex=6},TOPBAR)
corner(5,ALL_BTN); stroke(C.BORDER,1,ALL_BTN)
ALL_BTN.MouseEnter:Connect(function() tw(ALL_BTN,TI.fast,{BackgroundColor3=C.SURFACE}) end)
ALL_BTN.MouseLeave:Connect(function() tw(ALL_BTN,TI.fast,{BackgroundColor3=C.CARD}) end)

local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_SARP)

-- remote selector + target input
local TBAR=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,Size=UDim2.new(1,0,0,32),ZIndex=4},BODY)
stroke(C.BORDER,1,TBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TBAR)
pad(10,0,TBAR); listH(TBAR,8)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="Target",TextColor3=C.MUTED,TextSize=9,Size=UDim2.new(0,46,1,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=1},TBAR)
local TARGET_BOX=mk("TextBox",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Text=G.RBOX and G.RBOX.Text or "",PlaceholderText="remote name",
    PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,TextSize=10,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(1,-80,0,22),ZIndex=5,LayoutOrder=2},TBAR)
corner(5,TARGET_BOX); stroke(C.BORDER,1,TARGET_BOX); pad(6,0,TARGET_BOX)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="×",TextColor3=C.MUTED,TextSize=10,Size=UDim2.new(0,12,1,0),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5,LayoutOrder=3},TBAR)
local SAMP_BOX=mk("TextBox",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,Text=tostring(SAMPLES),PlaceholderText="8",PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,TextSize=10,Font=Enum.Font.Code,ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Center,Size=UDim2.new(0,30,0,22),ZIndex=5,LayoutOrder=4},TBAR)
corner(4,SAMP_BOX); stroke(C.BORDER,1,SAMP_BOX)

-- results split: left=model list, right=detail + log
local ML=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,0,0,32),Size=UDim2.new(0,220,1,-32),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},ML)
local MODEL_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},ML)
pad(6,8,MODEL_SCROLL); listV(MODEL_SCROLL,5)
local MODEL_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="Calibrated remotes will\nappear here.",TextColor3=C.MUTED,TextSize=9,TextWrapped=true,Size=UDim2.new(1,0,0,40),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5,LayoutOrder=1},MODEL_SCROLL)

local MR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,220,0,32),Size=UDim2.new(1,-220,1,-32),ZIndex=3},BODY)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},MR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="Enter a remote name and press ⟳ Calibrate\nto measure its response timing model.",TextColor3=C.MUTED,TextSize=10,TextWrapped=true,Size=UDim2.new(1,0,0,40),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5,LayoutOrder=1},LOG_SCROLL)

local sN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; sN+=1; mkRow(tag,msg,detail,hi,LOG_SCROLL,sN)
    task.defer(function() LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y) end)
end
local function addLogSep(txt) sN+=1; mkSep(txt,LOG_SCROLL,sN) end

local RISK_COL2={safe=Color3.fromRGB(80,210,100),warning=Color3.fromRGB(255,160,40),danger=Color3.fromRGB(255,80,80)}

local function rebuildModelList()
    for _,c in ipairs(MODEL_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    local names={}; for n in pairs(MODELS) do table.insert(names,n) end
    table.sort(names)
    if #names==0 then MODEL_EMPTY.Visible=true; return end
    MODEL_EMPTY.Visible=false
    for i,name in ipairs(names) do
        local m=MODELS[name]
        local riskCol=RISK_COL2[m.risk] or C.MUTED
        local card=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,ZIndex=4,LayoutOrder=i},MODEL_SCROLL)
        corner(5,card); stroke(riskCol,1,card); pad(8,5,card); listV(card,3)
        local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.new(1,0,0,15),ZIndex=5,LayoutOrder=1},card)
        listH(hrow,5)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text=name,TextColor3=C.TEXT,TextSize=10,Size=UDim2.new(1,-60,1,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6,LayoutOrder=1},hrow)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=m.median>0 and ("%.0fms"):format(m.median) or "—",
            TextColor3=riskCol,TextSize=10,
            Size=UDim2.new(0,50,1,0),TextXAlignment=Enum.TextXAlignment.Right,ZIndex=6,LayoutOrder=2},hrow)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text=m.description,TextColor3=C.MUTED,TextSize=8,TextWrapped=true,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},card)
    end
end

local calibrating=false
local function runCalibration(remoteName)
    if calibrating then return end
    calibrating=true
    tw(CAL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
    SARP_STATUS.Text="calibrating "..remoteName.."..."; SARP_STATUS.TextColor3=C.DELTA
    local n=math.clamp(math.floor(tonumber(SAMP_BOX.Text) or SAMPLES),3,20); SAMPLES=n
    addLogSep("SARP CALIBRATION — "..remoteName.." × "..n.." probes")
    task.spawn(function()
        local model=calibrate(remoteName,nil,
            function(p,total) SARP_STATUS.Text=("probe %d/%d — %s"):format(p,total,remoteName) end,
            addLog)
        if model then
            addLogSep("MODEL RESULT")
            addLog(model.risk=="safe" and "CLEAN" or "FINDING",
                remoteName.."  —  "..model.class,
                model.description..
                ("\nMedian: %.1fms  Stddev: ±%.1fms  Range: %.0f–%.0fms"):format(
                    model.median,model.stddev,model.min,model.max)..
                ("\nResponse rate: %.0f%%  Rejections: %d"):format(
                    model.responseRate*100, model.rejections),
                model.risk~="safe")
            SARP_STATUS.Text=("%.0fms %s"):format(model.median,model.class)
            SARP_STATUS.TextColor3=RISK_COL2[model.risk] or C.MUTED
        else
            SARP_STATUS.Text="calibration failed"; SARP_STATUS.TextColor3=Color3.fromRGB(255,80,80)
        end
        rebuildModelList()
        tw(CAL_BTN,TI.fast,{BackgroundColor3=C.ACCENT}); calibrating=false
    end)
end

CAL_BTN.MouseButton1Click:Connect(function()
    local name=TARGET_BOX.Text:match("^%s*(.-)%s*$")
    if name=="" then SARP_STATUS.Text="enter a remote name"; SARP_STATUS.TextColor3=Color3.fromRGB(255,80,80); return end
    runCalibration(name)
end)

ALL_BTN.MouseButton1Click:Connect(function()
    if calibrating then return end
    local map=G.DISCOVERY_MAP
    if not map then SARP_STATUS.Text="run Discovery first"; SARP_STATUS.TextColor3=Color3.fromRGB(255,80,80); return end
    calibrating=true
    tw(ALL_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
    task.spawn(function()
        local all={}
        for _,r in ipairs(map.remoteEvents) do table.insert(all,r.name) end
        for _,r in ipairs(map.remoteFunctions) do table.insert(all,r.name) end
        addLogSep("SARP FULL CALIBRATION — "..#all.." remotes")
        for _,name in ipairs(all) do
            SARP_STATUS.Text="calibrating "..name.."..."; SARP_STATUS.TextColor3=C.DELTA
            calibrate(name,nil,nil,addLog); task.wait(0.2)
        end
        rebuildModelList()
        SARP_STATUS.Text=#all.." remotes calibrated"; SARP_STATUS.TextColor3=Color3.fromRGB(80,210,100)
        tw(ALL_BTN,TI.fast,{BackgroundColor3=C.CARD}); calibrating=false
    end)
end)

G.SARP_MODELS=MODELS
G.sarp_calibrate=calibrate
if G.addTab then G.addTab("sarp","SARP",P_SARP)
else warn("[Oracle] G.addTab not found") end
