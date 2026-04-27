-- Oracle // 08_services.lua
-- Service Probe — Infrastructure layer analysis
-- Client-accessible method fuzzing · Callback correlation · Trust asymmetry mapping
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
local isNI   = G.isNI
local snap   = G.snap
local dif    = G.dif
local CON    = G.CON
local LP     = G.LP

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SERVICE REGISTRY
-- Every client-accessible service method worth probing
-- grouped by trust category and potential impact
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local SERVICES = {
    {
        name    = "MarketplaceService",
        color   = Color3.fromRGB(255, 160, 40),
        risk    = "HIGH",
        note    = "ProcessReceipt callbacks run with implicit server trust. Edge cases in receipt construction may bypass developer validation.",
        methods = {
            {
                fn    = "GetProductInfo",
                note  = "Returns product data — nil/error on invalid IDs may expose developer assumption bugs",
                probe = function(svc)
                    local results = {}
                    local cases = {
                        {l="ProductId=0",       v=function() return svc:GetProductInfo(0, Enum.InfoType.Product) end},
                        {l="ProductId=-1",      v=function() return svc:GetProductInfo(-1, Enum.InfoType.Product) end},
                        {l="ProductId=2^53",    v=function() return svc:GetProductInfo(2^53, Enum.InfoType.Product) end},
                        {l="ProductId=NaN",     v=function() return svc:GetProductInfo(0/0, Enum.InfoType.Product) end},
                        {l="AssetId=0",         v=function() return svc:GetProductInfo(0, Enum.InfoType.Asset) end},
                    }
                    for _, c in ipairs(cases) do
                        local ok, res = pcall(c.v)
                        table.insert(results, {
                            label  = c.l,
                            ok     = ok,
                            result = ok and type(res) or tostring(res):sub(1,80),
                            flag   = not ok and tostring(res):find("nil") ~= nil,
                        })
                    end
                    return results
                end,
            },
            {
                fn    = "UserOwnsGamePassAsync",
                note  = "Boolean return — nil/error may be treated as true by poorly guarded conditionals",
                probe = function(svc)
                    local results = {}
                    local uid = LP.UserId
                    local cases = {
                        {l="GamepassId=0",      v=function() return svc:UserOwnsGamePassAsync(uid, 0) end},
                        {l="GamepassId=-1",     v=function() return svc:UserOwnsGamePassAsync(uid, -1) end},
                        {l="UserId=0",          v=function() return svc:UserOwnsGamePassAsync(0, 1) end},
                        {l="UserId=-1",         v=function() return svc:UserOwnsGamePassAsync(-1, 1) end},
                        {l="UserId=NaN",        v=function() return svc:UserOwnsGamePassAsync(0/0, 1) end},
                    }
                    for _, c in ipairs(cases) do
                        local ok, res = pcall(c.v)
                        table.insert(results, {
                            label  = c.l,
                            ok     = ok,
                            result = ok and tostring(res) or tostring(res):sub(1,80),
                            -- Flag if error might be swallowed by pcall in server handler
                            flag   = not ok,
                        })
                    end
                    return results
                end,
            },
            {
                fn    = "PromptProductPurchase",
                note  = "Client-side UI trigger — edge inputs probe whether engine validates before showing prompt",
                probe = function(svc)
                    local results = {}
                    local cases = {
                        {l="ProductId=0",    v=function() svc:PromptProductPurchase(LP, 0) end},
                        {l="ProductId=-1",   v=function() svc:PromptProductPurchase(LP, -1) end},
                        {l="ProductId=NaN",  v=function() svc:PromptProductPurchase(LP, 0/0) end},
                        {l="ProductId=Inf",  v=function() svc:PromptProductPurchase(LP, math.huge) end},
                    }
                    for _, c in ipairs(cases) do
                        local ok, res = pcall(c.v)
                        table.insert(results, {
                            label  = c.l,
                            ok     = ok,
                            result = ok and "accepted" or tostring(res):sub(1,80),
                            flag   = ok, -- engine accepting invalid IDs is the anomaly
                        })
                    end
                    return results
                end,
            },
        },
    },

    {
        name    = "TeleportService",
        color   = Color3.fromRGB(168, 120, 255),
        risk    = "HIGH",
        note    = "Teleport data payload persists across server boundaries. Destination server receives it through trusted Roblox infrastructure — developer handlers often validate weakly.",
        methods = {
            {
                fn    = "GetLocalPlayerTeleportData",
                note  = "Returns data set by teleport origin — inspect what this server received and whether it is being used in grants",
                probe = function(svc)
                    local results = {}
                    local ok, data = pcall(function()
                        return svc:GetLocalPlayerTeleportData()
                    end)
                    if ok and data ~= nil then
                        table.insert(results, {
                            label  = "TeleportData present",
                            ok     = true,
                            result = type(data) == "table"
                                and ("table with "..tostring(#data).." array entries")
                                or tostring(data):sub(1,80),
                            flag   = true, -- data present = potential trust vector
                        })
                        if type(data) == "table" then
                            for k, v2 in pairs(data) do
                                table.insert(results, {
                                    label  = "  field: "..tostring(k),
                                    ok     = true,
                                    result = vs(v2),
                                    flag   = false,
                                })
                            end
                        end
                    else
                        table.insert(results, {
                            label  = "TeleportData",
                            ok     = ok,
                            result = ok and "nil (no teleport data)" or tostring(data):sub(1,80),
                            flag   = false,
                        })
                    end
                    return results
                end,
            },
            {
                fn    = "Teleport (edge inputs)",
                note  = "Engine-level validation of place IDs before transmission — anomalies suggest weak boundary checking",
                probe = function(svc)
                    local results = {}
                    local cases = {
                        {l="PlaceId=0",         v=function() svc:Teleport(0, LP) end},
                        {l="PlaceId=-1",        v=function() svc:Teleport(-1, LP) end},
                        {l="PlaceId=NaN",       v=function() svc:Teleport(0/0, LP) end},
                        {l="PlaceId=Inf",       v=function() svc:Teleport(math.huge, LP) end},
                        {l="PlaceId=2^53",      v=function() svc:Teleport(2^53, LP) end},
                    }
                    for _, c in ipairs(cases) do
                        local ok, res = pcall(c.v)
                        table.insert(results, {
                            label  = c.l,
                            ok     = ok,
                            result = ok and "accepted — engine queued teleport" or tostring(res):sub(1,80),
                            flag   = ok,
                        })
                    end
                    return results
                end,
            },
        },
    },

    {
        name    = "BadgeService",
        color   = Color3.fromRGB(80, 210, 100),
        risk    = "MEDIUM",
        note    = "UserHasBadge callbacks used as admin/permission gates. Error returns under edge inputs may be mishandled by conditional logic.",
        methods = {
            {
                fn    = "UserHasBadgeAsync",
                note  = "Boolean gate — probe what happens when the service errors or returns unexpected types",
                probe = function(svc)
                    local results = {}
                    local uid = LP.UserId
                    local cases = {
                        {l="BadgeId=0",         v=function() return svc:UserHasBadgeAsync(uid, 0) end},
                        {l="BadgeId=-1",        v=function() return svc:UserHasBadgeAsync(uid, -1) end},
                        {l="BadgeId=NaN",       v=function() return svc:UserHasBadgeAsync(uid, 0/0) end},
                        {l="BadgeId=2^53",      v=function() return svc:UserHasBadgeAsync(uid, 2^53) end},
                        {l="UserId=0",          v=function() return svc:UserHasBadgeAsync(0, 1) end},
                        {l="UserId=-1",         v=function() return svc:UserHasBadgeAsync(-1, 1) end},
                    }
                    for _, c in ipairs(cases) do
                        local ok, res = pcall(c.v)
                        table.insert(results, {
                            label  = c.l,
                            ok     = ok,
                            result = ok and tostring(res) or tostring(res):sub(1,80),
                            -- A non-false return under invalid input is an anomaly
                            flag   = ok and res == true,
                        })
                    end
                    return results
                end,
            },
        },
    },

    {
        name    = "GroupService",
        color   = Color3.fromRGB(80, 170, 210),
        risk    = "MEDIUM",
        note    = "Group rank checks used as permission systems. Async errors under edge inputs may produce unexpected rank values.",
        methods = {
            {
                fn    = "GetGroupsAsync",
                note  = "Returns groups for a UserId — edge UserId inputs probe service boundary validation",
                probe = function(svc)
                    local results = {}
                    local cases = {
                        {l="UserId=0",      v=function() return svc:GetGroupsAsync(0) end},
                        {l="UserId=-1",     v=function() return svc:GetGroupsAsync(-1) end},
                        {l="UserId=NaN",    v=function() return svc:GetGroupsAsync(0/0) end},
                        {l="UserId=2^53",   v=function() return svc:GetGroupsAsync(2^53) end},
                    }
                    for _, c in ipairs(cases) do
                        local ok, res = pcall(c.v)
                        local summary
                        if ok and type(res) == "table" then
                            summary = #res.." groups returned"
                        elseif ok then
                            summary = tostring(res)
                        else
                            summary = tostring(res):sub(1,80)
                        end
                        table.insert(results, {
                            label  = c.l,
                            ok     = ok,
                            result = summary,
                            flag   = ok and type(res)=="table" and #res > 0,
                        })
                    end
                    return results
                end,
            },
        },
    },

    {
        name    = "DataStoreService",
        color   = Color3.fromRGB(255, 90, 90),
        risk    = "INFO",
        note    = "Client cannot call DataStore directly — but timing windows during teleport can create race conditions between read and write operations on destination servers.",
        methods = {
            {
                fn    = "GetDataStore (client access test)",
                note  = "Verify whether client can access DataStore methods — should be blocked, any success is a critical finding",
                probe = function(svc)
                    local results = {}
                    local ok, res = pcall(function()
                        return svc:GetDataStore("test")
                    end)
                    table.insert(results, {
                        label  = "GetDataStore from client",
                        ok     = ok,
                        result = ok and "ACCESSIBLE — critical finding" or tostring(res):sub(1,80),
                        flag   = ok,
                    })
                    local ok2, res2 = pcall(function()
                        return svc:GetOrderedDataStore("test")
                    end)
                    table.insert(results, {
                        label  = "GetOrderedDataStore from client",
                        ok     = ok2,
                        result = ok2 and "ACCESSIBLE — critical finding" or tostring(res2):sub(1,80),
                        flag   = ok2,
                    })
                    return results
                end,
            },
        },
    },

    {
        name    = "Players",
        color   = Color3.fromRGB(80, 140, 255),
        risk    = "MEDIUM",
        note    = "Player service edge cases — UserId boundary inputs and GetPlayerByUserId anomalies that may affect server-side player lookups.",
        methods = {
            {
                fn    = "GetPlayerByUserId (edge inputs)",
                note  = "Returns nil or Player — edge UserId values probe internal lookup behavior",
                probe = function(svc)
                    local results = {}
                    local cases = {
                        {l="UserId=0",      v=function() return svc:GetPlayerByUserId(0) end},
                        {l="UserId=-1",     v=function() return svc:GetPlayerByUserId(-1) end},
                        {l="UserId=NaN",    v=function() return svc:GetPlayerByUserId(0/0) end},
                        {l="UserId=Inf",    v=function() return svc:GetPlayerByUserId(math.huge) end},
                        {l="UserId=2^53",   v=function() return svc:GetPlayerByUserId(2^53) end},
                        {l="UserId=2^53+1", v=function() return svc:GetPlayerByUserId(2^53+1) end},
                    }
                    for _, c in ipairs(cases) do
                        local ok, res = pcall(c.v)
                        table.insert(results, {
                            label  = c.l,
                            ok     = ok,
                            result = ok and (res and "returned "..tostring(res) or "nil") or tostring(res):sub(1,80),
                            flag   = ok and res ~= nil,
                        })
                    end
                    return results
                end,
            },
            {
                fn    = "GetCharacterAppearanceInfoAsync",
                note  = "Returns appearance data — edge UserId inputs probe async boundary handling",
                probe = function(svc)
                    local results = {}
                    local cases = {
                        {l="UserId=0",    v=function() return svc:GetCharacterAppearanceInfoAsync(0) end},
                        {l="UserId=-1",   v=function() return svc:GetCharacterAppearanceInfoAsync(-1) end},
                        {l="UserId=NaN",  v=function() return svc:GetCharacterAppearanceInfoAsync(0/0) end},
                    }
                    for _, c in ipairs(cases) do
                        local ok, res = pcall(c.v)
                        local summary
                        if ok and type(res)=="table" then
                            local keys=0; for _ in pairs(res) do keys+=1 end
                            summary = "table ("..keys.." keys)"
                        else
                            summary = tostring(res):sub(1,80)
                        end
                        table.insert(results, {
                            label=c.l, ok=ok, result=summary,
                            flag=ok and type(res)=="table",
                        })
                    end
                    return results
                end,
            },
        },
    },

    {
        name    = "RunService",
        color   = Color3.fromRGB(180, 130, 255),
        risk    = "INFO",
        note    = "Timing infrastructure — pathological delta values in Heartbeat/RenderStepped affect physics replication and server position validation.",
        methods = {
            {
                fn    = "Heartbeat delta integrity",
                note  = "Collect 120 frames and check for NaN, Inf, negative, or zero deltas",
                probe = function(svc)
                    local results = {}
                    local deltas = {}
                    local done = false
                    local conn
                    conn = svc.Heartbeat:Connect(function(dt)
                        table.insert(deltas, dt)
                        if #deltas >= 120 then conn:Disconnect(); done = true end
                    end)
                    local timeout = tick() + 10
                    while not done and tick() < timeout do task.wait() end

                    local nan,inf,neg,zero,ok_count = 0,0,0,0,0
                    local min_dt, max_dt = math.huge, 0
                    for _, dt in ipairs(deltas) do
                        if dt ~= dt              then nan  += 1
                        elseif dt == math.huge   then inf  += 1
                        elseif dt < 0            then neg  += 1
                        elseif dt == 0           then zero += 1
                        else
                            ok_count += 1
                            min_dt = math.min(min_dt, dt)
                            max_dt = math.max(max_dt, dt)
                        end
                    end

                    table.insert(results, {
                        label="Samples collected", ok=true,
                        result=#deltas.." frames", flag=false})
                    table.insert(results, {
                        label="NaN deltas",  ok=true,
                        result=tostring(nan),  flag=nan>0})
                    table.insert(results, {
                        label="Inf deltas",  ok=true,
                        result=tostring(inf),  flag=inf>0})
                    table.insert(results, {
                        label="Negative deltas", ok=true,
                        result=tostring(neg),  flag=neg>0})
                    table.insert(results, {
                        label="Zero deltas", ok=true,
                        result=tostring(zero), flag=zero>0})
                    if ok_count > 0 then
                        table.insert(results, {
                            label="Delta range", ok=true,
                            result=("%.4f – %.4f sec"):format(min_dt,max_dt),
                            flag=false})
                    end
                    return results
                end,
            },
        },
    },
}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_SVC = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.fromScale(1,1), Visible=false, ZIndex=3}, CON)

-- top bar
local TOPBAR = mk("Frame", {BackgroundColor3=C.SURFACE, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32), ZIndex=4}, P_SVC)
stroke(C.BORDER, 1, TOPBAR)
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1), Position=UDim2.new(0,0,1,-1), ZIndex=5}, TOPBAR)
pad(12, 0, TOPBAR); listH(TOPBAR, 10)
mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
    Text="⬡  SERVICE INFRASTRUCTURE PROBE", TextColor3=C.ACCENT, TextSize=11,
    Size=UDim2.new(1,-200,1,0), TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5, LayoutOrder=1}, TOPBAR)

