-- Oracle // 15_discovery.lua
-- Discovery — Full Environment Scan
-- Maps everything accessible: Remotes · Scripts · Modules · Services · Globals · DataStore names
local G=...; local C=G.C; local TI=G.TI; local mk=G.mk; local tw=G.tw
local corner=G.corner; local stroke=G.stroke; local pad=G.pad
local listV=G.listV; local listH=G.listH; local mkRow=G.mkRow; local mkSep=G.mkSep
local vs=G.vs; local CON=G.CON; local RepS=G.RepS; local LP=G.LP

local MAP={remoteEvents={},remoteFunctions={},localScripts={},moduleScripts={},
    bindableEvents={},bindableFuncs={},services={},globals={},datastoreNames={},
    valueObjects={},screenGuis={},summary={},scannedAt=0}

local SERVICES={"MarketplaceService","BadgeService","DataStoreService","MessagingService",
    "AnalyticsService","TeleportService","GroupService","FriendService",
    "PolicyService","LocalizationService","AssetService","ReplicatedStorage",
    "ReplicatedFirst","Players","RunService","UserInputService","GuiService",
    "SoundService","TweenService","PathfindingService","PhysicsService",
    "StarterGui","StarterPack","Teams"}

local EXEC_GLOBALS={"syn","http_request","request","fluxus","getgenv","getrenv",
    "getinstances","getnilinstances","getloadedmodules","getconnections","getscripts",
    "getgc","firesignal","hookfunction","newcclosure","isexecutorclosure",
    "checkcaller","filtergc","loadstring","getfenv","setfenv","debug"}

local function safe(f,...) local ok,r=pcall(f,...); return ok and r or nil end
local function safeDesc(root) return safe(function() return root:GetDescendants() end) or {} end

local function inferDS(src)
    local t={}
    for n in src:gmatch('GetDataStore%s*%(%s*["\']([^"\']+)["\']') do t[n]=true end
    for n in src:gmatch('GetOrderedDataStore%s*%(%s*["\']([^"\']+)["\']') do t[n]=true end
    return t
end

