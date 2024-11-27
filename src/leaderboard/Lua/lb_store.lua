-- This file handles the storage and related netvars of the leaderboard

---- Imported functions ----

-- lb_common.lua
local stat_t = lb_stat_t
local lbComp = lb_comp
local score_t = lb_score_t
local player_t = lb_player_t
local mapChecksum = lb_map_checksum
local mapnumFromExtended = lb_mapnum_from_extended
local ticsToTime = lb_TicsToTime
local StringReader = lb_string_reader
local StringWriter = lb_string_writer
local ghost_t = lb_ghost_t

----------------------------

local RINGS = VERSION == 2
local open = RINGS and function(path, mode) return io.openlocal("client/"..path, mode) end or io.open

local LEADERBOARD_VERSION = 2
local GHOST_VERSION = 1

local OLD_STARTTIME = 6*TICRATE + (3*TICRATE/4) -- starttime for version 1 records

local reloadstore = false

local diffcache, deletecache

local cv_directory = CV_RegisterVar({
	name = "lb_directory",
	flags = CV_NETVAR|CV_CALL|CV_NOINIT,
	defaultvalue = "",
	func = function(cv)
		if replayplayback then return end
		reloadstore = true
		print("Store changed to "..cv.string)
		if consoleplayer and lines[0] then
			print("Restart the map to load the store.")
		end
	end
})

-- Livestore are new records nad records loaded from leaderboard.txt file
local LiveStore

-- name of loaded store
local StoreName

-- next available ID for records
local NextID

-- which records are waiting to be written to the coldstore
local Dirty

local function isSameRecord(a, b, modeSep)
	if (a.flags & modeSep) ~= (b.flags & modeSep)
	or #a.players ~= #b.players then return false end
	for i = 1, #a.players do
		if a.players[i].name ~= b.players[i].name then return false end
	end
	return true
end

-- insert or replace the score in dest
-- returns true if inserted, false if (maybe) replaced
local function insertOrReplace(dest, score, modeSep)
	for i, record in ipairs(dest) do
		if isSameRecord(record, score, modeSep) then
			if lbComp(score, record) then
				dest[i] = score
				score.id = record.id
			end
			return false
		end
	end

	table.insert(dest, score)
	return true
end

local function postfix(filename, str)
	local i = #filename - filename:reverse():find(".", 1, true)
	return filename:sub(1, i)..str..filename:sub(i+1)
end

local function write_segmented(filename, data)
	local fnum = 0
	for i = 1, #data, 1048576 do
		local out = assert(
			open(postfix(filename, "_"..fnum), "wb"),
			"Failed to open file for writing: "..filename
		)
		out:write(data:sub(i, i+1048575))
		out:close()
		fnum = $ + 1
	end
	repeat
		local old = open(postfix(filename, "_"..fnum), "rb")
		if old then
			old:close()
			old = open(postfix(filename, "_"..fnum), "wb")
			old:close()
			fnum = $ + 1
		end
	until not old
end

local function read_segmented(filename)
	local fnum = 0
	local data = {}
	while true do
		local f = open(postfix(filename, "_"..fnum), "rb")
		if not (f and f:read(0)) then
			break
		end
		table.insert(data, f:read("*a"))
		f:close()
		fnum = $ + 1
	end
	data = table.concat($)
	return #data and StringReader(data) or nil
end