local STATUS_LBL = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="idle", TextColor3=C.MUTED, TextSize=9,
    Size=UDim2.new(0,110,1,0), TextXAlignment=Enum.TextXAlignment.Right,
    ZIndex=5, LayoutOrder=2}, TOPBAR)

local PROBE_BTN = mk("TextButton", {AutoButtonColor=false, BackgroundColor3=C.ACCENT,
    BorderSizePixel=0, Font=Enum.Font.GothamBold, Text="⚙  PROBE ALL",
    TextColor3=C.WHITE, TextSize=10, Size=UDim2.new(0,88,0,22),
    ZIndex=5, LayoutOrder=3}, TOPBAR)
corner(5, PROBE_BTN)
do local base=C.ACCENT
    PROBE_BTN.MouseEnter:Connect(function() tw(PROBE_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    PROBE_BTN.MouseLeave:Connect(function() tw(PROBE_BTN,TI.fast,{BackgroundColor3=base}) end)
end

-- body: left = service list, right = result panel
local BODY = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32), Size=UDim2.new(1,0,1,-32), ZIndex=3}, P_SVC)

-- left service list
local SL = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.new(0,200,1,0), ZIndex=3}, BODY)
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0), Position=UDim2.new(1,-1,0,0), ZIndex=4}, SL)
local SL_HDR = mk("Frame", {BackgroundColor3=C.SURFACE, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,24), ZIndex=4}, SL)
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1), Position=UDim2.new(0,0,1,-1), ZIndex=5}, SL_HDR)
mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
    Text="SERVICES", TextColor3=C.MUTED, TextSize=9,
    Size=UDim2.fromScale(1,1), TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5}, SL_HDR)