local function runScan(logFn)
    for k,v in pairs(MAP) do if type(v)=="table" then for kk in pairs(v) do v[kk]=nil end end end
    MAP.scannedAt=tick()
    local dsNames={}

    -- ReplicatedStorage
    logFn("INFO","Scanning ReplicatedStorage...")
    for _,x in ipairs(safeDesc(RepS)) do
        local p=x:GetFullName(); local n=x.Name
        if x:IsA("RemoteEvent") then table.insert(MAP.remoteEvents,{name=n,path=p,instance=x})
        elseif x:IsA("RemoteFunction") then table.insert(MAP.remoteFunctions,{name=n,path=p,instance=x})
        elseif x:IsA("ModuleScript") then
            local src=safe(function() return x.Source end) or ""
            local ds=inferDS(src); for k2 in pairs(ds) do dsNames[k2]=true end
            table.insert(MAP.moduleScripts,{name=n,path=p,accessible=#src>0,sourceLen=#src,hasDataStore=next(ds)~=nil})
        elseif x:IsA("BindableEvent") then table.insert(MAP.bindableEvents,{name=n,path=p})
        elseif x:IsA("BindableFunction") then table.insert(MAP.bindableFuncs,{name=n,path=p})
        elseif x.ClassName:find("Value$") then
            local v2=safe(function() return x.Value end)
            table.insert(MAP.valueObjects,{name=n,path=p,vtype=x.ClassName,value=vs(v2 or "")})
        end
    end

    -- Workspace remotes
    logFn("INFO","Scanning Workspace...")
    for _,x in ipairs(safeDesc(workspace)) do
        local p=x:GetFullName()
        if not p:find("ReplicatedStorage") then
            if x:IsA("RemoteEvent") then table.insert(MAP.remoteEvents,{name=x.Name,path=p,instance=x})
            elseif x:IsA("RemoteFunction") then table.insert(MAP.remoteFunctions,{name=x.Name,path=p,instance=x}) end
        end
    end

    -- LocalPlayer scripts
    logFn("INFO","Scanning LocalPlayer...")
    local function scanScripts(root)
        for _,x in ipairs(safeDesc(root)) do
            if x:IsA("LocalScript") then
                local src=safe(function() return x.Source end) or ""
                local ds=inferDS(src); for k2 in pairs(ds) do dsNames[k2]=true end
                table.insert(MAP.localScripts,{name=x.Name,path=x:GetFullName(),sourceLen=#src,hasDataStore=next(ds)~=nil})
            elseif x:IsA("ScreenGui") then
                local ch=safe(function() return x:GetChildren() end) or {}
                table.insert(MAP.screenGuis,{name=x.Name,path=x:GetFullName(),childCount=#ch})
            end
        end
    end
    scanScripts(LP)

    -- Services
    logFn("INFO","Probing services...")
    for _,svcName in ipairs(SERVICES) do
        local svc=safe(function() return game:GetService(svcName) end)
        local methods={}
        if svc then
            local checks={"GetProductInfo","UserOwnsGamePassAsync","PromptProductPurchase",
                "UserHasBadgeAsync","GetDataStore","GetOrderedDataStore","PublishAsync",
                "SubscribeAsync","GetAsync","SetAsync","Teleport","TeleportToPlaceInstance",
                "GetLocalPlayerTeleportData","GetGroupsAsync","GetPolicyInfoForPlayerAsync"}
            for _,m in ipairs(checks) do
                if safe(function() return svc[m] end)~=nil then table.insert(methods,m) end
            end
        end
        table.insert(MAP.services,{name=svcName,accessible=svc~=nil,methodCount=#methods,methods=methods})
    end

    -- Globals
    logFn("INFO","Scanning globals...")
    local seen={}
    local function addGlobal(name,val,executor)
        if seen[name] then return end; seen[name]=true
        local t=type(val); local flagged=executor
        for _,fg in ipairs(EXEC_GLOBALS) do if name==fg then flagged=true; break end end
        local preview
        if t=="function" then preview="[function]"
        elseif t=="table" then preview="[table "..tostring(val).."]"
        elseif t=="string" then preview='"'..tostring(val):sub(1,30)..'"'
        else preview=tostring(val):sub(1,30) end
        table.insert(MAP.globals,{name=name,gtype=t,preview=preview,flagged=flagged,executor=executor or false})
    end
    local ok,env=pcall(getfenv); if ok and type(env)=="table" then
        for k,v in pairs(env) do addGlobal(k,v,false) end
    end
    local genv=safe(function() return getgenv and getgenv() or {} end) or {}
    for _,name in ipairs(EXEC_GLOBALS) do
        local v=genv[name] or rawget(genv,name)
        if v~=nil then addGlobal(name,v,true) end
    end
    table.sort(MAP.globals,function(a,b)
        if a.flagged~=b.flagged then return a.flagged end; return a.name<b.name end)

    -- DataStore names
    for name in pairs(dsNames) do table.insert(MAP.datastoreNames,name) end
    table.sort(MAP.datastoreNames)

    -- Summary
    local flagCount=0
    for _,g in ipairs(MAP.globals) do if g.flagged then flagCount+=1 end end
    MAP.summary={
        remoteEvents=#MAP.remoteEvents,remoteFunctions=#MAP.remoteFunctions,
        localScripts=#MAP.localScripts,moduleScripts=#MAP.moduleScripts,
        bindableEvents=#MAP.bindableEvents,bindableFuncs=#MAP.bindableFuncs,
        services=#MAP.services,globals=#MAP.globals,flaggedGlobals=flagCount,
        datastoreNames=#MAP.datastoreNames,valueObjects=#MAP.valueObjects,
        screenGuis=#MAP.screenGuis,
    }

    logFn("FIRED","Discovery complete",
        ("%d remotes · %d scripts · %d modules · %d DS names"):format(
            #MAP.remoteEvents+#MAP.remoteFunctions,
            #MAP.localScripts,#MAP.moduleScripts,#MAP.datastoreNames))

    G.DISCOVERY_MAP=MAP; _G.ORACLE_DISCOVERY=MAP
    return MAP
end

-- PAGE
local P_DISC=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,Size=UDim2.new(1,0,0,32),ZIndex=4},P_DISC)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="⬡  DISCOVERY",TextColor3=C.ACCENT,TextSize=11,Size=UDim2.new(0,160,1,0),Position=UDim2.new(0,14,0,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local DISC_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="not scanned",TextColor3=C.MUTED,TextSize=9,Size=UDim2.new(0,200,1,0),Position=UDim2.new(1,-292,0,0),TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)
local SCAN_BTN=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.ACCENT,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="⬡  SCAN",TextColor3=C.WHITE,TextSize=10,Size=UDim2.new(0,80,0,22),Position=UDim2.new(1,-92,0.5,-11),ZIndex=6},TOPBAR)
corner(5,SCAN_BTN)
do local base=C.ACCENT
    SCAN_BTN.MouseEnter:Connect(function() tw(SCAN_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    SCAN_BTN.MouseLeave:Connect(function() tw(SCAN_BTN,TI.fast,{BackgroundColor3=base}) end)
end

local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_DISC)
local NL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.new(0,200,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=4},NL)
local NAV=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),ScrollBarThickness=3,ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},NL)
pad(6,8,NAV); listV(NAV,4)
local DR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,200,0,0),Size=UDim2.new(1,-200,1,0),ZIndex=3},BODY)
local DETAIL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},DR)
pad(10,8,DETAIL); listV(DETAIL,3)
local DETAIL_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="Press ⬡ SCAN to map the game environment.\n\nDiscovery is the foundation for AVD, GSE, SARP and TSR.",TextColor3=C.MUTED,TextSize=10,TextWrapped=true,Size=UDim2.new(1,0,0,80),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5,LayoutOrder=1},DETAIL)

