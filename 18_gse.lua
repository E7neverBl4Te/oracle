-- Oracle // 18_gse.lua
-- GSE — Game Service Edit
-- Service discovery · Method hooking · Economy/progression mapping
local G=...; local C=G.C; local TI=G.TI; local mk=G.mk; local tw=G.tw
local corner=G.corner; local stroke=G.stroke; local pad=G.pad
local listV=G.listV; local listH=G.listH; local mkRow=G.mkRow; local mkSep=G.mkSep
local vs=G.vs; local CON=G.CON; local LP=G.LP

local MktSvc  = game:GetService("MarketplaceService")
local BadgeSvc= game:GetService("BadgeService")
local Players = game:GetService("Players")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- GSE ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local HOOKS    = {}   -- active method hooks
local CALL_LOG = {}   -- [{service, method, args, result, tick}]
local MAX_LOG  = 300

local function safe(f,...) local ok,r=pcall(f,...); return ok and r or nil end

-- Log a service call
local function logCall(service, method, args, result)
    if #CALL_LOG>=MAX_LOG then table.remove(CALL_LOG,1) end
    table.insert(CALL_LOG,{
        service=service, method=method,
        args=args, result=result, tick=tick()
    })
end

-- Hook a service method to capture calls
local function hookMethod(svc, svcName, methodName)
    local key=svcName.."."..methodName
    if HOOKS[key] then return end
    local orig=safe(function() return svc[methodName] end)
    if type(orig)~="function" then return end
    local ok=pcall(function()
        svc[methodName]=function(self,...)
            local args={...}
            local argStr=""
            for i,a in ipairs(args) do argStr=argStr..(i>1 and ", " or "")..vs(a) end
            local ok2,ret=pcall(orig,self,...)
            local retStr=ok2 and vs(ret) or "ERROR:"..tostring(ret):sub(1,40)
            logCall(svcName,methodName,argStr,retStr)
            if ok2 then return ret
            else error(ret,2) end
        end
        HOOKS[key]=true
    end)
    return ok
end

-- Scan game scripts for product/badge IDs
local function scanForIDs(logFn)
    local products={};  local badges={}; local passes={}
    local function extractFromSrc(src)
        for id in src:gmatch("PromptProductPurchase%s*%([^,]+,%s*(%d+)") do products[id]=true end
        for id in src:gmatch("PromptGamePassPurchase%s*%([^,]+,%s*(%d+)") do passes[id]=true end
        for id in src:gmatch("UserHasBadgeAsync%s*%([^,]+,%s*(%d+)") do badges[id]=true end
        for id in src:gmatch("GetProductInfo%s*%(%s*(%d+)") do products[id]=true end
        for id in src:gmatch("AwardBadge%s*%([^,]+,%s*(%d+)") do badges[id]=true end
    end
    local function scanRoot(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do
            if x:IsA("LocalScript") or x:IsA("ModuleScript") then
                local src=safe(function() return x.Source end) or ""
                if #src>0 then extractFromSrc(src) end
            end
        end
    end
    local RepS2=game:GetService("ReplicatedStorage")
    scanRoot(RepS2); scanRoot(LP)
    local pg=LP:FindFirstChildOfClass("PlayerGui")
    if pg then scanRoot(pg) end

    local pList={};  for id in pairs(products) do table.insert(pList,id) end
    local bList={};  for id in pairs(badges)   do table.insert(bList,id) end
    local gList={};  for id in pairs(passes)    do table.insert(gList,id) end

    if logFn then
        logFn("INFO",("Found %d product IDs · %d badge IDs · %d gamepass IDs"):format(
            #pList,#bList,#gList))
        for _,id in ipairs(pList) do logFn("FINDING","Product ID: "..id,"PromptProductPurchase reference",true) end
        for _,id in ipairs(bList) do logFn("FINDING","Badge ID: "..id,"UserHasBadgeAsync/AwardBadge reference",true) end
        for _,id in ipairs(gList) do logFn("INFO","GamePass ID: "..id,"PromptGamePassPurchase reference") end
    end
    return {products=pList,badges=bList,passes=gList}
end

-- Probe a product ID for info
local function probeProduct(id, logFn)
    local numId=tonumber(id); if not numId then return end
    local ok,info=pcall(function()
        return MktSvc:GetProductInfo(numId, Enum.InfoType.Product)
    end)
    if ok and info then
        logFn("FINDING",tostring(id).." → "..tostring(info.Name),
            ("Price: %d  Type: %s  Creator: %s"):format(
                info.PriceInRobux or 0,
                tostring(info.ProductType),
                tostring(info.Creator and info.Creator.Name or "?")),true)
    else
        logFn("INFO",tostring(id).." — not found","Product may be private or ID is invalid")
    end
end

local function probeBadge(id, logFn)
    local numId=tonumber(id); if not numId then return end
    local ok,has=pcall(function()
        return BadgeSvc:UserHasBadgeAsync(LP.UserId,numId)
    end)
    if ok then
        logFn("INFO","Badge "..id.." — player has it: "..tostring(has))
    else
        logFn("INFO","Badge "..id.." — lookup failed",tostring(has):sub(1,60))
    end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- GSE PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_GSE=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,Size=UDim2.new(1,0,0,32),ZIndex=4},P_GSE)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,Text="⬡  GSE — GAME SERVICE EDIT",TextColor3=C.ACCENT,TextSize=11,Size=UDim2.new(0,250,1,0),Position=UDim2.new(0,14,0,0),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)
