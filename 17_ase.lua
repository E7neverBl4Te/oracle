-- Oracle // 17_ase.lua
-- ASE — Active Sink Engine
-- Managed fire channel for BRE · Response collection · Sink registry
local G=...; local C=G.C; local TI=G.TI; local mk=G.mk; local tw=G.tw
local corner=G.corner; local stroke=G.stroke; local pad=G.pad
local listV=G.listV; local listH=G.listH; local mkRow=G.mkRow; local mkSep=G.mkSep
local vs=G.vs; local snap=G.snap; local dif=G.dif
local hookR=G.hookR; local rlog=G.rlog; local discR=G.discR
local CFG=G.CFG; local CON=G.CON; local RepS=G.RepS; local LP=G.LP

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ASE ENGINE
-- A "sink" is a registered fire target with a name, remote instance,
-- payload builder, and response handler. ASE manages the lifecycle:
-- register → arm → fire → capture → report
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local SINKS   = {}   -- [id] = sink record
local HISTORY = {}   -- [{sinkId, payload, response, deltas, tick}]
local sinkIdx = 0

local function newSinkId()
    sinkIdx += 1
    return "sink_"..sinkIdx
end

-- Register a sink
-- name: display label
-- remoteName: target remote
-- payloadFn: function() → value(s) to fire
-- onResponse: optional callback(responses, deltas)
local function registerSink(name, remoteName, payloadFn, onResponse)
    local id = newSinkId()
    SINKS[id] = {
        id         = id,
        name       = name,
        remoteName = remoteName,
        payloadFn  = payloadFn,
        onResponse = onResponse,
        armed      = false,
        fireCount  = 0,
        hitCount   = 0,
        lastFired  = 0,
        lastResult = nil,
    }
    return id
end

-- Find remote by name
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
    sc(RepS); if not t then sc(workspace) end
    return t
end

-- Fire a sink and capture response
local function fireSink(id, logFn)
    local sink = SINKS[id]
    if not sink then return nil end

    local remote = findR(sink.remoteName)
    if not remote then
        if logFn then logFn("INFO", sink.name, "Remote not found: "..sink.remoteName) end
        return nil
    end

    -- Build payload
    local payload = {}
    local ok1, result = pcall(sink.payloadFn)
    if ok1 then
        if type(result) == "table" then
            local isArray = true
            for k in pairs(result) do if type(k)~="number" then isArray=false; break end end
            payload = (isArray and #result>0) and result or {result}
        elseif result ~= nil then
            payload = {result}
        end
    else
        if logFn then logFn("INFO", sink.name, "Payload error: "..tostring(result)) end
        return nil
    end

    -- Capture
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

    local ok2,err=pcall(function()
        if remote:IsA("RemoteEvent") then remote:FireServer(table.unpack(payload))
        else remote:InvokeServer(table.unpack(payload)) end
    end)

    if not ok2 then
        for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
        if logFn then logFn("INFO",sink.name,"Rejected: "..tostring(err)) end
        return nil
    end

    task.wait(CFG.RW)
    local dl=tick()+CFG.WD
    while tick()<dl do task.wait(0.05); if #rlog>0 then break end end

    local after=snap()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end

    local responses={}
    for _,r in ipairs(rlog) do table.insert(responses,r) end
    for k in pairs(rlog) do rlog[k]=nil end

    local deltas=dif(before,after)

    local record = {
        sinkId    = id,
        sinkName  = sink.name,
        payload   = payload,
        responses = responses,
        deltas    = deltas,
        tick      = tick(),
        ok        = ok2,
    }

    -- Update sink stats
    sink.fireCount += 1
    sink.lastFired  = tick()
    sink.hitCount  += #responses + #deltas
    sink.lastResult = record

    -- Store history
    if #HISTORY >= 200 then table.remove(HISTORY, 1) end
    table.insert(HISTORY, record)

    -- Callback
    if sink.onResponse then
        pcall(sink.onResponse, responses, deltas)
    end

    if logFn then
        logFn(#responses>0 and "RESPONSE" or (#deltas>0 and "DELTA" or "CLEAN"),
            sink.name.." → "..sink.remoteName,
            (#responses>0 and responses[1].args or
             #deltas>0 and (deltas[1].path.." "..deltas[1].bv.."→"..deltas[1].av) or
             "no observable response"),
            #responses>0 or #deltas>0)
    end

    return record
end

-- From Discovery map: auto-register sinks for all discovered remotes
local function autoRegisterFromDiscovery(logFn)
    local map = G.DISCOVERY_MAP
    if not map then
        if logFn then logFn("INFO","Discovery map not available","Run Discovery scan first") end
        return 0
    end
    local count = 0
    local function regRemote(r)
        -- Skip if already registered
        for _,s in pairs(SINKS) do
            if s.remoteName == r.name then return end
        end
        local obs = G.RSO_OBS and G.RSO_OBS[r.name]
        local payloadFn
        if obs and obs.sig and obs.sig.argCount > 0 then
            -- RSO-informed payload
            local topArgs = {}
            for i=1,obs.sig.argCount do
                local s2=obs.sig.schema and obs.sig.schema[i]
                if s2 and s2.topVals and #s2.topVals>0 then
                    local raw=s2.topVals[1].v; local tk=s2.domType
                    if     tk=="int" or tk=="float" then topArgs[i]=tonumber(raw) or 0
                    elseif tk=="boolean" then topArgs[i]=(raw=="true")
                    else   topArgs[i]=raw end
                else   topArgs[i]=nil end
            end
            payloadFn = function() return topArgs end
        else
            payloadFn = function() return {} end
        end
        registerSink(r.name, r.name, payloadFn, nil)
        count += 1
    end
    for _,r in ipairs(map.remoteEvents)    do regRemote(r) end
    for _,r in ipairs(map.remoteFunctions) do regRemote(r) end
    if logFn then logFn("INFO","Auto-registered "..count.." sinks from Discovery map") end
    return count
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ASE PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_ASE=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,Size=UDim2.new(1,0,0,32),ZIndex=4},P_ASE)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="⬡  ASE — ACTIVE SINK ENGINE",TextColor3=C.ACCENT,TextSize=11,Size=UDim2.new(0,260,1,0),Position=UDim2.new(0,14,0,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local ASE_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="0 sinks",TextColor3=C.MUTED,TextSize=9,Size=UDim2.new(0,120,1,0),Position=UDim2.new(1,-306,0,0),TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

local AUTO_BTN=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.ACCDIM,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="⟳ Auto-Register",TextColor3=C.ACCENT,TextSize=9,Size=UDim2.new(0,110,0,22),Position=UDim2.new(1,-298,0.5,-11),ZIndex=6},TOPBAR)
corner(5,AUTO_BTN); stroke(C.BORDER,1,AUTO_BTN)
AUTO_BTN.MouseEnter:Connect(function() tw(AUTO_BTN,TI.fast,{BackgroundColor3=C.ACCENT,TextColor3=Color3.fromRGB(8,8,12)}) end)
AUTO_BTN.MouseLeave:Connect(function() tw(AUTO_BTN,TI.fast,{BackgroundColor3=C.ACCDIM,TextColor3=C.ACCENT}) end)