local dN=0
local function addDetail(tag,msg,detail,hi)
    DETAIL_EMPTY.Visible=false; dN+=1; mkRow(tag,msg,detail,hi,DETAIL,dN)
    task.defer(function() DETAIL.CanvasPosition=Vector2.new(0,DETAIL.AbsoluteCanvasSize.Y) end)
end
local function addDetailSep(txt) dN+=1; mkSep(txt,DETAIL,dN) end
local function clearDetail()
    for _,c in ipairs(DETAIL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end; dN=0; DETAIL_EMPTY.Visible=true
end

local CAT_COL={remotes=Color3.fromRGB(168,120,255),scripts=Color3.fromRGB(80,170,210),
    modules=Color3.fromRGB(80,210,100),services=Color3.fromRGB(255,160,40),
    globals=Color3.fromRGB(255,80,80),datastore=Color3.fromRGB(255,90,150),
    values=Color3.fromRGB(80,140,255),bindables=Color3.fromRGB(180,130,255),
    ui=Color3.fromRGB(80,74,108)}

local activeNav=nil; local navBtnMap={}

local function showCategory(key,map)
    clearDetail()
    if key=="remotes" then
        addDetailSep("REMOTE EVENTS ("..#map.remoteEvents..")")
        for _,r in ipairs(map.remoteEvents) do addDetail("Event",r.name,r.path) end
        addDetailSep("REMOTE FUNCTIONS ("..#map.remoteFunctions..")")
        for _,r in ipairs(map.remoteFunctions) do addDetail("Func",r.name,r.path) end
    elseif key=="scripts" then
        addDetailSep("LOCAL SCRIPTS ("..#map.localScripts..")")
        for _,s in ipairs(map.localScripts) do
            addDetail(s.hasDataStore and "FINDING" or "INFO",s.name,
                s.path..(s.sourceLen and " ["..s.sourceLen.." bytes]" or "")..(s.hasDataStore and "  ⚑ DataStore name" or ""),s.hasDataStore)
        end
    elseif key=="modules" then
        addDetailSep("MODULE SCRIPTS ("..#map.moduleScripts..")")
        for _,m in ipairs(map.moduleScripts) do
            addDetail(m.accessible and(m.hasDataStore and "FINDING" or "CLEAN")or"INFO",m.name,
                m.path..(m.accessible and" ["..tostring(m.sourceLen).." bytes]" or" [no access]")..(m.hasDataStore and "  ⚑ DataStore" or ""),m.hasDataStore)
        end
    elseif key=="services" then
        addDetailSep("SERVICES ("..#map.services..")")
        for _,s in ipairs(map.services) do
            addDetail(s.accessible and"CLEAN"or"INFO",s.name,
                s.accessible and s.methodCount.." methods" or "not accessible")
            if s.accessible and #s.methods>0 then
                dN+=1
                mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                    Text="  "..table.concat(s.methods,"  ·  "):sub(1,200),
                    TextColor3=C.MUTED,TextSize=8,TextWrapped=true,
                    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=dN},DETAIL)
            end
        end
    elseif key=="globals" then
        addDetailSep("FLAGGED / EXECUTOR GLOBALS")
        for _,g in ipairs(map.globals) do
            if g.flagged then addDetail(g.executor and"FINDING"or"INFO",g.name,g.gtype.."  "..g.preview,g.executor) end
        end
        addDetailSep("ALL GLOBALS ("..#map.globals..")")
        for _,g in ipairs(map.globals) do
            if not g.flagged then addDetail("INFO",g.name,g.gtype.."  "..g.preview) end
        end
    elseif key=="datastore" then
        addDetailSep("INFERRED DATASTORE NAMES ("..#map.datastoreNames..")")
        if #map.datastoreNames==0 then
            addDetail("INFO","No DataStore names found","No accessible source code contained GetDataStore calls")
        else
            for _,n in ipairs(map.datastoreNames) do
                addDetail("FINDING",n,"Name inferred from script source — server may use this store",true)
            end
        end
    elseif key=="values" then
        addDetailSep("VALUE OBJECTS ("..#map.valueObjects..")")
        for _,v in ipairs(map.valueObjects) do
            addDetail("INFO",v.name,v.path.."  ["..v.vtype.."]  = "..v.value)
        end
    elseif key=="bindables" then
        addDetailSep("BINDABLE EVENTS ("..#map.bindableEvents..") + FUNCTIONS ("..#map.bindableFuncs..")")
        for _,b in ipairs(map.bindableEvents) do addDetail("INFO",b.name,b.path) end
        for _,b in ipairs(map.bindableFuncs) do addDetail("INFO",b.name,b.path) end
    elseif key=="ui" then
        addDetailSep("SCREEN GUIS ("..#map.screenGuis..")")
        for _,s in ipairs(map.screenGuis) do
            addDetail("INFO",s.name,s.path.."  ["..s.childCount.." children]")
        end
    end
end

local function buildNav(map)
    for _,c in ipairs(NAV:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    navBtnMap={}
    local CATS={
        {key="remotes",  label="Remotes",       count=map.summary.remoteEvents+map.summary.remoteFunctions, col=CAT_COL.remotes},
        {key="scripts",  label="LocalScripts",   count=map.summary.localScripts,  col=CAT_COL.scripts},
        {key="modules",  label="Modules",        count=map.summary.moduleScripts, col=CAT_COL.modules},
        {key="services", label="Services",       count=map.summary.services,      col=CAT_COL.services},
        {key="globals",  label="Globals",        count=map.summary.globals,       col=CAT_COL.globals,   flag=map.summary.flaggedGlobals},
        {key="datastore",label="DataStore Names",count=map.summary.datastoreNames,col=CAT_COL.datastore, flag=map.summary.datastoreNames},
        {key="values",   label="Value Objects",  count=map.summary.valueObjects,  col=CAT_COL.values},
        {key="bindables",label="Bindables",      count=map.summary.bindableEvents+map.summary.bindableFuncs,col=CAT_COL.bindables},
        {key="ui",       label="Screen GUIs",    count=map.summary.screenGuis,    col=CAT_COL.ui},
    }
    for i,cat in ipairs(CATS) do
        local sel=activeNav==cat.key
        local card=mk("TextButton",{AutoButtonColor=false,
            BackgroundColor3=sel and C.ACCDIM or C.CARD,BorderSizePixel=0,Text="",
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=i},NAV)
        corner(6,card); if sel then stroke(cat.col,1,card) end
        pad(10,7,card); listV(card,2)
        local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
        listH(hrow,6)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=cat.label,TextColor3=sel and C.WHITE or cat.col,TextSize=10,
            Size=UDim2.new(1,-40,1,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=6,LayoutOrder=1},hrow)
        local badge=mk("Frame",{BackgroundColor3=cat.col,BorderSizePixel=0,
            Size=UDim2.fromOffset(32,15),ZIndex=6,LayoutOrder=2},hrow)
        corner(7,badge)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=tostring(cat.count),TextColor3=Color3.fromRGB(8,8,12),TextSize=8,
            Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=7},badge)
        if cat.flag and cat.flag>0 then
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                Text="⚑ "..cat.flag.." flagged",TextColor3=Color3.fromRGB(255,160,40),TextSize=8,
                Size=UDim2.new(1,0,0,12),TextXAlignment=Enum.TextXAlignment.Left,
                ZIndex=5,LayoutOrder=2},card)
        end
        card.MouseEnter:Connect(function() if activeNav~=cat.key then tw(card,TI.fast,{BackgroundColor3=C.SURFACE}) end end)
        card.MouseLeave:Connect(function() if activeNav~=cat.key then tw(card,TI.fast,{BackgroundColor3=C.CARD}) end end)
        card.MouseButton1Click:Connect(function()
            activeNav=cat.key; buildNav(map); showCategory(cat.key,map)
        end)
        navBtnMap[cat.key]=card
    end
end

local scanning=false
SCAN_BTN.MouseButton1Click:Connect(function()
    if scanning then return end; scanning=true
    tw(SCAN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
    DISC_STATUS.Text="scanning..."; DISC_STATUS.TextColor3=C.DELTA
    clearDetail()
    task.spawn(function()
        local map=runScan(addDetail)
        buildNav(map)
        DISC_STATUS.Text=("%d remotes · %d scripts · %d DS names"):format(
            map.summary.remoteEvents+map.summary.remoteFunctions,
            map.summary.localScripts,map.summary.datastoreNames)
        DISC_STATUS.TextColor3=Color3.fromRGB(80,210,100)
        activeNav="remotes"; buildNav(map); showCategory("remotes",map)
        tw(SCAN_BTN,TI.fast,{BackgroundColor3=C.ACCENT}); scanning=false
    end)
end)

if G.addTab then G.addTab("discovery","Discovery",P_DISC)
else warn("[Oracle] G.addTab not found") end
