-- Oracle // 20_tsr.lua
-- TSR — Tactical Sovereign Runtime
-- Intent definition · Remote sequencing · Event-triggered execution · Binder
local G=...; local C=G.C; local TI=G.TI; local mk=G.mk; local tw=G.tw
local corner=G.corner; local stroke=G.stroke; local pad=G.pad
local listV=G.listV; local listH=G.listH; local mkRow=G.mkRow; local mkSep=G.mkSep
local vs=G.vs; local snap=G.snap; local dif=G.dif; local hookR=G.hookR
local rlog=G.rlog; local CFG=G.CFG; local CON=G.CON; local RepS=G.RepS; local LP=G.LP

local UIS=game:GetService("UserInputService")
local RS =game:GetService("RunService")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TSR ENGINE
-- An "intent" is a named action: name + sequence of steps
-- Each step: {remote, payloadFn, delayMs}
-- Intents can be bound to triggers: keypress, state condition, timer
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local INTENTS  = {}   -- [name] = intent
local BINDINGS = {}   -- [name] = binding
local intentIdx = 0

local function findR(name)
    local t=nil
    local function sc(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do
            if (x:IsA("RemoteEvent") or x:IsA("RemoteFunction")) and x.Name==name then t=x; return end
        end
    end
    sc(RepS); if not t then sc(workspace) end; return t
end

-- Execute an intent
local function executeIntent(name, logFn)
    local intent=INTENTS[name]
    if not intent then
        if logFn then logFn("INFO",name,"Intent not found") end
        return false
    end
    if intent.running then
        if logFn then logFn("INFO",name,"Already running") end
        return false
    end
    intent.running=true
    intent.execCount=(intent.execCount or 0)+1
    intent.lastExec=tick()

    task.spawn(function()
        local ev={}
        local function col(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return end
            for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(ev,x) end end
        end
        col(RepS); col(workspace)

        local totalHits=0

        for i,step in ipairs(intent.steps) do
            if i>1 and step.delayMs and step.delayMs>0 then
                task.wait(step.delayMs/1000)
            end

            local remote=findR(step.remote)
            if not remote then
                if logFn then logFn("INFO",("Step %d — %s"):format(i,step.remote),"Remote not found") end
                continue
            end

            -- Build payload
            local payload={}
            if step.payloadFn then
                local ok2,result=pcall(step.payloadFn)
                if ok2 then
                    if type(result)=="table" then
                        local isArr=true
                        for k in pairs(result) do if type(k)~="number" then isArr=false;break end end
                        payload=(isArr and #result>0) and result or {result}
                    elseif result~=nil then payload={result} end
                end
            end

            local before=snap()
            for k in pairs(rlog) do rlog[k]=nil end
            local conns=hookR(ev)

            local ok3,err=pcall(function()
                if remote:IsA("RemoteFunction") then remote:InvokeServer(table.unpack(payload))
                else remote:FireServer(table.unpack(payload)) end
            end)

            if not ok3 then
                for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
                if logFn then logFn("INFO",("Step %d — %s"):format(i,step.remote),"Rejected: "..tostring(err):sub(1,50)) end
                continue
            end

            task.wait(CFG.RW)
            local dl=tick()+CFG.WD
            while tick()<dl do task.wait(0.05); if #rlog>0 then break end end
            local after=snap()
            for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end

            local hits=#rlog
            for _,r in ipairs(rlog) do
                if logFn then logFn("RESPONSE",("Step %d — %s replied"):format(i,r.name),r.args,true) end
            end
            for k in pairs(rlog) do rlog[k]=nil end

            for _,ch in ipairs(dif(before,after)) do
                hits+=1
                if logFn then logFn(ch.bad and "PATHOLOG" or "DELTA",
                    ("Step %d — %s"):format(i,ch.path),ch.bv.."→"..ch.av,true) end
            end
            totalHits+=hits

            if logFn then logFn("FIRED",("Step %d/%d — %s"):format(i,#intent.steps,step.remote),
                hits>0 and hits.." hit(s)" or "clean") end
        end

        if logFn then logFn(totalHits>0 and "FINDING" or "CLEAN",
            ("Intent '%s' complete — %d total hit(s)"):format(name,totalHits),
            ("Steps: %d  Executions: %d"):format(#intent.steps,intent.execCount),
            totalHits>0) end

        intent.running=false
    end)
    return true
end

-- Create an intent from RSO chain data
local function intentFromRSO(targetRemote, logFn)
    local obs=G.RSO_OBS and G.RSO_OBS[targetRemote]
    if not obs or not obs.sig then
        if logFn then logFn("INFO",targetRemote,"No RSO signature — creating bare intent") end
    end

    local steps={}
    -- Add chain prerequisites
    if obs and obs.sig and obs.sig.chains then
        for _,ch in ipairs(obs.sig.chains) do
            if ch.causal then
                local predObs=G.RSO_OBS and G.RSO_OBS[ch.pred]
                local pArgs={}
                if predObs and predObs.sig then
                    for i=1,predObs.sig.argCount do
                        local s=predObs.sig.schema and predObs.sig.schema[i]
                        if s and s.topVals and #s.topVals>0 then
                            pArgs[i]=s.topVals[1].v end
                    end
                end
                table.insert(steps,{
                    remote    = ch.pred,
                    payloadFn = function() return pArgs end,
                    delayMs   = 0,
                })
            end
        end
    end
    -- Add target step
    local tArgs={}
    if obs and obs.sig then
        for i=1,obs.sig.argCount do
            local s=obs.sig.schema and obs.sig.schema[i]
            if s and s.topVals and #s.topVals>0 then tArgs[i]=s.topVals[1].v end
        end
    end
    -- Compute delay from first chain's jitter
    local delay=100
    if obs and obs.sig and obs.sig.chains and #obs.sig.chains>0 then
        delay=math.floor(obs.sig.chains[1].jMean or 100)
    end
    table.insert(steps,{
        remote    = targetRemote,
        payloadFn = function() return tArgs end,
        delayMs   = delay,
    })

    intentIdx+=1
    local intentName="Intent_"..targetRemote:sub(1,12)
    INTENTS[intentName]={
        name      = intentName,
        steps     = steps,
        execCount = 0,
        running   = false,
        lastExec  = 0,
        fromRSO   = true,
    }
    if logFn then logFn("INFO","Created intent: "..intentName,#steps.." step(s)") end
    return intentName
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TSR PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_TSR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,Size=UDim2.new(1,0,0,32),ZIndex=4},P_TSR)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="⬡  TSR — TACTICAL SOVEREIGN RUNTIME",TextColor3=C.ACCENT,TextSize=11,Size=UDim2.new(0,310,1,0),Position=UDim2.new(0,14,0,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local TSR_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="0 intents",TextColor3=C.MUTED,TextSize=9,Size=UDim2.new(0,100,1,0),Position=UDim2.new(1,-290,0,0),TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

local FROM_RSO=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.ACCDIM,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="⟳ From RSO",TextColor3=C.ACCENT,TextSize=9,Size=UDim2.new(0,90,0,22),Position=UDim2.new(1,-278,0.5,-11),ZIndex=6},TOPBAR)
corner(5,FROM_RSO); stroke(C.BORDER,1,FROM_RSO)
FROM_RSO.MouseEnter:Connect(function() tw(FROM_RSO,TI.fast,{BackgroundColor3=C.ACCENT,TextColor3=Color3.fromRGB(8,8,12)}) end)
FROM_RSO.MouseLeave:Connect(function() tw(FROM_RSO,TI.fast,{BackgroundColor3=C.ACCDIM,TextColor3=C.ACCENT}) end)

local ADD_INT=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.CARD,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="＋ New",TextColor3=C.TEXT,TextSize=9,Size=UDim2.new(0,54,0,22),Position=UDim2.new(1,-172,0.5,-11),ZIndex=6},TOPBAR)
corner(5,ADD_INT); stroke(C.BORDER,1,ADD_INT)
ADD_INT.MouseEnter:Connect(function() tw(ADD_INT,TI.fast,{BackgroundColor3=C.SURFACE}) end)
ADD_INT.MouseLeave:Connect(function() tw(ADD_INT,TI.fast,{BackgroundColor3=C.CARD}) end)

local EXEC_BTN=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.ACCENT,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="▶ Execute",TextColor3=C.WHITE,TextSize=10,Size=UDim2.new(0,80,0,22),Position=UDim2.new(1,-84,0.5,-11),ZIndex=6},TOPBAR)
corner(5,EXEC_BTN)
do local base=C.ACCENT
    EXEC_BTN.MouseEnter:Connect(function() tw(EXEC_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    EXEC_BTN.MouseLeave:Connect(function() tw(EXEC_BTN,TI.fast,{BackgroundColor3=base}) end)
end

local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_TSR)

-- left: intent list
local IL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.new(0,230,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(0,1,1,-20),Position=UDim2.new(0.46,0,0,10),ZIndex=4},BODY)
local INT_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},IL)
pad(6,8,INT_SCROLL); listV(INT_SCROLL,5)
local INT_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="No intents.\n\nPress ⟳ From RSO to generate\nintents from RSO signatures,\nor ＋ New to create manually.",TextColor3=C.MUTED,TextSize=9,TextWrapped=true,Size=UDim2.new(1,0,0,70),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5,LayoutOrder=1},INT_SCROLL)

