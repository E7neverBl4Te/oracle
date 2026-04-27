-- Oracle // 10_carrier.lua
-- Trusted Carrier Probe
-- Maps how server logic responds to service-delivered data
-- TeleportData injection · Service callback correlation · Decision tree inference
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
local hookR  = G.hookR
local rlog   = G.rlog
local CFG    = G.CFG
local CON    = G.CON
local RepS   = G.RepS
local LP     = G.LP

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CARRIER ENGINE
-- Observation window: watch server state changes that occur
-- within a defined window after a service interaction fires.
-- Correlates carrier delivery with downstream state mutations.
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local OBSERVE_WIN = 3.0   -- seconds to watch after carrier delivery
local CORRELATE_T = 0.5   -- max seconds between delivery and state change
                           -- to flag as correlated

-- Carrier types Oracle can probe or observe
local CARRIERS = {
    {
        id      = "teleport_data",
        label   = "TeleportData",
        color   = Color3.fromRGB(168,120,255),
        risk    = "HIGH",
        desc    = "Data you authored, delivered by Roblox's teleport infrastructure. "..
                  "Server receives it through GetLocalPlayerTeleportData() and "..
                  "often uses it without re-validating origin.",
        canRead = true,
        canWrite= true,
    },
    {
        id      = "http_response",
        label   = "HttpService",
        color   = Color3.fromRGB(255,160,40),
        risk    = "MEDIUM",
        desc    = "Server-side HTTP calls return data from external sources. "..
                  "If any server script fetches a URL you influence "..
                  "(e.g. a player-controlled profile endpoint), "..
                  "you can author the response the server processes.",
        canRead = false,
        canWrite= false,
    },
    {
        id      = "datastoreservice",
        label   = "DataStoreService",
        color   = Color3.fromRGB(255,90,90),
        risk    = "HIGH",
        desc    = "DataStore values are trusted by the server as ground truth. "..
                  "Race conditions during teleport or rapid reconnect may allow "..
                  "a write to land before a read, with the server treating "..
                  "your value as authoritative.",
        canRead = false,
        canWrite= false,
    },
    {
        id      = "messaging_service",
        label   = "MessagingService",
        color   = Color3.fromRGB(80,170,210),
        risk    = "MEDIUM",
        desc    = "Cross-server messages are trusted by receiving servers. "..
                  "If any game server subscribes to a topic you can publish to, "..
                  "the receiving server processes your message as infrastructure.",
        canRead = false,
        canWrite= false,
    },
}

-- Observation record
local observations = {}  -- [{carrier, field, before, after, delta_ms, correlated}]
local watchActive  = false
local watchStart   = 0
local watchThread  = nil
local watchConns   = {}

-- ── Teleport data reader ──────────────────────────────────────────────────────
local function readTeleportData()
    local TeleSvc = game:GetService("TeleportService")
    local ok, data = pcall(function()
        return TeleSvc:GetLocalPlayerTeleportData()
    end)
    if not ok or data == nil then return nil end
    return data
end

