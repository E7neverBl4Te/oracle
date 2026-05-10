-- Oracle // 30b_grantui.lua
-- GRANT UI Part B — Items · GUI Unlock · showGrantUI entry point
local G      = ...
local LP     = G.LP
local RepS   = G.RepS
local vs     = G.vs

-- Pull shared UI from 30a_grantui.lua
local _gui          = G._grantui
local ROOT          = _gui.ROOT
local SGUI          = _gui.SGUI
local CONTENT       = _gui.CONTENT
local TITLE_LBL     = _gui.TITLE_LBL
local STATUS_LBL    = _gui.STATUS_LBL
local STATUS_STRIP  = _gui.STATUS_STRIP
local OC            = _gui.OC
local clearContent  = _gui.clearContent
local flashConfirmed= _gui.flashConfirmed
local mkLabel       = _gui.mkLabel
local mkArrowBtn    = _gui.mkArrowBtn
local mkGrantBtn    = _gui.mkGrantBtn
local mkCard        = _gui.mkCard
local fireGrantPayload = _gui.fireGrantPayload

-- ── ITEMS & INVENTORY ──────────────────────────────────────────────────────────
local function buildItemsPanel(result)
    clearContent()
    TITLE_LBL.Text = "[I] ITEMS & INVENTORY"

    local items={}
    local seenI={}
    local function addItem(name,extra)
        if not name or name=="" or name=="nil" or seenI[name] then return end
        seenI[name]=true; local e=extra or {}; e.name=name; table.insert(items,e)
    end
    for _,delta in ipairs(result.deltas or {}) do
        if delta.av then addItem(delta.av,{path=delta.path}) end
    end
    if G.GRANT_RESULTS then
        for _,gr in ipairs(G.GRANT_RESULTS) do
            if gr.category=="items" then
                for _,hit in ipairs(gr.hits or {}) do
                    for _,d in ipairs(hit.deltas or {}) do
                        if d.av then addItem(d.av,{path=d.path}) end
                    end
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
    itemIcon.Text="[I]"; itemIcon.TextColor3=OC.GREEN; itemIcon.TextSize=28
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
    TITLE_LBL.Text = "[G] GUI & UI UNLOCK"

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
