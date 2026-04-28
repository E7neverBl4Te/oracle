-- Oracle // 14_rae_bridge.lua
-- RAE Bridge — Oracle to PaperCuts integration layer
-- Transforms Oracle intelligence into PaperCuts data structures
-- Exports to _G.PC_ORACLE_BRIDGE for PaperCuts to consume on load
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
local discR  = G.discR
local CON    = G.CON
local RepS   = G.RepS
local LP     = G.LP

local PC_BASE = "https://raw.githubusercontent.com/E7neverBl4Te/PaperCuts_RAE.luau/PaperTree/"

-- Reconstruct LastArgs from RSO schema top values
local function reconstructArgs(sig)
    if not sig or not sig.schema then return {} end
    local args = {}
    for i = 1, sig.argCount do
        local s = sig.schema[i]
        if s and s.topVals and #s.topVals > 0 then
            local raw = s.topVals[1].v
            local tk  = s.domType
            if     tk=="int" or tk=="float" then args[i] = tonumber(raw) or 0
            elseif tk=="boolean"  then args[i] = (raw=="true")
            elseif tk=="Vector3"  then
                local x,y,z = raw:match("^([^,]+),([^,]+),([^,]+)$")
                args[i] = Vector3.new(tonumber(x) or 0,tonumber(y) or 0,tonumber(z) or 0)
            elseif tk=="CFrame"   then
                local x,y,z = raw:match("^([^,]+),([^,]+),([^,]+)$")
                args[i] = CFrame.new(tonumber(x) or 0,tonumber(y) or 0,tonumber(z) or 0)
            else args[i] = raw end
        end
    end
    return args
end

-- Derive Beta(alpha,beta) ETM prior from RSO signature
local function deriveETMPrior(rec)
    if not rec or not rec.sig then return 1.0, 1.0 end
    local sig     = rec.sig
    local total   = rec.total or 0
    local pattern = sig.cadence and sig.cadence.pattern or "sporadic"
    local weight  = math.min(total / 50, 1.0)
    local pMod
    if     pattern=="steady"       then pMod=0.70
    elseif pattern=="burst"        then pMod=0.55
    elseif pattern=="input-driven" then pMod=0.60
    else                                pMod=0.45 end
    local schemaBonus = 0
    if sig.constraints then
        for _, cs in pairs(sig.constraints) do
            if cs.kind=="constant" then schemaBonus=schemaBonus+0.05
            elseif cs.kind=="enum" then schemaBonus=schemaBonus+0.02 end
        end
    end
    local pSuccess = math.clamp(pMod + math.min(schemaBonus,0.20), 0.10, 0.90)
    local strength = 2 + weight * 18
    return pSuccess * strength, (1-pSuccess) * strength
end

-- Convert Oracle chain observation to CDG edge
local function chainToCDGEdge(ch)
    local prob = ch.prob or 0; local count = ch.count or 0
    local effectSize
    if     ch.causal and ch.coupled then effectSize = 0.70 + prob*0.25
    elseif ch.causal                then effectSize = 0.50 + prob*0.30
    elseif ch.coupled               then effectSize = 0.30 + prob*0.20
    else                                 effectSize = 0.10 + prob*0.10 end
    local confidence = math.min(count/12.0, 1.0)
    if ch.stable then confidence = math.min(confidence+0.15, 1.0) end
    return {
        coFired=count, coSuccess=math.floor(count*prob),
        coFail=count-math.floor(count*prob), aFailBSuc=0, coTotal=count,
        effectSize=effectSize, confidence=confidence, lastUpdated=tick(),
    }
end

-- Get framework trust ceiling
local function getTrustCeiling(fwDetect)
    if not fwDetect or #fwDetect==0 then return 1.0 end
    local trust = fwDetect[1].fw and fwDetect[1].fw.trust or "COMMUNITY"
    if trust:find("EXTERNAL") then return 0.60
    elseif trust:find("UNKNOWN") then return 0.40
    else return 1.0 end