-- ── Server decision correlator ────────────────────────────────────────────────
-- Takes a baseline snapshot, then watches for state changes
-- and records timing relative to a delivery timestamp
local function correlateDelivery(baseline, deliveryTime, windowSec, logFn)
    local correlated = {}
    local deadline   = tick() + windowSec

    -- Collect all remotes for response watching
    local ev = {}
    local function col(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do if x:IsA("RemoteEvent") then table.insert(ev,x) end end
    end
    col(RepS); col(workspace)

    -- Hook responses
    for k in pairs(rlog) do rlog[k]=nil end
    local conns = hookR(ev)

    -- Poll state every 100ms
    local lastSnap = baseline
    while tick() < deadline do
        task.wait(0.1)
        local cur     = snap()
        local deltas  = dif(lastSnap, cur)
        local now     = tick()
        local elapsed = now - deliveryTime

        for _, ch in ipairs(deltas) do
            local entry = {
                path      = ch.path,
                bv        = ch.bv,
                av        = ch.av,
                bad       = ch.bad,
                elapsed   = elapsed,
                correlated= elapsed <= CORRELATE_T,
            }
            table.insert(correlated, entry)
            lastSnap[ch.path] = cur[ch.path]

            if logFn then
                logFn(
                    ch.bad and "PATHOLOG" or
                    (entry.correlated and "FINDING" or "DELTA"),
                    (entry.correlated and "⚑ CORRELATED " or "")..
                    "State change — "..ch.path,
                    ("%.0f ms after delivery  |  %s → %s"):format(
                        elapsed*1000, ch.bv, ch.av),
                    entry.correlated
                )
            end
        end

        -- Check responses
        for _, r in ipairs(rlog) do
            local entry = {
                path      = "RESPONSE:"..r.name,
                bv        = "",
                av        = r.args,
                bad       = false,
                elapsed   = elapsed,
                correlated= elapsed <= CORRELATE_T,
            }
            table.insert(correlated, entry)
            if logFn then
                logFn(
                    entry.correlated and "FINDING" or "RESPONSE",
                    (entry.correlated and "⚑ CORRELATED " or "")..
                    "Server replied via "..r.name,
                    ("%.0f ms after delivery  |  %s"):format(elapsed*1000, r.args),
                    entry.correlated
                )
            end
        end
        for k in pairs(rlog) do rlog[k]=nil end
    end

    for _,c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    return correlated
end

-- ── TeleportData injection probe ─────────────────────────────────────────────
-- Teleports to same place with authored data payload
-- then watches what the destination server does with it
local function probeTeleportData(payload, logFn, onComplete)
    local TeleSvc = game:GetService("TeleportService")

    -- First read what's already there
    local existing = readTeleportData()
    if existing then
        logFn("INFO", "Existing TeleportData found", "Server received data from previous teleport")
        if type(existing) == "table" then
            for k, v in pairs(existing) do
                logFn("INFO", "  field: "..tostring(k), vs(v))
            end
        end
    else
        logFn("INFO", "No existing TeleportData", "This is a fresh session or data was cleared")
    end

    -- Check if we can teleport (must be in an actual game)
    local placeId = game.PlaceId
    if placeId == 0 then
        logFn("INFO", "PlaceId = 0", "Running in Studio — teleport probe requires live game")
        if onComplete then onComplete({}) end
        return
    end

    logFn("INFO", "Preparing injection payload", "PlaceId: "..tostring(placeId))
    for k, v in pairs(payload) do
        logFn("INFO", "  payload."..tostring(k), vs(v))
    end

    -- Take baseline before teleport
    local baseline = snap()
    local deliveryTime = tick()

    -- Attempt teleport with authored data
    local ok, err = pcall(function()
        TeleSvc:TeleportToPlaceInstance(
            placeId,
            game.JobId,
            LP,
            "",
            payload  -- this is the trusted carrier
        )
    end)

    if not ok then
        -- Try alternate method
        ok, err = pcall(function()
            TeleSvc:Teleport(placeId, LP, payload)
        end)
    end

    if not ok then
        logFn("INFO", "Teleport rejected", tostring(err):sub(1,100))
        logFn("INFO", "Carrier delivery blocked",
            "Engine prevented teleport — payload never reached server infrastructure")
        if onComplete then onComplete({}) end
        return
    end

    logFn("FIRED", "Teleport initiated with authored payload",
        "Watching for server response before transition...")

    -- Watch for any server-side reaction before we're teleported away
    local results = correlateDelivery(baseline, deliveryTime, 2.0, logFn)
    if onComplete then onComplete(results) end
end

-- ── DataStore timing window probe ─────────────────────────────────────────────
local function probeDataStoreTiming(logFn, onComplete)
    -- We can't write DataStore from client — but we can observe
    -- whether rapid reconnect/teleport creates a timing window
    -- where the server reads stale data before our session is written

    logFn("INFO", "DataStore Timing Analysis",
        "Observing server state patterns that suggest DataStore read timing")

    local baseline = snap()
    local start    = tick()

    -- Watch for any state changes in the first 500ms after joining
    -- which would indicate the server loaded our DataStore before joining finished
    local results  = {}
    local deadline = tick() + 3.0

    while tick() < deadline do
        task.wait(0.1)
        local cur    = snap()
        local deltas = dif(baseline, cur)
        local elapsed= tick() - start

        for _, ch in ipairs(deltas) do
            table.insert(results, {
                path=ch.path, bv=ch.bv, av=ch.av,
                elapsed=elapsed, bad=ch.bad,
            })
            logFn(ch.bad and "PATHOLOG" or "DELTA",
                ("%.0fms — %s"):format(elapsed*1000, ch.path),
                ch.bv.." → "..ch.av,
                elapsed < 0.5)
            baseline[ch.path] = cur[ch.path]
        end
    end

    -- Analyse timing pattern
    if #results > 0 then
        local earliest = results[1].elapsed * 1000
        logFn("FINDING",
            ("DataStore load detected at %.0fms"):format(earliest),
            "Server loaded player data "..
            (earliest < 300 and "BEFORE full join — potential race window" or
             "after join — normal pattern"))
    else
        logFn("CLEAN", "No state changes in observation window",
            "DataStore timing appears normal")
    end

    if onComplete then onComplete(results) end
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CARRIER PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_CAR = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.fromScale(1,1), Visible=false, ZIndex=3}, CON)