local function writeRecord(f, record)
	f:writenum(record.id)
	f:writenum(record.flags)
	f:writenum(record.time)
	f:writenum(record.starttime)
	f:write8(#record.splits)
	for _, v in ipairs(record.splits) do
		f:writenum(v)
	end
	f:write8(#record.players)
	for _, p in ipairs(record.players) do
		f:writestr(p.name)
		f:writestr(p.skin)
		f:writestr(p.appear)
		f:write8(p.color)
		f:write8(p.stat)
	end
end

local function writeCount(f, table)
	local count = 0
	for _ in pairs(table) do
		count = $ + 1
	end
	f:writenum(count)
end

local function writeMapStore(f, store)
	writeCount(f, store)
	for map, checksums in pairs(store) do
		f:writestr(G_BuildMapName(map))
		writeCount(f, checksums)
		for checksum, records in pairs(checksums) do
			f:write16(tonumber(checksum, 16))
			f:writenum(#records)
			for _, record in ipairs(records) do
				writeRecord(f, record)
			end
		end
	end
end

local function writeGhost(record, ghosts)
	local f = StringWriter()
	f:writeliteral("GHOST")
	f:write8(GHOST_VERSION)

	f:write8(#ghosts)
	for _, ghost in ipairs(ghosts) do
		f:writenum(ghost.startofs)
		f:writelstr(ghost.data)
	end

	local out = open(string.format("Leaderboard/%s/g%d.sav2", StoreName, record.id), "wb")
	out:write(table.concat(f))
	out:close()
end
rawset(_G, "lb_write_ghost", writeGhost)

local function readGhost(record)
	local f = StringReader(open(string.format("Leaderboard/%s/g%d.sav2", StoreName, record.id), "rb"))
	if not f or f:empty() then return nil end

	if f:readliteral(5) ~= "GHOST" then
		error("Failed to read ghost: bad magic", 2)
	end
	local version = f:read8()
	if version > GHOST_VERSION then
		error(string.format("Failed to read ghost: version %d not supported (highest is %d)", version, GHOST_VERSION), 2)
	end

	local ghosts = {}
	local numplayers = f:read8()
	for i = 1, numplayers do
		local startofs = f:readnum()
		local data = f:readlstr()
		ghosts[i] = ghost_t(data, startofs)
	end

	return ghosts
end
rawset(_G, "lb_read_ghost", readGhost)

-- can't delete a file, so best we can do is truncate it
local function deleteGhost(id)
	local f = open(string.format("Leaderboard/%s/g%d.sav2", StoreName, id), "rb")
	if f then
		f:close()
		f = open(string.format("Leaderboard/%s/g%d.sav2", StoreName, id), "wb")
		f:close()
	end
end
rawset(_G, "lb_delete_ghost", deleteGhost)

local function clearcache()
	diffcache, deletecache = nil, nil
end

local function writeColdStore(store)
	local f = StringWriter()
	f:writestr(StoreName)
	writeMapStore(f, store)
	return table.concat(f)
end

local function dumpStoreToFile()
	local f = StringWriter()
	f:writeliteral("LEADERBOARD")
	f:write8(LEADERBOARD_VERSION)

	f:writenum(NextID)

	writeCount(f, Dirty)
	for id in pairs(Dirty) do
		f:writenum(id)
	end

	writeMapStore(f, LiveStore)

	write_segmented(string.format("Leaderboard/%s/store.sav2", StoreName), table.concat(f))
end

local function recordsIdentical(a, b)
	if --[[a.id ~= b.id or]] a.flags ~= b.flags or a.time ~= b.time or #a.players ~= #b.players then return false end
	for i, s in ipairs(a.splits) do
		if s ~= b.splits[i] then return false end
	end
	for i, p in ipairs(a.players) do
		local bp = b.players[i]
		if p.name ~= bp.name or p.skin ~= bp.skin or p.color ~= bp.color or p.stat ~= bp.stat then return false end
	end
	return true
end

local function mergeStore(other, deletelist)
	-- first, get the IDs of all records in here
	local my_mapforid = {}
	for map, checksums in pairs(LiveStore) do
		for checksum, records in pairs(checksums)
			for i, record in ipairs(records) do
				my_mapforid[record.id] = { map = map, rec = record, checksum = checksum, i = i }
			end
		end
	end
	local other_mapforid = {}
	for map, checksums in pairs(other) do
		for checksum, records in pairs(checksums) do
			for i, record in ipairs(records) do
				other_mapforid[record.id] = { map = map, rec = record, checksum = checksum }
			end
		end
	end

	local gaps = {} -- which maps might have gaps

	-- check the ids of the other store's records to see if anything moved
	for id = 1, NextID do
		local my, ot = my_mapforid[id], other_mapforid[id]
		if not ot or deletelist[id] then
			-- server doesn't have record anymore
			if my then
				LiveStore[my.map][my.checksum][my.i] = false
			end
			--print(string.format("delete %d", id))
		elseif not my and ot then
			-- server has a record we don't have
			if not LiveStore[ot.map] then LiveStore[ot.map] = {} end
			if not LiveStore[ot.map][ot.checksum] then LiveStore[ot.map][ot.checksum] = {} end
			table.insert(LiveStore[ot.map][ot.checksum], ot.rec)
			--print(string.format("add %d %d", ot.map, id))
		elseif my and ot and (not recordsIdentical(my.rec, ot.rec) or my.map ~= ot.map or my.checksum ~= ot.checksum) then
			-- replace our record with the server's, wiping the ghost
			LiveStore[my.map][my.checksum][my.i] = false
			if not LiveStore[ot.map] then LiveStore[ot.map] = {} end
			if not LiveStore[ot.map][ot.checksum] then LiveStore[ot.map][ot.checksum] = {} end
			table.insert(LiveStore[ot.map][ot.checksum], ot.rec)
			--print(string.format("overwrite %d %d", my.map, id))
		else
			--print(string.format("passthrough %d %d", ot.map, id))
			continue
		end
		-- if we didn't continue, something's changed. wipe the ghosts
		if my then gaps[my.map] = true; deleteGhost(id) end
		if ot then gaps[ot.map] = true; deleteGhost(id) end
	end

	for map in pairs(gaps) do
		-- delete the gaps
		for checksum, records in pairs(LiveStore[map]) do
			for i = #records, 1, -1 do
				if not records[i] then
					table.remove(records, i)
				end
			end
			-- no records? delete the table to save space
			if not next(records) then
				LiveStore[map][checksum] = nil
			end
		end
	end
	Dirty = {} -- you won't be needing this anymore
	dumpStoreToFile()
end

-- GLOBAL
-- Returns a list of all maps with records
local function MapList()
	local maplist = {}
	for mapid, checksums in pairs(LiveStore) do
		if next(checksums) then
			table.insert(maplist, mapid)
		end
	end
	table.sort(maplist)

	return maplist
end
rawset(_G, "lb_map_list", MapList)

-- GLOBAL
-- Construct the leaderboard table of the supplied mapid
local function GetMapRecords(map, modeSep, checksum)
	local mapRecords = {}
	if not LiveStore then return mapRecords end

	local store = LiveStore[map] and LiveStore[map][checksum or mapChecksum(map)]
	if not store then return mapRecords end

	for _, record in ipairs(store) do
		local mode = record.flags & modeSep
		mapRecords[mode] = $ or {}
		table.insert(mapRecords[mode], record)
	end

	-- Sort records
	for _, records in pairs(mapRecords) do
		table.sort(records, lbComp)
	end

	return mapRecords
end
rawset(_G, "lb_get_map_records", GetMapRecords)

-- GLOBAL
-- Save a record to the LiveStore and write to disk
-- SaveRecord will replace the record holders previous record
local function SaveRecord(score, map, modeSep, ghosts)
	if not LiveStore then
		-- TODO perhaps a more prominent warning that nothing's being saved
		print("Can't save records, please set a server directory! (lb_directory)")
		return
	end
	LiveStore[map] = $ or {}
	LiveStore[map][mapChecksum(map)] = $ or {}
	local store = LiveStore[map][mapChecksum(map)]
	local inserted = insertOrReplace(store, score, modeSep)
	if inserted then
		score.id = NextID
		NextID = $ + 1
	end

	print("Saving score ("..score.id..")")
	if isserver then
		Dirty[score.id] = true
		if ghosts then
			writeGhost(score, ghosts)
		else
			deleteGhost(score.id)
		end
		dumpStoreToFile()
		clearcache()
	end
end
rawset(_G, "lb_save_record", SaveRecord)

local function oldParseScore(str)
	-- Leaderboard is stored in the following tab separated format
	-- mapnum, name, skin, color, time, splits, flags, stat
	local t = {}
	for word in (str.."\t"):gmatch("(.-)\t") do
		table.insert(t, word)
	end

	local splits = {}
	if t[6] != nil then
		for str in t[6]:gmatch("([^ ]+)") do
			table.insert(splits, tonumber(str))
		end
	end

	local flags = 0
	if t[7] != nil then
		flags = tonumber(t[7])
	end

	local stats = nil
	if t[8] != nil then
		if #t[8] >= 2 then
			local speed = tonumber(string.sub(t[8], 1, 1))
			local weight = tonumber(string.sub(t[8], 2, 2))
			stats = stat_t(speed, weight)
		end
	end

	local checksum = t[9] or ""
	-- thanks windows
	checksum = $:sub(1, 4)

	return score_t(
		flags,
		tonumber(t[5]),	-- Time
		OLD_STARTTIME,
		splits,
		{
			player_t(
				t[2], -- Name
				t[3], -- Skin
				"",
				tonumber(t[4]), -- Color
				stats
			)
		}
	), tonumber(t[1]), checksum
end
rawset(_G, "lb_parse_score", oldParseScore)

local function parseScoreBinary(f, version)
	local id = f:readnum()
	local flags = f:readnum()
	local time = f:readnum()
	local starttime = OLD_STARTTIME
	if version >= 2 then
		starttime = f:readnum()
	end

	local splits = {}
	local numsplits = f:read8()
	for i = 1, numsplits do
		table.insert(splits, f:readnum())
	end

	local players = {}
	local numplayers = f:read8()
	for i = 1, numplayers do
		local name = f:readstr()
		local skin = f:readstr()
		local appear = ""
		if version >= 2 then
			appear = f:readstr()
		end
		local color = f:read8()
		local stats = f:read8()
		table.insert(players, player_t(name, skin, appear, color, stat_t(stats >> 4, stats & 0xf)))
	end

	return score_t(
		flags,
		time,
		starttime,
		splits,
		players,
		id
	)
end

local function loadMapStore(f, version)
	local store = {}
	for _ = 1, f:readnum() do
		local mapnum = mapnumFromExtended(f:readstr())
		local numchecksums = f:readnum()
		local checksums = {}
		store[mapnum] = checksums
		for i = 1, numchecksums do
			local checksum = string.format("%04x", f:read16())
			local numrecords = f:readnum()
			local scores = {}
			checksums[checksum] = scores
			for j = 1, numrecords do
				table.insert(scores, parseScoreBinary(f, version))
			end
		end
	end
	return store
end

local function loadColdStore(f)
	local directory = f:readstr()
	local store = loadMapStore(f, LEADERBOARD_VERSION)

	return store, directory
end

local function getColdStoreDir(f)
	return f:readstr()
end

-- Read and parse a store file
local function loadStoreFile(directory)
	print("Loading store "..directory)
	StoreName = directory
	LiveStore = {}
	Dirty = {}
	NextID = 1

	local f = read_segmented(string.format("Leaderboard/%s/store.sav2", StoreName))
	if not f then
		-- empty store, start a new one
		return
	end

	if f:readliteral(11) ~= "LEADERBOARD" then
		error("Failed to read store: bad magic", 2)
	end
	local version = f:read8()
	if version > LEADERBOARD_VERSION then
		error(string.format("Failed to read store: version %d not supported (highest is %d)", version, LEADERBOARD_VERSION), 2)
	end

	NextID = f:readnum()
	for _ = 1, f:readnum() do
		Dirty[f:readnum()] = true
	end

	LiveStore = loadMapStore(f, version)
	clearcache()
end

local function squishStore(store)
	for map, checksums in pairs(store) do
		for checksum, records in pairs(checksums) do
			if not next(records) then
				store[map][checksum] = nil
			end
		end
		if not next(checksums) then
			store[map] = nil
		end
	end
end

local coldloaded

local function AddColdStoreBinary(str)
	if replayplayback then return end
	coldloaded = lb_base128_decode(str)
	-- pre-emptively load the store to reduce join lag
	local dir = getColdStoreDir(StringReader(coldloaded))
	loadStoreFile(dir)
end
rawset(_G, "lb_add_coldstore_binary", AddColdStoreBinary)

-- yikes... that's a whole lot of pairs...
local function getRecordByID(id)
	for map, checksums in pairs(LiveStore) do
		for checksum, records in pairs(checksums) do
			for _, record in ipairs(records) do
				if record.id == id then
					return record, map, checksum
				end
			end
		end
	end
end
rawset(_G, "lb_rec_by_id", getRecordByID)

local function getIdsForMap(map, checksum)
	local ret = {}
	if not (LiveStore[map] and LiveStore[map][checksum]) then
		return ret
	end
	for _, record in ipairs(LiveStore[map][checksum]) do
		ret[record.id] = true
	end
	return ret
end
rawset(_G, "lb_ids_for_map", getIdsForMap)

-- GLOBAL
-- Command for moving records from one map to another
-- if targetmap is -1, deletes records
local function moveRecords(sourcemap, sourcesum, sourceids, targetmap, targetsum, modeSep)
	if not (LiveStore[sourcemap] and LiveStore[sourcemap][sourcesum]) then
		return 0
	end

	local delete = targetmap == -1

	if not delete then
		LiveStore[targetmap] = $ or {}
		LiveStore[targetmap][targetsum] = $ or {}
	end
	local moved = 0
	for i, score in ipairs(LiveStore[sourcemap][sourcesum]) do
		if not sourceids[score.id] then continue end
		if isserver then Dirty[score.id] = true end
		if not delete then insertOrReplace(LiveStore[targetmap][targetsum], score, modeSep) end
		moved = $ + 1
	end

	-- Destroy the original table
	local records = LiveStore[sourcemap][sourcesum]
	for i = #records, 1, -1 do
		local rec = records[i]
		if sourceids[rec.id] then
			table.remove(records, i)
			deleteGhost(rec.id)
		end
	end
	if not next(records) then
		LiveStore[sourcemap][sourcesum] = nil
	end

	if isserver then
		dumpStoreToFile()
		clearcache()
	end

	return moved
end
rawset(_G, "lb_move_records", moveRecords)

-- if we've got a coldstore loaded, apply the server's diff onto it
local function applyColdStore(diff)
	local coldstore, directory = loadColdStore(StringReader(coldloaded))
	if directory ~= StoreName then
		return diff
	end
	for map, checksums in pairs(diff) do
		if not coldstore[map] then coldstore[map] = {} end
		for checksum, records in pairs(checksums) do
			if not coldstore[map][checksum] then coldstore[map][checksum] = {} end
			for _, record in ipairs(records) do
				local target
				for i, rec2 in ipairs(coldstore[map][checksum]) do
					if rec2.id == record.id then
						target = i
						break
					end
				end
				if target then
					coldstore[map][checksum][target] = record
				else
					table.insert(coldstore[map][checksum], record)
				end
			end
		end
	end
	return coldstore
end

-- makes a diff to send to clients, and saves it
local function makecache()
	if diffcache and deletecache or not (isserver and LiveStore) then
		return
	end

	local send = {}
	local highest = 0
	local byid = {}
	for map, checksums in pairs(LiveStore) do
		send[map] = {}
		for checksum, records in pairs(checksums) do
			send[map][checksum] = {}
			for _, record in ipairs(records) do
				if Dirty[record.id] then
					table.insert(send[map][checksum], record)
				end
				byid[record.id] = record
				highest = max($, record.id)
			end
		end
	end
	-- need this in case the very latest records are deleted
	for i in pairs(Dirty) do
		highest = max($, i)
	end

	local deleted = StringWriter()
	for i = 1, highest do
		if not byid[i] then
			deleted:writenum(i)
		end
	end

	squishStore(send)
	diffcache, deletecache = writeColdStore(send), table.concat(deleted)
end

-- wait until netvars/mapchange so the savegame has a chance to set cv_directory
-- also in RR, maps are most likely not loaded yet, so we can't get their numbers
local function loadit()
	if reloadstore then
		reloadstore = false
		-- if we already have the right store, don't reload it
		if StoreName ~= cv_directory.string then
			loadStoreFile(cv_directory.string)
		end
	end
	-- might as well make a cache now instead of in netvars
	makecache()
end
addHook("MapChange", function()
	if not replayplayback then loadit() end
end)

local function netvars(net)
	if replayplayback then return end
	if isserver then
		makecache()
		net(diffcache, deletecache, NextID)
	else
		loadit()
		local diff = loadColdStore(StringReader(net("Yes I would like uhhh")))
		local deleted = StringReader(net("two strings please"))
		NextID = net("oh and a number")
		local deletions = {}
		while not deleted:empty() do
			deletions[deleted:readnum()] = true
		end
		if coldloaded then
			diff = applyColdStore($)
		end
		mergeStore(diff, deletions)
	end
end
addHook("NetVars", netvars)

COM_AddCommand("lb_write_coldstore", function(player, filename)
	if not filename then
		CONS_Printf(player, "Usage: lb_write_coldstore <filename>")
		return
	end

	if filename:sub(#filename-3) != ".txt" then
		filename = $..".txt"
	end

	local store = {}
	for map, checksums in pairs(LiveStore) do
		store[map] = $ or {}
		for checksum, records in pairs(checksums) do
			store[map][checksum] = {}
			for _, record in ipairs(records) do
				insertOrReplace(store[map][checksum], record, -1)
			end
		end
	end

	squishStore(store)

	local dat = writeColdStore(store)
	--[[
	local f = open("coldstore.sav2", "wb")
	f:write(dat)
	f:close()
	--]]

	-- B-B-BUT WHAT ABOUT PLAYER NAMES?
	-- right now we use base128 encoding, which doesn't have ] in its character set so that's not an issue
	-- if base252 ever becomes real we'll have to make it base251 and exclude ]
	write_segmented(filename, "lb_add_coldstore_binary[["..lb_base128_encode(dat).."]]")

	print("Cold store script written to "..filename.." (rename to "..filename:gsub(".txt", ".lua").."!)")
	Dirty = {}
	dumpStoreToFile()
	clearcache()
end, COM_LOCAL)

COM_AddCommand("lb_known_maps", function(player, map)
	local mapnum = gamemap
	if map then
		mapnum = mapnumFromExtended(map)
		if not mapnum then
			print(string.format("invalid map '%s'", map))
			return
		end
	end

	local known = {}

	if LiveStore[mapnum] then
		for checksum, records in pairs(LiveStore[mapnum]) do
			known[checksum] = #records
		end
	end

	print("Map	Chck	Records")
	for checksum, count in pairs(known) do
		print(string.format("%s	%s	%d", G_BuildMapName(mapnum), checksum, count))
	end
end, COM_LOCAL)

if not RINGS then
COM_AddCommand("lb_convert_to_binary", function(player, filename)
	filename = $ or "leaderboard.coldstore.txt"
	local f = open(filename)
	if not f then
		print("Can't open "..filename)
		return
	end
	print("Converting "..filename.." to binary")
	LiveStore = {}
	NextID = 1
	for l in f:lines() do
		local score, map, checksum = oldParseScore(l)
		score.id = NextID
		LiveStore[map] = $ or {}
		LiveStore[map][checksum] = $ or {}
		table.insert(LiveStore[map][checksum], score)
		NextID = $ + 1
		deleteGhost(score.id)
	end
	f:close()
	Dirty = {}

	dumpStoreToFile()
	clearcache()
end, COM_LOCAL)
end -- if not RINGS
