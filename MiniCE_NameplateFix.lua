-- MiniCE_NameplateFix
-- Blizzard's nameplate aura icons come from a frame pool whose released frames have no parent. RefreshList
-- (Blizzard_NamePlateAuras.lua:271-275) sets an icon's cooldown in SetAura *before* SetParent(listFrame), so
-- MiniCE sees the cooldown with no nameplate above it, can't claim it, and marks it "not mine" for good
-- (HookBridge.lua ProcessCooldownUpdate -> Registry:MarkNegative). Its nameplate timers then stay unstyled.
--
-- Fix: after each RefreshList, register every shown icon's cooldown with MiniCE as a nameplate cooldown (this
-- also clears the "not mine" mark) and let MiniCE style it. The hook is per AurasFrame instance, added when a
-- plate first gets a unit, so Blizzard's shared mixin is never touched.
--
-- Threshold colors: MiniCE never applies its "Color by Remaining Time" thresholds to nameplates
-- (DurationColorController.lua IsThresholdColorAllowedForSource). Below, each claimed timer is colored with
-- MiniCE's threshold curve from the aura's Duration object (C_UnitAuras.GetAuraDuration). The client only gives
-- addons that Duration while auras are not restricted (ShouldAurasBeSecret() false; the API needs aura access
-- and rejects secret arguments from addon code). While restricted, timers keep MiniCE's static nameplate color.

local MCE = LibStub("AceAddon-3.0"):GetAddon("MinimalistCooldownEdge", true)
if (not MCE) then return end

local CATEGORY = "nameplate"
local hooked = setmetatable({}, {__mode = "k"})
local tracked = setmetatable({}, {__mode = "k"})	-- aura item -> its cooldown
local StartTicker

local function Enabled()
	local profile = MCE.db and MCE.db.profile
	local config = profile and profile.categories and profile.categories[CATEGORY]
	return config and config.enabled and not (MCE.IsBetterBlizzPlatesAvailable and MCE:IsBetterBlizzPlatesAvailable())
end

local function Claim(listFrame)
	if (not Enabled() or not listFrame or listFrame:IsForbidden()) then
		return
	end
	local registry = MCE:GetModule("TargetRegistry", true)
	local engine = MCE:GetModule("StyleEngine", true)
	if (not registry or not engine) then
		return
	end
	for _, item in ipairs({listFrame:GetChildren()}) do
		local cooldown = item.Cooldown
		if (cooldown and not cooldown:IsForbidden() and MCE:CanUseFrameAsTableKey(cooldown)) then
			if (registry:GetCategory(cooldown) ~= CATEGORY) then
				registry:Register(cooldown, CATEGORY)
				engine:ApplyStyle(cooldown, CATEGORY)
			end
			tracked[item] = cooldown
		end
	end
end

local function HookPlate(unit)
	local plate = C_NamePlate.GetNamePlateForUnit(unit)
	local auras = plate and not plate:IsForbidden() and plate.UnitFrame and plate.UnitFrame.AurasFrame
	if (not auras or hooked[auras] or type(auras.RefreshList) ~= "function") then
		return
	end
	hooked[auras] = true
	hooksecurefunc(auras, "RefreshList", function(_, listFrame)
		securecallfunction(Claim, listFrame)
	end)
	-- Icons already shown before the hook existed
	for _, key in ipairs({"DebuffListFrame", "BuffListFrame", "CrowdControlListFrame"}) do
		securecallfunction(Claim, auras[key])
	end
	StartTicker()
end

-- Threshold colors ------------------------------------------------------------------------------------------

local issecretvalue = issecretvalue or function() return false end
local TICK = 0.2

local function NameplateConfig()
	local profile = MCE.db and MCE.db.profile
	return profile and profile.categories and profile.categories[CATEGORY]
end

-- MiniCE's threshold curve, or nil when "Color by Remaining Time" is off. MiniCE hands it out for any category
-- that allows thresholds; the unit frame key is used because nameplates are refused.
local THRESHOLD_SOURCE = "unitframe"
local THRESHOLD_CONFIG = {enabled = true, allowThresholdColors = true}
local function ThresholdCurve()
	local profile = MCE.db and MCE.db.profile
	if (not (profile and profile.durationTextColors and profile.durationTextColors.enabled)) then
		return nil
	end
	local colors = MCE:GetModule("DurationColorController", true)
	return colors and colors:GetDurationTextCurve(THRESHOLD_SOURCE, THRESHOLD_CONFIG)
end

local function Plain(value)
	return value ~= nil and not issecretvalue(value) and value or nil
end

local function Duration(item)
	local unit, id = Plain(item.unitToken), Plain(item.auraInstanceID)
	if (type(unit) ~= "string" or type(id) ~= "number") then
		return nil
	end
	local ok, duration = pcall(C_UnitAuras.GetAuraDuration, unit, id)
	return ok and duration or nil
end

-- true if the timer got a threshold color
local function ColorItem(item, cooldown, curve, engine)
	local duration = curve and Duration(item)
	if (duration) then
		local ok, color = pcall(duration.EvaluateRemainingDuration, duration, curve)
		if (ok and color) then
			engine:ApplyRGBAColorToCooldownRegions(cooldown, color:GetRGBA())
			return true
		end
	end
	return false
end

-- Global on Forever (TPerl uses it), namespaced on Midnight
local ShouldAurasBeSecretFn = (C_Secrets and C_Secrets.ShouldAurasBeSecret) or _G.ShouldAurasBeSecret
local function AurasRestricted()
	return ShouldAurasBeSecretFn ~= nil and ShouldAurasBeSecretFn() and true or false
end

local colored = setmetatable({}, {__mode = "k"})	-- cooldowns currently showing a threshold color

local function Tick()
	local engine = MCE:GetModule("StyleEngine", true)
	if (not engine or not Enabled()) then
		return
	end
	local curve = ThresholdCurve()
	local restricted = AurasRestricted()
	local config = NameplateConfig()
	for item, cooldown in pairs(tracked) do
		local shown = item:IsVisible()
		if (shown and not issecretvalue(shown) and not restricted and ColorItem(item, cooldown, curve, engine)) then
			colored[cooldown] = true
		elseif (colored[cooldown]) then
			colored[cooldown] = nil
			engine:ResetCountdownTextColor(cooldown, config)
		end
	end
end

local ticker
function StartTicker()
	if (not ticker) then
		ticker = C_Timer.NewTicker(TICK, function() securecallfunction(Tick) end)
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:SetScript("OnEvent", function(_, _, unit)
	if (type(unit) == "string" and not (issecretvalue and issecretvalue(unit))) then
		HookPlate(unit)
	end
end)