-- top bar
local TOPBAR = mk("Frame", {BackgroundColor3=C.SURFACE, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32), ZIndex=4}, P_CAR)
stroke(C.BORDER, 1, TOPBAR)
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1), Position=UDim2.new(0,0,1,-1), ZIndex=5}, TOPBAR)
pad(12, 0, TOPBAR); listH(TOPBAR, 10)
mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.GothamBold,
    Text="⬡  TRUSTED CARRIER PROBE", TextColor3=C.ACCENT, TextSize=11,
    Size=UDim2.new(1,-200,1,0), TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5, LayoutOrder=1}, TOPBAR)
local CAR_STATUS = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="idle", TextColor3=C.MUTED, TextSize=9,
    Size=UDim2.new(0,130,1,0), TextXAlignment=Enum.TextXAlignment.Right,
    ZIndex=5, LayoutOrder=2}, TOPBAR)
local SCAN_BTN = mk("TextButton", {AutoButtonColor=false,
    BackgroundColor3=C.ACCENT, BorderSizePixel=0,
    Font=Enum.Font.GothamBold, Text="⚙  PROBE",
    TextColor3=C.WHITE, TextSize=10,
    Size=UDim2.new(0,72,0,22), ZIndex=5, LayoutOrder=3}, TOPBAR)
corner(5, SCAN_BTN)
do local base=C.ACCENT
    SCAN_BTN.MouseEnter:Connect(function() tw(SCAN_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.08,1),math.min(base.G+.08,1),math.min(base.B+.08,1))}) end)
    SCAN_BTN.MouseLeave:Connect(function() tw(SCAN_BTN,TI.fast,{BackgroundColor3=base}) end)
end

-- body
local BODY = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32), Size=UDim2.new(1,0,1,-32), ZIndex=3}, P_CAR)

-- left: carrier list + config
local CL = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.new(0,230,1,0), ZIndex=3}, BODY)
mk("Frame", {BackgroundColor3=C.BORDER, BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0), Position=UDim2.new(1,-1,0,0), ZIndex=4}, CL)

-- carrier scroll
local CL_SCROLL = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.new(1,0,1,0),
    ScrollBarThickness=3, ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0), AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ZIndex=4}, CL)
pad(8, 8, CL_SCROLL); listV(CL_SCROLL, 10)

-- right: observation log
local CR = mk("Frame", {BackgroundTransparency=1, BorderSizePixel=0,
    Position=UDim2.new(0,230,0,0), Size=UDim2.new(1,-230,1,0), ZIndex=3}, BODY)
