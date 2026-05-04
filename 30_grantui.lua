-- Oracle // 30_grantui.lua
-- GRANT UI — In-Game Result Interface
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
-- It is separate from Oracle's window so it persists while Oracle is minimised
local SGUI = Instance.new("ScreenGui")
SGUI.Name             = "OracleGrantUI"
SGUI.ResetOnSpawn     = false
SGUI.IgnoreGuiInset   = true
SGUI.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
SGUI.Enabled          = false

-- Try PlayerGui first, fall back to CoreGui
local ok = pcall(function()
    SGUI.Parent = LP:WaitForChild("PlayerGui", 5)
end)
if not ok then
    pcall(function() SGUI.Parent = game:GetService("CoreGui") end)
end

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

    -- Collect tool names from deltas + backpack
    local tools = {}
    -- From confirmed deltas
    for _,delta in ipairs(result.deltas or {}) do
        if delta.av and delta.av ~= "" and delta.av ~= "nil" then
            table.insert(tools, {name=delta.av, path=delta.path})
        end
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

    -- Info card
    local infoCard=mkCard(CONTENT,142,50)
    local infoLbl=Instance.new("TextLabel")
    infoLbl.BackgroundTransparency=1; infoLbl.Font=Enum.Font.Code
    infoLbl.TextColor3=OC.MUTED; infoLbl.TextSize=9; infoLbl.TextWrapped=true
    infoLbl.Text="Server-confirmed grant path.\nTool will be placed in your Backpack."
    infoLbl.Size=UDim2.new(1,-16,1,-8); infoLbl.Position=UDim2.fromOffset(8,4)
    infoLbl.TextXAlignment=Enum.TextXAlignment.Left; infoLbl.Parent=infoCard

    -- GRANT button
    local grantBtn=mkGrantBtn("▶ GRANT SELECTED TOOL", OC.GREEN, CONTENT, 206)
    grantBtn.MouseButton1Click:Connect(function()
        local t=tools[idx]
        if not t then return end
        STATUS_LBL.Text="Granting "..t.name.."..."
        STATUS_LBL.TextColor3=OC.AMBER

        task.spawn(function()
            -- Use best confirmed remote + payload from GRANT
            local bestRemote=nil; local bestPayload=nil
            if G.GRANT_RESULTS then
                for _,gr in ipairs(G.GRANT_RESULTS) do
                    if gr.category=="tools" and gr.bestPath then
                        bestRemote=gr.bestPath.remote
                        bestPayload={action="give",item=t.name,player=LP.Name,
                            userId=LP.UserId}
                        break
                    end
                end
            end
            -- If tool instance exists, equip directly
            if t.instance then
                local clone=t.instance:Clone()
                clone.Parent=LP.Backpack or LP:FindFirstChildOfClass("Backpack")
                flashConfirmed("✓ "..t.name.." granted (local)")
            elseif bestRemote then
                fireGrantPayload(bestRemote, bestPayload)
                task.wait(0.5)
                flashConfirmed("✓ "..t.name.." sent to server")
            else
                flashConfirmed("⚠ No server path — check GRANT tab")
                STATUS_LBL.TextColor3=OC.AMBER
            end
        end)
    end)

    -- FIRE ALL button (grants all found tools)
    local allBtn=mkGrantBtn("▶ GRANT ALL FOUND TOOLS", OC.MUTED, CONTENT, 258)
    allBtn.MouseButton1Click:Connect(function()
        task.spawn(function()
            for _,t in ipairs(tools) do
                if t.instance then
                    local clone=t.instance:Clone()
                    clone.Parent=LP.Backpack or LP:FindFirstChildOfClass("Backpack")
                elseif G.GRANT_RESULTS then
                    for _,gr in ipairs(G.GRANT_RESULTS) do
                        if gr.category=="tools" and gr.bestPath then
                            fireGrantPayload(gr.bestPath.remote,
                                {action="give",item=t.name,player=LP.Name,userId=LP.UserId})
                            break
                        end
                    end
                end
                task.wait(0.12)
            end
            flashConfirmed("✓ All "..#tools.." tool(s) granted")
        end)
    end)
end

-- ── CURRENCY / ECONOMY ─────────────────────────────────────────────────────────
local function buildCurrencyPanel(result)
    clearContent()
    TITLE_LBL.Text = "💰 CURRENCY & ECONOMY"

    -- Collect currency names from deltas
    local currencies = {}
    local currKeys = {"coins","cash","gems","gold","tokens","credits","money",
                      "points","bucks","diamonds","stars","crystals","currency"}
    for _,delta in ipairs(result.deltas or {}) do
        local pathL=delta.path:lower()
        for _,ck in ipairs(currKeys) do
            if pathL:find(ck) then
                local cname=delta.path:match("[^%.]+$") or ck
                local found=false
                for _,c2 in ipairs(currencies) do if c2.name==cname then found=true;break end end
                if not found then
                    table.insert(currencies,{
                        name=cname,
                        path=delta.path,
                        current=tonumber(delta.av) or 0,
                    })
                end
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
    currIcon.Text="💰"; currIcon.TextColor3=OC.AMBER; currIcon.TextSize=26
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

-- ── ITEMS & INVENTORY ──────────────────────────────────────────────────────────
local function buildItemsPanel(result)
    clearContent()
    TITLE_LBL.Text = "📦 ITEMS & INVENTORY"

    local items={}
    for _,delta in ipairs(result.deltas or {}) do
        if delta.av and delta.av~="" and delta.av~="nil" then
            table.insert(items,{name=delta.av,path=delta.path})
        end
    end
    if G.GRANT_RESULTS then
        for _,gr in ipairs(G.GRANT_RESULTS) do
            if gr.category=="items" and gr.bestPath then
                local pStr=tostring(gr.bestPath.payload or "")
                for word in pStr:gmatch('"([^"]+)"') do
                    local f=false; for _,it in ipairs(items) do if it.name==word then f=true;break end end
                    if not f and #word>1 then table.insert(items,{name=word}) end
                end
            end
        end
    end
    if #items==0 then
        for _,n in ipairs({"Health Potion","Key","Gem","Chest","Material"}) do
            table.insert(items,{name=n})
        end
    end

    local idx=1; local total=#items
    local selCard=mkCard(CONTENT,10,80)

    local itemIcon=Instance.new("TextLabel")
    itemIcon.BackgroundTransparency=1; itemIcon.Font=Enum.Font.GothamBold
    itemIcon.Text="📦"; itemIcon.TextColor3=OC.GREEN; itemIcon.TextSize=28
    itemIcon.Size=UDim2.fromOffset(40,40); itemIcon.Position=UDim2.fromOffset(12,20)
    itemIcon.Parent=selCard

    local itemName=Instance.new("TextLabel")
    itemName.BackgroundTransparency=1; itemName.Font=Enum.Font.GothamBold
    itemName.TextColor3=OC.TEXT; itemName.TextSize=14
    itemName.Size=UDim2.new(1,-100,0,22); itemName.Position=UDim2.fromOffset(58,18)
    itemName.TextXAlignment=Enum.TextXAlignment.Left; itemName.Parent=selCard

    local itemSub=Instance.new("TextLabel")
    itemSub.BackgroundTransparency=1; itemSub.Font=Enum.Font.Code
    itemSub.TextColor3=OC.MUTED; itemSub.TextSize=9
    itemSub.Size=UDim2.new(1,-58,0,14); itemSub.Position=UDim2.fromOffset(58,44)
    itemSub.TextXAlignment=Enum.TextXAlignment.Left; itemSub.Parent=selCard

    local ctrL=Instance.new("TextLabel")
    ctrL.BackgroundTransparency=1; ctrL.Font=Enum.Font.Code
    ctrL.TextColor3=OC.MUTED; ctrL.TextSize=9
    ctrL.Size=UDim2.fromOffset(55,14); ctrL.Position=UDim2.new(1,-60,0,8)
    ctrL.TextXAlignment=Enum.TextXAlignment.Right; ctrL.Parent=selCard

    local qtyBox=Instance.new("TextBox")
    qtyBox.BackgroundColor3=OC.SURFACE; qtyBox.BorderSizePixel=0
    qtyBox.Font=Enum.Font.Code; qtyBox.TextColor3=OC.WHITE; qtyBox.TextSize=11
    qtyBox.PlaceholderText="qty"; qtyBox.PlaceholderColor3=OC.MUTED
    qtyBox.Text="1"; qtyBox.ClearTextOnFocus=false
    qtyBox.TextXAlignment=Enum.TextXAlignment.Center
    qtyBox.Size=UDim2.fromOffset(40,20); qtyBox.Position=UDim2.new(1,-58,0,48)
    qtyBox.ZIndex=4; qtyBox.Parent=selCard
    local qc=Instance.new("UICorner"); qc.CornerRadius=UDim.new(0,5); qc.Parent=qtyBox
    local qs=Instance.new("UIStroke"); qs.Color=OC.BORDER; qs.Parent=qtyBox

    local function updateItem()
        local it=items[idx]
        itemName.Text=it and it.name or "?"
        itemSub.Text=it and (it.path or "Confirmed by server") or ""
        ctrL.Text=tostring(idx).." / "..tostring(total)
    end
    updateItem()

    local prevB=mkArrowBtn("◀",CONTENT,16,104); local nextB=mkArrowBtn("▶",CONTENT,288,104)
    prevB.MouseButton1Click:Connect(function() idx=idx>1 and idx-1 or total; updateItem() end)
    nextB.MouseButton1Click:Connect(function() idx=idx<total and idx+1 or 1; updateItem() end)

    -- Info
    local infoCard=mkCard(CONTENT,152,40)
    local infoL=Instance.new("TextLabel")
    infoL.BackgroundTransparency=1; infoL.Font=Enum.Font.Code
    infoL.TextColor3=OC.MUTED; infoL.TextSize=9; infoL.TextWrapped=true
    infoL.Text="Server will add item to your inventory.\nQuantity field sets how many."
    infoL.Size=UDim2.new(1,-16,1,-8); infoL.Position=UDim2.fromOffset(8,4)
    infoL.TextXAlignment=Enum.TextXAlignment.Left; infoL.Parent=infoCard

    local grantBtn=mkGrantBtn("▶ GRANT SELECTED ITEM", OC.GREEN, CONTENT, 204)
    grantBtn.MouseButton1Click:Connect(function()
        local it=items[idx]; local qty=math.max(1,tonumber(qtyBox.Text) or 1)
        if not it then return end
        STATUS_LBL.Text="Granting "..it.name.."..."; STATUS_LBL.TextColor3=OC.AMBER
        task.spawn(function()
            local bestRemote=nil
            if G.GRANT_RESULTS then
                for _,gr in ipairs(G.GRANT_RESULTS) do
                    if gr.category=="items" and gr.bestPath then
                        bestRemote=gr.bestPath.remote; break
                    end
                end
            end
            if bestRemote then
                fireGrantPayload(bestRemote,
                    {action="giveItem",itemId=it.name,amount=qty,userId=LP.UserId})
                task.wait(0.3)
                flashConfirmed(("✓ %s ×%d sent to server"):format(it.name,qty))
            else
                flashConfirmed("⚠ No item grant path — check GRANT tab")
                STATUS_LBL.TextColor3=OC.AMBER
            end
        end)
    end)

    local allBtn=mkGrantBtn("▶ GRANT ALL FOUND ITEMS", OC.MUTED, CONTENT, 254)
    allBtn.MouseButton1Click:Connect(function()
        local bestRemote=nil
        if G.GRANT_RESULTS then
            for _,gr in ipairs(G.GRANT_RESULTS) do
                if gr.category=="items" and gr.bestPath then bestRemote=gr.bestPath.remote; break end
            end
        end
        if not bestRemote then flashConfirmed("⚠ No grant path found"); return end
        task.spawn(function()
            for _,it in ipairs(items) do
                fireGrantPayload(bestRemote,{action="giveItem",itemId=it.name,
                    amount=1,userId=LP.UserId})
                task.wait(0.1)
            end
            flashConfirmed("✓ All "..#items.." item(s) sent")
        end)
    end)
end

-- ── GUI UNLOCK ─────────────────────────────────────────────────────────────────
local function buildGuiPanel(result)
    clearContent()
    TITLE_LBL.Text = "🖥 GUI & UI UNLOCK"

    -- Collect GUIs from deltas + PlayerGui scan
    local foundGuis={}
    local pg=LP:FindFirstChildOfClass("PlayerGui")
    if pg then
        for _,gui in ipairs(pg:GetChildren()) do
            if gui:IsA("ScreenGui") and gui~=SGUI then
                -- Flag hidden or interesting GUIs
                local n=gui.Name:lower()
                local isInteresting=n:find("admin") or n:find("dev") or n:find("secret") or
                    n:find("panel") or n:find("hidden") or not gui.Enabled
                table.insert(foundGuis,{
                    name=gui.Name,
                    instance=gui,
                    enabled=gui.Enabled,
                    interesting=isInteresting,
                })
            end
        end
    end
    -- Sort — interesting first
    table.sort(foundGuis,function(a,b)
        if a.interesting~=b.interesting then return a.interesting end
        return a.name<b.name
    end)
    if #foundGuis==0 then
        table.insert(foundGuis,{name="No GUIs found — run Discovery",enabled=false})
    end

    mkLabel("FOUND GUIs — click to toggle",9,OC.MUTED,CONTENT,10,16,
        Enum.TextXAlignment.Left)

    local listFrame=Instance.new("ScrollingFrame")
    listFrame.BackgroundTransparency=1; listFrame.BorderSizePixel=0
    listFrame.Size=UDim2.new(1,-32,0,280); listFrame.Position=UDim2.new(0,16,0,28)
    listFrame.ScrollBarThickness=4; listFrame.ScrollBarImageColor3=OC.BORDER
    listFrame.CanvasSize=UDim2.fromScale(0,0); listFrame.AutomaticCanvasSize=Enum.AutomaticSize.Y
    listFrame.ScrollingDirection=Enum.ScrollingDirection.Y
    listFrame.ZIndex=3; listFrame.Parent=CONTENT
    local lll=Instance.new("UIListLayout"); lll.Padding=UDim.new(0,5); lll.Parent=listFrame

    for i,gui in ipairs(foundGuis) do
        local row=Instance.new("Frame")
        row.BackgroundColor3=gui.interesting and Color3.fromRGB(22,14,30) or OC.CARD
        row.BorderSizePixel=0
        row.Size=UDim2.new(1,0,0,38); row.ZIndex=4; row.LayoutOrder=i; row.Parent=listFrame
        local rc2=Instance.new("UICorner"); rc2.CornerRadius=UDim.new(0,8); rc2.Parent=row
        local rs2=Instance.new("UIStroke")
        rs2.Color=gui.interesting and OC.ACCENT or OC.BORDER; rs2.Parent=row

        local dot=Instance.new("Frame")
        dot.BackgroundColor3=gui.enabled and OC.GREEN or OC.MUTED
        dot.BorderSizePixel=0; dot.Size=UDim2.fromOffset(8,8)
        dot.Position=UDim2.fromOffset(10,15); dot.ZIndex=5; dot.Parent=row
        local dc=Instance.new("UICorner"); dc.CornerRadius=UDim.new(1,0); dc.Parent=dot

        local nameLbl=Instance.new("TextLabel")
        nameLbl.BackgroundTransparency=1; nameLbl.Font=Enum.Font.GothamBold
        nameLbl.Text=gui.name; nameLbl.TextColor3=gui.interesting and OC.ACCENT or OC.TEXT
        nameLbl.TextSize=10
        nameLbl.Size=UDim2.new(1,-80,0,16); nameLbl.Position=UDim2.fromOffset(24,5)
        nameLbl.TextXAlignment=Enum.TextXAlignment.Left; nameLbl.ZIndex=5; nameLbl.Parent=row

        local statLbl=Instance.new("TextLabel")
        statLbl.BackgroundTransparency=1; statLbl.Font=Enum.Font.Code
        statLbl.Text=gui.enabled and "VISIBLE" or "HIDDEN"
        statLbl.TextColor3=gui.enabled and OC.GREEN or OC.MUTED; statLbl.TextSize=8
        statLbl.Size=UDim2.new(1,-24,0,12); statLbl.Position=UDim2.fromOffset(24,22)
        statLbl.TextXAlignment=Enum.TextXAlignment.Left; statLbl.ZIndex=5; statLbl.Parent=row

        local toggleBtn=Instance.new("TextButton")
        toggleBtn.BackgroundColor3=gui.enabled and Color3.fromRGB(40,60,30) or OC.SURFACE
        toggleBtn.BorderSizePixel=0; toggleBtn.ZIndex=5
        toggleBtn.Font=Enum.Font.GothamBold
        toggleBtn.Text=gui.enabled and "Hide" or "Show"
        toggleBtn.TextColor3=gui.enabled and OC.GREEN or OC.MUTED; toggleBtn.TextSize=9
        toggleBtn.Size=UDim2.fromOffset(52,22); toggleBtn.Position=UDim2.new(1,-58,0.5,-11)
        toggleBtn.Parent=row
        local tc2=Instance.new("UICorner"); tc2.CornerRadius=UDim.new(0,6); tc2.Parent=toggleBtn

        if gui.instance then
            toggleBtn.MouseButton1Click:Connect(function()
                gui.enabled=not gui.enabled
                gui.instance.Enabled=gui.enabled
                dot.BackgroundColor3=gui.enabled and OC.GREEN or OC.MUTED
                statLbl.Text=gui.enabled and "VISIBLE" or "HIDDEN"
                statLbl.TextColor3=gui.enabled and OC.GREEN or OC.MUTED
                toggleBtn.Text=gui.enabled and "Hide" or "Show"
                toggleBtn.TextColor3=gui.enabled and OC.GREEN or OC.MUTED
                toggleBtn.BackgroundColor3=gui.enabled and Color3.fromRGB(40,60,30) or OC.SURFACE
                row.BackgroundColor3=gui.enabled and Color3.fromRGB(14,24,10) or OC.CARD
                flashConfirmed(gui.enabled and
                    ("✓ "..gui.name.." shown") or
                    ("✓ "..gui.name.." hidden"))
            end)
        end
    end

    -- Grant All Hidden
    local grantBtn=mkGrantBtn("▶ SHOW ALL FOUND GUIs", OC.ACCENT, CONTENT, 318)
    grantBtn.MouseButton1Click:Connect(function()
        for _,gui in ipairs(foundGuis) do
            if gui.instance then
                gui.instance.Enabled=true; gui.enabled=true
            end
        end
        flashConfirmed("✓ All GUIs enabled")
    end)
end

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- SHOW IMGUI — main entry point called by GRANT tab
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

local function showGrantUI(category, result)
    SGUI.Enabled = true
    ROOT.Visible = true
    ROOT.Size    = UDim2.fromOffset(340, 0)
    tw(ROOT, TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        {Size=UDim2.fromOffset(340, 440)})

    STATUS_LBL.Text="Grant confirmed — browsing results"
    STATUS_LBL.TextColor3=OC.GREEN
    STATUS_STRIP.BackgroundColor3=Color3.fromRGB(20,40,20)

    if     category=="tools"       then buildToolsPanel(result)
    elseif category=="currency"    then buildCurrencyPanel(result)
    elseif category=="items"       then buildItemsPanel(result)
    elseif category=="gui"         then buildGuiPanel(result)
    else
        clearContent()
        TITLE_LBL.Text="⬡ GRANT RESULT"
        mkLabel("Category: "..category, 11, OC.TEXT, CONTENT, 20)
        mkLabel("Evidence: "..(result.evidence or "confirmed"), 9, OC.MUTED, CONTENT, 46)
        mkLabel("Remote: "..(result.remote or "?"), 9, OC.GREEN, CONTENT, 62)
    end
end

-- Export for GRANT tab to call
G.showGrantUI = showGrantUI
G.GRANTUI_ROOT = ROOT
G.GRANTUI_SGUI = SGUI

-- Hook into GRANT results — auto-show IMGUI when grant is confirmed
-- Patch the GRANT button in 29_grant.lua result card
task.defer(function()
    -- Watch for GRANT_RESULTS changes and wire up Show IMGUI button in GRANT tab
    -- The GRANT tab will call G.showGrantUI directly after its result card appears
end)

print("[Oracle] GRANT UI loaded — G.showGrantUI available")