local FIRE_ALL=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.ACCENT,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="⚡ Fire All",TextColor3=C.WHITE,TextSize=10,Size=UDim2.new(0,80,0,22),Position=UDim2.new(1,-176,0.5,-11),ZIndex=6},TOPBAR)
corner(5,FIRE_ALL)
do local base=C.ACCENT
    FIRE_ALL.MouseEnter:Connect(function() tw(FIRE_ALL,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    FIRE_ALL.MouseLeave:Connect(function() tw(FIRE_ALL,TI.fast,{BackgroundColor3=base}) end)
end

local ADD_BTN=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.CARD,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="＋ Add",TextColor3=C.TEXT,TextSize=9,Size=UDim2.new(0,54,0,22),Position=UDim2.new(1,-84,0.5,-11),ZIndex=6},TOPBAR)
corner(5,ADD_BTN); stroke(C.BORDER,1,ADD_BTN)
ADD_BTN.MouseEnter:Connect(function() tw(ADD_BTN,TI.fast,{BackgroundColor3=C.SURFACE}) end)
ADD_BTN.MouseLeave:Connect(function() tw(ADD_BTN,TI.fast,{BackgroundColor3=C.CARD}) end)

local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_ASE)

-- left: sink list
local SL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.new(0.44,0,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(0,1,1,-20),Position=UDim2.new(0.44,0,0,10),ZIndex=4},BODY)
local SINK_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},SL)
pad(6,8,SINK_SCROLL); listV(SINK_SCROLL,5)
local SINK_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="No sinks registered.\nPress ⟳ Auto-Register to create sinks\nfrom the Discovery map,\nor ＋ Add to create one manually.",TextColor3=C.MUTED,TextSize=9,TextWrapped=true,Size=UDim2.new(1,0,0,60),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5,LayoutOrder=1},SINK_SCROLL)

-- right: response log
local SR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0.44,1,0,0),Size=UDim2.new(0.56,-1,1,0),ZIndex=3},BODY)
local RES_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},SR)
pad(10,8,RES_SCROLL); listV(RES_SCROLL,3)
local RES_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="Sink responses will appear here.\nFire individual sinks or use ⚡ Fire All.",TextColor3=C.MUTED,TextSize=10,TextWrapped=true,Size=UDim2.new(1,0,0,40),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5,LayoutOrder=1},RES_SCROLL)

