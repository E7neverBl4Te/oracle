-- Oracle // 30a_grantui.lua
-- GRANT UI Part A — Engine + Tools + Currency
-- Floating overlay that renders after GRANT confirms a finding
-- Tools · Currency · Items · GUI Unlock
-- Draggable · Persistent · Server-authenticated actions
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
local vs     = G.vs
local CON    = G.CON
local RepS   = G.RepS
local LP     = G.LP

local Players = game:GetService("Players")
local TS      = game:GetService("TweenService")

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- GRANTUI ENGINE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- The IMGUI is a ScreenGui that floats over the game
-- Try multiple parent strategies for executor compatibility
local SGUI = Instance.new("ScreenGui")
SGUI.Name             = "OracleGrantUI"
SGUI.ResetOnSpawn     = false
SGUI.IgnoreGuiInset   = true
SGUI.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
SGUI.Enabled          = false

-- Try PlayerGui → CoreGui → unparented fallback
local function tryParent()
    -- Method 1: gethui (some executors provide a protected GUI parent)
    if gethui then
        local ok=pcall(function() SGUI.Parent=gethui() end)
        if ok then return end
    end
    -- Method 2: PlayerGui direct
    local pg=LP:FindFirstChildOfClass("PlayerGui")
    if pg then
        local ok=pcall(function() SGUI.Parent=pg end)
        if ok then return end
    end
    -- Method 3: CoreGui
    pcall(function() SGUI.Parent=game:GetService("CoreGui") end)
end
tryParent()

-- ── Palette (matches Oracle but slightly lighter for overlay context) ──────────
local OC = {
    BG      = Color3.fromRGB(12,10,18),
    SURFACE = Color3.fromRGB(18,16,26),
    CARD    = Color3.fromRGB(24,22,34),
    BORDER  = Color3.fromRGB(38,34,58),
    TEXT    = Color3.fromRGB(220,216,240),
    MUTED   = Color3.fromRGB(90,84,120),
    ACCENT  = Color3.fromRGB(120,80,255),
    WHITE   = Color3.fromRGB(255,255,255),
    GREEN   = Color3.fromRGB(80,210,100),
    AMBER   = Color3.fromRGB(255,175,60),
    RED     = Color3.fromRGB(255,70,70),
}

-- ── Root container — draggable ─────────────────────────────────────────────────
local ROOT = Instance.new("Frame")
ROOT.Name             = "GrantUI_Root"
ROOT.BackgroundColor3 = OC.BG
ROOT.BorderSizePixel  = 0
ROOT.Size             = UDim2.fromOffset(340, 440)
ROOT.Position         = UDim2.new(1, -360, 0.5, -220)
ROOT.Visible          = false
ROOT.Parent           = SGUI

local rc = Instance.new("UICorner"); rc.CornerRadius=UDim.new(0,10); rc.Parent=ROOT
local rs = Instance.new("UIStroke"); rs.Color=OC.BORDER; rs.Thickness=1; rs.Parent=ROOT

-- Drop shadow
local shadow = Instance.new("Frame")
shadow.BackgroundColor3 = Color3.fromRGB(0,0,0)
shadow.BackgroundTransparency = 0.6
shadow.BorderSizePixel = 0
shadow.Size  = UDim2.new(1,16,1,16)
shadow.Position = UDim2.new(0,-8,0,8)
shadow.ZIndex = ROOT.ZIndex - 1
shadow.Parent = ROOT
local sc = Instance.new("UICorner"); sc.CornerRadius=UDim.new(0,14); sc.Parent=shadow