local GSE_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="idle",TextColor3=C.MUTED,TextSize=9,Size=UDim2.new(0,120,1,0),Position=UDim2.new(1,-306,0,0),TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

local SCAN_BTN=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.ACCENT,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="⬡ SCAN IDs",TextColor3=C.WHITE,TextSize=10,Size=UDim2.new(0,86,0,22),Position=UDim2.new(1,-208,0.5,-11),ZIndex=6},TOPBAR)
corner(5,SCAN_BTN)
do local base=C.ACCENT
    SCAN_BTN.MouseEnter:Connect(function() tw(SCAN_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    SCAN_BTN.MouseLeave:Connect(function() tw(SCAN_BTN,TI.fast,{BackgroundColor3=base}) end)
end

local HOOK_BTN=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.CARD,BorderSizePixel=0,Font=Enum.Font.GothamBold,Text="⟳ Hook Svcs",TextColor3=C.TEXT,TextSize=9,Size=UDim2.new(0,90,0,22),Position=UDim2.new(1,-106,0.5,-11),ZIndex=6},TOPBAR)
corner(5,HOOK_BTN); stroke(C.BORDER,1,HOOK_BTN)
HOOK_BTN.MouseEnter:Connect(function() tw(HOOK_BTN,TI.fast,{BackgroundColor3=C.SURFACE}) end)
HOOK_BTN.MouseLeave:Connect(function() tw(HOOK_BTN,TI.fast,{BackgroundColor3=C.CARD}) end)

-- tab bar for sub-pages
local SUBTABS=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,0,26),ZIndex=4},P_GSE)
stroke(C.BORDER,1,SUBTABS)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},SUBTABS)
local STROW=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),ZIndex=5},SUBTABS)
pad(8,3,STROW); listH(STROW,4)

local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,Position=UDim2.new(0,0,0,58),Size=UDim2.new(1,0,1,-58),ZIndex=3},P_GSE)
local LOGSCR=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,Size=UDim2.fromScale(1,1),ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},BODY)
pad(10,8,LOGSCR); listV(LOGSCR,3)
local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="Press ⬡ SCAN IDs to find product/badge IDs from scripts.\nPress ⟳ Hook Svcs to intercept service method calls.",TextColor3=C.MUTED,TextSize=10,TextWrapped=true,Size=UDim2.new(1,0,0,40),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5,LayoutOrder=1},LOGSCR)

local gN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; gN+=1; mkRow(tag,msg,detail,hi,LOGSCR,gN)
    task.defer(function() LOGSCR.CanvasPosition=Vector2.new(0,LOGSCR.AbsoluteCanvasSize.Y) end)
end
local function addLogSep(txt) gN+=1; mkSep(txt,LOGSCR,gN) end