-- right: execution log + step detail
local IR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,232,0,0),Size=UDim2.new(1,-232,1,0),ZIndex=3},BODY)
local EXEC_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},IR)
pad(10,8,EXEC_SCROLL); listV(EXEC_SCROLL,3)
local EXEC_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="Select an intent and press ▶ Execute.\nStep-by-step results will appear here.",TextColor3=C.MUTED,TextSize=10,TextWrapped=true,Size=UDim2.new(1,0,0,40),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5,LayoutOrder=1},EXEC_SCROLL)

local eN=0
local function addLog(tag,msg,detail,hi)
    EXEC_EMPTY.Visible=false; eN+=1; mkRow(tag,msg,detail,hi,EXEC_SCROLL,eN)
    task.defer(function() EXEC_SCROLL.CanvasPosition=Vector2.new(0,EXEC_SCROLL.AbsoluteCanvasSize.Y) end)
end
local function addLogSep(txt) eN+=1; mkSep(txt,EXEC_SCROLL,eN) end

local selIntent=nil

local function rebuildIntentList()
    for _,c in ipairs(INT_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    local names={}; for n in pairs(INTENTS) do table.insert(names,n) end
    table.sort(names)
    TSR_STATUS.Text=#names.." intent"..(#names~=1 and "s" or "")
    if #names==0 then INT_EMPTY.Visible=true; return end
    INT_EMPTY.Visible=false

    for i,name in ipairs(names) do
        local intent=INTENTS[name]; local sel=selIntent==name
        local card=mk("Frame",{BackgroundColor3=sel and C.ACCDIM or C.CARD,
            BorderSizePixel=0,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=i},INT_SCROLL)
        corner(5,card); if sel then stroke(C.ACCENT,1,card) end
        pad(8,6,card); listV(card,3)

        local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
        listH(hrow,6)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=name,TextColor3=sel and C.WHITE or C.TEXT,TextSize=10,
            Size=UDim2.new(1,-60,1,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6,LayoutOrder=1},hrow)
        -- status chip
        local chipTxt=intent.running and "RUNNING" or (intent.execCount>0 and "×"..intent.execCount or "idle")
        local chipCol=intent.running and Color3.fromRGB(255,160,40) or (intent.execCount>0 and Color3.fromRGB(80,210,100) or C.MUTED)
        local sc=mk("Frame",{BackgroundColor3=chipCol,BorderSizePixel=0,Size=UDim2.new(0,0,0,15),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
        corner(3,sc); mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4)},sc)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text=chipTxt,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},sc)

        -- Steps preview
        local stepsStr=""
        for j,step in ipairs(intent.steps) do
            stepsStr=stepsStr..(j>1 and " → " or "")..step.remote:sub(1,14)
        end
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=stepsStr,TextColor3=C.MUTED,TextSize=8,TextWrapped=true,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},card)

        -- Quick execute button
        local eb=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=Color3.fromRGB(30,60,30),BorderSizePixel=0,
            Font=Enum.Font.GothamBold,Text="▶",TextColor3=Color3.fromRGB(80,210,100),TextSize=10,
            Size=UDim2.new(0,22,0,18),ZIndex=6,LayoutOrder=3},card)
        corner(4,eb)
        eb.MouseButton1Click:Connect(function()
            selIntent=name; rebuildIntentList()
            addLogSep("EXECUTE — "..name)
            executeIntent(name,addLog)
            task.delay(1,rebuildIntentList)
        end)
        card.MouseButton1Click:Connect(function()
            selIntent=name; rebuildIntentList()
        end)
    end
