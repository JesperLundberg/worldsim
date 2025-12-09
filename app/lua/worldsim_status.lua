#!/usr/bin/env luajit

local json   = require("dkjson")
local config = require("worldsim_config")
local utils  = require("worldsim_utils")

local DB_PATH   = config.DB_PATH
local JSON_PATH = config.JSON_PATH

local function open_db()
  return utils.open_db(DB_PATH)
end

local function get_latest_tick(db)
  local row
  for r in db:nrows("SELECT * FROM world_tick ORDER BY id DESC LIMIT 1;") do
    row = r
  end
  return row
end

local function get_recent_summary(db, limit)
  limit = limit or 48
  local rows = {}
  for r in db:nrows(string.format(
    "SELECT * FROM world_tick ORDER BY id DESC LIMIT %d;",
    limit
  )) do
    table.insert(rows, r)
  end

  -- Reverse to chronological order.
  local history = {}
  for i = #rows, 1, -1 do
    table.insert(history, rows[i])
  end

  return history
end

local function build_status(latest, history)
  if not latest then
    return {
      has_data = false
    }
  end

  local status = {
    has_data   = true,
    last_tick  = latest.ts_utc,
    population = latest.population,
    food       = latest.food,
    workers    = latest.workers,
    recent     = {}
  }

  for _, r in ipairs(history) do
    table.insert(status.recent, {
      ts         = r.ts_utc,
      population = r.population,
      food       = r.food,
      workers    = r.workers
    })
  end

  return status
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
local latest  = get_latest_tick(db)
local history = get_recent_summary(db, 48)
local status  = build_status(latest, history)
db:close()

write_json(JSON_PATH, status)
