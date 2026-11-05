-- ============================================================
--  FREEMASON v3.0  |  + Car Body Fling  +  Teleport Tab
-- ============================================================

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

-- ─── REMOTES ────────────────────────────────────────────────
local ListWeaponRemote = ReplicatedStorage:FindFirstChild("ListWeaponRemote")
local BackpackRemote   = ReplicatedStorage:FindFirstChild("BackpackRemote")

-- ─── CONFIG ─────────────────────────────────────────────────
local CFG = {
    ListDelay     = 0.22,
    StoreWait     = 3.6,
    CycleCooldown = 1.5,
    GrabWait      = 0.5,
    EquipWait     = 1.0,
    ListPrice     = 999999,
    AutoReEquip   = true,
    Blacklist = {
        ["Fists"]=true,["Fist"]=true,["Phone"]=true,
        ["Car Keys"]=true,["Bandage"]=true,["762s"]=true,
        ["556s"]=true,["Extended"]=true,["T shirt"]=true,
        ["Combat"]=true,["Weight"]=true,
    },
}

-- ─── SHOP MAP ───────────────────────────────────────────────
local shopGUIs = {
    ["Bronx Market"]   = "Bronx Market 2",
    ["Tattoo Shop"]    = "Bronx TATTOOS",
    ["Open Trunk"]     = "TRUNK STORAGE",
    ["BRONX PAWNING"]  = "Bronx PAWNING",
    ["BRONX CLOTHING"] = "Bronx CLOTHING",
    ["Gas Station"]    = "ShopGUI",
    ["EXOTIC DEALER"]  = "ThaShop",
}
local shopList = {}
for k in pairs(shopGUIs) do table.insert(shopList, k) end
table.sort(shopList)

-- ─── DUPE STATE ─────────────────────────────────────────────
local DupeActive          = false
local currentSession      = 0
local masterObject        = nil
local GhostCache          = nil
local totalStored         = 0
local dupeBatchCount      = 0
local dupeTimer           = 0
local previousMarketCount = 0
local PERMANENT_IDS       = {}
local statCycles          = 0
local sessionStart        = nil

-- ─── RAINBOW STATE ──────────────────────────────────────────
getgenv().activeRainbowThreads = getgenv().activeRainbowThreads or {}
getgenv().rainbowConnections   = getgenv().rainbowConnections   or {}
getgenv().originalStates       = getgenv().originalStates       or {}
local rainbowOn = false

-- ─── PLAYER / ACTION STATE ──────────────────────────────────
local SelectedPlayer = nil
local spectateOn     = false
local bringOn        = false
local bringActive    = false

-- ─── CAR FLING STATE ────────────────────────────────────────
-- Mirrored from main script. 50k vertical guarantees anti-fly detection → kick.
getgenv().carBugEnabled = false
getgenv().carBugTarget  = nil
local carFlingOn        = false
local carFlingHits      = 0
local CAR_FLING_H_SPEED = 15000   -- horizontal magnitude (matches main script)
local CAR_FLING_V_SPEED = 50000   -- vertical launch — triggers Roblox anti-fly kick
local CAR_BV_LIFETIME   = 0.08    -- BodyVelocity lifetime in seconds

-- ─── GUI STATE ──────────────────────────────────────────────
local activeTab = "DUPE"
local logLines  = {}
local MAX_LOG   = 18

-- ═══════════════════════════════════════════════════════════
--  UTILITY
-- ═══════════════════════════════════════════════════════════
local function GetItemCount(name)
    local n = 0
    local bp = LocalPlayer:FindFirstChild("Backpack")
    if bp then for _,v in pairs(bp:GetChildren()) do if v.Name==name then n+=1 end end end
    if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild(name) then n+=1 end
    return n
end

local function GetMarketCount(toolName)
    local n, market = 0, ReplicatedStorage:FindFirstChild("MarketItems")
    if market then
        for _,item in ipairs(market:GetChildren()) do
            if item.Name==toolName
            and item:FindFirstChild("owner")
            and item.owner.Value==LocalPlayer.Name then n+=1 end
        end
    end
    return n
end

local function RestoreGhostItems()
    local bp, char = LocalPlayer:FindFirstChild("Backpack"), LocalPlayer.Character
    if not bp or not GhostCache then return end
    pcall(function()
        if GhostCache.Parent~=bp and GhostCache.Parent~=char then GhostCache.Parent=bp end
    end)
end

local function CollectExisting()
    local market = ReplicatedStorage:FindFirstChild("MarketItems")
    if market then
        for _,item in ipairs(market:GetChildren()) do
            if item:FindFirstChild("owner") and item.owner.Value==LocalPlayer.Name then
                local id = item:GetAttribute("SpecialId") or item:GetAttribute("UUID")
                if id then PERMANENT_IDS[id]=true end
            end
        end
    end
end
CollectExisting()

local function FormatTime(s)
    return string.format("%d:%02d", math.floor(s/60), s%60)
end

local function getPlayerByName(name)
    for _,p in ipairs(Players:GetPlayers()) do
        if p.Name==name or p.DisplayName==name then return p end
    end
    return nil
end

local function buildPlayerList()
    local list = {"None"}
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            table.insert(list, p.DisplayName~=p.Name
                and p.Name.." ("..p.DisplayName..")"
                or p.Name)
        end
    end
    return list
end

local AddLog  -- forward ref
local actionRowRefs = {}

-- ═══════════════════════════════════════════════════════════
--  CAR BODY FLING ENGINE
--  Mirrored from main script (auto clean red money bank updated and fling.txt)
--  Upgraded: task.wait() loop (every frame), 50k V to trigger anti-fly kick
-- ═══════════════════════════════════════════════════════════
local function startCarFlingLoop(targetPlayer)
    getgenv().carBugEnabled = true
    task.spawn(function()
        local pl = Players
        local lp = pl.LocalPlayer

        while getgenv().carBugEnabled do
            task.wait()  -- every frame, no throttle — matches main script

            local c = lp.Character
            if not c or not c:FindFirstChild("HumanoidRootPart") then continue end

            -- validate target still in server
            local tp = pl:FindFirstChild(targetPlayer)
            if not tp then
                if AddLog then AddLog("warn", "Car Fling: target left the server") end
                getgenv().carBugEnabled = false
                if actionRowRefs.carFlingToggleCb then actionRowRefs.carFlingToggleCb(false) end
                if actionRowRefs.playersPanelCarFlingSync then actionRowRefs.playersPanelCarFlingSync(false) end
                break
            end
            if not tp.Character or not tp.Character:FindFirstChild("HumanoidRootPart") then continue end

            -- find first unoccupied car in CivCars
            local civCars = workspace:FindFirstChild("CivCars")
            if not civCars then continue end
            local car = nil
            for _, m in ipairs(civCars:GetChildren()) do
                if not m:IsA("Model") then continue end
                local seat = m:FindFirstChild("DriveSeat")
                if seat and not seat.Occupant then car = m break end
            end
            if not car then continue end

            local driveSeat = car:FindFirstChild("DriveSeat")
            if not driveSeat or driveSeat.Occupant then continue end

            -- unlock car: sit LP to mark usable, then bail immediately
            if not car:GetAttribute("Usable") or car:GetAttribute("Usable") == false then
                local myHum = c:FindFirstChildOfClass("Humanoid")
                if myHum then
                    pcall(function() driveSeat:Sit(myHum) end)
                    car:SetAttribute("Usable", true)
                    task.wait(1)
                    pcall(function()
                        myHum:ChangeState(Enum.HumanoidStateType.Jumping)
                        myHum.Jump = true
                        myHum.Sit  = false
                    end)
                    task.wait(0.08)
                end
            end

            task.wait()  -- settle one tick before repositioning

            -- re-validate after unlock delay
            local freshTarget = pl:FindFirstChild(targetPlayer)
            if not freshTarget or not freshTarget.Character then continue end
            local freshHRP = freshTarget.Character:FindFirstChild("HumanoidRootPart")
            if not freshHRP then continue end

            -- ensure PrimaryPart exists
            if not car.PrimaryPart then
                local body = car:FindFirstChild("Body")
                if body then
                    car.PrimaryPart = body:FindFirstChild("#Weight")
                        or body:FindFirstChildOfClass("BasePart")
                end
                if not car.PrimaryPart then
                    car.PrimaryPart = car:FindFirstChildOfClass("BasePart")
                end
            end
            if not car.PrimaryPart then continue end

            -- teleport car directly onto target
            pcall(function()
                car:SetPrimaryPartCFrame(freshHRP.CFrame + Vector3.new(0, 0.5, 0))
            end)

            -- strip any existing forces so nothing fights the launch
            for _, inst in ipairs(freshHRP:GetChildren()) do
                if inst:IsA("BodyVelocity")
                or inst:IsA("BodyForce")
                or inst:IsA("LinearVelocity")
                or inst:IsA("BodyAngularVelocity")
                or inst:IsA("AngularVelocity") then
                    inst:Destroy()
                end
            end

            -- LAUNCH:
            --   15k horizontal (random direction) + 50k vertical
            --   50k vertical sends target out of map ceiling → Roblox anti-fly kicks them
            local flingBV        = Instance.new("BodyVelocity")
            flingBV.MaxForce     = Vector3.new(1e9, 1e9, 1e9)
            local angle          = math.random(0, 359)
            local hx             = math.cos(math.rad(angle)) * CAR_FLING_H_SPEED
            local hz             = math.sin(math.rad(angle)) * CAR_FLING_H_SPEED
            flingBV.Velocity     = Vector3.new(hx, CAR_FLING_V_SPEED, hz)
            flingBV.Parent       = freshHRP
            task.delay(CAR_BV_LIFETIME, function()
                if flingBV and flingBV.Parent then flingBV:Destroy() end
            end)

            carFlingHits += 1
            if AddLog then AddLog("ok", "Fling #"..carFlingHits.." → "..targetPlayer) end
            if actionRowRefs.carFlingHitLabel then
                actionRowRefs.carFlingHitLabel.Text = "HITS: "..carFlingHits
            end
        end
    end)
end

local function stopCarFling()
    getgenv().carBugEnabled = false
end