-- Drag
do
    local dragging, dragStart, startPos = false, nil, nil
    ROOT.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging=true; dragStart=i.Position
            startPos=ROOT.Position
        end
    end)
    ROOT.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging=false
        end
    end)
    game:GetService("UserInputService").InputChanged:Connect(function(i)
        if dragging and i.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = i.Position - dragStart
            ROOT.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

-- ── Title bar ──────────────────────────────────────────────────────────────────
local TITLEBAR = Instance.new("Frame")
TITLEBAR.BackgroundColor3 = OC.SURFACE
TITLEBAR.BorderSizePixel  = 0
TITLEBAR.Size  = UDim2.new(1,0,0,36)
TITLEBAR.ZIndex = 3
TITLEBAR.Parent = ROOT
local tc = Instance.new("UICorner")
tc.CornerRadius = UDim.new(0,10); tc.Parent=TITLEBAR
-- bottom-flatten the corner
local tflat = Instance.new("Frame")
tflat.BackgroundColor3 = OC.SURFACE; tflat.BorderSizePixel=0
tflat.Size=UDim2.new(1,0,0,10); tflat.Position=UDim2.new(0,0,1,-10); tflat.Parent=TITLEBAR

local TITLE_ICO = Instance.new("TextLabel")
TITLE_ICO.BackgroundTransparency=1; TITLE_ICO.Font=Enum.Font.GothamBold
TITLE_ICO.Text="⬡"; TITLE_ICO.TextColor3=OC.ACCENT; TITLE_ICO.TextSize=14
TITLE_ICO.Size=UDim2.fromOffset(24,36); TITLE_ICO.Position=UDim2.fromOffset(10,0)
TITLE_ICO.Parent=TITLEBAR

local TITLE_LBL = Instance.new("TextLabel")
TITLE_LBL.BackgroundTransparency=1; TITLE_LBL.Font=Enum.Font.GothamBold
TITLE_LBL.Text="GRANT RESULT"; TITLE_LBL.TextColor3=OC.TEXT; TITLE_LBL.TextSize=12
TITLE_LBL.Size=UDim2.new(1,-100,1,0); TITLE_LBL.Position=UDim2.fromOffset(36,0)
TITLE_LBL.TextXAlignment=Enum.TextXAlignment.Left; TITLE_LBL.Parent=TITLEBAR

local CLOSE_BTN = Instance.new("TextButton")
CLOSE_BTN.BackgroundColor3=Color3.fromRGB(50,20,20); CLOSE_BTN.BorderSizePixel=0
CLOSE_BTN.Font=Enum.Font.GothamBold; CLOSE_BTN.Text="✕"
CLOSE_BTN.TextColor3=OC.RED; CLOSE_BTN.TextSize=12
CLOSE_BTN.Size=UDim2.fromOffset(28,22); CLOSE_BTN.Position=UDim2.new(1,-32,0.5,-11)
CLOSE_BTN.ZIndex=4; CLOSE_BTN.Parent=TITLEBAR
local cbc=Instance.new("UICorner"); cbc.CornerRadius=UDim.new(0,5); cbc.Parent=CLOSE_BTN

CLOSE_BTN.MouseButton1Click:Connect(function()
    tw(ROOT,TweenInfo.new(0.15),{Size=UDim2.fromOffset(340,0)})
    task.delay(0.15,function() ROOT.Visible=false; SGUI.Enabled=false end)
end)

-- Status strip under title
local STATUS_STRIP = Instance.new("Frame")
STATUS_STRIP.BackgroundColor3=Color3.fromRGB(20,40,20); STATUS_STRIP.BorderSizePixel=0
STATUS_STRIP.Size=UDim2.new(1,0,0,22); STATUS_STRIP.Position=UDim2.fromOffset(0,36)
STATUS_STRIP.ZIndex=3; STATUS_STRIP.Parent=ROOT
local STATUS_LBL=Instance.new("TextLabel")
STATUS_LBL.BackgroundTransparency=1; STATUS_LBL.Font=Enum.Font.Code
STATUS_LBL.Text="Awaiting grant..."; STATUS_LBL.TextColor3=OC.GREEN; STATUS_LBL.TextSize=10
STATUS_LBL.Size=UDim2.fromScale(1,1); STATUS_LBL.TextXAlignment=Enum.TextXAlignment.Center
STATUS_LBL.Parent=STATUS_STRIP

-- Content area
local CONTENT = Instance.new("Frame")
CONTENT.BackgroundTransparency=1; CONTENT.BorderSizePixel=0
CONTENT.Position=UDim2.fromOffset(0,58); CONTENT.Size=UDim2.new(1,0,1,-58)
CONTENT.ZIndex=2; CONTENT.Parent=ROOT

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- HELPERS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function clearContent()
    for _,c in ipairs(CONTENT:GetChildren()) do c:Destroy() end
end

local function mkLabel(text, size, col, parent, yOff, xOff, align)
    local lbl=Instance.new("TextLabel")
    lbl.BackgroundTransparency=1; lbl.Font=Enum.Font.GothamBold
    lbl.Text=text; lbl.TextColor3=col or OC.TEXT; lbl.TextSize=size or 11
    lbl.Size=UDim2.new(1,-(xOff or 0)*2,0,size and size+4 or 16)
    lbl.Position=UDim2.fromOffset(xOff or 0, yOff or 0)
    lbl.TextXAlignment=align or Enum.TextXAlignment.Center
    lbl.TextWrapped=true; lbl.Parent=parent
    return lbl
end

local function mkArrowBtn(txt, parent, x, y, w)
    local b=Instance.new("TextButton")
    b.BackgroundColor3=OC.CARD; b.BorderSizePixel=0
    b.Font=Enum.Font.GothamBold; b.Text=txt
    b.TextColor3=OC.TEXT; b.TextSize=16
    b.Size=UDim2.fromOffset(w or 36, 36)
    b.Position=UDim2.fromOffset(x,y); b.ZIndex=4; b.Parent=parent
    local bc=Instance.new("UICorner"); bc.CornerRadius=UDim.new(0,8); bc.Parent=b
    local bs=Instance.new("UIStroke"); bs.Color=OC.BORDER; bs.Thickness=1; bs.Parent=b
    b.MouseEnter:Connect(function() b.BackgroundColor3=OC.SURFACE end)
    b.MouseLeave:Connect(function() b.BackgroundColor3=OC.CARD end)
    return b
end

local function mkGrantBtn(txt, col, parent, y)
    local b=Instance.new("TextButton")
    b.BackgroundColor3=col or OC.ACCENT; b.BorderSizePixel=0
    b.Font=Enum.Font.GothamBold; b.Text=txt or "▶ GRANT"
    b.TextColor3=Color3.fromRGB(8,8,12); b.TextSize=13
    b.Size=UDim2.new(1,-32,0,40)
    b.Position=UDim2.new(0,16,0,y or 0); b.ZIndex=4; b.Parent=parent
    local bc=Instance.new("UICorner"); bc.CornerRadius=UDim.new(0,10); bc.Parent=b
    b.MouseEnter:Connect(function()
        tw(b,TweenInfo.new(0.1),{BackgroundColor3=Color3.new(
            math.min((col or OC.ACCENT).R+.06,1),
            math.min((col or OC.ACCENT).G+.06,1),
            math.min((col or OC.ACCENT).B+.06,1))})
    end)
    b.MouseLeave:Connect(function()
        tw(b,TweenInfo.new(0.1),{BackgroundColor3=col or OC.ACCENT})
    end)
    return b
end

local function mkCard(parent, y, h)
    local card=Instance.new("Frame")
    card.BackgroundColor3=OC.CARD; card.BorderSizePixel=0
    card.Size=UDim2.new(1,-32,0,h or 80)
    card.Position=UDim2.new(0,16,0,y or 0); card.ZIndex=3; card.Parent=parent
    local cc=Instance.new("UICorner"); cc.CornerRadius=UDim.new(0,10); cc.Parent=card
    local cs=Instance.new("UIStroke"); cs.Color=OC.BORDER; cs.Thickness=1; cs.Parent=card
    return card
end

local function fireGrantPayload(remoteName, payload, logFn)
    -- Re-use GRANT engine's fireGrantProbe via G export
    if G.grant_attempt then
        -- Already confirmed — just fire the payload again
        local function findR(name)
            local t=nil
            local function sc(root)
                local ok,d=pcall(function() return root:GetDescendants() end)
                if not ok then return end
                for _,x in ipairs(d) do
                    if (x:IsA("RemoteEvent") or x:IsA("RemoteFunction"))
                    and x.Name==name then t=x; return end
                end
            end
            sc(RepS); if not t then sc(workspace) end; return t
        end
        local r=findR(remoteName)
        if r then
            local args=type(payload)=="table" and payload or {payload}
            pcall(function()
                if r:IsA("RemoteFunction") then r:InvokeServer(table.unpack(args))
                else r:FireServer(table.unpack(args)) end
            end)
            return true
        end
    end
    return false
end

-- Flash confirmed animation on status strip
local function flashConfirmed(text)
    STATUS_LBL.Text = text or "✓ GRANTED"
    STATUS_STRIP.BackgroundColor3 = Color3.fromRGB(20,60,20)
    STATUS_LBL.TextColor3 = OC.GREEN
    tw(STATUS_STRIP,TweenInfo.new(0.3),{BackgroundColor3=Color3.fromRGB(40,100,40)})
    task.delay(0.6,function()
        tw(STATUS_STRIP,TweenInfo.new(0.5),{BackgroundColor3=Color3.fromRGB(20,40,20)})
    end)
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PANEL BUILDERS — one per grant category
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- ── TOOLS & WEAPONS ────────────────────────────────────────────────────────────
local function buildToolsPanel(result)
    clearContent()
    TITLE_LBL.Text = "⚔ TOOLS & WEAPONS"

    -- ── Only show tools the SERVER confirmed granting ─────────────────────────
    -- Sources in priority order:
    -- 1. Items that appeared in Backpack AFTER the confirmed grant fire
    -- 2. Deltas from the grant probe that reference tool/item paths
    -- 3. Response data from the server
    -- DO NOT scan existing Backpack — that is the player's prior inventory

    local serverGranted = {}  -- tools confirmed as server-delivered
    local seen = {}

    local function addGranted(name, source)
        if not name or name=="" or name=="nil" or seen[name] then return end
        seen[name] = true
        table.insert(serverGranted, {name=name, source=source})
    end

    -- Pull from deltas — path changes that reference tool-like values
    for _,delta in ipairs(result.deltas or {}) do
        local pathL = (delta.path or ""):lower()
        local av    = delta.av or ""
        -- Only include if the delta path suggests something was added/changed
        -- and the value looks like an item name (not a number or bool)
        if av ~= "" and av ~= "nil" and av ~= "true" and av ~= "false"
        and not tonumber(av) then
            addGranted(av, "ServerDelta:"..delta.path)
        end
    end

    -- Pull from GRANT_RESULTS confirmed hits
    if G.GRANT_RESULTS then
        for _,gr in ipairs(G.GRANT_RESULTS) do
            if gr.category == "tools" then
                for _,hit in ipairs(gr.hits or {}) do
                    -- Only hits where server actually responded
                    if (hit.deltas or 0) > 0 or (hit.responses or 0) > 0 then
                        -- Extract item name from the probe tag
                        local tag = hit.payload or hit.tag or ""
                        local item = tostring(tag):match("give_(.+)") or
                                     tostring(tag):match("grant_(.+)") or
                                     tostring(tag):match("equip_(.+)")
                        if item then
                            -- Convert snake_case back to readable
                            local readable = item:gsub("_"," ")
                                               :gsub("(%a)([%w_']*)",
                                                function(a,b) return a:upper()..b end)
                            addGranted(readable, "GrantHit:"..hit.remote)
                        end
                    end
                    -- Also check deltas from hits
                    for _,d in ipairs(hit.deltas or {}) do
                        if d.av and not tonumber(d.av) and d.av~="true" and d.av~="false" then
                            addGranted(d.av, "HitDelta:"..d.path)
                        end
                    end
                end
                -- Evidence string — new format: "Server granted new tool(s): ToolName"
                if gr.bestPath and gr.bestPath.evidence then
                    local ev = gr.bestPath.evidence or ""
                    local toolName = ev:match("Server granted new tool%(s%):%s*(.+)")
                              or ev:match("Tool in Backpack:%s*(.+)")
                              or ev:match("Tool equipped:%s*(.+)")
                              or ev:match("Tool state change:%s*([^→]+)")
                    if toolName then
                        addGranted(toolName:match("^%s*(.-)%s*$"), "ServerConfirm")
                    end
                end
            end
        end
    end

    -- If grant path exists but no items detected, show requestable targets
    local availablePayloads = {}
    if #serverGranted == 0 then
        if G.GRANT_RESULTS and G.grant_payloads then
            for _,gr in ipairs(G.GRANT_RESULTS) do
                if gr.category == "tools" and gr.bestPath then
                    local probes = G.grant_payloads("tools", nil)
                    for _,p in ipairs(probes) do
                        local item = p.tag:match("give_(.+)") or p.tag:match("grant_(.+)")
                        if item then
                            local readable = item:gsub("_"," ")
                                :gsub("(%a)([%w_']*)",function(a,b) return a:upper()..b end)
                            table.insert(availablePayloads,{name=readable,tag=p.tag,payload=p.p})
                        end
                    end
                    break
                end
            end
        end
    end

    -- If still nothing, show a clear message — don't hallucinate items
    if #serverGranted == 0 and #availablePayloads == 0 then
        mkLabel("No server-granted items detected yet.", 11, OC.AMBER, CONTENT, 20)
        mkLabel(
            "GRANT found a path but the server hasn't\n"..
            "delivered any items yet.\n\n"..
            "Press ▶ GRANT below to request items\nfrom the server.\n\n"..
            "Items that the server grants will\nappear here after confirmation.",
            9, OC.MUTED, CONTENT, 50)

        -- Still show grant button to attempt delivery
        local grantBtn=mkGrantBtn("▶ REQUEST TOOL FROM SERVER", OC.GREEN, CONTENT, 200)
        grantBtn.MouseButton1Click:Connect(function()
            STATUS_LBL.Text="Requesting from server..."
            STATUS_LBL.TextColor3=OC.AMBER
            task.spawn(function()
                local bestRemote=nil
                if G.GRANT_RESULTS then
                    for _,gr in ipairs(G.GRANT_RESULTS) do
                        if gr.category=="tools" and gr.bestPath then
                            bestRemote=gr.bestPath.remote; break
                        end
                    end
                end
                if bestRemote then
                    local before={}
                    local bp=LP:FindFirstChildOfClass("Backpack")
                    if bp then for _,i in ipairs(bp:GetChildren()) do before[i.Name]=true end end
                    fireGrantPayload(bestRemote,
                        {action="give",player=LP.Name,userId=LP.UserId,grant=true})
                    task.wait(1.0)
                    local appeared={}
                    if bp then for _,i in ipairs(bp:GetChildren()) do
                        if not before[i.Name] then table.insert(appeared,i.Name) end
                    end end
                    if #appeared>0 then
                        flashConfirmed("✓ Server granted: "..table.concat(appeared,", "))
                    else
                        STATUS_LBL.Text="Fired — no new item detected yet"
                        STATUS_LBL.TextColor3=OC.MUTED
                    end
                else
                    STATUS_LBL.Text="⚠ No confirmed grant path — run GRANT tab first"
                    STATUS_LBL.TextColor3=OC.AMBER
                end
            end)
        end)
        return
    end

    -- Use confirmed server items OR available payloads for navigation
    local displayList = #serverGranted > 0 and serverGranted or availablePayloads
    local isConfirmed = #serverGranted > 0
    local idx = 1
    local total = #displayList

    -- Selection card
    local selCard = mkCard(CONTENT, 10, 90)

    -- Team colour dot
    local teamDot = Instance.new("Frame")
    teamDot.BackgroundColor3 = LP.Team and LP.Team.TeamColor.Color or OC.MUTED
    teamDot.BorderSizePixel=0
    teamDot.Size=UDim2.fromOffset(10,10)
    teamDot.Position=UDim2.fromOffset(12,10); teamDot.Parent=selCard
    local tdc=Instance.new("UICorner"); tdc.CornerRadius=UDim.new(1,0); tdc.Parent=teamDot

    local teamLbl=Instance.new("TextLabel")
    teamLbl.BackgroundTransparency=1; teamLbl.Font=Enum.Font.Code
    teamLbl.Text=LP.Team and LP.Team.Name or "Neutral"
    teamLbl.TextColor3=OC.MUTED; teamLbl.TextSize=8
    teamLbl.Size=UDim2.fromOffset(90,12); teamLbl.Position=UDim2.fromOffset(26,8)
    teamLbl.TextXAlignment=Enum.TextXAlignment.Left; teamLbl.Parent=selCard

    -- Source badge
    local srcBadge=Instance.new("Frame")
    srcBadge.BackgroundColor3=isConfirmed and OC.GREEN or OC.AMBER
    srcBadge.BorderSizePixel=0
    srcBadge.Size=UDim2.fromOffset(0,13); srcBadge.AutomaticSize=Enum.AutomaticSize.X
    srcBadge.Position=UDim2.new(1,-4,0,8); srcBadge.AnchorPoint=Vector2.new(1,0)
    srcBadge.Parent=selCard
    local sbc=Instance.new("UICorner"); sbc.CornerRadius=UDim.new(0,4); sbc.Parent=srcBadge
    mk2("UIPadding",{PaddingLeft=UDim.new(0,4),PaddingRight=UDim.new(0,4)},srcBadge)
    local srcLbl=Instance.new("TextLabel")
    srcLbl.BackgroundTransparency=1; srcLbl.Font=Enum.Font.GothamBold
    srcLbl.Text=isConfirmed and "SERVER CONFIRMED" or "AVAILABLE"
    srcLbl.TextColor3=Color3.fromRGB(8,8,12); srcLbl.TextSize=7
    srcLbl.Size=UDim2.fromOffset(0,13); srcLbl.AutomaticSize=Enum.AutomaticSize.X
    srcLbl.Parent=srcBadge

    local toolIcon=Instance.new("TextLabel")
    toolIcon.BackgroundTransparency=1; toolIcon.Font=Enum.Font.GothamBold
    toolIcon.Text="⚔"; toolIcon.TextColor3=OC.ACCENT; toolIcon.TextSize=28
    toolIcon.Size=UDim2.fromOffset(40,40); toolIcon.Position=UDim2.fromOffset(12,28)
    toolIcon.Parent=selCard

    local toolName=Instance.new("TextLabel")
    toolName.BackgroundTransparency=1; toolName.Font=Enum.Font.GothamBold
    toolName.TextColor3=OC.TEXT; toolName.TextSize=15
    toolName.Size=UDim2.new(1,-90,0,22); toolName.Position=UDim2.fromOffset(56,30)
    toolName.TextXAlignment=Enum.TextXAlignment.Left; toolName.Parent=selCard

    local sourceLbl=Instance.new("TextLabel")
    sourceLbl.BackgroundTransparency=1; sourceLbl.Font=Enum.Font.Code
    sourceLbl.TextColor3=OC.MUTED; sourceLbl.TextSize=8
    sourceLbl.Size=UDim2.new(1,-56,0,12); sourceLbl.Position=UDim2.fromOffset(56,54)
    sourceLbl.TextXAlignment=Enum.TextXAlignment.Left; sourceLbl.Parent=selCard

    local counterLbl=Instance.new("TextLabel")
    counterLbl.BackgroundTransparency=1; counterLbl.Font=Enum.Font.Code
    counterLbl.TextColor3=OC.MUTED; counterLbl.TextSize=9
    counterLbl.Size=UDim2.fromOffset(50,14); counterLbl.Position=UDim2.new(0,56,0,68)
    counterLbl.TextXAlignment=Enum.TextXAlignment.Left; counterLbl.Parent=selCard

    local function updateSel()
        local entry = displayList[idx]
        if not entry then return end
        toolName.Text  = entry.name or "?"
        sourceLbl.Text = entry.source or ""
        counterLbl.Text= tostring(idx).." / "..tostring(total)
        teamDot.BackgroundColor3 = LP.Team and LP.Team.TeamColor.Color or OC.MUTED
        teamLbl.Text = LP.Team and LP.Team.Name or "Neutral"
    end
    updateSel()

    -- Navigation arrows
    local prevBtn=mkArrowBtn("◀",CONTENT,16,114); local nextBtn=mkArrowBtn("▶",CONTENT,288,114)
    prevBtn.MouseButton1Click:Connect(function() idx=idx>1 and idx-1 or total; updateSel() end)
    nextBtn.MouseButton1Click:Connect(function() idx=idx<total and idx+1 or 1; updateSel() end)

    -- Dot indicators
    local dotRow=Instance.new("Frame")
    dotRow.BackgroundTransparency=1; dotRow.BorderSizePixel=0
    dotRow.Size=UDim2.new(1,-120,0,12); dotRow.Position=UDim2.new(0,58,0,118)
    dotRow.Parent=CONTENT
    local function rebuildDots()
        for _,c in ipairs(dotRow:GetChildren()) do c:Destroy() end
        local ll=Instance.new("UIListLayout")
        ll.FillDirection=Enum.FillDirection.Horizontal; ll.Padding=UDim.new(0,4)
        ll.HorizontalAlignment=Enum.HorizontalAlignment.Center
        ll.VerticalAlignment=Enum.VerticalAlignment.Center; ll.Parent=dotRow
        for i=1,math.min(total,8) do
            local dot=Instance.new("Frame"); dot.BorderSizePixel=0; dot.Parent=dotRow
            dot.Size=UDim2.fromOffset(i==idx and 14 or 6,6)
            dot.BackgroundColor3=i==idx and OC.ACCENT or OC.BORDER
            local dc=Instance.new("UICorner"); dc.CornerRadius=UDim.new(1,0); dc.Parent=dot
        end
    end
    rebuildDots()
    prevBtn.MouseButton1Click:Connect(rebuildDots)
    nextBtn.MouseButton1Click:Connect(rebuildDots)

    -- Validation status card
    local valCard=mkCard(CONTENT,142,46)
    do
        local pathType="UNCONFIRMED"; local pathCol=OC.AMBER
        local pathDesc="No server path found — run GRANT tab first"
        if G.GRANT_RESULTS then
            for _,gr in ipairs(G.GRANT_RESULTS) do
                if gr.category=="tools" and gr.bestPath then
                    pathType="GRANT CONFIRMED — score "..gr.bestPath.score
                    pathCol=OC.GREEN
                    pathDesc=gr.bestPath.remote.." via "..gr.bestPath.path
                    break
                end
            end
        end
        if G.BOUNDARY_RESULTS then
            for _,br in ipairs(G.BOUNDARY_RESULTS) do
                if br.level and br.level.severity<=1 then
                    pathType="L3 BOUNDARY — server trusts client"
                    pathCol=OC.GREEN; pathDesc=br.remote; break
                end
            end
        end
        local dot=Instance.new("Frame"); dot.BackgroundColor3=pathCol
        dot.BorderSizePixel=0; dot.Size=UDim2.fromOffset(8,8)
        dot.Position=UDim2.fromOffset(10,10); dot.Parent=valCard
        local dc=Instance.new("UICorner"); dc.CornerRadius=UDim.new(1,0); dc.Parent=dot
        local tl=Instance.new("TextLabel")
        tl.BackgroundTransparency=1; tl.Font=Enum.Font.GothamBold
        tl.Text=pathType; tl.TextColor3=pathCol; tl.TextSize=9
        tl.Size=UDim2.new(1,-24,0,13); tl.Position=UDim2.fromOffset(22,5)
        tl.TextXAlignment=Enum.TextXAlignment.Left; tl.Parent=valCard
        local dl=Instance.new("TextLabel")
        dl.BackgroundTransparency=1; dl.Font=Enum.Font.Code
        dl.Text=pathDesc; dl.TextColor3=OC.MUTED; dl.TextSize=8; dl.TextWrapped=true
        dl.Size=UDim2.new(1,-12,0,18); dl.Position=UDim2.fromOffset(6,22)
        dl.TextXAlignment=Enum.TextXAlignment.Left; dl.Parent=valCard
    end

    -- GRANT button — fires to server only, watches for NEW items
    local grantBtn=mkGrantBtn(
        isConfirmed and "▶ RE-GRANT FROM SERVER" or "▶ REQUEST FROM SERVER",
        OC.GREEN, CONTENT, 200)
    grantBtn.MouseButton1Click:Connect(function()
        local entry=displayList[idx]
        if not entry then return end

        local bestRemote=nil
        if G.GRANT_RESULTS then
            for _,gr in ipairs(G.GRANT_RESULTS) do
                if gr.category=="tools" and gr.bestPath then
                    bestRemote=gr.bestPath.remote; break
                end
            end
        end
        if not bestRemote then
            STATUS_LBL.Text="⚠ No server grant path — run GRANT tab first"
            STATUS_LBL.TextColor3=OC.AMBER; return
        end

        STATUS_LBL.Text="Requesting from server: "..entry.name
        STATUS_LBL.TextColor3=OC.AMBER

        task.spawn(function()
            -- Snapshot BEFORE — so we can detect what the server adds
            local before={}
            local bp=LP:FindFirstChildOfClass("Backpack")
            if bp then for _,i in ipairs(bp:GetChildren()) do before[i.Name]=true end end
            local ch=LP.Character
            if ch then for _,i in ipairs(ch:GetChildren()) do
                if i:IsA("Tool") then before[i.Name]=true end
            end end

            -- Fire to server with the item name
            local payload={
                action="give", item=entry.name,
                player=LP.Name, userId=LP.UserId,
                tool=entry.name, grant=true,
            }
            -- Also try the original confirmed payload if available
            if entry.payload then payload=entry.payload end

            fireGrantPayload(bestRemote, payload)

            -- Wait for server replication
            task.wait(1.0)

            -- Detect what the server actually added
            local appeared={}
            if bp then for _,i in ipairs(bp:GetChildren()) do
                if not before[i.Name] then table.insert(appeared,i.Name) end
            end end
            if ch then for _,i in ipairs(ch:GetChildren()) do
                if i:IsA("Tool") and not before[i.Name] then
                    table.insert(appeared,i.Name) end
            end end

            if #appeared>0 then
                flashConfirmed("✓ SERVER GRANTED: "..table.concat(appeared,", "))
                -- Add newly server-granted items to our confirmed list
                for _,name in ipairs(appeared) do
                    addGranted(name,"ServerDelivered")
                end
            else
                STATUS_LBL.Text="Fired — server may still be processing"
                STATUS_LBL.TextColor3=OC.MUTED
            end
        end)
    end)
end
    -- From character backpack
    local bp=LP:FindFirstChildOfClass("Backpack")
    if bp then
        for _,item in ipairs(bp:GetChildren()) do
            if item:IsA("Tool") then
                local found=false
                for _,t in ipairs(tools) do if t.name==item.Name then found=true;break end end
                if not found then table.insert(tools,{name=item.Name,instance=item}) end
            end
        end
    end
    -- From grant payloads in GRANT_RESULTS
    if G.GRANT_RESULTS then
        for _,gr in ipairs(G.GRANT_RESULTS) do
            if gr.category=="tools" and gr.bestPath then
                local payStr=gr.bestPath.payload or ""
                for word in tostring(payStr):gmatch("[A-Z][a-zA-Z]+") do
                    local found=false
                    for _,t in ipairs(tools) do if t.name==word then found=true;break end end
                    if not found and #word>2 then table.insert(tools,{name=word}) end
                end
            end
        end
    end
    -- Fallback
    if #tools==0 then
        for _,v in ipairs({"Sword","Gun","Bow","Staff","Shield"}) do
            table.insert(tools,{name=v})
        end
    end

    local idx = 1
    local total = #tools

    -- Team color detection
    local function getTeamColor()
        local team=LP.Team
        if team then return team.TeamColor.Color end
        return OC.ACCENT
    end

    -- Selection card
    local selCard = mkCard(CONTENT, 10, 90)
    local teamDot = Instance.new("Frame")
    teamDot.BackgroundColor3=getTeamColor(); teamDot.BorderSizePixel=0
    teamDot.Size=UDim2.fromOffset(12,12); teamDot.Position=UDim2.fromOffset(12,12); teamDot.Parent=selCard
    local tdc=Instance.new("UICorner"); tdc.CornerRadius=UDim.new(1,0); tdc.Parent=teamDot
    local teamLbl=Instance.new("TextLabel")
    teamLbl.BackgroundTransparency=1; teamLbl.Font=Enum.Font.Code
    teamLbl.Text=LP.Team and LP.Team.Name or "Neutral"
    teamLbl.TextColor3=OC.MUTED; teamLbl.TextSize=8
    teamLbl.Size=UDim2.fromOffset(80,14); teamLbl.Position=UDim2.fromOffset(28,10)
    teamLbl.TextXAlignment=Enum.TextXAlignment.Left; teamLbl.Parent=selCard

    local toolIcon=Instance.new("TextLabel")
    toolIcon.BackgroundTransparency=1; toolIcon.Font=Enum.Font.GothamBold
    toolIcon.Text="⚔"; toolIcon.TextColor3=OC.ACCENT; toolIcon.TextSize=28
    toolIcon.Size=UDim2.fromOffset(40,40); toolIcon.Position=UDim2.fromOffset(12,28)
    toolIcon.Parent=selCard

    local toolName=Instance.new("TextLabel")
    toolName.BackgroundTransparency=1; toolName.Font=Enum.Font.GothamBold
    toolName.TextColor3=OC.TEXT; toolName.TextSize=15
    toolName.Size=UDim2.new(1,-100,0,22); toolName.Position=UDim2.fromOffset(58,30)
    toolName.TextXAlignment=Enum.TextXAlignment.Left; toolName.Parent=selCard

    local counterLbl=Instance.new("TextLabel")
    counterLbl.BackgroundTransparency=1; counterLbl.Font=Enum.Font.Code
    counterLbl.TextColor3=OC.MUTED; counterLbl.TextSize=9
    counterLbl.Size=UDim2.fromOffset(60,14); counterLbl.Position=UDim2.new(1,-68,0,10)
    counterLbl.TextXAlignment=Enum.TextXAlignment.Right; counterLbl.Parent=selCard

    local function updateSel()
        local t=tools[idx]
        toolName.Text = t and t.name or "?"
        counterLbl.Text = tostring(idx).." / "..tostring(total)
        teamDot.BackgroundColor3 = getTeamColor()
        teamLbl.Text = LP.Team and LP.Team.Name or "Neutral"
    end
    updateSel()

    -- Arrow navigation
    local prevBtn = mkArrowBtn("◀", CONTENT, 16, 114)
    local nextBtn = mkArrowBtn("▶", CONTENT, 288, 114)
    local dotRow  = Instance.new("Frame")
    dotRow.BackgroundTransparency=1; dotRow.BorderSizePixel=0
    dotRow.Size=UDim2.new(1,-120,0,14); dotRow.Position=UDim2.new(0,58,0,118)
    dotRow.Parent=CONTENT

    local function rebuildDots()
        for _,c in ipairs(dotRow:GetChildren()) do c:Destroy() end
        local ll=Instance.new("UIListLayout"); ll.FillDirection=Enum.FillDirection.Horizontal
        ll.Padding=UDim.new(0,4); ll.HorizontalAlignment=Enum.HorizontalAlignment.Center
        ll.VerticalAlignment=Enum.VerticalAlignment.Center; ll.Parent=dotRow
        for i=1,math.min(total,8) do
            local dot=Instance.new("Frame")
            dot.BorderSizePixel=0; dot.Parent=dotRow
            dot.Size=UDim2.fromOffset(i==idx and 14 or 6,6)
            dot.BackgroundColor3=i==idx and OC.ACCENT or OC.BORDER
            local dc=Instance.new("UICorner"); dc.CornerRadius=UDim.new(1,0); dc.Parent=dot
        end
    end
    rebuildDots()

    prevBtn.MouseButton1Click:Connect(function()
        idx=idx>1 and idx-1 or total
        updateSel(); rebuildDots()
    end)
    nextBtn.MouseButton1Click:Connect(function()
        idx=idx<total and idx+1 or 1
        updateSel(); rebuildDots()
    end)

    -- Validation status card — shows what kind of server trust this grant has
    local valCard=mkCard(CONTENT,142,50)
    do
        local pathType="UNCONFIRMED"; local pathCol=OC.AMBER; local pathDesc="No server path found yet"
        -- Check BOUNDARY results
        if G.BOUNDARY_RESULTS then
            for _,br in ipairs(G.BOUNDARY_RESULTS) do
                if br.level and br.level.severity<=1 then
                    pathType="L3 BOUNDARY CONFIRMED"; pathCol=OC.GREEN
                    pathDesc="Server trusts client state — "..br.remote; break
                end
            end
        end
        -- Check VEX
        if pathType=="UNCONFIRMED" and G.VEX_SESSIONS then
            for _,vs2 in pairs(G.VEX_SESSIONS) do
                if vs2.finalPayload and vs2.finalDepth and vs2.finalDepth>=5 then
                    pathType="VEX PATH CONFIRMED"; pathCol=OC.GREEN
                    pathDesc="Deep execution path confirmed — depth "..vs2.finalDepth; break
                end
            end
        end
        -- Check AVD
        if pathType=="UNCONFIRMED" and G.AVD_FINDINGS then
            for _,f in ipairs(G.AVD_FINDINGS) do
                if f.vuln and f.vuln.id=="NO_VALID" then
                    pathType="AVD: NO VALIDATION"; pathCol=OC.AMBER
                    pathDesc="Remote has no server validation — "..f.remote; break
                end
            end
        end
        -- Check GRANT results
        if G.GRANT_RESULTS then
            for _,gr in ipairs(G.GRANT_RESULTS) do
                if gr.category=="tools" and gr.bestPath then
                    pathType="GRANT CONFIRMED"; pathCol=OC.GREEN
                    pathDesc="Probe score "..gr.bestPath.score.." — "..gr.bestPath.remote; break
                end
            end
        end
        local dot=Instance.new("Frame")
        dot.BackgroundColor3=pathCol; dot.BorderSizePixel=0
        dot.Size=UDim2.fromOffset(8,8); dot.Position=UDim2.fromOffset(10,10); dot.Parent=valCard
        local dc=Instance.new("UICorner"); dc.CornerRadius=UDim.new(1,0); dc.Parent=dot
        local tl=Instance.new("TextLabel")
        tl.BackgroundTransparency=1; tl.Font=Enum.Font.GothamBold
        tl.Text=pathType; tl.TextColor3=pathCol; tl.TextSize=9
        tl.Size=UDim2.new(1,-24,0,13); tl.Position=UDim2.fromOffset(22,6)
        tl.TextXAlignment=Enum.TextXAlignment.Left; tl.Parent=valCard
        local dl=Instance.new("TextLabel")
        dl.BackgroundTransparency=1; dl.Font=Enum.Font.Code
        dl.Text=pathDesc; dl.TextColor3=OC.MUTED; dl.TextSize=8; dl.TextWrapped=true
        dl.Size=UDim2.new(1,-12,0,22); dl.Position=UDim2.fromOffset(6,22)
        dl.TextXAlignment=Enum.TextXAlignment.Left; dl.Parent=valCard
    end

    -- GRANT button — server-only path
    local grantBtn=mkGrantBtn("▶ GRANT SELECTED TOOL", OC.GREEN, CONTENT, 206)
    grantBtn.MouseButton1Click:Connect(function()
        local t=tools[idx]
        if not t then return end

        -- Find best BOUNDARY-confirmed or AVD-confirmed remote for this category
        local bestRemote=nil; local bestPayload=nil
        if G.GRANT_RESULTS then
            for _,gr in ipairs(G.GRANT_RESULTS) do
                if gr.category=="tools" and gr.bestPath then
                    bestRemote=gr.bestPath.remote
                    bestPayload={
                        action="give", item=t.name,
                        player=LP.Name, userId=LP.UserId,
                        tool=t.name, grant=true,
                    }
                    break
                end
            end
        end

        if not bestRemote then
            STATUS_LBL.Text="⚠ No server-confirmed path — run GRANT first"
            STATUS_LBL.TextColor3=OC.AMBER; return
        end

        STATUS_LBL.Text="Sending to server: "..t.name
        STATUS_LBL.TextColor3=OC.AMBER

        task.spawn(function()
            -- Snapshot inventory BEFORE fire so we can detect what the server added
            local before={}
            local bp=LP:FindFirstChildOfClass("Backpack")
            if bp then for _,item in ipairs(bp:GetChildren()) do before[item.Name]=true end end
            local ch=LP.Character
            if ch then for _,item in ipairs(ch:GetChildren()) do
                if item:IsA("Tool") then before[item.Name]=true end
            end end

            local ok=fireGrantPayload(bestRemote, bestPayload)
            if not ok then
                STATUS_LBL.Text="⚠ Remote fire failed"; STATUS_LBL.TextColor3=OC.AMBER; return
            end

            -- Wait for server replication then check what appeared
            task.wait(0.8)
            local appeared={}
            if bp then for _,item in ipairs(bp:GetChildren()) do
                if not before[item.Name] then table.insert(appeared,item.Name) end
            end end
            if ch then for _,item in ipairs(ch:GetChildren()) do
                if item:IsA("Tool") and not before[item.Name] then
                    table.insert(appeared,item.Name) end
            end end

            if #appeared>0 then
                flashConfirmed("✓ SERVER GRANTED: "..table.concat(appeared,", "))
            else
                STATUS_LBL.Text="Fired — server processing (no new item detected yet)"
                STATUS_LBL.TextColor3=OC.MUTED
            end
        end)
    end)
end

-- ── CURRENCY / ECONOMY ─────────────────────────────────────────────────────────
local function buildCurrencyPanel(result)
    clearContent()
    TITLE_LBL.Text = "$ CURRENCY & ECONOMY"

    -- Collect currency names from deltas + leaderstats + GRANT hits
    local currencies = {}
    local seenC = {}
    local function addCurr(name, extra)
        if not name or seenC[name] then return end
        seenC[name]=true
        local entry = extra or {}; entry.name=name
        table.insert(currencies, entry)
    end

    local currKeys = {"coins","cash","gems","gold","tokens","credits","money",
                      "points","bucks","diamonds","stars","crystals","currency"}
    for _,delta in ipairs(result.deltas or {}) do
        local pathL=(delta.path or ""):lower()
        for _,ck in ipairs(currKeys) do
            if pathL:find(ck) then
                local cname=delta.path:match("[^%.]+$") or ck
                addCurr(cname,{path=delta.path,current=tonumber(delta.av) or 0})
                break
            end
        end
    end
    -- Fallback from leaderstats
    local ls=LP:FindFirstChild("leaderstats")
    if ls then
        for _,v in ipairs(ls:GetChildren()) do
            if v:IsA("IntValue") or v:IsA("NumberValue") then
                local found=false
                for _,c2 in ipairs(currencies) do if c2.name==v.Name then found=true;break end end
                if not found then
                    local ok2,val=pcall(function() return v.Value end)
                    table.insert(currencies,{name=v.Name,path=v:GetFullName(),
                        current=ok2 and val or 0, instance=v})
                end
            end
        end
    end
    if #currencies==0 then
        for _,n in ipairs({"Coins","Cash","Gems"}) do
            table.insert(currencies,{name=n,current=0})
        end
    end

    local idx=1; local total=#currencies
    local pendingAmount=nil

    -- Currency selector card
    local selCard=mkCard(CONTENT,10,70)
    local currIcon=Instance.new("TextLabel")
    currIcon.BackgroundTransparency=1; currIcon.Font=Enum.Font.GothamBold
    currIcon.Text="$"; currIcon.TextColor3=OC.AMBER; currIcon.TextSize=26
    currIcon.Size=UDim2.fromOffset(36,36); currIcon.Position=UDim2.fromOffset(12,18)
    currIcon.Parent=selCard

    local currName=Instance.new("TextLabel")
    currName.BackgroundTransparency=1; currName.Font=Enum.Font.GothamBold
    currName.TextColor3=OC.TEXT; currName.TextSize=15
    currName.Size=UDim2.new(1,-110,0,22); currName.Position=UDim2.fromOffset(52,10)
    currName.TextXAlignment=Enum.TextXAlignment.Left; currName.Parent=selCard

    local currVal=Instance.new("TextLabel")
    currVal.BackgroundTransparency=1; currVal.Font=Enum.Font.Code
    currVal.TextColor3=OC.GREEN; currVal.TextSize=11
    currVal.Size=UDim2.new(1,-52,0,16); currVal.Position=UDim2.fromOffset(52,34)
    currVal.TextXAlignment=Enum.TextXAlignment.Left; currVal.Parent=selCard

    local ctrLbl=Instance.new("TextLabel")
    ctrLbl.BackgroundTransparency=1; ctrLbl.Font=Enum.Font.Code
    ctrLbl.TextColor3=OC.MUTED; ctrLbl.TextSize=9
    ctrLbl.Size=UDim2.fromOffset(55,14); ctrLbl.Position=UDim2.new(1,-60,0,8)
    ctrLbl.TextXAlignment=Enum.TextXAlignment.Right; ctrLbl.Parent=selCard

    local function updateCurrSel()
        local c=currencies[idx]
        currName.Text=c and c.name or "?"
        currVal.Text=c and ("Current: "..tostring(c.current)) or ""
        ctrLbl.Text=tostring(idx).." / "..tostring(total)
    end
    updateCurrSel()

    -- Navigation
    local prevB=mkArrowBtn("◀",CONTENT,16,92); local nextB=mkArrowBtn("▶",CONTENT,288,92)
    prevB.MouseButton1Click:Connect(function() idx=idx>1 and idx-1 or total; updateCurrSel() end)
    nextB.MouseButton1Click:Connect(function() idx=idx<total and idx+1 or 1; updateCurrSel() end)

    -- Amount label
    mkLabel("AMOUNT TO ADD", 9, OC.MUTED, CONTENT, 140, 16, Enum.TextXAlignment.Left)

    -- Amount input
    local amtBox=Instance.new("TextBox")
    amtBox.BackgroundColor3=OC.CARD; amtBox.BorderSizePixel=0
    amtBox.Font=Enum.Font.Code; amtBox.TextColor3=OC.WHITE; amtBox.TextSize=18
    amtBox.PlaceholderText="Enter amount..."; amtBox.PlaceholderColor3=OC.MUTED
    amtBox.Text=""; amtBox.ClearTextOnFocus=false
    amtBox.TextXAlignment=Enum.TextXAlignment.Center
    amtBox.Size=UDim2.new(1,-32,0,44); amtBox.Position=UDim2.new(0,16,0,156)
    amtBox.ZIndex=4; amtBox.Parent=CONTENT
    local abc=Instance.new("UICorner"); abc.CornerRadius=UDim.new(0,10); abc.Parent=amtBox
    local abs2=Instance.new("UIStroke"); abs2.Color=OC.BORDER; abs2.Parent=amtBox

    amtBox.Focused:Connect(function()
        tw(amtBox,TweenInfo.new(0.1),{})
        local abs3=amtBox:FindFirstChildOfClass("UIStroke")
        if abs3 then abs3.Color=OC.ACCENT; abs3.Thickness=2 end
    end)
    amtBox.FocusLost:Connect(function()
        local abs3=amtBox:FindFirstChildOfClass("UIStroke")
        if abs3 then abs3.Color=OC.BORDER; abs3.Thickness=1 end
        pendingAmount=tonumber(amtBox.Text)
    end)

    -- Preset buttons
    local presetRow=Instance.new("Frame")
    presetRow.BackgroundTransparency=1; presetRow.BorderSizePixel=0
    presetRow.Size=UDim2.new(1,-32,0,26); presetRow.Position=UDim2.new(0,16,0,206)
    presetRow.Parent=CONTENT
    local pll=Instance.new("UIListLayout"); pll.FillDirection=Enum.FillDirection.Horizontal
    pll.Padding=UDim.new(0,6); pll.Parent=presetRow

    for _,amt in ipairs({100,1000,10000,99999}) do
        local pb=Instance.new("TextButton")
        pb.BackgroundColor3=OC.CARD; pb.BorderSizePixel=0
        pb.Font=Enum.Font.Code; pb.Text=amt>=1000 and (amt/1000).."k" or tostring(amt)
        pb.TextColor3=OC.MUTED; pb.TextSize=9
        pb.Size=UDim2.fromOffset(52,22); pb.ZIndex=4; pb.Parent=presetRow
        local pc=Instance.new("UICorner"); pc.CornerRadius=UDim.new(0,6); pc.Parent=pb
        local ps=Instance.new("UIStroke"); ps.Color=OC.BORDER; ps.Parent=pb
        pb.MouseButton1Click:Connect(function()
            amtBox.Text=tostring(amt); pendingAmount=amt
            pb.BackgroundColor3=OC.ACCENT; pb.TextColor3=Color3.fromRGB(8,8,12)
            task.delay(0.3,function()
                if pb.Parent then
                    pb.BackgroundColor3=OC.CARD; pb.TextColor3=OC.MUTED
                end
            end)
        end)
    end

    -- GRANT button
    local grantBtn=mkGrantBtn("▶ ADD CURRENCY", OC.AMBER, CONTENT, 244)
    grantBtn.MouseButton1Click:Connect(function()
        local c=currencies[idx]
        local amt=pendingAmount or tonumber(amtBox.Text)
        if not c or not amt or amt<=0 then
            STATUS_LBL.Text="⚠ Select currency and enter an amount"
            STATUS_LBL.TextColor3=OC.AMBER; return
        end

        STATUS_LBL.Text=("Adding %s %s..."):format(tostring(amt),c.name)
        STATUS_LBL.TextColor3=OC.AMBER

        task.spawn(function()
            local bestRemote=nil
            if G.GRANT_RESULTS then
                for _,gr in ipairs(G.GRANT_RESULTS) do
                    if gr.category=="currency" and gr.bestPath then
                        bestRemote=gr.bestPath.remote; break
                    end
                end
            end
            if bestRemote then
                local payload={action="add",currency=c.name,amount=amt,
                    userId=LP.UserId,player=LP.Name}
                fireGrantPayload(bestRemote,payload)
                task.wait(0.3)
                -- Update local display
                if c.instance then
                    local ok3,_ =pcall(function()
                        c.instance.Value=c.instance.Value+amt
                        c.current=c.instance.Value
                    end)
                end
                flashConfirmed(("✓ +%s %s sent"):format(tostring(amt),c.name))
                updateCurrSel()
            else
                flashConfirmed("⚠ No currency grant path found")
                STATUS_LBL.TextColor3=OC.AMBER
            end
        end)
    end)
end


-- Export shared UI primitives for 30b_grantui.lua
G._grantui = {
    ROOT           = ROOT,
    SGUI           = SGUI,
    CONTENT        = CONTENT,
    TITLE_LBL      = TITLE_LBL,
    STATUS_LBL     = STATUS_LBL,
    STATUS_STRIP   = STATUS_STRIP,
    OC             = OC,
    clearContent   = clearContent,
    flashConfirmed = flashConfirmed,
    mkLabel        = mkLabel,
    mkArrowBtn     = mkArrowBtn,
    mkGrantBtn     = mkGrantBtn,
    mkCard         = mkCard,
    fireGrantPayload=fireGrantPayload,
    buildToolsPanel   = buildToolsPanel,
    buildCurrencyPanel= buildCurrencyPanel,
}