local CR_SCROLL = mk("ScrollingFrame", {BackgroundTransparency=1, BorderSizePixel=0,
    Size=UDim2.fromScale(1,1), ScrollBarThickness=4,
    ScrollBarImageColor3=C.ACCDIM, CanvasSize=UDim2.fromScale(0,0),
    AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y, ZIndex=4}, CR)
pad(12, 8, CR_SCROLL); listV(CR_SCROLL, 3)

local CR_EMPTY = mk("TextLabel", {BackgroundTransparency=1, Font=Enum.Font.Code,
    Text="Select a carrier and press ⚙ PROBE\nto map how the server processes it",
    TextColor3=C.MUTED, TextSize=10, TextWrapped=true,
    Size=UDim2.new(1,0,0,50), TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5, LayoutOrder=1}, CR_SCROLL)

-- ── UI helpers ────────────────────────────────────────────────────────────────
local RISK_COL = {
    HIGH   = Color3.fromRGB(255, 80, 80),
    MEDIUM = Color3.fromRGB(255,160, 40),
    INFO   = Color3.fromRGB(80, 140,255),
}

local crN = 0
local function addLog(tag, msg, detail, hi)
    CR_EMPTY.Visible = false
    crN += 1; mkRow(tag, msg, detail, hi, CR_SCROLL, crN)
    task.defer(function()
        CR_SCROLL.CanvasPosition = Vector2.new(0, CR_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt)
    crN += 1; mkSep(txt, CR_SCROLL, crN)
end
local function clearLog()
    for _, c in ipairs(CR_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    crN = 0; CR_EMPTY.Visible = true
end

local function infoCard(parent, order)
    local c=mk("Frame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        ZIndex=4,LayoutOrder=order},parent)
    corner(6,c); stroke(C.BORDER,1,c)
    return c
end

local function riskChip(risk, parent)
    local f=mk("Frame",{BackgroundColor3=RISK_COL[risk] or C.MUTED,
        BorderSizePixel=0,Size=UDim2.new(0,0,0,15),AutomaticSize=Enum.AutomaticSize.X,
        ZIndex=6},parent)
    corner(4,f); mk("UIPadding",{PaddingLeft=UDim.new(0,5),PaddingRight=UDim.new(0,5)},f)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text=risk,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
        TextXAlignment=Enum.TextXAlignment.Center,ZIndex=7},f)
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TELEPORTDATA PAYLOAD BUILDER
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local payloadFields = {}  -- [{key, value, keyBox, valBox}]
local payloadOrd    = 0

local function buildPayloadFromFields()
    local t = {}
    for _, f in ipairs(payloadFields) do
        local k = f.keyBox.Text:match("^%s*(.-)%s*$")
        local v = f.valBox.Text:match("^%s*(.-)%s*$")
        if k ~= "" then
            -- Auto-type: number if parseable, else string
            local n = tonumber(v)
            t[k] = n or v
        end
    end
    return t
end

local PF_SCROLL = nil  -- assigned below after UI build

local function addPayloadField(dk, dv)
    if not PF_SCROLL then return end
    payloadOrd += 1
    local f = {}

    local row = mk("Frame",{BackgroundColor3=C.SURFACE,BackgroundTransparency=0.4,
        BorderSizePixel=0,Size=UDim2.new(1,0,0,26),
        ZIndex=5,LayoutOrder=payloadOrd},PF_SCROLL)
    corner(4,row)

    local kb = mk("TextBox",{BackgroundColor3=C.BG,BorderSizePixel=0,
        Text=dk or "",PlaceholderText="key",
        PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,
        TextSize=10,Font=Enum.Font.Code,ClearTextOnFocus=false,
        TextXAlignment=Enum.TextXAlignment.Left,
        Size=UDim2.new(0,80,0,20),Position=UDim2.new(0,4,0.5,-10),ZIndex=6},row)
    corner(3,kb); f.keyBox=kb

    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,Text="=",
        TextColor3=C.MUTED,TextSize=10,
        Size=UDim2.new(0,10,1,0),Position=UDim2.new(0,87,0,0),
        TextXAlignment=Enum.TextXAlignment.Center,ZIndex=6},row)

    local vb = mk("TextBox",{BackgroundColor3=C.BG,BorderSizePixel=0,
        Text=dv or "",PlaceholderText="value",
        PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,
        TextSize=10,Font=Enum.Font.Code,ClearTextOnFocus=false,
        TextXAlignment=Enum.TextXAlignment.Left,
        Size=UDim2.new(1,-140,0,20),Position=UDim2.new(0,100,0.5,-10),ZIndex=6},row)
    corner(3,vb); f.valBox=vb

    local rb = mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=C.REDDIM,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text="✕",TextColor3=C.RED,TextSize=9,
        Size=UDim2.new(0,20,0,18),Position=UDim2.new(1,-24,0.5,-9),ZIndex=6},row)
    corner(3,rb)
    rb.MouseButton1Click:Connect(function()
        for i,pf in ipairs(payloadFields) do
            if pf==f then table.remove(payloadFields,i); break end
        end
        row:Destroy()
    end)

    f.row = row
    table.insert(payloadFields, f)
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CARRIER CARD BUILDER
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local selCarrier  = nil
local carrierBtns = {}

