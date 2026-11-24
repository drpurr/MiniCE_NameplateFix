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
-- (DurationColorController.lua IsThresholdColorAllowedForSource). Each claimed timer instead gets a countdown
-- formatter carrying MiniCE's threshold colors (see the Threshold colors section below).

local MCE = LibStub("AceAddon-3.0"):GetAddon("MinimalistCooldownEdge", true)
if (not MCE) then return end

local CATEGORY = "nameplate"
local hooked = setmetatable({}, {__mode = "k"})
local tracked = setmetatable({}, {__mode = "k"})	-- aura item -> its cooldown
local ApplyThresholdColors

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
			ApplyThresholdColors(cooldown)
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
end

-- Threshold colors ------------------------------------------------------------------------------------------
-- In combat the nameplate timer's start/duration are secret and addon code cannot turn them into a remaining
-- time (/npfix showed startSecret=true, restricted=true). The client can: a Cooldown's countdown text goes through
-- its NumericFormatter (SetCountdownFormatter), evaluated client-side on the real remaining time. So each timer
-- gets a formatter whose breakpoints are MiniCE's threshold bands, each band's format wrapped in that band's
-- color code. Rebuilt whenever MiniCE settings change, so new colors apply right away.

local CreateFormatter = C_StringUtil and C_StringUtil.CreateNumericRuleFormatter

local function ColorCode(color)
	local function Byte(value)
		return math.floor(math.max(0, math.min(1, tonumber(value) or 1)) * 255 + 0.5)
	end
	return format("|cff%02x%02x%02x", Byte(color.r), Byte(color.g), Byte(color.b))
end

-- MiniCE's bands, as in its BuildColorCurve: first color from 0, color i from threshold[i-1] + offset, the
-- default color from the last threshold + offset.
local function ColorBands(config)
	local thresholds = config.thresholds
	if (type(thresholds) ~= "table" or #thresholds == 0) then
		return nil
	end
	local sorted = {}
	for i = 1, #thresholds do
		sorted[i] = thresholds[i]
	end
	table.sort(sorted, function(a, b) return (a.threshold or 0) < (b.threshold or 0) end)
	local offset = type(config.offset) == "number" and config.offset or 0
	local bands = {{at = 0, code = ColorCode(sorted[1].color or {})}}
	for i = 2, #sorted do
		bands[#bands + 1] = {at = math.max(0, (sorted[i - 1].threshold or 0) + offset), code = ColorCode(sorted[i].color or {})}
	end
	if (config.defaultColor) then
		bands[#bands + 1] = {at = math.max(0, (sorted[#sorted].threshold or 0) + offset), code = ColorCode(config.defaultColor)}
	end
	return bands
end

-- MiniCE's countdown number format (its GetNativeDurationFormatter): seconds, then minutes, then hours.
local function NumberRules(profile)
	local constants = MCE.Constants and MCE.Constants.Options or {}
	local abbrev = tonumber(profile.abbrevThreshold or constants.DefaultAbbrevThreshold) or 90
	local millis = tonumber(profile.countdownMillisecondsThreshold or constants.DefaultMillisecondsThreshold) or 0
	abbrev, millis = math.max(0, abbrev), math.max(0, millis)
	local down, up = Enum.NumericRuleFormatRounding.Down, Enum.NumericRuleFormatRounding.Up
	local minuteAt = math.max(abbrev + 1, millis)
	local hourAt = math.max(abbrev * 60 + 1, minuteAt + 1)
	local rules = {}
	if (millis > 0) then
		rules[#rules + 1] = {at = 0, rule = {step = 0.1, format = "%.1f"}}
		if (minuteAt > millis) then
			rules[#rules + 1] = {at = millis, rule = {step = 1, rounding = down, min = 1, format = "%d"}}
		end
	else
		rules[#rules + 1] = {at = 0, rule = {step = 1, rounding = down, min = 1, format = "%d"}}
	end
	rules[#rules + 1] = {at = minuteAt, rule = {step = 1, rounding = down, min = 1, format = "%dm", components = {{div = 60, rounding = up}}}}
	rules[#rules + 1] = {at = hourAt, rule = {step = 1, rounding = down, min = 1, format = "%dh", components = {{div = 3600, rounding = up}}}}
	return rules
end

local function ActiveAt(list, value)
	local active = list[1]
	for _, entry in ipairs(list) do
		if (entry.at <= value) then
			active = entry
		end
	end
	return active
end

local formatter	-- current colored formatter, or false when threshold colors are off

local function BuildFormatter()
	local profile = MCE.db and MCE.db.profile
	local config = profile and profile.durationTextColors
	if (not (config and config.enabled and CreateFormatter)) then
		return false
	end
	local bands, rules = ColorBands(config), NumberRules(profile)
	if (not bands) then
		return false
	end
	-- One breakpoint at every point where either the color band or the number format changes.
	local cuts, seen = {}, {}
	for _, list in ipairs({bands, rules}) do
		for _, entry in ipairs(list) do
			if (not seen[entry.at]) then
				seen[entry.at] = true
				cuts[#cuts + 1] = entry.at
			end
		end
	end
	table.sort(cuts)
	local breakpoints = {}
	for _, at in ipairs(cuts) do
		local rule = ActiveAt(rules, at).rule
		local breakpoint = {threshold = at, format = ActiveAt(bands, at).code .. rule.format .. "|r"}
		for key, value in pairs(rule) do
			if (key ~= "format") then
				breakpoint[key] = value
			end
		end
		breakpoints[#breakpoints + 1] = breakpoint
	end
	local ok, created = pcall(function()
		local fmt = CreateFormatter()
		fmt:SetBreakpoints(breakpoints)
		return fmt
	end)
	return ok and created or false
end

local function Formatter()
	if (formatter == nil) then
		formatter = BuildFormatter()
	end
	return formatter or nil
end

local applied = setmetatable({}, {__mode = "k"})	-- cooldown -> formatter it currently has

ApplyThresholdColors = function(cooldown)
	local fmt = Formatter()
	if (applied[cooldown] == (fmt or false) or not cooldown.SetCountdownFormatter) then
		return
	end
	if (pcall(cooldown.SetCountdownFormatter, cooldown, fmt)) then
		applied[cooldown] = fmt or false
	end
end

-- MiniCE runs ForceUpdateAll after every option change; rebuild the formatter and re-apply it.
local refreshTimer
hooksecurefunc(MCE, "ForceUpdateAll", function()
	if (refreshTimer) then
		refreshTimer:Cancel()
	end
	refreshTimer = C_Timer.NewTimer(0.3, function()
		refreshTimer = nil
		formatter = nil
		for _, cooldown in pairs(tracked) do
			securecallfunction(ApplyThresholdColors, cooldown)
		end
	end)
end)

local events = CreateFrame("Frame")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:SetScript("OnEvent", function(_, _, unit)
	if (type(unit) == "string" and not (issecretvalue and issecretvalue(unit))) then
		HookPlate(unit)
	end
end)

