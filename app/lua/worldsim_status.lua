#!/usr/bin/env luajit

local json = require("dkjson")
local config = require("worldsim_config")
local utils = require("worldsim_utils")

local DB_PATH = config.DB_PATH
local JSON_PATH = config.JSON_PATH

local function open_db()
	return utils.open_db(DB_PATH)
end

-- Read only the latest state
local function get_latest_tick(db)
	local row
	for r in
		db:nrows([[
    SELECT
      ts_utc,
      strftime('%s', ts_utc) AS ts_epoch,
      population,
      food,
      workers
    FROM world_tick
    ORDER BY id DESC
    LIMIT 1;
  ]])
	do
		row = r
	end
	return row
end

local function build_status(latest)
	if not latest then
		return { has_data = false }
	end

	return {
		has_data = true,
		last_tick_epoch = tonumber(latest.ts_epoch) or 0,
		last_tick_iso = latest.ts_utc,
		population = latest.population,
		food = latest.food,
		workers = latest.workers,
	}
end

local function write_json(path, tbl)
	utils.ensure_dir("/var/www/html/worldsim")
	local f, err = io.open(path, "w")
	if not f then
		io.stderr:write("Failed to open JSON file: " .. tostring(err) .. "\n")
		return
	end

	local encoded = json.encode(tbl, { indent = true })
	f:write(encoded)
	f:close()
end

-- Main
local db = open_db()
local latest = get_latest_tick(db)
local status = build_status(latest)
db:close()

write_json(JSON_PATH, status)