-- ═══════════════════════════════════════════════════════════
--  PLAYER ACTIONS
-- ═══════════════════════════════════════════════════════════
local function doSpectate(on)
    spectateOn = on
    if on then
        if SelectedPlayer and SelectedPlayer.Character
        and SelectedPlayer.Character:FindFirstChild("Humanoid") then
            workspace.CurrentCamera.CameraSubject = SelectedPlayer.Character.Humanoid
            if AddLog then AddLog("info","Spectating: "..SelectedPlayer.Name) end
        else
            spectateOn = false
            if AddLog then AddLog("warn","Spectate: no valid target") end
            return false
        end
    else
        if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
            workspace.CurrentCamera.CameraSubject = LocalPlayer.Character.Humanoid
        end
        if AddLog then AddLog("info","Spectate off") end
    end
    return true
end

local function doBring(on)
    bringOn = on
    if on then
        if not SelectedPlayer then
            bringOn = false
            if AddLog then AddLog("warn","Bring: no target selected") end
            return false
        end
        local target = SelectedPlayer
        bringActive = true
        task.spawn(function()
            while bringOn and bringActive do
                local tChar  = target and target.Character
                local tRoot  = tChar and tChar:FindFirstChild("HumanoidRootPart")
                local myHRP  = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                if not tRoot or not myHRP then
                    bringOn=false; bringActive=false
                    if AddLog then AddLog("warn","Bring: target lost") end
                    if actionRowRefs.bringToggleCb then actionRowRefs.bringToggleCb(false) end
                    break
                end
                local tHum = tChar:FindFirstChildOfClass("Humanoid")
                if tHum then tHum.Sit=false end
                task.wait()
                pcall(function() tRoot.CFrame=myHRP.CFrame+Vector3.new(3,1,0) end)
                task.wait(0.1)
            end
            bringActive=false
        end)
        if AddLog then AddLog("info","Bringing: "..target.Name) end
    else
        bringActive=false
        if AddLog then AddLog("info","Bring off") end
    end
    return true
end

local function doViewInventory()
    if not SelectedPlayer then
        if AddLog then AddLog("warn","Inventory: no target") end; return
    end
    local bp = SelectedPlayer:FindFirstChild("Backpack")
    if not bp then
        if AddLog then AddLog("warn","Inventory: backpack not visible") end; return
    end
    local items = {}
    for _,i in ipairs(bp:GetChildren()) do
        if i:IsA("Tool") then table.insert(items,i.Name) end
    end
    if SelectedPlayer.Character then
        for _,i in ipairs(SelectedPlayer.Character:GetChildren()) do
            if i:IsA("Tool") then table.insert(items,i.Name.." [EQ]") end
        end
    end
    if AddLog then
        if #items>0 then AddLog("ok",SelectedPlayer.Name..": "..table.concat(items,", "))
        else AddLog("info",SelectedPlayer.Name.."'s backpack is empty") end
    end
end

-- ═══════════════════════════════════════════════════════════
--  RAINBOW GUNS
-- ═══════════════════════════════════════════════════════════
local function storeOriginal(p)
    if not getgenv().originalStates[p] then
        getgenv().originalStates[p]={Color=p.Color,Material=p.Material,Transparency=p.Transparency}
    end
end
local function startRainbow(tool)
    if getgenv().activeRainbowThreads[tool] then return end
    local parts={}
    for _,p in ipairs(tool:GetDescendants()) do
        if p:IsA("BasePart") then storeOriginal(p); table.insert(parts,p) end
    end
    if #parts==0 then return end
    local stopped=false
    getgenv().activeRainbowThreads[tool]=function() stopped=true end
    task.spawn(function()
        for _,p in ipairs(parts) do p.Material=Enum.Material.Neon; p.Transparency=0 end
        local hue=0
        while not stopped do
            hue=(hue+0.04)%1
            local color=Color3.fromHSV(hue,1,1)
            for _,p in ipairs(parts) do if p and p.Parent then p.Color=color end end
            task.wait(0.03)
        end
    end)
end
local function stopAllRainbows()
    for _,stopper in pairs(getgenv().activeRainbowThreads) do stopper() end
    for p,s in pairs(getgenv().originalStates) do
        if p and p.Parent then p.Color=s.Color; p.Material=s.Material; p.Transparency=s.Transparency end
    end
    getgenv().originalStates={}; getgenv().activeRainbowThreads={}
end
local function setupAdminGuns(state)
    local gunsFolder=workspace:FindFirstChild("GUNS")
    if not gunsFolder then return end
    local validGunNames={}
    for _,gun in ipairs(gunsFolder:GetChildren()) do validGunNames[gun.Name]=true end
    if state then
        local bp,char=LocalPlayer.Backpack,LocalPlayer.Character
        if bp   then for _,t in ipairs(bp:GetChildren())   do if t:IsA("Tool") and validGunNames[t.Name] then startRainbow(t) end end end
        if char then for _,t in ipairs(char:GetChildren()) do if t:IsA("Tool") and validGunNames[t.Name] then startRainbow(t) end end end
        table.insert(getgenv().rainbowConnections,
            LocalPlayer.Backpack.ChildAdded:Connect(function(t)
                if t:IsA("Tool") and validGunNames[t.Name] then startRainbow(t) end
            end))
        table.insert(getgenv().rainbowConnections,
            LocalPlayer.CharacterAdded:Connect(function(c)
                c.ChildAdded:Connect(function(t)
                    if t:IsA("Tool") and validGunNames[t.Name] then startRainbow(t) end
                end)
            end))
    else
        stopAllRainbows()
        for _,c in ipairs(getgenv().rainbowConnections) do c:Disconnect() end
        getgenv().rainbowConnections={}
    end
end

-- ═══════════════════════════════════════════════════════════
--  GUI
-- ═══════════════════════════════════════════════════════════
local ScreenGui=Instance.new("ScreenGui")
ScreenGui.Name="Freemason"; ScreenGui.ResetOnSpawn=false
ScreenGui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling; ScreenGui.IgnoreGuiInset=true
if gethui then ScreenGui.Parent=gethui()
elseif syn and syn.protect_gui then syn.protect_gui(ScreenGui); ScreenGui.Parent=game.CoreGui
else pcall(function() ScreenGui.Parent=game.CoreGui end)
    if not ScreenGui.Parent then ScreenGui.Parent=LocalPlayer.PlayerGui end
end

local C = {
    BG        = Color3.fromRGB(11,  10,  18),
    Card      = Color3.fromRGB(21,  18,  34),
    Input     = Color3.fromRGB(9,   8,   16),
    Accent    = Color3.fromRGB(139, 92,  246),
    AccentDim = Color3.fromRGB(32,  20,  58),
    Green     = Color3.fromRGB(34,  197, 94),
    Yellow    = Color3.fromRGB(245, 158, 11),
    Blue      = Color3.fromRGB(96,  165, 250),
    Orange    = Color3.fromRGB(251, 146, 60),
    TextPri   = Color3.fromRGB(240, 240, 240),
    TextSec   = Color3.fromRGB(138, 138, 154),
    TextDim   = Color3.fromRGB(74,  74,  90),
    Border    = Color3.fromRGB(42,  36,  64),
    BorderAcc = Color3.fromRGB(78,  52,  142),
    White     = Color3.fromRGB(255, 255, 255),
    DropBG    = Color3.fromRGB(15,  13,  26),
    DropHover = Color3.fromRGB(36,  28,  60),
}

local WIN_W, WIN_H = 460, 560
local WIN_SCALE = 0.78

local function Make(cls,props,parent)
    local o=Instance.new(cls)
    for k,v in pairs(props) do o[k]=v end
    if parent then o.Parent=parent end
    return o
end
local function MakeFrame(p,par)
    p.BackgroundColor3=p.BackgroundColor3 or C.Card
    p.BorderSizePixel=p.BorderSizePixel or 0
    return Make("Frame",p,par)
end
local function MakeLabel(p,par)
    p.BackgroundTransparency=p.BackgroundTransparency or 1
    p.BorderSizePixel=p.BorderSizePixel or 0
    p.Font=p.Font or Enum.Font.GothamBold
    p.TextColor3=p.TextColor3 or C.TextPri
    p.TextSize=p.TextSize or 12
    p.TextXAlignment=p.TextXAlignment or Enum.TextXAlignment.Left
    return Make("TextLabel",p,par)
end
local function MakeButton(p,par)
    p.BackgroundColor3=p.BackgroundColor3 or C.AccentDim
    p.BorderSizePixel=p.BorderSizePixel or 0
    p.Font=p.Font or Enum.Font.GothamBold
    p.TextColor3=p.TextColor3 or C.Accent
    p.TextSize=p.TextSize or 11
    p.AutoButtonColor=false
    return Make("TextButton",p,par)
end
local function MakeInput(p,par)
    p.BackgroundColor3=p.BackgroundColor3 or C.Input
    p.BorderSizePixel=p.BorderSizePixel or 0
    p.Font=p.Font or Enum.Font.Code
    p.TextColor3=p.TextColor3 or C.TextPri
    p.TextSize=p.TextSize or 11
    return Make("TextBox",p,par)
end
local function Stroke(par,col,th)
    local s=Instance.new("UIStroke")
    s.Color=col or C.Border; s.Thickness=th or 1; s.Parent=par; return s
end
local function Corner(par,r)
    local c=Instance.new("UICorner")
    c.CornerRadius=UDim.new(0,r or 4); c.Parent=par; return c
end
local function Pad(par,t,b,l,r)
    local p=Instance.new("UIPadding")
    p.PaddingTop=UDim.new(0,t or 6); p.PaddingBottom=UDim.new(0,b or 6)
    p.PaddingLeft=UDim.new(0,l or 10); p.PaddingRight=UDim.new(0,r or 10)
    p.Parent=par; return p
end

-- ── WINDOW ──────────────────────────────────────────────────
local Win=MakeFrame({
    Size=UDim2.new(0,WIN_W,0,WIN_H),
    AnchorPoint=Vector2.new(0.5,0),
    Position=UDim2.new(0.5,0,0.5,-WIN_H*WIN_SCALE/2),
    BackgroundColor3=C.BG,ClipsDescendants=true,
},ScreenGui)
Corner(Win,10); Stroke(Win,C.Accent,1.2)
Make("UIScale",{Scale=WIN_SCALE},Win)
MakeFrame({Size=UDim2.new(1,0,0,2),BackgroundColor3=C.Accent,ZIndex=10},Win)

