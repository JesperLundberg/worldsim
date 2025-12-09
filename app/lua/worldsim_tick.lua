#!/usr/bin/env luajit

local sqlite3 = require("lsqlite3")
local config = require("worldsim_config")
local utils = require("worldsim_utils")

local DB_PATH = config.DB_PATH

-- Return current UTC timestamp in ISO-8601 format.
local function now_utc_iso()
  local t = os.date("!*t")
  return string.format(
    "%04d-%02d-%02dT%02d:%02d:%02dZ",
    t.year, t.month, t.day, t.hour, t.min, t.sec
  )
end

-- Open DB and ensure table exists.
local function open_db_and_init()
  utils.ensure_dir("/opt/worldsim/db")
  local db = sqlite3.open(DB_PATH)
  db:busy_timeout(5000)

  local create_sql = [[
CREATE TABLE IF NOT EXISTS world_tick (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  ts_utc      TEXT NOT NULL,
  population  INTEGER NOT NULL,
  food        REAL NOT NULL,
  workers     INTEGER NOT NULL,
  notes       TEXT
);
  ]]
  assert(db:exec(create_sql) == sqlite3.OK, "Failed to create world_tick table")

  return db
end

-- Get latest row or nil if table is empty.
local function get_latest_state(db)
  local row
  for r in db:nrows("SELECT * FROM world_tick ORDER BY id DESC LIMIT 1;") do
    row = r
  end
  return row
end

-- Very simple placeholder rules, can be replaced later.
local function compute_next_state(last)
  if not last then
    -- Initial world state
    return {
      population = 100,
      food = 500.0,
      workers = 40,
      notes = "Initial world state"
    }
  end

  local population = last.population
  local food       = last.food
  local workers    = last.workers

  -- Production: workers generate food.
  local produced = workers * 1.2

  -- Consumption: population eats.
  local consumed = population * 0.6

  local food_next = food + produced - consumed
  if food_next < 0 then
    food_next = 0
  end

  -- Population reaction to food level.
  local population_next = population
  if food_next > 700 then
    population_next = population_next + 1
  elseif food_next < 150 and population_next > 5 then
    population_next = population_next - 1
  end

  -- Workers: fixed 40% of population (at least 1).
  local workers_next = math.floor(population_next * 0.4)
  if workers_next < 1 then
    workers_next = 1
  end

  return {
    population = population_next,
    food       = food_next,
    workers    = workers_next,
    notes      = nil
  }
end

local function insert_state(db, state)
  local sql = [[
INSERT INTO world_tick (ts_utc, population, food, workers, notes)
VALUES (?, ?, ?, ?, ?);
  ]]
  local stmt = db:prepare(sql)
  assert(stmt, "Failed to prepare insert")

  stmt:bind_values(
    now_utc_iso(),
    state.population,
    state.food,
    state.workers,
    state.notes
  )

  assert(stmt:step() == sqlite3.DONE, "Failed to insert world state")
  stmt:finalize()
end

-- Main
local db = open_db_and_init()
local last = get_latest_state(db)
local next_state = compute_next_state(last)
insert_state(db, next_state)
db:close()