end

-- Main sync
local function performSync(logFn)
    local obs         = G.RSO_OBS or {}
    local fwDetect    = _G.ORACLE_FW_DETECTIONS or {}
    local carrierData = G.CARRIER_TELEPORT_DATA

    logFn("INFO","Starting Oracle to PaperCuts bridge sync")

    local ev, fn = discR()
    local instMap = {}
    for _,r in ipairs(ev) do instMap[r.Name]=r end
    for _,r in ipairs(fn) do instMap[r.Name]=r end
    logFn("INFO",("Live: %d events  %d functions"):format(#ev,#fn))

    -- RSO -> RemoteEvent entries
    local remoteEntries = {}; local sigCount = 0
    for name, rec in pairs(obs) do
        if rec.sig then
            sigCount+=1
            local inst    = instMap[name]
            local args    = reconstructArgs(rec.sig)
            local al,bt   = deriveETMPrior(rec)
            table.insert(remoteEntries, {
                Name=name, Instance=inst,
                Path=inst and inst:GetFullName() or ("ReplicatedStorage."..name),
                FireCount=rec.total or 0,
                LastArgs=#args>0 and args or nil,
                LastFire=rec.last or 0,
                OracleRSO=true,
                Cadence=rec.sig.cadence and rec.sig.cadence.pattern or "unknown",
                Role=rec.sig.role or "Unknown",
                ArgCount=rec.sig.argCount or 0,
                HasChain=#(rec.sig.chains or {})>0,
                ETMAlpha=al, ETMBeta=bt,
            })
        end
    end
    for _,r in ipairs(ev) do
        if not obs[r.Name] then
            table.insert(remoteEntries,{
                Name=r.Name,Instance=r,Path=r:GetFullName(),
                FireCount=0,LastArgs=nil,LastFire=0,
                OracleRSO=false,ETMAlpha=1.0,ETMBeta=1.0,
            })
        end
    end
    table.sort(remoteEntries,function(a,b) return (a.FireCount or 0)>(b.FireCount or 0) end)
    logFn("INFO",("RSO signatures: %d / %d remotes"):format(sigCount,#remoteEntries))

    -- Chains -> CDG seeds
    local cdgSeeds = {}; local chainCount = 0
    for name, rec in pairs(obs) do
        if rec.sig and rec.sig.chains then
            for _, ch in ipairs(rec.sig.chains) do
                if ch.causal then
                    chainCount+=1
                    if not cdgSeeds[ch.pred] then cdgSeeds[ch.pred]={} end
                    cdgSeeds[ch.pred][name] = chainToCDGEdge(ch)
                    logFn("INFO",("CDG: %s -> %s  eff=%.2f  conf=%.0f%%"):format(
                        ch.pred,name,cdgSeeds[ch.pred][name].effectSize,
                        cdgSeeds[ch.pred][name].confidence*100))
                end
            end
        end
    end
    logFn("INFO",("CDG pre-seed: %d causal edges"):format(chainCount))

    -- Framework trust ceilings
    local trustCap = getTrustCeiling(fwDetect)
    local trustCeilings = {}
    for _,entry in ipairs(remoteEntries) do trustCeilings[entry.Name]=trustCap end
    if trustCap < 1.0 then
        local topFW = fwDetect[1] and fwDetect[1].fw
        logFn("FINDING",("Framework trust cap: %.0f%% (%s)"):format(
            trustCap*100, topFW and topFW.name or "unknown"),
            "ETM ceiling applied to all remotes")
    else
        logFn("CLEAN","No external framework — no ETM ceiling applied")
    end

    -- ETM seeds from RSO priors
    local etmSeeds = {}
    for _, entry in ipairs(remoteEntries) do
        if entry.OracleRSO then
            local alpha = math.min(entry.ETMAlpha, trustCap*20)
            local beta  = entry.ETMBeta
            local n     = math.min(entry.FireCount, 50)
            local mean  = alpha/(alpha+beta)
            etmSeeds[entry.Name] = {
                oracle_prior = {
                    alpha=alpha, beta=beta, n=n, mean=mean, M2=0,
                    stddev=math.sqrt((alpha*beta)/((alpha+beta)^2*(alpha+beta+1))),
                    converged=n>=10 and mean>0.4, lastUpdated=tick(),
                }
            }
        end
    end

    -- Carrier data
    local carrierExport = nil
    if carrierData and type(carrierData)=="table" then
        carrierExport = carrierData
        local fields=0; for _ in pairs(carrierData) do fields+=1 end
        logFn("FINDING",("TeleportData: %d field(s)"):format(fields),
            "Server received authored payload — included in bridge")
    end

    local bridge = {
        version="1.0", syncedAt=tick(), placeId=game.PlaceId,
        RemoteEvents=remoteEntries,
        CDG_Seeds=cdgSeeds,
        ETM_Seeds=etmSeeds,
        TrustCeilings=trustCeilings,
        CarrierData=carrierExport,
        Summary={
            totalRemotes=#remoteEntries, rsoSigned=sigCount,
            cdgEdges=chainCount, trustCap=trustCap,
            hasCarrier=carrierExport~=nil,
            fwDetected=#fwDetect>0 and fwDetect[1].fw and fwDetect[1].fw.name or nil,
        },
    }

    _G.PC_ORACLE_BRIDGE   = bridge
    _G.ORACLE_BRIDGE_READY = true

    logFn("FIRED",("Bridge sync complete — %d remotes  %d RSO  %d CDG edges"):format(
        #remoteEntries, sigCount, chainCount))
    return bridge
end

-- PAGE UI
local P_BRIDGE=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_BRIDGE)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⟳  RAE BRIDGE",TextColor3=C.ACCENT,TextSize=11,
    Size=UDim2.new(0,160,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local BRIDGE_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="not synced",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,180,1,0),Position=UDim2.new(1,-360,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)
local SYNC_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ACCENT,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⟳  SYNC",TextColor3=C.WHITE,TextSize=10,
    Size=UDim2.new(0,70,0,22),Position=UDim2.new(1,-170,0.5,-11),ZIndex=6},TOPBAR)
corner(5,SYNC_BTN)
do local base=C.ACCENT
    SYNC_BTN.MouseEnter:Connect(function() tw(SYNC_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    SYNC_BTN.MouseLeave:Connect(function() tw(SYNC_BTN,TI.fast,{BackgroundColor3=base}) end)
end
local RAE_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.CARD,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="▶  LAUNCH RAE",TextColor3=C.MUTED,TextSize=10,
    Size=UDim2.new(0,104,0,22),Position=UDim2.new(1,-58,0.5,-11),ZIndex=6},TOPBAR)
corner(5,RAE_BTN); stroke(C.BORDER,1,RAE_BTN)
RAE_BTN.MouseEnter:Connect(function() tw(RAE_BTN,TI.fast,{BackgroundColor3=C.SURFACE,TextColor3=C.TEXT}) end)
RAE_BTN.MouseLeave:Connect(function() tw(RAE_BTN,TI.fast,{BackgroundColor3=C.CARD,TextColor3=C.MUTED}) end)

local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_BRIDGE)

-- left panel
local BL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0,240,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},BL)
local BL_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},BL)
pad(10,10,BL_SCROLL); listV(BL_SCROLL,8)

