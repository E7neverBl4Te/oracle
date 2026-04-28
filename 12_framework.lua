-- Oracle // 12_framework.lua
-- Framework Detection — Third-Party Module Fingerprinting
-- Detects whether RemoteFunction/RemoteEvent handlers are wrapped by
-- external frameworks, identifies framework signatures, probes asset ownership
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

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- FRAMEWORK SIGNATURE DATABASE
-- Known frameworks identified by their response patterns, error formats,
-- timing characteristics, and structural tells
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local KNOWN_FRAMEWORKS = {
    {
        name    = "Knit",
        color   = Color3.fromRGB(80,170,210),
        tells   = {
            errorPatterns  = {"Knit", "KnitServer", "KnitClient", "Service"},
            returnPatterns = {"Service", "Controller"},
            timingMin      = 0,
            timingMax      = 50,
            structureKeys  = {"Name","Server","Client","KnitInit","KnitStart"},
        },
        assetHint = "Sleitnick/Knit — GitHub open source, not Roblox asset",
        trust     = "COMMUNITY — source available, widely audited",
    },
    {
        name    = "Nevermore",
        color   = Color3.fromRGB(168,120,255),
        tells   = {
            errorPatterns  = {"Nevermore","NevermoreEngine","loader"},
            returnPatterns = {},
            timingMin      = 0,
            timingMax      = 80,
            structureKeys  = {"Load","GetModule"},
        },
        assetHint = "Asset ID range: 1173..."
            .." — Quenty's NevermoreEngine",
        trust     = "COMMUNITY — open source",
    },
    {
        name    = "HDAdmin / MainModule",
        color   = Color3.fromRGB(255,80,80),
        tells   = {
            errorPatterns  = {"MainModule","HD_Admin","HDAdmin"},
            returnPatterns = {"Allowed","Banned","Rank"},
            timingMin      = 0,
            timingMax      = 200,
            structureKeys  = {"Allowed","Banned","Ranked","Settings"},
        },
        assetHint = "Requires external asset — developer trusts HD_Admin author",
        trust     = "EXTERNAL DEPENDENCY — author controls server execution",
    },
    {
        name    = "Adonis Admin",
        color   = Color3.fromRGB(255,160,40),
        tells   = {
            errorPatterns  = {"Adonis","adonis","AdonisAdmin"},
            returnPatterns = {"Rank","Permission","Core"},
            timingMin      = 0,
            timingMax      = 300,
            structureKeys  = {"Core","Logs","Anti"},
        },
        assetHint = "Asset ID: 7510622... — Adonis_Admin on Roblox",
        trust     = "EXTERNAL DEPENDENCY — author controls server execution",
    },
    {
        name    = "Cmdr",
        color   = Color3.fromRGB(80,210,100),
        tells   = {
            errorPatterns  = {"Cmdr","cmdr","CommandContext"},
            returnPatterns = {"Dispatcher","Registry"},
            timingMin      = 0,
            timingMax      = 100,
            structureKeys  = {"Dispatcher","Registry","Util"},
        },
        assetHint = "evaera/cmdr — GitHub open source",
        trust     = "COMMUNITY — open source",
    },
    {
        name    = "ProfileService",
        color   = Color3.fromRGB(80,140,255),
        tells   = {
            errorPatterns  = {"ProfileService","Profile","DataError"},
            returnPatterns = {"Profile","Data","Coins","Level"},
            timingMin      = 100,
            timingMax      = 2000,
            structureKeys  = {"Data","MetaData","RobloxMetaData"},
        },
        assetHint = "MadStudioRoblox/ProfileService — DataStore wrapper",
        trust     = "COMMUNITY — wraps DataStore, open source",
    },
    {
        name    = "DataStore2",
        color   = Color3.fromRGB(255,90,150),
        tells   = {
            errorPatterns  = {"DataStore2","DS2"},
            returnPatterns = {},
            timingMin      = 100,
            timingMax      = 3000,
            structureKeys  = {"Get","Set","Increment","OnUpdate"},
        },
        assetHint = "Kampfkarren/DataStore2",
        trust     = "COMMUNITY — open source",
    },
    {
        name    = "Generic Anti-Cheat",
        color   = Color3.fromRGB(255,55,55),
        tells   = {
            errorPatterns  = {"anticheat","AntiCheat","Exploit",
                              "kick","Kick","ban","Ban","detected"},
            returnPatterns = {"kicked","banned","detected"},
            timingMin      = 0,
            timingMax      = 50,
            structureKeys  = {},
        },
        assetHint = "Unknown anti-cheat module — source not public",
        trust     = "UNKNOWN DEPENDENCY — treats your client as adversary",
    },
}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- DETECTION ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Probe result structure
-- {remote, elapsed, retStr, retType, errStr, stateDeltas, responses}
local function probeRemote(remote, logFn)
    local ev = {}
    local function col(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(ev,x) end end
    end
    col(RepS); col(workspace)

    local before  = snap()
    for k in pairs(rlog) do rlog[k]=nil end
    local conns   = hookR(ev)

    local t0      = tick()
    local probes  = {}

    -- Probe 1: empty invoke
    local ok1, ret1 = pcall(function()
        if remote:IsA("RemoteFunction") then
            return remote:InvokeServer()
        end
    end)
    local t1 = (tick()-t0)*1000

    -- Probe 2: nil invoke
    local ok2, ret2 = pcall(function()
        if remote:IsA("RemoteFunction") then
            return remote:InvokeServer(nil)
        end
    end)
    local t2 = (tick()-t0)*1000 - t1

    -- Probe 3: structured table (framework detection probe)
    local ok3, ret3 = pcall(function()
        if remote:IsA("RemoteFunction") then
            return remote:InvokeServer({
                __oracle_probe = true,
                version        = "1.0",
                timestamp      = tick(),
            })
        end
    end)
    local t3 = (tick()-t0)*1000 - t1 - t2

    local after = snap()
    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end

    local responses = {}
    for _,r in ipairs(rlog) do table.insert(responses,r) end
    for k in pairs(rlog) do rlog[k]=nil end

    return {
        remote    = remote,
        probes    = {
            {ok=ok1, ret=ret1, retStr=vs(ret1), elapsed=t1,
             errStr=not ok1 and tostring(ret1) or nil},
            {ok=ok2, ret=ret2, retStr=vs(ret2), elapsed=t2,
             errStr=not ok2 and tostring(ret2) or nil},
            {ok=ok3, ret=ret3, retStr=vs(ret3), elapsed=t3,
             errStr=not ok3 and tostring(ret3) or nil},
        },
        deltas    = dif(before, after),
        responses = responses,
        totalTime = t1 + t2 + t3,
    }
end

-- Score a probe result against a known framework signature
local function scoreFramework(fw, result)
    local score    = 0
    local evidence = {}

    for _, probe in ipairs(result.probes) do
        local errStr = probe.errStr or ""
        local retStr = probe.retStr or ""

        -- Error pattern matching
        for _, pat in ipairs(fw.tells.errorPatterns) do
            if errStr:lower():find(pat:lower()) then
                score += 3
                table.insert(evidence, "error contains '"..pat.."'")
            end
        end

        -- Return pattern matching
        for _, pat in ipairs(fw.tells.returnPatterns) do
            if retStr:lower():find(pat:lower()) then
                score += 2
                table.insert(evidence, "return contains '"..pat.."'")
            end
        end

        -- Return structure key matching
        if probe.ok and type(probe.ret) == "table" then
            for _, key in ipairs(fw.tells.structureKeys) do
                if probe.ret[key] ~= nil then
                    score += 4
                    table.insert(evidence, "return table has key '"..key.."'")
                end
            end
        end

        -- Timing match
        if probe.elapsed >= fw.tells.timingMin
        and probe.elapsed <= fw.tells.timingMax then
            score += 1
        end
    end

    -- Response pattern matching
    for _, r in ipairs(result.responses) do
        for _, pat in ipairs(fw.tells.returnPatterns) do
            if r.args:lower():find(pat:lower()) then
                score += 2
                table.insert(evidence, "response args contain '"..pat.."'")
            end
        end
        for _, pat in ipairs(fw.tells.errorPatterns) do
            if r.args:lower():find(pat:lower()) then
                score += 2
                table.insert(evidence, "response args contain '"..pat.."'")
            end
        end
    end

    return score, evidence
end

-- Detect framework from a set of probe results
local function detectFramework(results)
    local scores  = {}
    local allEvid = {}

    for _, fw in ipairs(KNOWN_FRAMEWORKS) do
        local totalScore = 0
        local evidence   = {}
        for _, result in ipairs(results) do
            local s, e = scoreFramework(fw, result)
            totalScore += s
            for _, ev2 in ipairs(e) do
                table.insert(evidence, result.remote.Name..": "..ev2)
            end
        end
        if totalScore > 0 then
            table.insert(scores, {fw=fw, score=totalScore, evidence=evidence})
        end
    end

    table.sort(scores, function(a,b) return a.score > b.score end)
    return scores
end

-- Structural fingerprint — describes the handler pattern
-- without matching against known frameworks
local function buildFingerprint(results)
    local fp = {
        alwaysErrors      = 0,
        alwaysSilent      = 0,
        returnsTable      = 0,
        returnsString     = 0,
        returnsNil        = 0,
        fastResponders    = 0,  -- < 50ms
        slowResponders    = 0,  -- > 200ms
        stateChangers     = 0,
        responseEmitters  = 0,
        avgElapsed        = 0,
        totalProbed       = #results,
        consistentErrors  = {},
        commonReturnKeys  = {},
    }

    local elapsed_sum = 0
    local errorBag    = {}
    local retKeyBag   = {}

    for _, result in ipairs(results) do
        for _, probe in ipairs(result.probes) do
            elapsed_sum += probe.elapsed
            if not probe.ok then
                fp.alwaysErrors += 1
                if probe.errStr then
                    local short = probe.errStr:sub(1,60)
                    errorBag[short] = (errorBag[short] or 0) + 1
                end
            elseif probe.ret == nil then
                fp.returnsNil   += 1
                fp.alwaysSilent += 1
            elseif type(probe.ret) == "table" then
                fp.returnsTable += 1
                for k in pairs(probe.ret) do
                    retKeyBag[k] = (retKeyBag[k] or 0) + 1
                end
            elseif type(probe.ret) == "string" then
                fp.returnsString += 1
            end
            if probe.elapsed < 50  then fp.fastResponders += 1 end
            if probe.elapsed > 200 then fp.slowResponders += 1 end
        end
        if #result.deltas    > 0 then fp.stateChangers   += 1 end
        if #result.responses > 0 then fp.responseEmitters += 1 end
    end

    local total = fp.totalProbed * 3
    if total > 0 then fp.avgElapsed = elapsed_sum / total end

    -- Most common errors
    for msg, cnt in pairs(errorBag) do
        if cnt >= 2 then
            table.insert(fp.consistentErrors, {msg=msg, count=cnt})
        end
    end
    table.sort(fp.consistentErrors, function(a,b) return a.count > b.count end)

    -- Most common return keys
    for key, cnt in pairs(retKeyBag) do
        if cnt >= 2 then
            table.insert(fp.commonReturnKeys, {key=key, count=cnt})
        end
    end
    table.sort(fp.commonReturnKeys, function(a,b) return a.count > b.count end)

    return fp
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- FRAMEWORK PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_FW = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- top bar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_FW)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)