local TitleBar=MakeFrame({
    Size=UDim2.new(1,0,0,32),Position=UDim2.new(0,0,0,2),
    BackgroundColor3=Color3.fromRGB(16,12,30),
},Win)
MakeLabel({Size=UDim2.new(1,-90,1,0),Position=UDim2.new(0,12,0,0),Text="⬡  FREEMASON  v3.0",TextSize=12,ZIndex=5},TitleBar)
local CloseBtn=MakeButton({Size=UDim2.new(0,24,0,20),Position=UDim2.new(1,-28,0.5,-10),Text="✕",TextSize=12,BackgroundColor3=Color3.fromRGB(52,30,96),TextColor3=C.Accent,ZIndex=10},TitleBar)
Corner(CloseBtn,5)
local MinBtn=MakeButton({Size=UDim2.new(0,24,0,20),Position=UDim2.new(1,-56,0.5,-10),Text="−",TextSize=14,BackgroundColor3=C.Card,TextColor3=C.TextSec,ZIndex=10},TitleBar)
Corner(MinBtn,5)


-- Window drag.
do
	local dragging, dragStart, startPos = false, nil, nil
	TitleBar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, Win.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			Win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

local StatusBar=MakeFrame({Size=UDim2.new(1,0,0,24),Position=UDim2.new(0,0,0,34),BackgroundColor3=Color3.fromRGB(9,8,15)},Win)
local StatusDot=MakeFrame({Size=UDim2.new(0,7,0,7),Position=UDim2.new(0,10,0.5,-3.5),BackgroundColor3=C.Yellow},StatusBar)
Corner(StatusDot,4)
local StatusLabel=MakeLabel({Size=UDim2.new(0,70,1,0),Position=UDim2.new(0,23,0,0),Text="IDLE",TextSize=10,TextColor3=C.Yellow},StatusBar)
local ItemPill=MakeLabel({Size=UDim2.new(0,150,1,0),Position=UDim2.new(0,96,0,0),Text="NO ITEM",TextSize=10,TextColor3=C.TextDim},StatusBar)
local CountLabel=MakeLabel({Size=UDim2.new(0,100,1,0),Position=UDim2.new(1,-106,0,0),Text="STORED: 0",TextSize=10,TextColor3=C.Accent,Font=Enum.Font.Code,TextXAlignment=Enum.TextXAlignment.Right},StatusBar)

local TabBar=MakeFrame({Size=UDim2.new(1,0,0,26),Position=UDim2.new(0,0,0,58),BackgroundColor3=Color3.fromRGB(14,12,24)},Win)
Stroke(TabBar,C.Border,1)

-- BLACKLIST replaced with TELEPORT
local TABS = {"DUPE","RAINBOW","MARKET","SETTINGS","TELEPORT"}
local TabBtns={}
for i,name in ipairs(TABS) do
    local w=1/#TABS
    TabBtns[name]=MakeButton({Size=UDim2.new(w,-1,1,0),Position=UDim2.new(w*(i-1),0,0,0),Text=name,TextSize=9,BackgroundColor3=Color3.fromRGB(14,12,24),TextColor3=C.TextDim},TabBar)
end

local ContentArea=MakeFrame({Size=UDim2.new(1,0,1,-88),Position=UDim2.new(0,0,0,84),BackgroundColor3=C.BG,ClipsDescendants=true},Win)
local Panels={}
local function NewPanel(name)
    local p=MakeFrame({Size=UDim2.new(1,0,1,0),BackgroundColor3=C.BG,Visible=false},ContentArea)
    Panels[name]=p; return p
end
local function SecLabel(text,parent,yPos)
    local row=MakeFrame({Size=UDim2.new(1,-24,0,16),Position=UDim2.new(0,12,0,yPos),BackgroundColor3=C.BG},parent)
    MakeFrame({Size=UDim2.new(0,3,0,9),Position=UDim2.new(0,0,0.5,-4.5),BackgroundColor3=C.Accent},row)
    MakeLabel({Size=UDim2.new(1,-12,1,0),Position=UDim2.new(0,10,0,0),Text=text:upper(),TextSize=8,TextColor3=C.TextDim},row)
    MakeFrame({Size=UDim2.new(1,-10,0,1),Position=UDim2.new(0,10,1,0),BackgroundColor3=C.Border},row)
    return row
end

