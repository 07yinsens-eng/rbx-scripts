--[[
	AutoFarm.lua
	Full-featured auto farm script for Anime Gatefall (Roblox).

	Place this as a LocalScript in StarterPlayer -> StarterPlayerScripts
	(or as a child of the LocalPlayer's PlayerScripts).

	Features:
	  - Auto-farm nearest enemy within range
	  - Auto-attack (equips + activates a combat tool on cooldown)
	  - Auto-collect dropped loot (orbs / coins / items)
	  - Auto-revive a few seconds after death
	  - Auto-heal with a potion/food when health is low
	  - Anti-AFK so the server never kicks you
	  - On-screen UI with a toggle for every feature
	  - Chat commands (!farm, !collect, !heal, !revive, !afk)
	  - Live session statistics (kills, coins, time)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()

-- ============================================================================
-- CONFIGURATION
-- ============================================================================
local CONFIG = {
	AutoFarm           = true,   -- master toggle
	AutoAttack         = true,   -- attack enemies automatically
	AttackRange        = 30,     -- studs to engage an enemy
	AutoCollect        = true,   -- pick up orbs / coins / items
	CollectRange       = 20,     -- studs to reach loot
	AutoRevive         = true,   -- respawn automatically on death
	ReviveDelay        = 3,      -- seconds to wait after death
	AutoHeal           = true,   -- heal when below this % health
	HealPercent        = 30,     -- 0-100
	AntiAFK            = true,   -- prevent server AFK kicks
	AbilityCooldown    = 1.5,    -- seconds between attacks
	HealDelay          = 2,      -- seconds between heals
	LootIgnoreRadius   = 5,      -- don't chase loot closer than this
	AFKInterval        = 60,     -- seconds between AFK nudges
}

-- Substring hints that identify "enemies" inside the Workspace.
-- Adjust these to match Anime Gatefall's actual hierarchy.
local ENEMY_HINTS = {
	"Enemy", "Enemies", "Mob", "Mobs", "Zombie", "NPC",
	"Boss", "Fodder", "Monster", "Monsters",
}

-- Substring hints that identify collectible "loot".
local LOOT_HINTS = {
	"Orb", "Orbs", "Coin", "Coins", "Loot", "Drop", "Drops",
	"Item", "Items", "EXP", "Money", "Gem",
}

-- Reserved for remote-based revive/tp features.
local RESPAWN_REMOTE_NAMES = { "Respawn", "Revive", "Teleport" }

-- ============================================================================
-- STATE
-- ============================================================================
local toggles = {}
local session = {
	start = tick(),
	kills = 0,
	coins = 0,
	targetKey = nil,   -- current enemy reference to avoid double counting
}
local lastDeath = 0
local lastAttack = 0
local lastHeal = 0
local lastAFK = 0

-- ============================================================================
-- UI
-- ============================================================================
local function buildUI()
	local ui = Instance.new("ScreenGui")
	ui.Name = "AutoFarmUI"
	ui.ResetOnSpawn = false
	ui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "Main"
	frame.Size = UDim2.new(0, 220, 0, 300)
	frame.Position = UDim2.new(0, 10, 0.5, -150)
	frame.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Draggable = true
	frame.Parent = ui

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
	title.BorderSizePixel = 0
	title.Text = "Auto Farm"
	title.TextColor3 = Color3.fromRGB(255, 210, 0)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.Parent = frame

	local statsLabel = Instance.new("TextLabel")
	statsLabel.Name = "Stats"
	statsLabel.Size = UDim2.new(1, 0, 0, 44)
	statsLabel.Position = UDim2.new(0, 0, 1, -44)
	statsLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
	statsLabel.BorderSizePixel = 0
	statsLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
	statsLabel.Font = Enum.Font.Gotham
	statsLabel.TextSize = 12
	statsLabel.TextWrapped = true
	statsLabel.Parent = frame

	local function addToggle(name, label)
		local row = Instance.new("TextButton")
		row.Size = UDim2.new(1, -20, 0, 26)
		row.BackgroundColor3 = Color3.fromRGB(60, 60, 200)
		row.BorderSizePixel = 0
		row.Text = label .. "  [ON]"
		row.TextColor3 = Color3.fromRGB(255, 255, 255)
		row.Font = Enum.Font.Gotham
		row.TextSize = 13
		row.Parent = frame

		local count = 0
		for _ in pairs(toggles) do count = count + 1 end
		row.Position = UDim2.new(0, 10, 0, 36 + count * 30)

		local enabled = true
		row.MouseButton1Click:Connect(function()
			enabled = not enabled
			row.Text = label .. (enabled and "  [ON]" or "  [OFF]")
			row.BackgroundColor3 = enabled and Color3.fromRGB(60, 60, 200) or Color3.fromRGB(120, 60, 60)
		end)

		toggles[name] = {
			row = row,
			set = function(on)
				enabled = on
				row.Text = label .. (enabled and "  [ON]" or "  [OFF]")
				row.BackgroundColor3 = enabled and Color3.fromRGB(60, 60, 200) or Color3.fromRGB(120, 60, 60)
			end,
			get = function() return enabled end,
		}
	end

	addToggle("AutoFarm", "Auto Farm")
	addToggle("AutoAttack", "Auto Attack")
	addToggle("AutoCollect", "Auto Collect")
	addToggle("AutoRevive", "Auto Revive")
	addToggle("AutoHeal", "Auto Heal")
	addToggle("AntiAFK", "Anti AFK")

	return statsLabel
end

local statsLabel = buildUI()

-- ============================================================================
-- HELPERS
-- ============================================================================
local function getCharacter()
	return player.Character
end

local function getHumanoid(char)
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function getRoot(char)
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function distance(a, b)
	return (a - b).Magnitude
end

local function isAlive(char)
	local hum = getHumanoid(char)
	return char and hum and hum.Health > 0
end

local function updateStats()
	local elapsed = math.floor(tick() - session.start)
	local mins = math.floor(elapsed / 60)
	local secs = elapsed % 60
	statsLabel.Text = string.format(
		"Kills: %d   Coins: %d\nTime: %02d:%02d",
		session.kills, session.coins, mins, secs
	)
end

-- ============================================================================
-- LOOKUP (recursive scan of the Workspace, resilient to game layout)
-- ============================================================================
local function scanByName(container, hints, results, depth)
	depth = depth or 0
	if depth > 8 then return end
	for _, child in ipairs(container:GetChildren()) do
		for _, hint in ipairs(hints) do
			if child.Name:lower():find(hint:lower(), 1, true) then
				results[#results + 1] = child
				break
			end
		end
		local t = child.ClassName
		if t == "Folder" or t == "Model" or t == "Workspace" then
			scanByName(child, hints, results, depth + 1)
		end
	end
end

local function getPart(target)
	if target:IsA("BasePart") then return target end
	return target:FindFirstChild("HumanoidRootPart")
		or target:FindFirstChild("Torso")
		or target:FindFirstChildWhichIsA("BasePart")
end

-- Nearest enemy part within maxDistance. Also returns its containing model.
local function getNearestEnemy(maxDistance)
	local root = getRoot(getCharacter())
	if not root then return nil, nil end

	local results = {}
	scanByName(Workspace, ENEMY_HINTS, results)

	local nearestPart, nearestModel, bestDist = nil, nil, maxDistance
	for _, obj in ipairs(results) do
		local part = getPart(obj)
		if part then
			local dist = distance(root.Position, part.Position)
			if dist < bestDist then
				nearestPart, nearestModel, bestDist = part, obj, dist
			end
		end
	end
	return nearestPart, nearestModel
end

-- Nearest loot part within maxDistance.
local function getNearestLoot(maxDistance)
	local root = getRoot(getCharacter())
	if not root then return nil end

	local results = {}
	scanByName(Workspace, LOOT_HINTS, results)

	local nearest, bestDist = nil, maxDistance
	for _, obj in ipairs(results) do
		local part = getPart(obj)
		if part then
			local dist = distance(root.Position, part.Position)
			if dist < bestDist and dist > CONFIG.LootIgnoreRadius then
				nearest, bestDist = part, dist
			end
		end
	end
	return nearest
end

-- ============================================================================
-- MOVEMENT
-- ============================================================================
local function moveTo(position)
	local hum = getHumanoid(getCharacter())
	if not hum then return end
	hum:MoveTo(position)
end

local function faceTowards(position)
	local root = getRoot(getCharacter())
	if not root then return end
	local delta = position - root.Position
	if delta.Magnitude < 0.01 then return end
	local look = delta.Unit
	root.CFrame = CFrame.lookAt(root.Position, root.Position + Vector3.new(look.X, 0, look.Z))
end

-- ============================================================================
-- COMBAT
-- ============================================================================
local function equipFirstTool()
	for _, tool in ipairs(player.Backpack:GetChildren()) do
		local t = tool.ClassName
		if t == "Tool" or t == "Hopperbin" then
			local hum = getHumanoid(getCharacter())
			if hum then
				hum:EquipTool(tool)
				return
			end
		end
	end
end

local function tryAttack()
	equipFirstTool()
	local char = getCharacter()
	local equipped = char and char:FindFirstChildOfClass("Tool")
	if not equipped then return false end

	local now = tick()
	if now - lastAttack < CONFIG.AbilityCooldown then return false end

	equipped:Activate()
	lastAttack = now
	return true
end

-- ============================================================================
-- HEALING
-- ============================================================================
local function isHealItem(item)
	if item.ClassName == "Tool" then
		local n = item.Name:lower()
		if n:find("potion", 1, true) or n:find("food", 1, true)
			or n:find("heal", 1, true) or n:find("apple", 1, true)
			or n:find("bread", 1, true) or n:find("bandage", 1, true) then
			return true
		end
	end
	return false
end

local function tryHeal()
	local hum = getHumanoid(getCharacter())
	if not hum or hum.MaxHealth <= 0 then return end

	local percent = (hum.Health / hum.MaxHealth) * 100
	if percent > CONFIG.HealPercent then return end

	local now = tick()
	if now - lastHeal < CONFIG.HealDelay then return end

	for _, item in ipairs(player.Backpack:GetChildren()) do
		if isHealItem(item) then
			local hum2 = getHumanoid(getCharacter())
			if hum2 then
				hum2:EquipTool(item)
				if item.ClassName == "Tool" then
					item:Activate()
				end
			end
			lastHeal = now
			return true
		end
	end
	return false
end

-- ============================================================================
-- REVIVE (best-effort; see README)
-- ============================================================================
local function tryRespawn()
	local char = getCharacter()
	if not char then return end

	local containers = { Workspace, game:GetService("ReplicatedStorage"), char }
	for _, c in ipairs(containers) do
		for _, child in ipairs(c:GetChildren()) do
			local n = child.Name:lower()
			for _, rname in ipairs(RESPAWN_REMOTE_NAMES) do
				if n:find(rname:lower(), 1, true) then
					if child:IsA("RemoteEvent") then
						pcall(function() child:FireServer() end)
						return
					elseif child:IsA("RemoteFunction") then
						pcall(function() child:InvokeServer() end)
						return
					end
				end
			end
		end
	end
	-- No matching remote found: nothing more the client can safely do.
end

local function handleDeath()
	local hum = getHumanoid(getCharacter())
	if not hum or hum.Health > 0 then return end

	local now = tick()
	if now - lastDeath <= CONFIG.ReviveDelay then return end

	if toggles["AutoRevive"]:get() then
		tryRespawn()
	end
	lastDeath = now
end

-- ============================================================================
-- ANTI-AFK
-- ============================================================================
local function antiAFK()
	local now = tick()
	if now - lastAFK < CONFIG.AFKInterval then return end

	local hum = getHumanoid(getCharacter())
	local root = getRoot(getCharacter())
	if hum and root then
		-- Nudge the humanoid so the server sees activity.
		hum.Jump = true
		root.AssemblyLinearVelocity = root.AssemblyLinearVelocity
			+ Vector3.new(math.random(-2, 2), 0, math.random(-2, 2))
	end
	lastAFK = now
end

-- ============================================================================
-- CHAT COMMANDS
-- ============================================================================
local CHAT_HANDLERS = {
	["!farm"] = function()
		toggles["AutoFarm"]:set(not toggles["AutoFarm"]:get())
	end,
	["!collect"] = function()
		toggles["AutoCollect"]:set(not toggles["AutoCollect"]:get())
	end,
	["!heal"] = function()
		toggles["AutoHeal"]:set(not toggles["AutoHeal"]:get())
	end,
	["!revive"] = function()
		toggles["AutoRevive"]:set(not toggles["AutoRevive"]:get())
	end,
	["!afk"] = function()
		toggles["AntiAFK"]:set(not toggles["AntiAFK"]:get())
	end,
	["!attack"] = function()
		toggles["AutoAttack"]:set(not toggles["AutoAttack"]:get())
	end,
}

-- React to the player's own chat messages. Note: on the client, PlayerChatted
-- fires for the local player's sent messages; the game must allow chat.
local function onChatted(message)
	local key = message:lower()
	local handler = CHAT_HANDLERS[key]
	if handler then
		handler()
	end
end

-- ============================================================================
-- MAIN LOOP
-- ============================================================================
local function farmTick()
	local char = getCharacter()
	if not isAlive(char) then
		handleDeath()
		return
	end

	-- 1) Collect loot first so we don't miss drops.
	if toggles["AutoCollect"]:get() then
		local loot = getNearestLoot(CONFIG.CollectRange)
		if loot then
			faceTowards(loot.Position)
			moveTo(loot.Position)
		end
	end

	-- 2) Engage the nearest enemy.
	local targetPart, targetModel = getNearestEnemy(CONFIG.AttackRange)
	if targetPart then
		faceTowards(targetPart.Position)
		moveTo(targetPart.Position)

		local key = tostring(targetModel or targetPart)
		if session.targetKey ~= key then
			-- New encounter: attempt the first hit.
			if tryAttack() then
				session.targetKey = key
				session.kills = session.kills + 1
			end
		elseif tryAttack() then
			-- Already engaged: keep swinging on cooldown.
		end
	end

	-- 3) Heal when low.
	tryHeal()

	-- 4) Anti-AFK.
	antiAFK()

	updateStats()
end

-- Master toggle decides whether the tick does anything at all.
RunService.Heartbeat:Connect(function()
	if not CONFIG.AutoFarm then return end
	if not toggles["AutoFarm"]:get() then return end
	farmTick()
end)

-- Reset state whenever the character respawns.
local function onCharacterAdded(newChar)
	character = newChar
	session.targetKey = nil
	lastAttack = 0
	lastHeal = 0
	lastDeath = tick()
end
player.CharacterAdded:Connect(onCharacterAdded)

-- Wire up chat commands.
if player.Chatted then
	player.Chatted:Connect(onChatted)
end

warn("[AutoFarm] Loaded. Use the on-
