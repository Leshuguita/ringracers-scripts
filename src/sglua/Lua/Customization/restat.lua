--original code by Tyron (hostmod)
--HUD stuff by spee
--namespaced, ring-raced and anti-PRNG'd by GenericHeroGuy

local hostmod_restat = CV_RegisterVar({
	name = "hm_restat",
	defaultvalue = "On",
	flags = CV_NETVAR,
	possiblevalue = CV_OnOff,
	description = "Allow players to change their stats."
})
local hostmod_restatnotify = CV_RegisterVar({
	name = "hm_restat_notify",
	defaultvalue = "On",
	flags = CV_NETVAR,
	possiblevalue = CV_OnOff,
	description = "Notify when someone changes their stats."
})

local fmt = string.format

-- common reused strings
local function statstring(s, w)
	return fmt("%d{{ RS_SPD }}, %d{{ RS_WT }}", s, w)
end
local function statusstring(p)
	local rs = p.hostmod.restat
	if rs.skin ~= "" then
		return fmt("%s (%s)", rs.skin, statstring(rs.pendingspeed, rs.pendingweight))
	elseif rs.pendingspeed then
		return statstring(rs.pendingspeed, rs.pendingweight)
	else
		return "{{ RS_DEFAULT }}"
	end
end
local function usage(p, str)
	CONS_Printf(p, str)
	CONS_Printf(p, fmt("{{ RS_HELP }}", p.hostmod.restat.pendingspeed and "off" or "random"))
end

local function initstats(p)
	if p.hostmod == nil then
		-- no trapping yet
		p.hostmod = {}--setmetatable({}, { __index = function(_, k) error("Attempt to read "..tostring(k), 2) end, __newindex = function(_, k) error("Attempt to write "..tostring(k), 2) end })
		p.hostmod.restat = { speed = 0, weight = 0, pendingspeed = 0, pendingweight = 0, random = false, skin = "" }
	end
end

-- apply and announce stat change
local function updatestats(p)
	initstats(p)

	local rs = p.hostmod.restat

	if rs.random then
		rs.pendingspeed = P_RandomRange(1, 9)
		rs.pendingweight = P_RandomRange(1, 9)
		rs.skin = "random"
	end

	if rs.pendingspeed ~= rs.speed or rs.pendingweight ~= rs.weight then
		rs.speed = rs.pendingspeed
		rs.weight = rs.pendingweight
		if not rs.speed then
			p.kartspeed = skins[p.mo.skin].kartspeed
			p.kartweight = skins[p.mo.skin].kartweight
		end
		if hostmod_restatnotify.value then
			if rs.speed then
				if rs.skin ~= "" then
					chatprint(fmt("{{ RS_USING_CHAR }}", p.name, rs.skin, statstring(rs.speed, rs.weight)), true)
				else
					chatprint(fmt("{{ RS_USING_STATS }}", p.name, statstring(rs.speed, rs.weight)), true)
				end
			else
				chatprint(fmt("{{ RS_USING_DEFAULT }}", p.name), true)
			end
		end
	end
end

local function findSkin(name)
	-- First, search by id
	for skin in skins.iterate do
		if name == skin.name:lower() then
			return skin
		end
	end

	-- Couldn't find by id, now try to find skin by realname
	for skin in skins.iterate do
		if name == skin.realname:lower() then
			return skin
		end
	end
end

-- whee, text command parsing! this is always the worst.
COM_AddCommand("restat", function(p, ...)
	-- maybe i should dynamically register and unregister the command in this situation?
	if not hostmod_restat.value then
		CONS_Printf(p, "{{ RS_DISABLED }}")
		return
	end

	local args = {...}
	local nspeed, nweight = tonumber(args[1]), tonumber(args[2])
	local cmd = args[1]

	initstats(p)
	local rs = p.hostmod.restat

	if not cmd then
		usage(p, fmt("{{ RS_CURRENT_CHAR }}", statusstring(p)))
		return
	elseif cmd == "random" then
		rs.random = true
		CONS_Printf(p, "{{ RS_RANDOM_ON_1 }}")
		CONS_Printf(p, "{{ RS_RANDOM_ON_2 }}")
		return
	elseif cmd == "randomonce" then
		nspeed = P_RandomRange(1, 9)
		nweight = P_RandomRange(1, 9)
		--rs.skin = "random" -- Flex
	elseif cmd == "default" or cmd == "reset" or cmd == "off" then
		rs.pendingspeed = 0
		rs.pendingweight = 0
		rs.random = false
		rs.skin = ""
		CONS_Printf(p, fmt("{{ RS_TURNED_OFF }}", rs.random and "{{ RS_RANDOM_NAME }}" or "{{ RS_RESTAT_NAME }}"))
		return
	elseif nspeed ~= nil and nweight ~= nil then
		if min(nspeed, nweight) < 1 or max(nspeed, nweight) > 9 then
			CONS_Printf(p, "{{ RS_OOB }}")
			return
		end
		rs.skin = ""
	else
		local fug = table.concat(args, " "):lower()
		local skin = findSkin(fug)
		if skin then
			nspeed = skin.kartspeed
			nweight = skin.kartweight
			rs.skin = skin.realname
		else
			usage(p, "{{ RS_SKIN_NOT_FOUND }}")
			return
		end
	end

	-- update pending stats. we'll apply these for real when it's appropriate.
	rs.pendingspeed = nspeed
	rs.pendingweight = nweight

	if rs.random then
		rs.random = false
		CONS_Printf(p, "{{ RS_RANDOM_OFF }}")
	end

	CONS_Printf(p, fmt("{{ RS_STATS_CHOSEN_1 }}", statstring(nspeed, nweight)))
	CONS_Printf(p, "{{ RS_STATS_CHOSEN_2 }}")
end)

addHook("ThinkFrame", function()
	if not hostmod_restat.value then return end

	if leveltime == 1 then
		for p in players.iterate do updatestats(p) end
	end

	for p in players.iterate
		local rs = p.hostmod and p.hostmod.restat
		-- fuck off if we need to fuck off
		if p.spectator or not rs then continue end
		-- lock our stats
		if rs.speed then
			p.kartspeed = rs.speed
			p.kartweight = rs.weight
		end
	end
end)

local function stringdraw(v, x, y, str, flags, colormap)
	for i = 1, #str do
		local char = str:sub(i, i)
		local patch = v.cachePatch(string.format("OPPRF%03d", char:byte()))
		v.drawScaled(x, y, FRACUNIT, patch, flags, colormap)
		x = x + 6*FRACUNIT
	end
end

--Hud
hud.add(function(v, p)
	local flags = V_SNAPTOLEFT | V_SNAPTOBOTTOM | V_SLIDEIN

	v.draw(17, 189, v.cachePatch("GFXHUS"), flags)
	v.draw(37, 189, v.cachePatch("GFXHUW"), flags)

	local smap = v.getColormap(TC_RAINBOW, SKINCOLOR_ORANGE)
	local wmap = v.getColormap(TC_RAINBOW, SKINCOLOR_BLUE)
	stringdraw(v, 28*FRACUNIT, 191*FRACUNIT, tostring(p.kartspeed), flags, smap)
	stringdraw(v, 48*FRACUNIT, 191*FRACUNIT, tostring(p.kartweight), flags, wmap)
end)