-- title — left anchored
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⬡  FRAMEWORK DETECTION",TextColor3=C.ACCENT,TextSize=11,
    Size=UDim2.new(0,260,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)

-- status label — right of centre
local FW_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,120,1,0),Position=UDim2.new(1,-210,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- DETECT button — pinned to right edge
local DETECT_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.ACCENT,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⬡  DETECT",
    TextColor3=C.WHITE,TextSize=10,
    Size=UDim2.new(0,86,0,22),Position=UDim2.new(1,-98,0.5,-11),
    ZIndex=6},TOPBAR)
corner(5,DETECT_BTN)
do local base=C.ACCENT
    DETECT_BTN.MouseEnter:Connect(function() tw(DETECT_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    DETECT_BTN.MouseLeave:Connect(function() tw(DETECT_BTN,TI.fast,{BackgroundColor3=base}) end)
end

-- body: left results, right detail
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,1,-32),ZIndex=3},P_FW)

-- left: detection results + fingerprint
local FL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0.44,0,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,-20),Position=UDim2.new(0.44,0,0,10),ZIndex=4},BODY)
local FL_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=3,
    ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),
    AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4},FL)
pad(10,8,FL_SCROLL); listV(FL_SCROLL,6)

-- right: probe log + framework detail
local FR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0.44,1,0,0),Size=UDim2.new(0.56,-1,1,0),ZIndex=3},BODY)
local FR_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=4,
    ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),
    AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},FR)