local function buildCarrierList()
    for _, c in ipairs(CL_SCROLL:GetChildren()) do
        if not c:IsA("UIListLayout") and not c:IsA("UIPadding") then c:Destroy() end
    end
    carrierBtns = {}

    -- Session info card at top
    local infoC = infoCard(CL_SCROLL, 1)
    pad(10,8,infoC); listV(infoC,3)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="⬡  TRUSTED CARRIER PROBE",TextColor3=C.ACCENT,TextSize=10,
        Size=UDim2.new(1,0,0,15),TextXAlignment=Enum.TextXAlignment.Left,
        ZIndex=5,LayoutOrder=1},infoC)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
        Text="Maps how server logic responds\nto data delivered through\ntrusted Roblox services.",
        TextColor3=C.MUTED,TextSize=9,TextWrapped=true,
        Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
        TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},infoC)

    -- Separator
    local sep=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,12),ZIndex=4,LayoutOrder=2},CL_SCROLL)
    mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,0.5,0),ZIndex=5},sep)

    -- Carrier cards
    for i, car in ipairs(CARRIERS) do
        local sel = selCarrier == car.id
        local card=mk("Frame",{BackgroundColor3=sel and C.ACCDIM or C.CARD,
            BorderSizePixel=0,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            ZIndex=4,LayoutOrder=i+2},CL_SCROLL)
        corner(7,card)
        if sel then stroke(car.color,1,card) end
        pad(10,8,card); listV(card,4)

        -- header row
        local hrow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=1},card)
        listH(hrow,6)
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
            Text=car.label,TextColor3=sel and C.WHITE or car.color,TextSize=10,
            Size=UDim2.new(1,-50,1,0),TextXAlignment=Enum.TextXAlignment.Left,
            ZIndex=6,LayoutOrder=1},hrow)
        riskChip(car.risk, hrow)

        -- description
        mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
            Text=car.desc,TextColor3=C.MUTED,TextSize=8,TextWrapped=true,
            Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,
            TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5,LayoutOrder=2},card)

        -- access chips row
        local arow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
            Size=UDim2.new(1,0,0,16),ZIndex=5,LayoutOrder=3},card)
        listH(arow,5)

        local function accessChip(txt, col2)
            local f=mk("Frame",{BackgroundColor3=col2,BorderSizePixel=0,
                Size=UDim2.new(0,0,0,14),AutomaticSize=Enum.AutomaticSize.X,
                ZIndex=6},arow)
            corner(3,f); mk("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4)},f)
            mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
                Text=txt,TextColor3=Color3.fromRGB(8,8,12),TextSize=7,
                Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
                TextXAlignment=Enum.TextXAlignment.Center,ZIndex=7},f)
        end

        if car.canRead  then accessChip("CLIENT READ",  Color3.fromRGB(80,210,100)) end
        if car.canWrite then accessChip("CLIENT WRITE", Color3.fromRGB(255,160,40)) end
        if not car.canRead and not car.canWrite then
            accessChip("OBSERVE ONLY", C.MUTED)
        end

        -- select on click
        local function selectThis()
            selCarrier = car.id
            buildCarrierList()
        end

        card.InputBegan:Connect(function(inp)
            if inp.UserInputType==Enum.UserInputType.MouseButton1 then
                selectThis()
            end
        end)

        carrierBtns[car.id] = card
    end

    -- ── TeleportData payload builder (always visible below carrier list) ───────
    local pbHdr = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,14),ZIndex=4,
        LayoutOrder=#CARRIERS+3},CL_SCROLL)
    mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,0.5,0),ZIndex=4},pbHdr)
    local pbBg=mk("Frame",{BackgroundColor3=C.BG,BorderSizePixel=0,
        Size=UDim2.fromOffset(120,12),Position=UDim2.new(0,0,0.5,-6),ZIndex=5},pbHdr)
    mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
        Text="TELEPORT PAYLOAD",TextColor3=C.MUTED,TextSize=8,
        Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Center,ZIndex=6},pbBg)

    -- payload field scroll
    PF_SCROLL = mk("ScrollingFrame",{BackgroundColor3=C.CARD,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,120),ScrollBarThickness=3,
        ScrollBarImageColor3=C.ACCDIM,CanvasSize=UDim2.fromScale(0,0),
        AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=4,
        LayoutOrder=#CARRIERS+4},CL_SCROLL)
    corner(6,PF_SCROLL); stroke(C.BORDER,1,PF_SCROLL)
    pad(5,4,PF_SCROLL); listV(PF_SCROLL,3)

    -- add field button
    local addRow=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
        Size=UDim2.new(1,0,0,22),ZIndex=4,
        LayoutOrder=#CARRIERS+5},CL_SCROLL)
    listH(addRow,6)
    local addPF=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=C.ACCDIM,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text="＋ Add Field",
        TextColor3=C.ACCENT,TextSize=9,
        Size=UDim2.new(0,90,0,20),ZIndex=5,LayoutOrder=1},addRow)
    corner(4,addPF); stroke(C.BORDER,1,addPF)
    addPF.MouseButton1Click:Connect(function() addPayloadField() end)

    -- Pre-fill with interesting default fields
    if #payloadFields == 0 then
        addPayloadField("role",   "admin")
        addPayloadField("coins",  "9999")
        addPayloadField("vip",    "true")
    else
        -- Re-parent existing field rows to new PF_SCROLL
        for _, f in ipairs(payloadFields) do
            if f.row then f.row.Parent = PF_SCROLL end
        end
    end

    -- DataStore timing probe button
    local dtBtn=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=C.CARD,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text="⏱  Time DataStore Load",
        TextColor3=C.TEXT,TextSize=9,
        Size=UDim2.new(1,0,0,26),ZIndex=4,
        LayoutOrder=#CARRIERS+6},CL_SCROLL)
    corner(6,dtBtn); stroke(C.BORDER,1,dtBtn)
    dtBtn.MouseEnter:Connect(function() tw(dtBtn,TI.fast,{BackgroundColor3=C.SURFACE}) end)
    dtBtn.MouseLeave:Connect(function() tw(dtBtn,TI.fast,{BackgroundColor3=C.CARD}) end)
    dtBtn.MouseButton1Click:Connect(function()
        clearLog(); crN=0
        addLogSep("DATASTORE TIMING PROBE")
        CAR_STATUS.Text="timing DataStore..."
        CAR_STATUS.TextColor3=C.DELTA
        task.spawn(function()
            probeDataStoreTiming(addLog, function(results)
                CAR_STATUS.Text=#results.." timing observations"
                CAR_STATUS.TextColor3=C.MUTED
            end)
        end)
    end)