local SL_SCROLL = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0,0,0,24), Size=UDim2.new(1,0,1,-24),
    ScrollBarThickness=3, ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ZIndex=4}, SL)
pad(5,6,SL_SCROLL); listV(SL_SCROLL, 4)

-- right result panel
local SR = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0,200,0,0), Size=UDim2.new(1,-200,1,0), ZIndex=3}, BODY)
local RES_SCROLL = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.fromScale(1,1), ScrollBarThickness=4,
    ScrollBarImageColor3=C.ACCDIM, CanvasSize=UDim2.fromScale(0,0),
    AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y, ZIndex=4}, SR)
pad(12, 8, RES_SCROLL); listV(RES_SCROLL, 6)

local RES_EMPTY = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="Select a service and press ⚙ PROBE ALL\nor click a method to probe individually",
    TextColor3=C.MUTED, TextSize=10, TextWrapped=true,
    Size=UDim2.new(1,0,0,50), TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5, LayoutOrder=1}, RES_SCROLL)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- UI HELPERS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local RISK_COL = {
    HIGH   = Color3.fromRGB(255, 80,  80),
    MEDIUM = Color3.fromRGB(255,160,  40),
    INFO   = Color3.fromRGB(80, 140, 255),
}

local function infoCard(parent, order)
    local c = mk("Frame", {BackgroundColor3=C.CARD, BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4, LayoutOrder=order}, parent)
    corner(6,c); stroke(C.BORDER,1,c)
    return c