pad(10,8,FR_SCROLL); listV(FR_SCROLL,3)

local FR_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="Press ⬡ DETECT to probe all RemoteFunctions\nand identify active frameworks",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,50),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},FR_SCROLL)

-- ── Log helpers ───────────────────────────────────────────────────────────────
local frN=0
local function addLog(tag,msg,detail,hi)
    FR_EMPTY.Visible=false
    frN+=1; mkRow(tag,msg,detail,hi,FR_SCROLL,frN)
    task.defer(function()
        FR_SCROLL.CanvasPosition=Vector2.new(0,FR_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) frN+=1; mkSep(txt,FR_SCROLL,frN) end
local function clearLog()
    for _,c in ipairs(FR_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    frN=0; FR_EMPTY.Visible=true
end

-- ── Left panel helpers ────────────────────────────────────────────────────────
local flN=0
local function flCard(order)
    local c=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=order},FL_SCROLL)
    corner(6,c); stroke(C.BORDER,1,c)
    return c
end
local function flChip(txt,col,parent,order)
    local f=mk("Frame",{BackgroundColor3=col,BorderSizePixel=0,
        Size=UDim2.new(0,0,0,15),AutomaticSize=Enum.AutomaticSize.X,
        ZIndex=6,LayoutOrder=order or 99},parent)
    corner(4,f); mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5)},f)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=txt,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
        TextXAlignment=Enum.TextXAlignment.Center,ZIndex=7},f)