-- ═══════════════════════════════════════════════════════════
--  PLAYER DROPDOWN COMPONENT
-- ═══════════════════════════════════════════════════════════
local function MakePlayerDropdown(parent,yPos,onSelect)
    local DROPDOWN_H=32; local LIST_ITEM_H=28; local MAX_VISIBLE=6
    local header=MakeButton({Size=UDim2.new(1,-24,0,DROPDOWN_H),Position=UDim2.new(0,12,0,yPos),Text="",TextSize=11,BackgroundColor3=C.Card,TextColor3=C.TextPri,ZIndex=5},parent)
    Corner(header,4); Stroke(header,C.Border,1)
    MakeLabel({Size=UDim2.new(0,20,1,0),Position=UDim2.new(0,10,0,0),Text="👤",TextSize=13,TextXAlignment=Enum.TextXAlignment.Center,ZIndex=6},header)
    local headerText=MakeLabel({Size=UDim2.new(1,-56,1,0),Position=UDim2.new(0,34,0,0),Text="None",TextSize=11,TextColor3=C.TextSec,Font=Enum.Font.GothamBold,ZIndex=6},header)
    local chevron=MakeLabel({Size=UDim2.new(0,18,1,0),Position=UDim2.new(1,-22,0,0),Text="▾",TextSize=12,TextColor3=C.TextDim,TextXAlignment=Enum.TextXAlignment.Center,ZIndex=6},header)
    MakeLabel({Size=UDim2.new(0,90,0,14),Position=UDim2.new(1,-102,0.5,-7),Text="[RSHIFT] REFRESH",TextSize=7,Font=Enum.Font.Code,TextColor3=C.TextDim,TextXAlignment=Enum.TextXAlignment.Right,ZIndex=6},header)
    local listFrame=Make("Frame",{Size=UDim2.new(1,-24,0,0),Position=UDim2.new(0,12,0,yPos+DROPDOWN_H+2),BackgroundColor3=C.DropBG,BorderSizePixel=0,ClipsDescendants=true,Visible=false,ZIndex=20},parent)
    Corner(listFrame,4); Stroke(listFrame,C.BorderAcc,1)
    local listScroll=Make("ScrollingFrame",{Size=UDim2.new(1,0,1,0),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=C.Border,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y,ZIndex=21},listFrame)
    Make("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,1),Parent=listScroll})
    local isOpen=false; local selected="None"
    local function closeList()
        isOpen=false; chevron.Text="▾"
        TweenService:Create(listFrame,TweenInfo.new(0.12),{Size=UDim2.new(1,-24,0,0)}):Play()
        task.delay(0.13,function() listFrame.Visible=false end)
        Stroke(header,C.Border,1)
    end
    local function buildItems(list)
        for _,v in pairs(listScroll:GetChildren()) do if v:IsA("TextButton") or v:IsA("Frame") then v:Destroy() end end
        for idx,name in ipairs(list) do
            local isNone=name=="None"
            local btn=MakeButton({Size=UDim2.new(1,0,0,LIST_ITEM_H),Text="",BackgroundColor3=name==selected and Color3.fromRGB(36,24,66) or C.DropBG,ZIndex=22,LayoutOrder=idx},listScroll)
            local dot=MakeFrame({Size=UDim2.new(0,4,0,4),Position=UDim2.new(0,8,0.5,-2),BackgroundColor3=name==selected and C.Accent or C.DropBG,ZIndex=23},btn)
            Corner(dot,2)
            MakeLabel({Size=UDim2.new(1,-26,1,0),Position=UDim2.new(0,18,0,0),Text=isNone and "— None —" or name,TextSize=11,Font=Enum.Font.GothamBold,TextColor3=isNone and C.TextDim or (name==selected and C.Accent or C.TextSec),ZIndex=23},btn)
            btn.MouseEnter:Connect(function() if name~=selected then TweenService:Create(btn,TweenInfo.new(0.08),{BackgroundColor3=C.DropHover}):Play() end end)
            btn.MouseLeave:Connect(function() if name~=selected then TweenService:Create(btn,TweenInfo.new(0.08),{BackgroundColor3=C.DropBG}):Play() end end)
            btn.MouseButton1Click:Connect(function()
                selected=name
                headerText.Text=name=="None" and "None" or name
                headerText.TextColor3=name=="None" and C.TextDim or C.TextPri
                closeList(); if onSelect then onSelect(name) end; buildItems(list)
            end)
        end
    end
    local lastList=buildPlayerList()
    local function refresh()
        lastList=buildPlayerList()
        local s=Instance.new("UIStroke"); s.Color=C.Green; s.Thickness=1; s.Parent=header
        task.delay(0.5,function() s:Destroy(); Stroke(header,isOpen and C.BorderAcc or C.Border,1) end)
        if isOpen then buildItems(lastList); listFrame.Size=UDim2.new(1,-24,0,math.min(#lastList,MAX_VISIBLE)*LIST_ITEM_H+2) end
    end
    local function openList(list)
        isOpen=true; chevron.Text="▴"
        buildItems(list)
        listFrame.Size=UDim2.new(1,-24,0,0); listFrame.Visible=true; Stroke(header,C.BorderAcc,1)
        TweenService:Create(listFrame,TweenInfo.new(0.15),{Size=UDim2.new(1,-24,0,math.min(#list,MAX_VISIBLE)*LIST_ITEM_H+2)}):Play()
    end
    header.MouseButton1Click:Connect(function()
        lastList=buildPlayerList()
        if isOpen then closeList() else openList(lastList) end
    end)
    return {frame=header,list=listFrame,refresh=refresh,getSelected=function() return selected end}
end

-- ═══════════════════════════════════════════════════════════
--  PANEL: DUPE
-- ═══════════════════════════════════════════════════════════
local DupePanel=NewPanel("DUPE")
local DupeScroll=Make("ScrollingFrame",{
    Size=UDim2.new(1,0,1,0),BackgroundTransparency=1,BorderSizePixel=0,
    ScrollBarThickness=3,ScrollBarImageColor3=C.Border,
    CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,
    ScrollingDirection=Enum.ScrollingDirection.Y,
},DupePanel)
Make("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,0),Parent=DupeScroll})

local DupeContainer=MakeFrame({Size=UDim2.new(1,0,0,600),BackgroundColor3=C.BG,LayoutOrder=1},DupeScroll)

-- item card
SecLabel("Current Target",DupeContainer,8)
local ItemCard=MakeFrame({Size=UDim2.new(1,-24,0,46),Position=UDim2.new(0,12,0,30),BackgroundColor3=C.Card},DupeContainer)
Corner(ItemCard,4); Stroke(ItemCard,C.BorderAcc,1)
local ItemIcon=MakeLabel({Size=UDim2.new(0,32,0,32),Position=UDim2.new(0,8,0.5,-16),Text="⚔",TextSize=18,TextXAlignment=Enum.TextXAlignment.Center,BackgroundColor3=C.AccentDim,BackgroundTransparency=0},ItemCard)
Corner(ItemIcon,4); Stroke(ItemIcon,C.BorderAcc,1)
local ItemNameLabel=MakeLabel({Size=UDim2.new(1,-110,0,18),Position=UDim2.new(0,48,0,6),Text="No Item Equipped",TextSize=13,Font=Enum.Font.GothamBold},ItemCard)
local ItemMetaLabel=MakeLabel({Size=UDim2.new(1,-110,0,14),Position=UDim2.new(0,48,0,26),Text="Equip an item to begin",TextSize=9,Font=Enum.Font.Gotham,TextColor3=C.TextSec},ItemCard)
local ItemBadge=MakeLabel({Size=UDim2.new(0,60,0,18),Position=UDim2.new(1,-68,0.5,-9),Text="READY",TextSize=8,Font=Enum.Font.GothamBold,TextColor3=C.Green,TextXAlignment=Enum.TextXAlignment.Center,BackgroundColor3=Color3.fromRGB(10,40,22),BackgroundTransparency=0},ItemCard)
Corner(ItemBadge,3); Stroke(ItemBadge,Color3.fromRGB(20,80,44),1)

-- dropdown
SecLabel("Target Player",DupeContainer,84)
local playerDropdown=MakePlayerDropdown(DupeContainer,106,function(name)
    if name=="None" then
        SelectedPlayer=nil
        if bringOn then bringOn=false; bringActive=false end
        if spectateOn then doSpectate(false) end
        if carFlingOn then
            carFlingOn=false; stopCarFling()
            if actionRowRefs.carFlingToggleCb then actionRowRefs.carFlingToggleCb(false) end
        end
    else
        local rawName=name:match("^(.-)%s+%(") or name
        SelectedPlayer=getPlayerByName(rawName)
        getgenv().carBugTarget=rawName
    end
end)

-- ── ACTION HELPERS ───────────────────────────────────────────
-- container param defaults to DupeContainer for backward compat
local function ActionToggle(label,icon,yPos,colorOn,onToggle,container)
    container = container or DupeContainer
    local row=MakeFrame({Size=UDim2.new(1,-24,0,34),Position=UDim2.new(0,12,0,yPos),BackgroundColor3=C.Card},container)
    Corner(row,4); Stroke(row,C.Border,1)
    MakeLabel({Size=UDim2.new(0,22,1,0),Position=UDim2.new(0,8,0,0),Text=icon,TextSize=14,TextXAlignment=Enum.TextXAlignment.Center},row)
    MakeLabel({Size=UDim2.new(1,-100,1,0),Position=UDim2.new(0,34,0,0),Text=label,TextSize=11,Font=Enum.Font.GothamBold,TextColor3=C.TextSec},row)
    local pillBg=MakeFrame({Size=UDim2.new(0,44,0,22),Position=UDim2.new(1,-54,0.5,-11),BackgroundColor3=C.Input},row)
    Corner(pillBg,11); Stroke(pillBg,C.Border,1)
    local pillNub=MakeFrame({Size=UDim2.new(0,16,0,16),Position=UDim2.new(0,3,0.5,-8),BackgroundColor3=C.White},pillBg)
    Corner(pillNub,8)
    local pillLabel=MakeLabel({Size=UDim2.new(1,0,1,0),Text="OFF",TextSize=8,Font=Enum.Font.GothamBold,TextColor3=C.TextDim,TextXAlignment=Enum.TextXAlignment.Center},pillBg)
    local state=false
    local function setState(v,silent)
        state=v
        if v then
            TweenService:Create(pillBg,TweenInfo.new(0.15),{BackgroundColor3=colorOn}):Play()
            TweenService:Create(pillNub,TweenInfo.new(0.15),{Position=UDim2.new(1,-19,0.5,-8)}):Play()
            pillLabel.Text="ON"; pillLabel.TextColor3=C.White; Stroke(pillBg,colorOn,1)
        else
            TweenService:Create(pillBg,TweenInfo.new(0.15),{BackgroundColor3=C.Input}):Play()
            TweenService:Create(pillNub,TweenInfo.new(0.15),{Position=UDim2.new(0,3,0.5,-8)}):Play()
            pillLabel.Text="OFF"; pillLabel.TextColor3=C.TextDim; Stroke(pillBg,C.Border,1)
        end
        if not silent and onToggle then onToggle(v) end
    end
    pillBg.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then setState(not state) end
    end)
    return setState
end

local function ActionButton(label,icon,btnText,btnColor,yPos,extraLabel,onClick,container)
    container = container or DupeContainer
    local row=MakeFrame({Size=UDim2.new(1,-24,0,34),Position=UDim2.new(0,12,0,yPos),BackgroundColor3=C.Card},container)
    Corner(row,4); Stroke(row,C.Border,1)
    MakeLabel({Size=UDim2.new(0,22,1,0),Position=UDim2.new(0,8,0,0),Text=icon,TextSize=14,TextXAlignment=Enum.TextXAlignment.Center},row)
    MakeLabel({Size=UDim2.new(1,-150,1,0),Position=UDim2.new(0,34,0,0),Text=label,TextSize=11,Font=Enum.Font.GothamBold,TextColor3=C.TextSec},row)
    local extraLbl=nil
    if extraLabel then
        extraLbl=MakeLabel({Size=UDim2.new(0,60,1,0),Position=UDim2.new(1,-132,0,0),Text=extraLabel,TextSize=8,Font=Enum.Font.Code,TextColor3=C.TextDim,TextXAlignment=Enum.TextXAlignment.Right},row)
    end
    local btn=MakeButton({
        Size=UDim2.new(0,60,0,24),Position=UDim2.new(1,-70,0.5,-12),
        Text=btnText,TextSize=10,Font=Enum.Font.GothamBold,
        BackgroundColor3=Color3.new(btnColor.R*0.16,btnColor.G*0.16,btnColor.B*0.16),
        TextColor3=btnColor,
    },row)
    Corner(btn,3); Stroke(btn,Color3.new(btnColor.R*0.35,btnColor.G*0.35,btnColor.B*0.35),1)
    btn.MouseEnter:Connect(function() TweenService:Create(btn,TweenInfo.new(0.1),{BackgroundColor3=btnColor,TextColor3=C.White}):Play() end)
    btn.MouseLeave:Connect(function() TweenService:Create(btn,TweenInfo.new(0.1),{BackgroundColor3=Color3.new(btnColor.R*0.16,btnColor.G*0.16,btnColor.B*0.16),TextColor3=btnColor}):Play() end)
    btn.MouseButton1Click:Connect(function() if onClick then onClick() end end)
    return extraLbl
end

SecLabel("Player Actions",DupeContainer,146)

-- spectate
local setSpectate=ActionToggle("Spectate Player","👁",168,C.Blue,function(v)
    local ok=doSpectate(v)
    if not ok then task.defer(function() setSpectate(false,true) end) end
end)
actionRowRefs.spectateToggleCb=function(v) setSpectate(v,true) end

-- bring
local setBring=ActionToggle("Bring Player","🧲",210,C.Green,function(v)
    local ok=doBring(v)
    if not ok then task.defer(function() setBring(false,true) end) end
end)
actionRowRefs.bringToggleCb=function(v) setBring(v,true) end

-- view inventory
ActionButton("View Inventory","🎒","VIEW",C.Blue,252,nil,function() doViewInventory() end)

-- ── CAR BODY FLING ROW ──────────────────────────────────────
local carRow=MakeFrame({Size=UDim2.new(1,-24,0,46),Position=UDim2.new(0,12,0,294),BackgroundColor3=C.Card},DupeContainer)
Corner(carRow,4); Stroke(carRow,C.Border,1)

MakeLabel({Size=UDim2.new(0,22,0,22),Position=UDim2.new(0,8,0.5,-11),Text="🚗",TextSize=15,TextXAlignment=Enum.TextXAlignment.Center},carRow)
MakeLabel({Size=UDim2.new(1,-160,0,18),Position=UDim2.new(0,34,0,5),Text="Car Body Fling",TextSize=11,Font=Enum.Font.GothamBold,TextColor3=C.TextSec},carRow)

local carHitLbl=MakeLabel({
    Size=UDim2.new(0,70,0,12),Position=UDim2.new(0,34,0,27),
    Text="HITS: 0",TextSize=8,Font=Enum.Font.Code,TextColor3=C.TextDim,
},carRow)
actionRowRefs.carFlingHitLabel=carHitLbl

-- updated spec label: mirrors main script, 50k V for anti-fly kick
MakeLabel({Size=UDim2.new(1,-160,0,12),Position=UDim2.new(0,108,0,27),Text="15k H · 50k V · max rate → kick",TextSize=7,Font=Enum.Font.Gotham,TextColor3=C.Accent},carRow)

local carPillBg=MakeFrame({Size=UDim2.new(0,44,0,22),Position=UDim2.new(1,-54,0.5,-11),BackgroundColor3=C.Input},carRow)
Corner(carPillBg,11); Stroke(carPillBg,C.Border,1)
local carPillNub=MakeFrame({Size=UDim2.new(0,16,0,16),Position=UDim2.new(0,3,0.5,-8),BackgroundColor3=C.White},carPillBg)
Corner(carPillNub,8)
local carPillLbl=MakeLabel({Size=UDim2.new(1,0,1,0),Text="OFF",TextSize=8,Font=Enum.Font.GothamBold,TextColor3=C.TextDim,TextXAlignment=Enum.TextXAlignment.Center},carPillBg)

local function setCarFlingUI(v,silent)
    carFlingOn=v
    if v then
        TweenService:Create(carPillBg,TweenInfo.new(0.15),{BackgroundColor3=C.Orange}):Play()
        TweenService:Create(carPillNub,TweenInfo.new(0.15),{Position=UDim2.new(1,-19,0.5,-8)}):Play()
        carPillLbl.Text="ON"; carPillLbl.TextColor3=C.White; Stroke(carPillBg,C.Orange,1)
        Stroke(carRow,C.Orange,1)
    else
        TweenService:Create(carPillBg,TweenInfo.new(0.15),{BackgroundColor3=C.Input}):Play()
        TweenService:Create(carPillNub,TweenInfo.new(0.15),{Position=UDim2.new(0,3,0.5,-8)}):Play()
        carPillLbl.Text="OFF"; carPillLbl.TextColor3=C.TextDim; Stroke(carPillBg,C.Border,1)
        Stroke(carRow,C.Border,1)
    end
    if not silent then
        if v then
            if not getgenv().carBugTarget or getgenv().carBugTarget=="" then
                if AddLog then AddLog("warn","Car Fling: select a target first") end
                task.defer(function() setCarFlingUI(false,true) end)
                return
            end
            carFlingHits=0; carHitLbl.Text="HITS: 0"
            startCarFlingLoop(getgenv().carBugTarget)
            if AddLog then AddLog("info","Car fling → "..tostring(getgenv().carBugTarget)) end
        else
            stopCarFling()
            if AddLog then AddLog("warn","Car fling stopped — "..carFlingHits.." hits") end
        end
    end
end
actionRowRefs.carFlingToggleCb=function(v) setCarFlingUI(v,true) end

carPillBg.InputBegan:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 then setCarFlingUI(not carFlingOn) end
end)

-- ── DUPE CONTROLS ───────────────────────────────────────────
SecLabel("Dupe Controls",DupeContainer,350)
local MainBtn=MakeButton({
    Size=UDim2.new(1,-24,0,36),Position=UDim2.new(0,12,0,372),
    Text="▶   START DUPE",TextSize=13,Font=Enum.Font.GothamBold,
    BackgroundColor3=C.Accent,TextColor3=C.White,
},DupeContainer)
Corner(MainBtn,4)

SecLabel("Session Stats",DupeContainer,416)
local StatValues={}
local statDefs={{l="STORED",k="stored",v="0",c=C.Green},{l="CYCLES",k="cycles",v="0",c=C.TextPri},{l="RUNTIME",k="runtime",v="0:00",c=C.Yellow}}
local boxW=math.floor((WIN_W-24-16)/3)
for i,d in ipairs(statDefs) do
    local box=MakeFrame({Size=UDim2.new(0,boxW,0,44),Position=UDim2.new(0,12+(i-1)*(boxW+8),0,438),BackgroundColor3=C.Card},DupeContainer)
    Corner(box,3); Stroke(box,C.Border,1)
    local vl=MakeLabel({Size=UDim2.new(1,0,0,24),Position=UDim2.new(0,0,0,6),Text=d.v,TextSize=18,Font=Enum.Font.Code,TextColor3=d.c,TextXAlignment=Enum.TextXAlignment.Center},box)
    MakeLabel({Size=UDim2.new(1,0,0,12),Position=UDim2.new(0,0,1,-14),Text=d.l,TextSize=7,Font=Enum.Font.GothamBold,TextColor3=C.TextDim,TextXAlignment=Enum.TextXAlignment.Center},box)
    StatValues[d.k]=vl
end

SecLabel("Activity Log",DupeContainer,490)
local LogFrame=MakeFrame({Size=UDim2.new(1,-24,0,90),Position=UDim2.new(0,12,0,512),BackgroundColor3=C.Input,ClipsDescendants=true},DupeContainer)
Corner(LogFrame,3); Stroke(LogFrame,C.Border,1)
local LogScroll=Make("ScrollingFrame",{Size=UDim2.new(1,-4,1,-4),Position=UDim2.new(0,2,0,2),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=C.Border,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y},LogFrame)
Make("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,1),Parent=LogScroll})

-- ═══════════════════════════════════════════════════════════
--  LOG
-- ═══════════════════════════════════════════════════════════
local logColors={ok=C.Green,warn=C.Yellow,err=C.Accent,info=C.Blue}
AddLog=function(t,msg)
    local ts=os.date("%H:%M")
    local col=logColors[t] or C.TextSec
    local line=MakeFrame({Size=UDim2.new(1,-6,0,15),BackgroundTransparency=1,LayoutOrder=#LogScroll:GetChildren()},LogScroll)
    MakeLabel({Size=UDim2.new(0,38,1,0),Text="["..ts.."]",TextSize=9,Font=Enum.Font.Code,TextColor3=C.TextDim},line)
    MakeLabel({Size=UDim2.new(1,-42,1,0),Position=UDim2.new(0,42,0,0),Text=msg,TextSize=9,Font=Enum.Font.Code,TextColor3=col,TextTruncate=Enum.TextTruncate.AtEnd},line)
    table.insert(logLines,line)
    if #logLines>MAX_LOG then logLines[1]:Destroy(); table.remove(logLines,1) end
    task.defer(function()
        LogScroll.CanvasPosition=Vector2.new(0,math.max(0,LogScroll.AbsoluteCanvasSize.Y-LogScroll.AbsoluteSize.Y))
    end)
end
AddLog("info","Freemason v3.0 ready.")

-- ═══════════════════════════════════════════════════════════
--  PANEL: RAINBOW
-- ═══════════════════════════════════════════════════════════
local RainbowPanel=NewPanel("RAINBOW")
SecLabel("Rainbow Guns",RainbowPanel,10)
local RbCard=MakeFrame({Size=UDim2.new(1,-24,0,70),Position=UDim2.new(0,12,0,32),BackgroundColor3=C.Card},RainbowPanel)
Corner(RbCard,4); Stroke(RbCard,C.Border,1)
local RbIcon=MakeLabel({Size=UDim2.new(0,42,0,42),Position=UDim2.new(0,10,0.5,-21),Text="🌈",TextSize=24,TextXAlignment=Enum.TextXAlignment.Center,BackgroundColor3=Color3.fromRGB(20,10,35),BackgroundTransparency=0},RbCard)
Corner(RbIcon,4)
MakeLabel({Size=UDim2.new(1,-120,0,18),Position=UDim2.new(0,62,0,12),Text="Rainbow Guns",TextSize=13,Font=Enum.Font.GothamBold},RbCard)
MakeLabel({Size=UDim2.new(1,-120,0,14),Position=UDim2.new(0,62,0,30),Text="Neon material · fast HSV cycle · auto-reapply",TextSize=9,Font=Enum.Font.Gotham,TextColor3=C.TextSec},RbCard)
MakeLabel({Size=UDim2.new(1,-120,0,12),Position=UDim2.new(0,62,0,48),Text="Requires workspace.GUNS folder",TextSize=8,Font=Enum.Font.Gotham,TextColor3=C.TextDim},RbCard)
local RbToggle=MakeButton({Size=UDim2.new(0,64,0,26),Position=UDim2.new(1,-74,0.5,-13),Text="OFF",TextSize=11,Font=Enum.Font.GothamBold,BackgroundColor3=C.Card,TextColor3=C.TextDim},RbCard)
Corner(RbToggle,4); Stroke(RbToggle,C.Border,1)
local RbPreview=MakeFrame({Size=UDim2.new(1,-24,0,28),Position=UDim2.new(0,12,0,112),BackgroundColor3=C.Card},RainbowPanel)
Corner(RbPreview,4)
local RbPreviewLabel=MakeLabel({Size=UDim2.new(1,0,1,0),Text="● INACTIVE",TextSize=10,Font=Enum.Font.GothamBold,TextColor3=C.TextDim,TextXAlignment=Enum.TextXAlignment.Center},RbPreview)
SecLabel("Effect Details",RainbowPanel,148)
local rbInfoData={{"Material","Neon (full brightness, no shadows)"},{"Cycle Speed","~33 fps — 0.04 hue shift per frame"},{"Scope","All BaseParts in valid GUNS folder tools"},{"On Pickup","Auto-applies to any gun grabbed mid-session"}}
for i,row in ipairs(rbInfoData) do
    local y=170+(i-1)*32
    local f=MakeFrame({Size=UDim2.new(1,-24,0,28),Position=UDim2.new(0,12,0,y),BackgroundColor3=C.Card},RainbowPanel)
    Corner(f,3); Stroke(f,C.Border,1)
    MakeLabel({Size=UDim2.new(0,100,1,0),Position=UDim2.new(0,10,0,0),Text=row[1],TextSize=10,Font=Enum.Font.GothamBold,TextColor3=C.TextSec},f)
    MakeLabel({Size=UDim2.new(1,-114,1,0),Position=UDim2.new(0,110,0,0),Text=row[2],TextSize=9,Font=Enum.Font.Gotham,TextColor3=C.TextDim},f)
end
local rbHue=0
task.spawn(function()
    while ScreenGui.Parent do
        task.wait(0.04)
        if rainbowOn then
            rbHue=(rbHue+0.04)%1
            local col=Color3.fromHSV(rbHue,1,1)
            RbPreview.BackgroundColor3=col; RbPreviewLabel.TextColor3=Color3.fromRGB(0,0,0)
            RbPreviewLabel.Text="● ACTIVE — CYCLING"; RbIcon.BackgroundColor3=Color3.fromHSV(rbHue,0.8,0.4)
        else
            RbPreview.BackgroundColor3=C.Card; RbPreviewLabel.TextColor3=C.TextDim
            RbPreviewLabel.Text="● INACTIVE"; RbIcon.BackgroundColor3=Color3.fromRGB(20,10,35)
        end
    end
end)
RbToggle.MouseButton1Click:Connect(function()
    rainbowOn=not rainbowOn; setupAdminGuns(rainbowOn)
    if rainbowOn then RbToggle.Text="ON"; RbToggle.TextColor3=C.Green; RbToggle.BackgroundColor3=Color3.fromRGB(10,40,20); Stroke(RbToggle,Color3.fromRGB(20,80,40),1)
    else RbToggle.Text="OFF"; RbToggle.TextColor3=C.TextDim; RbToggle.BackgroundColor3=C.Card; Stroke(RbToggle,C.Border,1) end
end)

-- ═══════════════════════════════════════════════════════════
--  PANEL: MARKET
-- ═══════════════════════════════════════════════════════════
local MarketPanel=NewPanel("MARKET")
SecLabel("Open Market / Shop",MarketPanel,10)
local MktScroll=Make("ScrollingFrame",{Size=UDim2.new(1,0,1,-30),Position=UDim2.new(0,0,0,30),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=C.Border,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ScrollingDirection=Enum.ScrollingDirection.Y},MarketPanel)
Make("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,6),Parent=MktScroll}); Pad(MktScroll,6,10,12,12)
local shopIcons={["Bronx Market"]="🛒",["Tattoo Shop"]="🔺",["Open Trunk"]="🚗",["BRONX PAWNING"]="💎",["BRONX CLOTHING"]="👕",["Gas Station"]="⛽",["EXOTIC DEALER"]="🌿"}
for _,shopName in ipairs(shopList) do
    local guiName=shopGUIs[shopName]
    local row=MakeFrame({Size=UDim2.new(1,0,0,44),BackgroundColor3=C.Card,LayoutOrder=1},MktScroll)
    Corner(row,4); Stroke(row,C.Border,1)
    local iconLbl=MakeLabel({Size=UDim2.new(0,34,0,34),Position=UDim2.new(0,6,0.5,-17),Text=shopIcons[shopName] or "🏪",TextSize=18,TextXAlignment=Enum.TextXAlignment.Center,BackgroundColor3=Color3.fromRGB(18,18,28),BackgroundTransparency=0},row)
    Corner(iconLbl,4)
    MakeLabel({Size=UDim2.new(1,-110,0,18),Position=UDim2.new(0,48,0,6),Text=shopName,TextSize=12,Font=Enum.Font.GothamBold,TextColor3=C.TextPri},row)
    MakeLabel({Size=UDim2.new(1,-110,0,14),Position=UDim2.new(0,48,0,26),Text="GUI: "..guiName,TextSize=9,Font=Enum.Font.Code,TextColor3=C.TextDim},row)
    local openBtn=MakeButton({Size=UDim2.new(0,56,0,26),Position=UDim2.new(1,-66,0.5,-13),Text="OPEN",TextSize=10,Font=Enum.Font.GothamBold},row)
    Corner(openBtn,3); Stroke(openBtn,C.BorderAcc,1)
    openBtn.MouseEnter:Connect(function() TweenService:Create(openBtn,TweenInfo.new(0.1),{BackgroundColor3=C.Accent,TextColor3=C.White}):Play() end)
    openBtn.MouseLeave:Connect(function() TweenService:Create(openBtn,TweenInfo.new(0.1),{BackgroundColor3=C.AccentDim,TextColor3=C.Accent}):Play() end)
    openBtn.MouseButton1Click:Connect(function()
        local function tryOpen(c)
            if not c then return false end
            local gui=c:FindFirstChild(guiName)
            if gui then gui.Enabled=not gui.Enabled; openBtn.Text=gui.Enabled and "CLOSE" or "OPEN"; openBtn.TextColor3=gui.Enabled and C.Green or C.Accent; return true end
            return false
        end
        if not tryOpen(LocalPlayer:FindFirstChild("PlayerGui")) then
            if not tryOpen(game:GetService("CoreGui")) then
                local r=ReplicatedStorage:FindFirstChild("OpenShop") or ReplicatedStorage:FindFirstChild("ShopRemote")
                if r then pcall(function() r:FireServer(shopName) end) end
            end
        end
    end)
end

-- ═══════════════════════════════════════════════════════════
--  PANEL: SETTINGS
-- ═══════════════════════════════════════════════════════════
local SettingsPanel=NewPanel("SETTINGS")
local SScroll=Make("ScrollingFrame",{Size=UDim2.new(1,0,1,0),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=3,ScrollBarImageColor3=C.Border,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y},SettingsPanel)
Make("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Padding=UDim.new(0,5),Parent=SScroll}); Pad(SScroll,8,10,12,12)
local function SettingRow(label,sub,ctrlType,default,key)
    local row=MakeFrame({Size=UDim2.new(1,0,0,42),BackgroundColor3=C.Card,LayoutOrder=1},SScroll)
    Corner(row,3); Stroke(row,C.Border,1)
    MakeLabel({Size=UDim2.new(1,-80,0,18),Position=UDim2.new(0,10,0,5),Text=label,TextSize=11,Font=Enum.Font.GothamBold,TextColor3=C.TextSec},row)
    if sub then MakeLabel({Size=UDim2.new(1,-80,0,13),Position=UDim2.new(0,10,0,23),Text=sub,TextSize=8,Font=Enum.Font.Gotham,TextColor3=C.TextDim},row) end
    if ctrlType=="toggle" then
        local tbg=MakeFrame({Size=UDim2.new(0,34,0,18),Position=UDim2.new(1,-44,0.5,-9),BackgroundColor3=default and C.Accent or C.Card},row)
        Corner(tbg,9); Stroke(tbg,default and C.Accent or C.Border,1)
        local nub=MakeFrame({Size=UDim2.new(0,12,0,12),Position=default and UDim2.new(1,-15,0.5,-6) or UDim2.new(0,3,0.5,-6),BackgroundColor3=C.White},tbg)
        Corner(nub,6); local st=default
        tbg.InputBegan:Connect(function(i)
            if i.UserInputType==Enum.UserInputType.MouseButton1 then
                st=not st; CFG[key]=st
                TweenService:Create(tbg,TweenInfo.new(0.15),{BackgroundColor3=st and C.Accent or C.Card}):Play()
                TweenService:Create(nub,TweenInfo.new(0.15),{Position=st and UDim2.new(1,-15,0.5,-6) or UDim2.new(0,3,0.5,-6)}):Play()
            end
        end)
    elseif ctrlType=="number" then
        local inp=MakeInput({Size=UDim2.new(0,62,0,24),Position=UDim2.new(1,-72,0.5,-12),Text=tostring(default),TextXAlignment=Enum.TextXAlignment.Right,ClearTextOnFocus=false},row)
        Corner(inp,3); Stroke(inp,C.Border,1); Pad(inp,0,0,6,6)
        inp.FocusLost:Connect(function()
            local n=tonumber(inp.Text)
            if n then CFG[key]=n else inp.Text=tostring(CFG[key]) end
        end)
    end
end
SettingRow("List Delay (s)",     "FireServer on ListWeaponRemote",    "number",0.22,   "ListDelay")
SettingRow("Store Wait (s)",     "After BackpackRemote Store invoke", "number",3.6,    "StoreWait")
SettingRow("Cycle Cooldown (s)", "Wait between full dupe cycles",     "number",1.5,    "CycleCooldown")
SettingRow("List Price",         "Robux price for market listings",   "number",999999, "ListPrice")
SettingRow("Auto Re-Equip",      "Re-equip masterObject each cycle",  "toggle",true,   "AutoReEquip")

-- ═══════════════════════════════════════════════════════════
--  TELEPORT HELPERS
-- ═══════════════════════════════════════════════════════════
local function BypassTP(cf)
    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hum or not hrp then return end
    getgenv().SwimMethod = true
    hum:ChangeState(0)
    repeat task.wait(0.0001) until not LocalPlayer:GetAttribute("LastACPos")
    hrp.CFrame = cf
    task.wait(0.1)
    hum:ChangeState(2)
    getgenv().SwimMethod = false
end

-- ─── LOCATIONS (mirrored from main script) ──────────────────
local locations = {
    ["💸 Bail Player Spot"]    = Vector3.new(-1206.54, 253.89, -3342.74),
    ["💳 Bank"]                = Vector3.new(-1216.63, 253.88, -3634.77),
    ["🏚️ Money Wash"]          = Vector3.new(-376.18, 253.68, -1975.59),
    ["🪙 Safe Items"]          = Vector3.new(68514.90, 52941.50, -796.09),
    ["💎 Pawn Shop"]           = Vector3.new(-1049.64, 253.54, -818.27),
    ["🔒 Bank Vault"]          = Vector3.new(-217.57, 373.80, -1216.21),
    ["💵 Mr Money Man"]        = Vector3.new(-1008.69, 262.33, 54.57),
    ["💥 GunShop 1"]           = Vector3.new(92959.87, 122098.50, 17244.46),
    ["🏠 GunShop 1 Lobby"]     = Vector3.new(-1002.42, 253.64, -1441.91),
    ["🎯 GunShop 2"]           = Vector3.new(66195.45, 123615.71, 5750.28),
    ["🚪 GunShop 2 Lobby"]     = Vector3.new(-224.38, 283.80, -794.72),
    ["🔫 GunShop 3"]           = Vector3.new(60819.88, 87609.15, -351.47),
    ["🔫 GunShop 4"]           = Vector3.new(72421.91, 128855.82, -1080.61),
    ["🏙️ Pent House"]          = Vector3.new(-178.27, 397.14, -573.03),
    ["🍃☕ Pent House 2"]       = Vector3.new(-618.03, 356.55, -681.40),
    ["🏡 Mini Mansion"]        = Vector3.new(-791.52, 256.79, 1414.42),
    ["🏠 Roof"]                = Vector3.new(-381.65, 463.69, -706.36),
    ["🧳 Backpack Shop"]       = Vector3.new(-713.97, 253.92, -693.49),
    ["💠 Frozen Shop"]         = Vector3.new(-216.31, 284.03, -1169.03),
    ["💦 Drip Shop"]           = Vector3.new(67462.70, 10489.04, 549.59),
    ["🍗 Chicken Wings"]       = Vector3.new(-1157.91, 253.54, -815.94),
    ["🥪 Deli"]                = Vector3.new(-755.81, 254.69, -687.12),
    ["🚙 Car Dealer"]          = Vector3.new(-401.99, 253.41, -1248.84),
    ["🥤 Soda Warehouse"]      = Vector3.new(-187.86, 284.63, -291.34),
    ["🍾 Soda Supplies"]       = Vector3.new(51372.82, 21680.42, 5840.86),
    ["🍹 Soda Seller"]         = Vector3.new(-1292.22, 253.30, -3003.05),
    ["🐊 Exotic Dealer"]       = Vector3.new(-1523.57, 273.97, -990.66),
    ["⚙️ Switch Seller"]       = Vector3.new(-1446.22, 256.06, 2189.88),
    ["🏦 Bank Tools"]          = Vector3.new(-397.43, 334.31, -555.70),
    ["🏗️ Construction Site"]   = Vector3.new(-1731.83, 370.81, -1176.84),
    ["🚓 Prison"]              = Vector3.new(-1135.05, 254.72, -3330.00),
    ["🍔 Popeyeas"]            = Vector3.new(-71.81, 283.64, -769.44),
    ["🧊 Ice Box"]             = Vector3.new(-215.14, 283.52, -1258.69),
    ["🏥 Hospital"]            = Vector3.new(-1589.50, 254.27, 17.66),
    ["🛒 MarGreens"]           = Vector3.new(-381.21, 254.45, -385.67),
    ["🕵️ Feds Room"]           = Vector3.new(-1441.79, 255.04, -3132.60),
    ["💰 ATM 1"]               = Vector3.new(-1043.47, 254.83, -1127.02),
    ["💵 ATM 2"]               = Vector3.new(-738.26, 253.76, -787.86),
    ["🏧 ATM 3"]               = Vector3.new(-96.72, 283.63, -766.33),
    ["🏠 House Rob"]           = Vector3.new(-613.05, 254.07, -730.71),
    ["🎬 Studio Robbery"]      = Vector3.new(93427.52, 14484.91, 566.67),
    ["🏘️ TrailerPark"]         = Vector3.new(-1522.77, 253.16, 2344.96),
    ["🏨 Woody's Hotel"]       = Vector3.new(-1022.62, 325.84, -908.92),
    ["🏙️ 600 Block"]           = Vector3.new(-990.68, 253.71, -281.32),
    ["🎵 Marleys Studio"]      = Vector3.new(-1554.91, 280.95, -1019.51),
    ["📱 T-Mobile"]            = Vector3.new(-679.19, 253.67, -698.56),
    ["🍕 Lil Caesars"]         = Vector3.new(-611.52, 254.31, -800.34),
    ["🌮 Taco Shop"]           = Vector3.new(-672.70, 253.83, -807.84),
    ["🍔 Burger n Fries"]      = Vector3.new(-750.63, 253.76, -784.57),
    ["🏚️ Cookin House"]        = Vector3.new(-1605.92, 254.04, -488.44),
}

local orderedLocations = {
    "💸 Bail Player Spot",
    "💥 GunShop 1","🏠 GunShop 1 Lobby","🎯 GunShop 2","🚪 GunShop 2 Lobby",
    "🔫 GunShop 3","🔫 GunShop 4",
    "💳 Bank","🔒 Bank Vault","🏦 Bank Tools","💰 ATM 1","💵 ATM 2","🏧 ATM 3","🏚️ Money Wash",
    "🏙️ Pent House","🍃☕ Pent House 2","🏡 Mini Mansion","🏠 Roof",
    "🪙 Safe Items","💎 Pawn Shop","🧳 Backpack Shop","💠 Frozen Shop","💦 Drip Shop",
    "🍗 Chicken Wings","🥪 Deli","🚙 Car Dealer","🥤 Soda Warehouse","🍾 Soda Supplies","🍹 Soda Seller",
    "🐊 Exotic Dealer","⚙️ Switch Seller","🏗️ Construction Site","🚓 Prison","🍔 Popeyeas",
    "🧊 Ice Box","🏥 Hospital","🛒 MarGreens","🕵️ Feds Room",
    "🏠 House Rob","🎬 Studio Robbery","🏘️ TrailerPark","🏨 Woody's Hotel","🏙️ 600 Block",
    "🎵 Marleys Studio","📱 T-Mobile","🍕 Lil Caesars","🌮 Taco Shop","🍔 Burger n Fries",
    "💵 Mr Money Man","🏚️ Cookin House",
}

-- ═══════════════════════════════════════════════════════════
--  PANEL: TELEPORT  (replaces BLACKLIST)
-- ═══════════════════════════════════════════════════════════
local TeleportPanel = NewPanel("TELEPORT")

-- scrollable list of location buttons
local TpScroll = Make("ScrollingFrame", {
    Size = UDim2.new(1, 0, 1, -54),
    Position = UDim2.new(0, 0, 0, 54),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.Border,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
}, TeleportPanel)
Make("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = TpScroll})
Pad(TpScroll, 6, 8, 10, 10)

-- header bar with dropdown + GO button
local TpHeaderBg = MakeFrame({
    Size = UDim2.new(1, 0, 0, 50),
    Position = UDim2.new(0, 0, 0, 0),
    BackgroundColor3 = Color3.fromRGB(11, 10, 18),
}, TeleportPanel)
Stroke(TpHeaderBg, C.Border, 1)

local selectedLocation = orderedLocations[1]
local TpDropBg = MakeButton({
    Size = UDim2.new(1, -90, 0, 30),
    Position = UDim2.new(0, 8, 0, 10),
    Text = "", BackgroundColor3 = C.Card, ZIndex = 5,
}, TpHeaderBg)
Corner(TpDropBg, 4); Stroke(TpDropBg, C.Border, 1)
MakeLabel({Size=UDim2.new(0,20,1,0),Position=UDim2.new(0,8,0,0),Text="📍",TextSize=13,TextXAlignment=Enum.TextXAlignment.Center,ZIndex=6},TpDropBg)
local TpDropText = MakeLabel({
    Size = UDim2.new(1, -52, 1, 0),
    Position = UDim2.new(0, 30, 0, 0),
    Text = selectedLocation,
    TextSize = 10, Font = Enum.Font.GothamBold,
    TextColor3 = C.TextSec, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 6,
}, TpDropBg)
local TpDropChev = MakeLabel({Size=UDim2.new(0,16,1,0),Position=UDim2.new(1,-18,0,0),Text="▾",TextSize=11,TextColor3=C.TextDim,TextXAlignment=Enum.TextXAlignment.Center,ZIndex=6},TpDropBg)

local TpGoBtn = MakeButton({
    Size = UDim2.new(0, 70, 0, 30),
    Position = UDim2.new(1, -78, 0, 10),
    Text = "▶ GO", TextSize = 11, Font = Enum.Font.GothamBold,
    BackgroundColor3 = C.Accent, TextColor3 = C.White,
}, TpHeaderBg)
Corner(TpGoBtn, 4)
TpGoBtn.MouseEnter:Connect(function() TweenService:Create(TpGoBtn,TweenInfo.new(0.1),{BackgroundColor3=Color3.fromRGB(167,125,255)}):Play() end)
TpGoBtn.MouseLeave:Connect(function() TweenService:Create(TpGoBtn,TweenInfo.new(0.1),{BackgroundColor3=C.Accent}):Play() end)

-- inline dropdown list (appears below header)
local TpListFrame = Make("Frame", {
    Size = UDim2.new(1, -20, 0, 0),
    Position = UDim2.new(0, 10, 0, 54),
    BackgroundColor3 = C.DropBG,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Visible = false,
    ZIndex = 30,
}, TeleportPanel)
Corner(TpListFrame, 4); Stroke(TpListFrame, C.BorderAcc, 1)
local TpListScroll = Make("ScrollingFrame", {
    Size = UDim2.new(1, 0, 1, 0),
    BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = C.Border,
    CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y, ZIndex = 31,
}, TpListFrame)
Make("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 1), Parent = TpListScroll})

local tpDropOpen = false
local LIST_ITEM_H = 26
local MAX_DROP_H  = 200

local function closeTpDrop()
    tpDropOpen = false; TpDropChev.Text = "▾"
    TweenService:Create(TpListFrame, TweenInfo.new(0.12), {Size=UDim2.new(1,-20,0,0)}):Play()
    task.delay(0.13, function() TpListFrame.Visible = false end)
    Stroke(TpDropBg, C.Border, 1)
end

local function buildTpList()
    for _, v in pairs(TpListScroll:GetChildren()) do
        if v:IsA("TextButton") then v:Destroy() end
    end
    for idx, name in ipairs(orderedLocations) do
        local btn = MakeButton({
            Size = UDim2.new(1, 0, 0, LIST_ITEM_H),
            Text = "", LayoutOrder = idx, ZIndex = 32,
            BackgroundColor3 = name == selectedLocation
                and Color3.fromRGB(36, 24, 66) or C.DropBG,
        }, TpListScroll)
        local dot = MakeFrame({Size=UDim2.new(0,4,0,4),Position=UDim2.new(0,8,0.5,-2),BackgroundColor3=name==selectedLocation and C.Accent or C.DropBG,ZIndex=33},btn)
        Corner(dot, 2)
        MakeLabel({
            Size = UDim2.new(1, -20, 1, 0), Position = UDim2.new(0, 16, 0, 0),
            Text = name, TextSize = 10, Font = Enum.Font.GothamBold,
            TextColor3 = name == selectedLocation and C.Accent or C.TextSec,
            TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 33,
        }, btn)
        btn.MouseEnter:Connect(function()
            if name ~= selectedLocation then
                TweenService:Create(btn,TweenInfo.new(0.08),{BackgroundColor3=C.DropHover}):Play()
            end
        end)
        btn.MouseLeave:Connect(function()
            if name ~= selectedLocation then
                TweenService:Create(btn,TweenInfo.new(0.08),{BackgroundColor3=C.DropBG}):Play()
            end
        end)
        btn.MouseButton1Click:Connect(function()
            selectedLocation = name
            TpDropText.Text = name
            TpDropText.TextColor3 = C.TextPri
            closeTpDrop()
            buildTpList()
        end)
    end
end
buildTpList()

TpDropBg.MouseButton1Click:Connect(function()
    if tpDropOpen then
        closeTpDrop()
    else
        tpDropOpen = true; TpDropChev.Text = "▴"
        buildTpList()
        TpListFrame.Visible = true; TpListFrame.Size = UDim2.new(1,-20,0,0)
        Stroke(TpDropBg, C.BorderAcc, 1)
        TweenService:Create(TpListFrame, TweenInfo.new(0.15), {
            Size = UDim2.new(1,-20,0,math.min(#orderedLocations,MAX_DROP_H//LIST_ITEM_H)*LIST_ITEM_H+4)
        }):Play()
    end
end)

TpGoBtn.MouseButton1Click:Connect(function()
    local vec = locations[selectedLocation]
    if not vec then
        AddLog("warn", "TP: location not found — " .. selectedLocation)
        return
    end
    task.spawn(function()
        BypassTP(CFrame.new(vec))
        AddLog("ok", "TP → " .. selectedLocation)
    end)
end)

-- ── Location button grid (quick access tiles) ────────────────
SecLabel("Quick Locations", TeleportPanel, 54)  -- section header sits under the header bar

for _, name in ipairs(orderedLocations) do
    local vec = locations[name]
    if not vec then continue end

    local tile = MakeFrame({
        Size = UDim2.new(1, 0, 0, 34),
        BackgroundColor3 = C.Card,
        LayoutOrder = 1,
    }, TpScroll)
    Corner(tile, 4); Stroke(tile, C.Border, 1)

    -- location name
    MakeLabel({
        Size = UDim2.new(1, -80, 1, 0),
        Position = UDim2.new(0, 10, 0, 0),
        Text = name,
        TextSize = 10, Font = Enum.Font.GothamBold,
        TextColor3 = C.TextSec,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, tile)

    -- TP button
    local tpBtn = MakeButton({
        Size = UDim2.new(0, 52, 0, 22),
        Position = UDim2.new(1, -60, 0.5, -11),
        Text = "TP", TextSize = 10, Font = Enum.Font.GothamBold,
        BackgroundColor3 = C.AccentDim, TextColor3 = C.Accent,
    }, tile)
    Corner(tpBtn, 3); Stroke(tpBtn, C.BorderAcc, 1)
    tpBtn.MouseEnter:Connect(function()
        TweenService:Create(tpBtn,TweenInfo.new(0.1),{BackgroundColor3=C.Accent,TextColor3=C.White}):Play()
    end)
    tpBtn.MouseLeave:Connect(function()
        TweenService:Create(tpBtn,TweenInfo.new(0.1),{BackgroundColor3=C.AccentDim,TextColor3=C.Accent}):Play()
    end)

    local locName = name  -- capture for closure
    local locVec  = vec
    tpBtn.MouseButton1Click:Connect(function()
        -- also update the header dropdown to match
        selectedLocation = locName
        TpDropText.Text  = locName
        TpDropText.TextColor3 = C.TextPri
        task.spawn(function()
            BypassTP(CFrame.new(locVec))
            AddLog("ok", "TP → " .. locName)
        end)
        -- flash tile border green as feedback
        local flash = Instance.new("UIStroke"); flash.Color=C.Green; flash.Thickness=1; flash.Parent=tile
        task.delay(0.5, function() flash:Destroy(); Stroke(tile,C.Border,1) end)
    end)
end

-- ── Blacklist still respected by dupe engine (edit CFG.Blacklist at top) ──

-- ═══════════════════════════════════════════════════════════
--  TAB SWITCHING
-- ═══════════════════════════════════════════════════════════
local function SwitchTab(name)
    activeTab=name
    for n,p in pairs(Panels) do p.Visible=(n==name) end
    for n,btn in pairs(TabBtns) do
        btn.TextColor3=n==name and C.Accent or C.TextDim
        btn.BackgroundColor3=n==name and Color3.fromRGB(36,24,66) or Color3.fromRGB(14,12,24)
    end
end
for name,btn in pairs(TabBtns) do btn.MouseButton1Click:Connect(function() SwitchTab(name) end) end
SwitchTab("DUPE")

-- ═══════════════════════════════════════════════════════════
--  DRAG
-- ═══════════════════════════════════════════════════════════
do
    local drag,ds,sp=false,nil,nil
    TitleBar.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=true;ds=i.Position;sp=Win.Position end end)
    UserInputService.InputChanged:Connect(function(i)
        if drag and i.UserInputType==Enum.UserInputType.MouseMovement then
            local d=i.Position-ds; Win.Position=UDim2.new(sp.X.Scale,sp.X.Offset+d.X,sp.Y.Scale,sp.Y.Offset+d.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end end)
end

-- ═══════════════════════════════════════════════════════════
--  RIGHT SHIFT REFRESH
-- ═══════════════════════════════════════════════════════════
UserInputService.InputBegan:Connect(function(input,gp)
    if gp then return end
    if input.KeyCode==Enum.KeyCode.RightShift then
        playerDropdown.refresh()
        playerDropdownPlayers.refresh()
        AddLog("info","Refreshed — "..tostring(#buildPlayerList()-1).." player(s)")
    end
end)

-- ═══════════════════════════════════════════════════════════
--  WINDOW CONTROLS
-- ═══════════════════════════════════════════════════════════
local minimized=false
CloseBtn.MouseButton1Click:Connect(function()
    DupeActive=false; bringOn=false; bringActive=false
    carFlingOn=false; stopCarFling()
    setupAdminGuns(false); ScreenGui:Destroy()
end)
MinBtn.MouseButton1Click:Connect(function()
    minimized=not minimized
    ContentArea.Visible=not minimized; TabBar.Visible=not minimized; StatusBar.Visible=not minimized
    Win.Size=minimized and UDim2.new(0,WIN_W,0,36) or UDim2.new(0,WIN_W,0,WIN_H)
end)

-- ═══════════════════════════════════════════════════════════
--  DUPE ENGINE
-- ═══════════════════════════════════════════════════════════
local function SetStatus(running)
    if running then
        StatusDot.BackgroundColor3=C.Green; StatusLabel.Text="RUNNING"; StatusLabel.TextColor3=C.Green
        MainBtn.BackgroundColor3=C.AccentDim; MainBtn.TextColor3=C.Accent; MainBtn.Text="■   STOP DUPE"
        ItemBadge.Text="RUNNING"; ItemBadge.BackgroundColor3=C.AccentDim; ItemBadge.TextColor3=C.Accent
    else
        StatusDot.BackgroundColor3=C.Yellow; StatusLabel.Text="IDLE"; StatusLabel.TextColor3=C.Yellow
        MainBtn.BackgroundColor3=C.Accent; MainBtn.TextColor3=C.White; MainBtn.Text="▶   START DUPE"
        ItemBadge.Text="STOPPED"; ItemBadge.BackgroundColor3=Color3.fromRGB(36,24,66); ItemBadge.TextColor3=C.Accent
    end
end

local function StartDupe()
    local char=LocalPlayer.Character
    local held=char and char:FindFirstChildOfClass("Tool")
    if not held then AddLog("err","No item equipped"); return end
    if CFG.Blacklist[held.Name] then AddLog("warn","Blacklisted: "..held.Name); return end
    DupeActive=true; currentSession=currentSession+1
    local mySession=currentSession
    masterObject=held; GhostCache=held
    previousMarketCount=GetMarketCount(held.Name); totalStored=previousMarketCount
    dupeBatchCount=0; dupeTimer=0; statCycles=0; sessionStart=tick()
    ItemNameLabel.Text=held.Name; ItemMetaLabel.Text="Dupe active — cycling"
    ItemPill.Text=held.Name:upper(); ItemPill.TextColor3=C.TextSec
    SetStatus(true)
    AddLog("info","Dupe started — "..held.Name)
    if SelectedPlayer then AddLog("info","Target: "..SelectedPlayer.Name) end
    AddLog("ok","ListWeaponRemote hooked")

    task.spawn(function()
        while DupeActive and mySession==currentSession do
            task.wait(1); dupeTimer+=1
            StatValues["runtime"].Text=FormatTime(dupeTimer)
        end
    end)

    task.spawn(function()
        while DupeActive and mySession==currentSession do
            local char2=LocalPlayer.Character
            local hum=char2 and char2:FindFirstChildOfClass("Humanoid")
            local bp=LocalPlayer:FindFirstChild("Backpack")
            if not char2 or not bp or not hum then task.wait(1) continue end
            local tool=nil
            if masterObject and masterObject.Parent then tool=masterObject
            else
                local f=bp:FindFirstChild(masterObject.Name) or char2:FindFirstChild(masterObject.Name)
                if f then masterObject=f; GhostCache=f; tool=f end
            end
            if tool and not CFG.Blacklist[tool.Name] then
                GhostCache=tool
                local tn=tool.Name
                if tool.Parent==char2 then tool.Parent=bp; task.wait(0.2) end
                pcall(function() if ListWeaponRemote then ListWeaponRemote:FireServer(tn,CFG.ListPrice) end end)
                task.wait(CFG.ListDelay)
                pcall(function() if BackpackRemote then BackpackRemote:InvokeServer("Store",tn) end end)
                task.wait(CFG.StoreWait)
                pcall(function() if BackpackRemote then BackpackRemote:InvokeServer("Grab",tn) end end)
                task.wait(CFG.GrabWait)
                RestoreGhostItems()
                task.wait(CFG.GrabWait)
                local curMkt=GetMarketCount(tn)
                if curMkt>previousMarketCount then
                    local added=curMkt-previousMarketCount
                    dupeBatchCount+=added; totalStored+=added; statCycles+=1
                    StatValues["stored"].Text=tostring(totalStored)
                    StatValues["cycles"].Text=tostring(statCycles)
                    CountLabel.Text="STORED: "..totalStored
                    AddLog("ok","Cycle "..statCycles.." — ×"..added.." "..tn)
                    local mkt=ReplicatedStorage:FindFirstChild("MarketItems")
                    if mkt then
                        for _,item in ipairs(mkt:GetChildren()) do
                            if item.Name==tn and item:FindFirstChild("owner") and item.owner.Value==LocalPlayer.Name then
                                local id=item:GetAttribute("SpecialId") or item:GetAttribute("UUID")
                                if id and not PERMANENT_IDS[id] then PERMANENT_IDS[id]=true end
                            end
                        end
                    end
                    previousMarketCount=curMkt
                else
                    statCycles+=1; StatValues["cycles"].Text=tostring(statCycles)
                    AddLog("warn","Cycle "..statCycles.." — market unchanged")
                end
                local cc=GetItemCount(tn)
                if cc>=2 then
                    for _,v in pairs(bp:GetChildren()) do
                        if v:IsA("Tool") and v.Name==tn and v~=masterObject then v:Destroy(); break end
                    end
                    if CFG.AutoReEquip and masterObject and masterObject.Parent then
                        if masterObject.Parent~=char2 then hum:EquipTool(masterObject) end
                    end
                    task.wait(CFG.EquipWait)
                elseif cc==1 then
                    if CFG.AutoReEquip then
                        if masterObject and masterObject.Parent then
                            if masterObject.Parent~=char2 then hum:EquipTool(masterObject) end
                        else
                            local f=bp:FindFirstChild(tn) or char2:FindFirstChild(tn)
                            if f then masterObject=f;GhostCache=f;hum:EquipTool(f) end
                        end
                    end
                    task.wait(CFG.EquipWait)
                elseif cc==0 then
                    pcall(function() if BackpackRemote then BackpackRemote:InvokeServer("Grab",tn) end end)
                    task.wait(CFG.EquipWait)
                    local nc=GetItemCount(tn)
                    if nc>=1 then
                        local f=bp:FindFirstChild(tn) or char2:FindFirstChild(tn)
                        if f then masterObject=f;GhostCache=f;hum:EquipTool(f) end
                    end
                    task.wait(CFG.EquipWait)
                end
                totalStored=GetMarketCount(tn)
                task.wait(CFG.CycleCooldown)
            else
                task.wait(1)
            end
        end
    end)
end

local function StopDupe()
    DupeActive=false; currentSession=currentSession+1
    SetStatus(false)
    AddLog("warn","Dupe stopped — "..totalStored.." stored")
end

MainBtn.MouseButton1Click:Connect(function()
    if not DupeActive then StartDupe() else StopDupe() end
end)
MainBtn.MouseEnter:Connect(function()
    if not DupeActive then TweenService:Create(MainBtn,TweenInfo.new(0.12),{BackgroundColor3=Color3.fromRGB(167,125,255)}):Play() end
end)
MainBtn.MouseLeave:Connect(function()
    if not DupeActive then TweenService:Create(MainBtn,TweenInfo.new(0.12),{BackgroundColor3=C.Accent}):Play() end
end)