-- Sub-tab buttons
local activeSub=nil
local SUBS={
    {k="ids",   l="Product IDs"},
    {k="hooks", l="Hook Log"},
    {k="badge", l="Badges"},
}
local subBtns={}
local function showSub(key)
    activeSub=key
    for _,sb in pairs(subBtns) do
        tw(sb,TI.fast,{BackgroundColor3=C.CARD,TextColor3=C.MUTED})
    end
    if subBtns[key] then
        tw(subBtns[key],TI.fast,{BackgroundColor3=C.ACCDIM,TextColor3=C.ACCENT})
    end
    -- Clear log and show relevant content
    for _,c in ipairs(LOGSCR:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    gN=0; LOG_EMPTY.Visible=false

    if key=="hooks" then
        if #CALL_LOG==0 then
            LOG_EMPTY.Visible=true
            LOG_EMPTY.Text="No service calls captured yet.\nPress ⟳ Hook Svcs then interact with the game."
        else
            addLogSep("SERVICE CALL LOG ("..#CALL_LOG..")")
            for i=#CALL_LOG,math.max(1,#CALL_LOG-50),-1 do
                local e=CALL_LOG[i]
                addLog("INFO",e.service.."."..e.method,
                    "args: "..e.args.."  →  "..e.result)
            end
        end
    elseif key=="ids" then
        LOG_EMPTY.Visible=true
        LOG_EMPTY.Text="Press ⬡ SCAN IDs to extract product and badge IDs from accessible scripts."
    elseif key=="badge" then
        addLogSep("BADGE CHECK")
        local ok,has=pcall(function() return BadgeSvc:UserHasBadgeAsync(LP.UserId,0) end)
        addLog("INFO","BadgeService accessible",ok and "GetAsync works" or "blocked")
        local ok2,info=pcall(function()
            return MktSvc:GetProductInfo(game.PlaceId,Enum.InfoType.Asset)
        end)
        if ok2 and info then
            addLog("INFO","Place: "..tostring(info.Name),
                "PlaceId: "..tostring(game.PlaceId).."  Creator: "..tostring(info.Creator and info.Creator.Name))
        end
    end
end

for i,sub in ipairs(SUBS) do
    local b=mk("TextButton",{AutoButtonColor=false,BackgroundColor3=C.CARD,BorderSizePixel=0,
        Font=Enum.Font.GothamSemibold,Text=sub.l,TextColor3=C.MUTED,TextSize=9,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,ZIndex=6},STROW)
    corner(5,b); mk("UIPadding",{PaddingLeft=UDim.new(0,10),PaddingRight=UDim.new(0,10)},b)
    b.MouseButton1Click:Connect(function() showSub(sub.k) end)
    subBtns[sub.k]=b
end
showSub("ids")

SCAN_BTN.MouseButton1Click:Connect(function()
    GSE_STATUS.Text="scanning..."; GSE_STATUS.TextColor3=C.DELTA
    showSub("ids")
    task.spawn(function()
        local ids=scanForIDs(addLog)
        -- Probe product IDs
        if #ids.products>0 then
            addLogSep("PRODUCT INFO LOOKUP")
            for _,id in ipairs(ids.products) do
                probeProduct(id,addLog); task.wait(0.3)
            end
        end
        GSE_STATUS.Text=("%d products · %d badges · %d passes"):format(
            #ids.products,#ids.badges,#ids.passes)
        GSE_STATUS.TextColor3=Color3.fromRGB(80,210,100)
    end)
end)

HOOK_BTN.MouseButton1Click:Connect(function()
    local count=0
    local svcs={
        {game:GetService("MarketplaceService"),"MarketplaceService",
            {"GetProductInfo","UserOwnsGamePassAsync","PromptProductPurchase"}},
        {game:GetService("BadgeService"),"BadgeService",
            {"UserHasBadgeAsync","AwardBadge"}},
        {game:GetService("TeleportService"),"TeleportService",
            {"Teleport","TeleportToPlaceInstance","GetLocalPlayerTeleportData"}},
    }
    for _,s in ipairs(svcs) do
        local svc,name,methods=s[1],s[2],s[3]
        if svc then
            for _,m in ipairs(methods) do
                if hookMethod(svc,name,m) then count+=1 end
            end
        end
    end
    addLog("INFO","Hooked "..count.." service methods","Calls will appear in Hook Log tab")
    GSE_STATUS.Text=count.." methods hooked"; GSE_STATUS.TextColor3=Color3.fromRGB(80,210,100)
    -- Set up auto-refresh for hook log
    task.spawn(function()
        while true do
            task.wait(3)
            if activeSub=="hooks" and P_GSE.Visible then showSub("hooks") end
        end
    end)
end)

G.GSE_CALL_LOG=CALL_LOG
if G.addTab then G.addTab("gse","GSE",P_GSE)
else warn("[Oracle] G.addTab not found") end