end
local function flSecLabel(txt,order)
    flN+=1
    local f=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,14),ZIndex=4,LayoutOrder=order or flN},FL_SCROLL)
    mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,0.5,0),ZIndex=4},f)
    local bg=mk("Frame",{BackgroundColor3=C.BG,BorderSizePixel=0,
        Size=UDim2.fromOffset(#txt*7+12,12),Position=UDim2.new(0,0,0.5,-6),ZIndex=5},f)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=txt,TextColor3=C.MUTED,TextSize=8,Size=UDim2.fromScale(1,1),
        TextXAlignment=Enum.TextXAlignment.Center,ZIndex=6},bg)
end
local function flKV(lbl,val,col,parent,order)
    local row=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,14),ZIndex=5,LayoutOrder=order},parent)
    listH(row,6)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=lbl,TextColor3=C.MUTED,TextSize=8,
        Size=UDim2.new(0,120,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=1},row)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text=val,TextColor3=col or C.TEXT,TextSize=8,TextWrapped=true,
        Size=UDim2.new(1,-130,1,0),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=6,LayoutOrder=2},row)
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- RESULT RENDERER
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function renderResults(detectionScores, fingerprint, probeCount)
    -- Clear left panel
    for _,c in ipairs(FL_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    flN=0

    -- ── Summary card ──────────────────────────────────────────────────────────
    flN+=1
    local sumCard=flCard(flN); pad(10,8,sumCard); listV(sumCard,4)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="Scan Summary",TextColor3=C.WHITE,TextSize=12,
        Size=UDim2.new(1,0,0,16),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=1},sumCard)
    flKV("Remotes probed",    tostring(probeCount),      C.TEXT, sumCard, 2)
    flKV("Avg response",
        ("%.0fms"):format(fingerprint.avgElapsed),       C.TEXT, sumCard, 3)
    flKV("State changers",    tostring(fingerprint.stateChangers),
        fingerprint.stateChangers>0 and C.DELTA or C.TEXT, sumCard, 4)
    flKV("Response emitters", tostring(fingerprint.responseEmitters),
        fingerprint.responseEmitters>0 and C.RESP or C.TEXT, sumCard, 5)

    -- ── Framework matches ─────────────────────────────────────────────────────
    if #detectionScores > 0 then
        flSecLabel("DETECTED FRAMEWORKS")

        for i, ds in ipairs(detectionScores) do
            if i > 5 then break end -- show top 5 matches
            local fw        = ds.fw
            local confidence= math.min(100, ds.score * 8)
            local confCol
            if     confidence >= 70 then confCol=Color3.fromRGB(255,80,80)
            elseif confidence >= 40 then confCol=Color3.fromRGB(255,160,40)
            else                         confCol=C.MUTED end

            flN+=1
            local fc=flCard(flN); stroke(fw.color,1,fc); pad(10,8,fc); listV(fc,5)

            local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
                Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},fc)
            listH(hrow,6)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text=fw.name,TextColor3=fw.color,TextSize=11,
                Size=UDim2.new(1,-80,1,0),TextXAlignment=Enum.TextXAlignment.Left,
                ZIndex=6,LayoutOrder=1},hrow)
            flChip(("~%d%%"):format(confidence), confCol, hrow, 2)

            flKV("Trust level", fw.trust,
                fw.trust:find("EXTERNAL") and Color3.fromRGB(255,80,80)
                or fw.trust:find("UNKNOWN") and Color3.fromRGB(255,160,40)
                or Color3.fromRGB(80,210,100), fc, 2)

            flKV("Asset hint", fw.assetHint, C.MUTED, fc, 3)

            -- Evidence list (top 3)
            if #ds.evidence > 0 then
                local evStr = ""
                for j=1,math.min(3,#ds.evidence) do
                    evStr=evStr..(j>1 and "  ·  " or "")..ds.evidence[j]
                end
                mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                    Text="Evidence: "..evStr,
                    TextColor3=Color3.fromRGB(255,175,70),TextSize=8,TextWrapped=true,
                    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=4},fc)
            end

            -- Trust implication
            if fw.trust:find("EXTERNAL") or fw.trust:find("UNKNOWN") then
                mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                    Text="⚑  Developer's server runs code they do not fully control",
                    TextColor3=Color3.fromRGB(255,80,80),TextSize=8,TextWrapped=true,
                    Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=5},fc)
            end
        end
    else
        flN+=1
        local nc=flCard(flN); pad(10,6,nc)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text="No known frameworks detected\nCustom or unrecognised handlers",
            TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
            Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=5},nc)
    end

    -- ── Structural fingerprint ────────────────────────────────────────────────
    flSecLabel("STRUCTURAL FINGERPRINT")
    flN+=1
    local fpCard=flCard(flN); pad(10,8,fpCard); listV(fpCard,4)

    -- Handler pattern description
    local pattern
    if fingerprint.alwaysErrors > fingerprint.totalProbed then
        pattern = "Strict validator — rejects unexpected input"
    elseif fingerprint.returnsTable > 0 then
        pattern = "Framework-style — returns structured data"
    elseif fingerprint.returnsNil > fingerprint.totalProbed then
        pattern = "Fire-and-forget style — no meaningful return"
    elseif fingerprint.fastResponders > fingerprint.totalProbed then
        pattern = "Lightweight handler — fast synchronous logic"
    elseif fingerprint.slowResponders > 0 then
        pattern = "Async/DataStore handler — waits on external calls"
    else
        pattern = "Standard handler"
    end

    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=pattern,TextColor3=C.TEXT,TextSize=10,TextWrapped=true,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=1},fpCard)

    flKV("Returns table",   tostring(fingerprint.returnsTable),   C.TEXT,fpCard,2)
    flKV("Returns nil",     tostring(fingerprint.returnsNil),     C.TEXT,fpCard,3)
    flKV("Always errors",   tostring(fingerprint.alwaysErrors),   C.TEXT,fpCard,4)
    flKV("Fast (<50ms)",    tostring(fingerprint.fastResponders), C.TEXT,fpCard,5)
    flKV("Slow (>200ms)",   tostring(fingerprint.slowResponders), C.TEXT,fpCard,6)

    -- Common return keys
    if #fingerprint.commonReturnKeys > 0 then
        local keyStr=""
        for j=1,math.min(5,#fingerprint.commonReturnKeys) do
            local k=fingerprint.commonReturnKeys[j]
            keyStr=keyStr..(j>1 and "  " or "")..k.key.."("..k.count.."×)"
        end
        flKV("Return keys", keyStr, Color3.fromRGB(255,175,70), fpCard, 7)
    end

    -- Consistent error patterns
    if #fingerprint.consistentErrors > 0 then
        flSecLabel("CONSISTENT ERROR PATTERNS")
        flN+=1
        local ec=flCard(flN); pad(10,8,ec); listV(ec,3)
        for j,ce in ipairs(fingerprint.consistentErrors) do
            if j>4 then break end
            flKV(("×%d"):format(ce.count), ce.msg, Color3.fromRGB(255,80,80), ec, j)
        end
    end

    -- ── require chain analysis ────────────────────────────────────────────────
    flSecLabel("require() CHAIN ANALYSIS")
    flN+=1
    local rqCard=flCard(flN); pad(10,8,rqCard); listV(rqCard,4)

    -- Check ReplicatedStorage for required modules
    local foundModules = {}
    local function scanModules(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do
            if x:IsA("ModuleScript") then
                table.insert(foundModules, x)
            end
        end
    end
    scanModules(RepS)

    if #foundModules > 0 then
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=("Found %d accessible ModuleScript(s)"):format(#foundModules),
            TextColor3=Color3.fromRGB(255,160,40),TextSize=10,
            Size=UDim2.new(1,0,0,14),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=5,LayoutOrder=1},rqCard)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text="These modules are accessible from the client.\n"..
                 "Server may require additional hidden modules not visible here.",
            TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},rqCard)

        for j=1,math.min(6,#foundModules) do
            local m=foundModules[j]
            flKV(m.Name, m:GetFullName():sub(1,50), C.TEXT, rqCard, 2+j)
        end
        if #foundModules > 6 then
            flKV("...", ("and %d more"):format(#foundModules-6), C.MUTED, rqCard, 9)
        end
    else
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text="No ModuleScripts visible in ReplicatedStorage.\n"..
                 "Server modules loaded via require(assetId) are not visible to client.",
            TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=1},rqCard)
    end

    -- Trust inheritance warning
    if #detectionScores > 0 then
        local hasExternal=false
        for _,ds in ipairs(detectionScores) do
            if ds.fw.trust:find("EXTERNAL") then hasExternal=true; break end
        end
        if hasExternal then
            flSecLabel("TRUST CHAIN WARNING")
            flN+=1
            local wCard=flCard(flN)
            stroke(Color3.fromRGB(255,80,80),1,wCard)
            pad(10,8,wCard); listV(wCard,3)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
                Text="⚑  External dependency detected",
                TextColor3=Color3.fromRGB(255,80,80),TextSize=11,
                Size=UDim2.new(1,0,0,16),TextXAlignment=Enum.TextXAlignment.Left,
                ZIndex=5,LayoutOrder=1},wCard)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                Text="The developer has granted a third party\n"..
                     "server-side execution through require(assetId).\n"..
                     "The framework author's code runs with full\n"..
                     "server trust on every session start.",
                TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
                Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
                TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},wCard)
        end
    end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- DETECT BUTTON
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local detecting=false