end

-- ── Observe existing TeleportData immediately on load ─────────────────────────
local function autoObserveTeleportData()
    local data = readTeleportData()
    if not data then return end

    -- Store for G access
    G.CARRIER_TELEPORT_DATA = data

    -- Log it to results if visible
    addLog("FINDING", "TeleportData present on this server",
        "Server received authored payload — check fields below", true)
    if type(data) == "table" then
        for k, v in pairs(data) do
            local valStr = vs(v)
            addLog("INFO", "  "..tostring(k).." = "..valStr, nil, false)
        end

        -- Cross-reference with RSO to see if any observed state matches
        -- teleport data fields — indicates the server used this data
        addLog("INFO",
            "Watch for state changes that match these values",
            "If game state contains "..tostring(next(data)).." → server trusted this data")
    end
end

-- ── PROBE button ──────────────────────────────────────────────────────────────
local probing = false
SCAN_BTN.MouseButton1Click:Connect(function()
    if probing then return end

    local car = nil
    for _, c in ipairs(CARRIERS) do
        if c.id == selCarrier then car=c; break end
    end
    if not car then
        -- Default to TeleportData
        car = CARRIERS[1]
        selCarrier = car.id
        buildCarrierList()
    end

    probing = true
    tw(SCAN_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(35,32,55)})
    clearLog(); crN=0
    CAR_STATUS.Text="probing "..car.label.."..."
    CAR_STATUS.TextColor3=C.DELTA

    addLogSep("CARRIER PROBE — "..car.label)
    addLog("INFO", "Carrier: "..car.label)
    addLog("INFO", "Risk: "..car.risk, car.desc:sub(1,80))

    task.spawn(function()
        if car.id == "teleport_data" then
            local payload = buildPayloadFromFields()
            addLog("INFO", "Payload fields: "..tostring(#payloadFields))
            probeTeleportData(payload, addLog, function(results)
                local correlated = 0
                for _, r in ipairs(results) do
                    if r.correlated then correlated += 1 end
                end
                addLogSep("PROBE COMPLETE — "..correlated.." correlated findings")
                CAR_STATUS.Text = correlated.." correlated"
                CAR_STATUS.TextColor3 = correlated>0 and C.DELTA or C.MUTED
                tw(SCAN_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
                probing = false
            end)

        elseif car.id == "datastoreservice" then
            probeDataStoreTiming(addLog, function(results)
                addLogSep("TIMING PROBE COMPLETE — "..#results.." observations")
                CAR_STATUS.Text = #results.." observations"
                CAR_STATUS.TextColor3 = #results>0 and C.DELTA or C.MUTED
                tw(SCAN_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
                probing = false
            end)

        else
            -- Observe-only carriers: watch state for 5s and report anything
            addLog("INFO", "Observe-only carrier",
                "Watching for state changes correlated with "..car.label.." activity")
            local baseline = snap()
            local deliveryTime = tick()
            local results = correlateDelivery(baseline, deliveryTime, 5.0, addLog)
            local found = 0
            for _, r in ipairs(results) do
                if r.correlated then found += 1 end
            end
            addLogSep("OBSERVATION COMPLETE — "..found.." correlated findings")
            CAR_STATUS.Text = found.." correlated"
            CAR_STATUS.TextColor3 = found>0 and C.DELTA or C.MUTED
            tw(SCAN_BTN,TI.fast,{BackgroundColor3=C.ACCENT})
            probing = false
        end
    end)
end)

-- ── Build UI ──────────────────────────────────────────────────────────────────
buildCarrierList()

-- Auto-observe TeleportData on load (runs silently)
task.delay(1, function()
    autoObserveTeleportData()
end)

-- ── Register tab ─────────────────────────────────────────────────────────────
if G.addTab then
    G.addTab("carrier", "Carrier", P_CAR)
else
    warn("[Oracle] G.addTab not found — ensure 06_init.lua is up to date")
end