-- right panel
local BR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,240,0,0),Size=UDim2.new(1,-240,1,0),ZIndex=3},BODY)
local BR_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},BR)
pad(10,8,BR_SCROLL); listV(BR_SCROLL,3)
local BR_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Press ⟳ SYNC to bridge Oracle intelligence into PaperCuts RAE.\n\n"..
         "Oracle observes · PaperCuts acts · bridge connects them.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,60),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},BR_SCROLL)

local brN=0
local function addLog(tag,msg,detail,hi)
    BR_EMPTY.Visible=false
    brN+=1; mkRow(tag,msg,detail,hi,BR_SCROLL,brN)
    task.defer(function() BR_SCROLL.CanvasPosition=Vector2.new(0,BR_SCROLL.AbsoluteCanvasSize.Y) end)
end
local function addLogSep(txt) brN+=1; mkSep(txt,BR_SCROLL,brN) end
local function clearLog()
    for _,c in ipairs(BR_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    brN=0; BR_EMPTY.Visible=true
end

local function buildLeftPanel(bridge)
    for _,c in ipairs(BL_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    local ord=0; local function o() ord+=1; return ord end
    local s=bridge.Summary

    local function sCard(title,val,col,sub)
        local card=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=o()},BL_SCROLL)
        corner(6,card); stroke(C.BORDER,1,card); pad(10,6,card); listV(card,2)
        local h=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,18),ZIndex=5,LayoutOrder=1},card)
        listH(h,6)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=title,TextColor3=C.MUTED,TextSize=9,
            Size=UDim2.new(1,-60,1,0),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=6,LayoutOrder=1},h)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=tostring(val),TextColor3=col or C.TEXT,TextSize=12,
            Size=UDim2.new(0,55,1,0),TextXAlignment=Enum.TextXAlignment.Right,
            ZIndex=6,LayoutOrder=2},h)
        if sub then mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=sub,TextColor3=C.MUTED,TextSize=8,TextWrapped=true,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2},card) end
    end

    sCard("RSO Signatures", s.rsoSigned,
        s.rsoSigned>0 and Color3.fromRGB(80,210,100) or C.MUTED,
        "behavioral fingerprints ready")
    sCard("Total Remotes",  s.totalRemotes, C.TEXT, "live + RSO-observed")
    sCard("CDG Edges",      s.cdgEdges,
        s.cdgEdges>0 and Color3.fromRGB(255,160,40) or C.MUTED,
        "causal chains pre-seeded")
    sCard("ETM Priors",     s.rsoSigned,
        s.rsoSigned>0 and Color3.fromRGB(168,120,255) or C.MUTED,
        "Bayesian priors derived from RSO cadence")
    local capStr = s.trustCap>=1.0 and "none (community)" or
        ("%.0f%% cap — %s"):format(s.trustCap*100, s.fwDetected or "?")
    sCard("Trust Cap",
        s.trustCap>=1.0 and "none" or ("%.0f%%"):format(s.trustCap*100),
        s.trustCap<0.60 and Color3.fromRGB(255,80,80) or
        s.trustCap<1.0  and Color3.fromRGB(255,160,40) or
        Color3.fromRGB(80,210,100), capStr)
    sCard("Carrier Data",
        s.hasCarrier and "YES" or "none",
        s.hasCarrier and Color3.fromRGB(255,160,40) or C.MUTED,
        s.hasCarrier and "TeleportData in bridge" or "no carrier data found")

    -- _G status indicator
    local glbl=mk("Frame",{BackgroundColor3=
        _G.PC_ORACLE_BRIDGE and Color3.fromRGB(8,30,12) or C.CARD,
        BorderSizePixel=0,Size=UDim2.new(1,0,0,36),
        ZIndex=4,LayoutOrder=o()},BL_SCROLL)
    corner(6,glbl)
    stroke(_G.PC_ORACLE_BRIDGE and Color3.fromRGB(80,210,100) or C.BORDER,1,glbl)
    pad(10,0,glbl)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=_G.PC_ORACLE_BRIDGE and
            "⬡  _G.PC_ORACLE_BRIDGE  READY" or
            "○  _G.PC_ORACLE_BRIDGE  not set",
        TextColor3=_G.PC_ORACLE_BRIDGE and Color3.fromRGB(80,210,100) or C.MUTED,
        TextSize=10,Size=UDim2.fromScale(1,1),
        TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5},glbl)

    -- Step guide
    local guide=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=o()},BL_SCROLL)
    corner(6,guide); pad(10,8,guide); listV(guide,4)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="HOW TO USE",TextColor3=C.MUTED,TextSize=8,
        Size=UDim2.new(1,0,0,13),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=1},guide)
    local steps={"1. RSO — collect signatures (Signatures tab)",
                 "2. Framework — run detection scan",
                 "3. Here — press SYNC",
                 "4. Press LAUNCH RAE",
                 "   PaperCuts reads _G.PC_ORACLE_BRIDGE",
                 "   Cold start bypassed — ETM/CDG pre-seeded"}
    for i,step in ipairs(steps) do
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=step,TextColor3=C.MUTED,TextSize=8,
            Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=i+1},guide)
    end