local rN=0
local function addLog(tag,msg,detail,hi)
    RES_EMPTY.Visible=false; rN+=1; mkRow(tag,msg,detail,hi,RES_SCROLL,rN)
    task.defer(function() RES_SCROLL.CanvasPosition=Vector2.new(0,RES_SCROLL.AbsoluteCanvasSize.Y) end)
end
local function addLogSep(txt) rN+=1; mkSep(txt,RES_SCROLL,rN) end

local selSink=nil

local function rebuildSinkList()
    for _,c in ipairs(SINK_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    local ids={}; for id in pairs(SINKS) do table.insert(ids,id) end
    table.sort(ids,function(a,b) return (SINKS[a].hitCount or 0)>(SINKS[b].hitCount or 0) end)

    local count=#ids
    ASE_STATUS.Text=count.." sink"..(count~=1 and "s" or "")
    if count==0 then SINK_EMPTY.Visible=true; return end
    SINK_EMPTY.Visible=false

    for i,id in ipairs(ids) do
        local s=SINKS[id]; local sel=selSink==id
        local hasHits=s.hitCount>0
        local card=mk("Frame",{BackgroundColor3=sel and C.ACCDIM or (hasHits and Color3.fromRGB(14,24,8) or C.CARD),
            BorderSizePixel=0,Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=i},SINK_SCROLL)
        corner(5,card)
        if sel then stroke(C.ACCENT,1,card) elseif hasHits then stroke(Color3.fromRGB(80,210,100),1,card) end
        pad(8,6,card); listV(card,3)

        local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
        listH(hrow,6)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=s.name,TextColor3=sel and C.WHITE or C.TEXT,TextSize=10,
            Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6,LayoutOrder=1},hrow)
        -- stats chips
        local function statChip(txt,col2)
            local f=mk("Frame",{BackgroundColor3=col2,BorderSizePixel=0,
                Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},hrow)
            corner(3,f); mk("UIPadding",{PaddingLeft=UDim.new(0,3),PaddingRight=UDim.new(0,3)},f)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text=txt,
                TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
                Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=7},f)
        end
        statChip("×"..s.fireCount, C.MUTED)
        if s.hitCount>0 then statChip("↩"..s.hitCount,Color3.fromRGB(80,210,100)) end

        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=s.remoteName,TextColor3=C.MUTED,TextSize=8,
            Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},card)

        -- fire button
        local fb=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=Color3.fromRGB(40,80,40),BorderSizePixel=0,
            Font=Enum.Font.GothamBold,Text="⚡",TextColor3=Color3.fromRGB(80,210,100),TextSize=11,
            Size=UDim2.new(0,24,0,18),ZIndex=6,LayoutOrder=3},card)
        corner(4,fb)
        fb.MouseButton1Click:Connect(function()
            selSink=id; rebuildSinkList()
            addLogSep("SINK FIRE — "..s.name)
            task.spawn(function() fireSink(id,addLog); rebuildSinkList() end)
        end)
        card.MouseButton1Click:Connect(function()
            selSink=id; rebuildSinkList()
        end)
    end
end

-- Manual add sink
ADD_BTN.MouseButton1Click:Connect(function()
    local name="Sink_"..tostring(sinkIdx+1)
    local remoteName=G.RBOX and G.RBOX.Text:match("^%s*(.-)%s*$") or ""
    if remoteName=="" then remoteName="RemoteName" end
    registerSink(name,remoteName,function() return {} end,nil)
    rebuildSinkList()
end)

-- Auto-register
AUTO_BTN.MouseButton1Click:Connect(function()
    local count=autoRegisterFromDiscovery(addLog)
    rebuildSinkList()
    addLog("INFO","Registered "..count.." new sinks","Total: "..#(function()local t={}for k in pairs(SINKS) do table.insert(t,k)end return t end)())
end)

-- Fire all
local firing=false
FIRE_ALL.MouseButton1Click:Connect(function()
    if firing then return end; firing=true
    tw(FIRE_ALL,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
    local ids={}; for id in pairs(SINKS) do table.insert(ids,id) end
    addLogSep("FIRE ALL — "..#ids.." sinks")
    task.spawn(function()
        for _,id in ipairs(ids) do
            fireSink(id,addLog); task.wait(0.2)
        end
        rebuildSinkList()
        tw(FIRE_ALL,TI.fast,{BackgroundColor3=C.ACCENT}); firing=false
    end)
end)

-- Export
G.ASE_SINKS   = SINKS
G.ASE_HISTORY = HISTORY
G.ase_registerSink = registerSink
G.ase_fireSink     = fireSink

if G.addTab then G.addTab("ase","ASE",P_ASE)
else warn("[Oracle] G.addTab not found") end