end

local function svcChip(txt, col, parent, order)
    local f = mk("Frame", {BackgroundColor3=col, BorderSizePixel=0,
        Size=UDim2.new(0,0,0,16), AutomaticSize=Enum.AutomaticSize.X,
        ZIndex=6, LayoutOrder=order or 99}, parent)
    corner(4,f); mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5)},f)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=txt,TextColor3=Color3.fromRGB(8,8,12),TextSize=8,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
        TextXAlignment=Enum.TextXAlignment.Center,ZIndex=7},f)
    return f
end

local function secLabel(txt, parent, order)
    local f=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,16),ZIndex=4,LayoutOrder=order},parent)
    mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,0.5,0),ZIndex=4},f)
    local bg=mk("Frame",{BackgroundColor3=C.BG,BorderSizePixel=0,
        Size=UDim2.fromOffset(#txt*7+12,14),Position=UDim2.new(0,0,0.5,-7),ZIndex=5},f)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=txt,TextColor3=C.MUTED,TextSize=9,Size=UDim2.fromScale(1,1),
        TextXAlignment=Enum.TextXAlignment.Center,ZIndex=6},bg)
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- RESULT RENDERER
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function clearResults()
    for _, c in ipairs(RES_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    RES_EMPTY.Visible = true
end

local resOrd = 0
local function addResult(tag, msg, detail, hi)
    RES_EMPTY.Visible = false
    resOrd += 1
    mkRow(tag, msg, detail, hi, RES_SCROLL, resOrd)
    task.defer(function()
        RES_SCROLL.CanvasPosition = Vector2.new(0, RES_SCROLL.AbsoluteCanvasSize.Y)
    end)
end

local function addResSection(txt)
    RES_EMPTY.Visible = false
    resOrd += 1
    mkSep(txt, RES_SCROLL, resOrd)
end

local function renderMethodResults(svcName, methodName, results, stateBefore, stateAfter)
    addResSection(svcName.." · "..methodName)

    local flagCount = 0
    for _, r in ipairs(results) do
        if r.flag then flagCount += 1 end
    end

    -- State delta check
    local deltas = dif(stateBefore, stateAfter)

    for _, r in ipairs(results) do
        local tag
        if r.flag and not r.ok then tag = "ANOMALY"
        elseif r.flag and r.ok  then tag = "FINDING"
        elseif r.ok             then tag = "CLEAN"
        else                         tag = "INFO"
        end
        addResult(tag, r.label, r.result, r.flag)
    end

    if #deltas > 0 then
        for _, ch in ipairs(deltas) do
            addResult(
                ch.bad and "PATHOLOG" or "DELTA",
                "Server state changed during probe",
                ch.path.."  "..ch.bv.." → "..ch.av,
                true)
        end
    end

    return flagCount
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SERVICE LIST BUILDER
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Track findings per service for badge
local svcFindings = {}
local selSvc      = nil
local svcBtnMap   = {}

local function buildServiceList()
    for _, c in ipairs(SL_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    svcBtnMap = {}

    for i, svc in ipairs(SERVICES) do
        local findings = svcFindings[svc.name] or 0
        local sel      = selSvc == svc.name

        local row = mk("Frame", {BackgroundColor3=sel and C.ACCDIM or C.SURFACE,
            BackgroundTransparency=sel and 0 or 0.4, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4, LayoutOrder=i}, SL_SCROLL)
        corner(6, row)
        if sel then stroke(svc.color, 1, row) end
        pad(10, 8, row); listV(row, 4)

        -- service name + risk chip row
        local nameRow = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,16), ZIndex=5, LayoutOrder=1}, row)
        listH(nameRow, 6)
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
            Text=svc.name, TextColor3=sel and C.WHITE or svc.color, TextSize=10,
            Size=UDim2.new(1,-60,1,0), TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=6, LayoutOrder=1}, nameRow)
        svcChip(svc.risk, RISK_COL[svc.risk] or C.MUTED, nameRow, 2)

        -- method count + finding badge
        local infoRow = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,13), ZIndex=5, LayoutOrder=2}, row)
        listH(infoRow, 6)
        mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
            Text=#svc.methods.." method"..(#svc.methods>1 and "s" or ""),
            TextColor3=C.MUTED, TextSize=8,
            Size=UDim2.new(1,0,1,0), TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=6, LayoutOrder=1}, infoRow)

        if findings > 0 then
            local badge = mk("Frame", {BackgroundColor3=Color3.fromRGB(255,80,80),
                BorderSizePixel=0, Size=UDim2.fromOffset(20,13), ZIndex=6,
                LayoutOrder=2}, infoRow)
            corner(6, badge)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=tostring(findings), TextColor3=Color3.fromRGB(8,8,12),
                TextSize=8, Size=UDim2.fromScale(1,1),
                TextXAlignment=Enum.TextXAlignment.Center, ZIndex=7}, badge)
        end

        -- Probe button
        local probeRow = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
            Size=UDim2.new(1,0,0,22), ZIndex=5, LayoutOrder=3}, row)
        listH(probeRow, 6)

        local pb = mk("TextButton", {AutoButtonColor=false,
            BackgroundColor3=svc.color, BorderSizePixel=0,
            Font=Enum.Font.GothamBold, Text="⚙ Probe",
            TextColor3=Color3.fromRGB(8,8,12), TextSize=9,
            Size=UDim2.new(0,68,0,20), ZIndex=6, LayoutOrder=1}, probeRow)
        corner(4, pb)

        -- whole row click = select
        local function selectThis()
            selSvc = svc.name
            buildServiceList()
        end
        row.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 then
                selectThis()
            end
        end)

        -- probe button click
        pb.MouseButton1Click:Connect(function()
            selSvc = svc.name
            buildServiceList()
            clearResults()
            resOrd = 0

            -- service note card
            local nc = infoCard(RES_SCROLL, 1)
            pad(10, 8, nc); listV(nc, 4)
            local nh = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                ZIndex=5, LayoutOrder=1}, nc)
            listH(nh, 6)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
                Text=svc.name, TextColor3=svc.color, TextSize=12,
                Size=UDim2.new(0,0,0,18), AutomaticSize=Enum.AutomaticSize.X,
                ZIndex=6, LayoutOrder=1}, nh)
            svcChip(svc.risk, RISK_COL[svc.risk] or C.MUTED, nh, 2)
            mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
                Text=svc.note, TextColor3=C.MUTED, TextSize=9, TextWrapped=true,
                Size=UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
                ZIndex=5, LayoutOrder=2}, nc)
            RES_EMPTY.Visible = false
            resOrd = 1

            STATUS_LBL.Text = "probing "..svc.name.."..."
            STATUS_LBL.TextColor3 = C.DELTA

            local totalFlags = 0
            local ok2, svcInst = pcall(function()
                return game:GetService(svc.name)
            end)
            if not ok2 then
                addResult("INFO", svc.name.." not available", tostring(svcInst))
                STATUS_LBL.Text = "unavailable"
                STATUS_LBL.TextColor3 = C.MUTED
                return
            end

            for _, method in ipairs(svc.methods) do
                task.wait(0.1) -- brief pause between methods
                local before = snap()
                local ok3, results = pcall(method.probe, svcInst)
                local after  = snap()

                if not ok3 then
                    addResult("INFO", method.fn, "Probe error: "..tostring(results):sub(1,80))
                else
                    local flags = renderMethodResults(svc.name, method.fn, results, before, after)
                    totalFlags += flags
                end
            end

            svcFindings[svc.name] = totalFlags
            buildServiceList()

            STATUS_LBL.Text = totalFlags > 0
                and (totalFlags.." finding(s) in "..svc.name)
                or  (svc.name.." — clean")
            STATUS_LBL.TextColor3 = totalFlags > 0 and C.DELTA or C.MUTED

            -- Summary separator
            addResSection(svc.name.." PROBE COMPLETE — "..totalFlags.." finding(s)")
        end)

        svcBtnMap[svc.name] = {row=row, pb=pb}
    end