end

-- From RSO button
FROM_RSO.MouseButton1Click:Connect(function()
    local obs=G.RSO_OBS or {}
    local count=0
    for name,rec in pairs(obs) do
        if rec.sig and (rec.sig.argCount>0 or (rec.sig.chains and #rec.sig.chains>0)) then
            if not INTENTS["Intent_"..name:sub(1,12)] then
                intentFromRSO(name,addLog); count+=1
            end
        end
    end
    rebuildIntentList()
    addLog("INFO","Created "..count.." intents from RSO signatures")
end)

-- Add new intent
ADD_INT.MouseButton1Click:Connect(function()
    intentIdx+=1
    local remoteName=G.RBOX and G.RBOX.Text:match("^%s*(.-)%s*$") or "RemoteName"
    local name="Intent_"..intentIdx
    INTENTS[name]={
        name=name,
        steps={{remote=remoteName,payloadFn=function() return {} end,delayMs=0}},
        execCount=0, running=false, lastExec=0, fromRSO=false,
    }
    selIntent=name
    rebuildIntentList()
    addLog("INFO","Created: "..name,"Remote: "..remoteName)
end)

-- Execute selected
EXEC_BTN.MouseButton1Click:Connect(function()
    if not selIntent then TSR_STATUS.Text="select an intent first"; TSR_STATUS.TextColor3=Color3.fromRGB(255,80,80); return end
    addLogSep("EXECUTE — "..selIntent)
    executeIntent(selIntent,addLog)
    task.delay(1,rebuildIntentList)
end)

G.TSR_INTENTS=INTENTS
G.tsr_execute=executeIntent
G.tsr_fromRSO=intentFromRSO
if G.addTab then G.addTab("tsr","TSR",P_TSR)
else warn("[Oracle] G.addTab not found") end