end

local function buildRemoteTable(bridge)
    addLogSep("BRIDGE TABLE — "..#bridge.RemoteEvents.." entries")
    for _, entry in ipairs(bridge.RemoteEvents) do
        local details={}
        if entry.OracleRSO then
            table.insert(details,"cadence:"..entry.Cadence)
            table.insert(details,"fires:"..entry.FireCount)
            table.insert(details,("ETM:α=%.1f β=%.1f"):format(entry.ETMAlpha,entry.ETMBeta))
            if entry.HasChain then table.insert(details,"⛓ chained") end
        else
            table.insert(details,"no RSO signature")
        end
        local argStr=""
        if entry.LastArgs and #entry.LastArgs>0 then
            local parts={}
            for _,a in ipairs(entry.LastArgs) do table.insert(parts,vs(a):sub(1,18)) end
            argStr="args: "..table.concat(parts,", ")
        end
        mkRow(entry.OracleRSO and "RSO" or "INFO",
            entry.Name,
            table.concat(details,"  ·  ")..(argStr~="" and "\n"..argStr or ""),
            entry.OracleRSO, BR_SCROLL, brN+1)
        brN+=1
    end
    if next(bridge.CDG_Seeds) then
        addLogSep("CDG EDGES")
        for pred, targets in pairs(bridge.CDG_Seeds) do
            for target, edge in pairs(targets) do
                mkRow("INFO", pred.." → "..target,
                    ("eff=%.2f  conf=%.0f%%  fires=%d"):format(
                        edge.effectSize, edge.confidence*100, edge.coFired),
                    edge.effectSize>0.5, BR_SCROLL, brN+1)
                brN+=1
            end
        end
    end
end

-- SYNC
local syncing=false
SYNC_BTN.MouseButton1Click:Connect(function()
    if syncing then return end
    syncing=true
    tw(SYNC_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
    BRIDGE_STATUS.Text="syncing..."; BRIDGE_STATUS.TextColor3=C.DELTA
    clearLog()
    task.spawn(function()
        local bridge=performSync(addLog)
        buildLeftPanel(bridge)
        buildRemoteTable(bridge)
        BRIDGE_STATUS.Text=("%d remotes  %d RSO  %d CDG"):format(
            bridge.Summary.totalRemotes,bridge.Summary.rsoSigned,bridge.Summary.cdgEdges)
        BRIDGE_STATUS.TextColor3=Color3.fromRGB(80,210,100)
        tw(RAE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,210,100),TextColor3=Color3.fromRGB(8,8,12)})
        tw(SYNC_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
        syncing=false
    end)
end)

-- LAUNCH RAE
local launching=false
RAE_BTN.MouseButton1Click:Connect(function()
    if launching then return end
    if not _G.PC_ORACLE_BRIDGE then
        BRIDGE_STATUS.Text="sync first"; BRIDGE_STATUS.TextColor3=Color3.fromRGB(255,80,80); return
    end
    launching=true
    tw(RAE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
    BRIDGE_STATUS.Text="loading PaperCuts..."; BRIDGE_STATUS.TextColor3=C.DELTA
    addLogSep("LAUNCHING PAPERCUTS RAE")
    task.spawn(function()
        local function httpGet(url)
            if syn and syn.request then return syn.request({Url=url,Method="GET"}).Body
            elseif http_request then return http_request({Url=url,Method="GET"}).Body
            elseif request then return request({Url=url,Method="GET"}).Body
            elseif fluxus and fluxus.request then return fluxus.request({Url=url,Method="GET"}).Body
            end; error("No HTTP function available")
        end
        local ok,err=pcall(function()
            addLog("INFO","Fetching PaperCuts loader.lua...")
            local src=httpGet(PC_BASE.."loader.lua")
            local fn,pe=loadstring(src)
            assert(fn,"Parse error in loader.lua: "..tostring(pe))
            addLog("INFO","Executing PaperCuts loader — _G.PC_ORACLE_BRIDGE active with "..
                #(_G.PC_ORACLE_BRIDGE.RemoteEvents or {}).." remote entries")
            fn()
        end)
        if not ok then
            addLog("INFO","PaperCuts boot failed",tostring(err))
            addLog("INFO","Bridge data still in _G.PC_ORACLE_BRIDGE",
                "Load PaperCuts manually — data persists in _G")
            BRIDGE_STATUS.Text="boot failed — bridge data ready"
            BRIDGE_STATUS.TextColor3=Color3.fromRGB(255,160,40)
        else
            addLog("FIRED","PaperCuts RAE launched with Oracle bridge")
            addLog("INFO","ETM seeded with RSO priors — cold start bypassed")
            if next(_G.PC_ORACLE_BRIDGE.CDG_Seeds) then
                addLog("INFO","CDG pre-seeded with Oracle chain edges")
            end
            BRIDGE_STATUS.Text="PaperCuts running with Oracle data"
            BRIDGE_STATUS.TextColor3=Color3.fromRGB(80,210,100)
        end
        tw(RAE_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,210,100),TextColor3=Color3.fromRGB(8,8,12)})
        launching=false
    end)
end)

-- Initial left panel (pre-sync)
do
    local obs=G.RSO_OBS or {}; local obsCount=0
    for _ in pairs(obs) do obsCount+=1 end
    local ord=0; local function o() ord+=1; return ord end
    local hdr=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=o()},BL_SCROLL)
    corner(6,hdr); stroke(C.BORDER,1,hdr); pad(10,8,hdr); listV(hdr,3)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="ORACLE BRIDGE",TextColor3=C.ACCENT,TextSize=12,
        Size=UDim2.new(1,0,0,16),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=1},hdr)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text="Connects Oracle's intelligence layer to PaperCuts RAE's decision engine.\n\n"..
             "Oracle observes · PaperCuts acts · bridge connects them.",
        TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},hdr)

    local function readyRow(txt, ready)
        local row=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,16),ZIndex=4,LayoutOrder=o()},BL_SCROLL)
        listH(row,6)
        local dot=mk("Frame",{BackgroundColor3=ready and Color3.fromRGB(80,210,100) or C.MUTED,
            BorderSizePixel=0,Size=UDim2.fromOffset(8,8),ZIndex=5,LayoutOrder=1},row)
        corner(4,dot)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=txt,TextColor3=ready and C.TEXT or C.MUTED,TextSize=9,
            Size=UDim2.new(1,-20,1,0),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=2},row)
    end
    readyRow("RSO: "..obsCount.." signatures", obsCount>0)
    readyRow("Framework detection", _G.ORACLE_FW_DETECTIONS~=nil)
    readyRow("_G.PC_ORACLE_BRIDGE", _G.PC_ORACLE_BRIDGE~=nil)
end

-- Export hook for 12_framework.lua to write detections
G.exportFWDetections = function(scores) _G.ORACLE_FW_DETECTIONS = scores end

-- Register tab
if G.addTab then
    G.addTab("bridge","RAE Bridge",P_BRIDGE)
else
    warn("[Oracle] G.addTab not found")
end