end

-- ── Probe All button ──────────────────────────────────────────────────────────
local probing = false
PROBE_BTN.MouseButton1Click:Connect(function()
    if probing then return end
    probing = true
    tw(PROBE_BTN, TI.fast, {BackgroundColor3=Color3.fromRGB(35,32,55)})

    clearResults(); resOrd = 0

    task.spawn(function()
        local grandTotal = 0

        for _, svc in ipairs(SERVICES) do
            STATUS_LBL.Text = "probing "..svc.name.."..."
            STATUS_LBL.TextColor3 = C.DELTA

            local ok2, svcInst = pcall(function()
                return game:GetService(svc.name)
            end)

            if ok2 then
                for _, method in ipairs(svc.methods) do
                    task.wait(0.1)
                    local before = snap()
                    local ok3, results = pcall(method.probe, svcInst)
                    local after  = snap()
                    if ok3 then
                        local flags = renderMethodResults(
                            svc.name, method.fn, results, before, after)
                        grandTotal += flags
                        svcFindings[svc.name] = (svcFindings[svc.name] or 0) + flags
                    else
                        addResult("INFO", svc.name.."/"..method.fn,
                            "Probe error: "..tostring(results):sub(1,80))
                    end
                end
            else
                addResult("INFO", svc.name, "Service unavailable")
            end

            buildServiceList()
            task.wait(0.2)
        end

        addResSection("ALL SERVICES COMPLETE — "..grandTotal.." total findings")
        STATUS_LBL.Text = grandTotal.." finding(s) across all services"
        STATUS_LBL.TextColor3 = grandTotal > 0 and C.DELTA or C.MUTED
        tw(PROBE_BTN, TI.fast, {BackgroundColor3=C.ACCENT})
        probing = false
    end)
end)

-- ── Build initial list ────────────────────────────────────────────────────────
buildServiceList()

-- ── Register tab ─────────────────────────────────────────────────────────────
if G.addTab then
    G.addTab("services", "Services", P_SVC)
else
    warn("[Oracle] G.addTab not found — ensure 06_init.lua is up to date")
end