DETECT_BTN.MouseButton1Click:Connect(function()
    if detecting then return end
    detecting=true
    tw(DETECT_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
    clearLog(); frN=0
    FW_STATUS.Text="scanning..."; FW_STATUS.TextColor3=C.DELTA

    task.spawn(function()
        -- Discover RemoteFunctions
        local rfuncs={}
        local function scan(root)
            local ok,d=pcall(function() return root:GetDescendants() end)
            if not ok then return end
            for _,x in ipairs(d) do
                if x:IsA("RemoteFunction") then table.insert(rfuncs,x) end
            end
        end
        scan(RepS); scan(workspace)

        addLogSep("FRAMEWORK DETECTION SCAN")
        addLog("INFO",("Found %d RemoteFunction(s) to probe"):format(#rfuncs))

        if #rfuncs==0 then
            addLog("INFO","No RemoteFunctions found",
                "Run inside a live game — Studio has no server to probe")
            FW_STATUS.Text="no remotes"
            FW_STATUS.TextColor3=C.MUTED
            tw(DETECT_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
            detecting=false
            return
        end

        -- Probe each RemoteFunction
        local allResults={}
        for _,rf in ipairs(rfuncs) do
            FW_STATUS.Text="probing "..rf.Name.."..."
            addLog("INFO","Probing: "..rf:GetFullName())
            local result=probeRemote(rf,addLog)
            table.insert(allResults,result)

            -- Log per-probe results
            for i,probe in ipairs(result.probes) do
                local probeNames={"empty","nil","structured"}
                addLog(
                    probe.ok and "CLEAN" or "INFO",
                    ("[%s] probe #%d — %.0fms — %s"):format(
                        rf.Name, i, probe.elapsed,
                        probe.errStr and probe.errStr:sub(1,50) or probe.retStr:sub(1,50)),
                    nil, false)
            end

            -- State changes
            for _,ch in ipairs(result.deltas) do
                addLog(ch.bad and "PATHOLOG" or "DELTA",
                    rf.Name.." caused state change: "..ch.path,
                    ch.bv.." → "..ch.av,true)
            end

            task.wait(0.15)
        end

        addLogSep("ANALYSIS")

        -- Detect frameworks
        local scores      = detectFramework(allResults)
        local fingerprint = buildFingerprint(allResults)

        -- Log top match
        if #scores>0 then
            local top=scores[1]
            addLog("FINDING",
                ("Likely framework: %s (~%d%% confidence)"):format(
                    top.fw.name, math.min(100,top.score*8)),
                "Trust: "..top.fw.trust, true)
            if top.fw.trust:find("EXTERNAL") then
                addLog("FINDING",
                    "⚑  TRUST CHAIN VULNERABILITY",
                    "Developer granted third-party server execution via require(assetId)",
                    true)
            end
        else
            addLog("INFO","No known framework signatures matched",
                "Custom handlers or unfamiliar framework")
        end

        -- Render left panel
        renderResults(scores, fingerprint, #rfuncs)

        local foundCount = #scores
        FW_STATUS.Text = foundCount>0
            and (scores[1].fw.name.." detected")
            or  ("custom — "..#rfuncs.." probed")
        FW_STATUS.TextColor3 = foundCount>0
            and (scores[1].fw.trust:find("EXTERNAL")
                and Color3.fromRGB(255,80,80)
                or  Color3.fromRGB(255,160,40))
            or  C.MUTED

        addLogSep("SCAN COMPLETE")
        tw(DETECT_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
        detecting=false
    end)
end)

-- ── Register tab ─────────────────────────────────────────────────────────────
if G.addTab then
    G.addTab("framework","Framework",P_FW)
else
    warn("[Oracle] G.addTab not found — ensure 06_init.lua is up to date")
end
