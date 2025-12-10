#!/usr/bin/env luajit

-- worldsim_tick.lua
-- One simulation tick: read latest state, compute next state, store in SQLite.

local sqlite3 = require("lsqlite3")
local config = require("worldsim_config")
local utils = require("worldsim_utils")

local DB_PATH = config.DB_PATH

-- Return current UTC timestamp in ISO-8601 format.
local function now_utc_iso()
	local t = os.date("!*t")
	return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", t.year, t.month, t.day, t.hour, t.min, t.sec)
end

-- Open DB and ensure the main table exists.
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

-- Decide how large fraction of the population are workers.
-- Fewer people -> higher fraction, more people -> lower fraction.
local function get_workers_ratio(population)
	if population <= 20 then
		return 0.45 -- small group: almost half are workers
	elseif population <= 100 then
		return 0.40
	elseif population <= 500 then
		return 0.35
	elseif population <= 2000 then
		return 0.30
	else
		return 0.25 -- very large population: many non-workers
	end
end

-- Compute the next state of the world based on the previous state.
local function compute_next_state(last)
	-- If no previous state exists, create an initial world.
	if not last then
		local population = 100
		local workers_ratio = get_workers_ratio(population)
		local workers = math.max(1, math.floor(population * workers_ratio))

		return {
			population = population,
			food = 400.0,
			workers = workers,
			notes = "Initial world state",
		}
	end

	local population = last.population
	local food = last.food

	-- 1) Decide worker count based on current population size.
	local workers_ratio = get_workers_ratio(population)
	local workers = math.max(1, math.floor(population * workers_ratio))
	if workers > population then
		workers = population
	end

	-- 2) Food dynamics.
	--    Each person eats a fixed amount.
	--    Each worker produces a fixed amount.
	--    These values are tuned so that there is a possible balance.
	local consumption_per_person = 1.0 -- food units per person per tick
	local production_per_worker = 2.5 -- food units per worker per tick

	local produced = workers * production_per_worker
	local consumed = population * consumption_per_person

	local food_next = food + produced - consumed
	if food_next < 0 then
		food_next = 0
	end

	-- 3) Population reacts to food per capita.
	local population_next = population

	if population > 0 then
		local food_per_capita = food_next / population

		-- Plenty of food -> gentle growth.
		-- Thresholds are in "food units per person" based on the 1.0 consumption rate.
		if food_per_capita > 8 then
			-- about 0.5% per tick, at least +1
			local growth = math.max(1, math.floor(population * 0.005))
			population_next = population + growth

		-- Comfortable -> roughly stable.
		elseif food_per_capita > 4 then
			population_next = population

		-- Tight but not catastrophic -> slow decline.
		elseif food_per_capita > 2 then
			local decline = math.max(1, math.floor(population * 0.005))
			population_next = population - decline

		-- Very little food -> faster decline.
		else
			local strong_decline = math.max(1, math.floor(population * 0.01))
			population_next = population - strong_decline
		end
	end

	-- 4) Population is not allowed to drop below 2.
	if population_next < 2 then
		population_next = 2
	end

	-- Recompute workers for the new population.
	local workers_next_ratio = get_workers_ratio(population_next)
	local workers_next = math.max(1, math.floor(population_next * workers_next_ratio))
	if workers_next > population_next then
		workers_next = population_next
	end

	return {
		population = population_next,
		food = food_next,
		workers = workers_next,
		notes = nil,
	}
end

local function insert_state(db, state)
	local sql = [[
INSERT INTO world_tick (ts_utc, population, food, workers, notes)
VALUES (?, ?, ?, ?, ?);
  ]]
	local stmt = db:prepare(sql)
	assert(stmt, "Failed to prepare insert")

	stmt:bind_values(now_utc_iso(), state.population, state.food, state.workers, state.notes)

	assert(stmt:step() == sqlite3.DONE, "Failed to insert world state")
	stmt:finalize()
end

-- Main
local db = open_db_and_init()
local last_state = get_latest_state(db)
local next_state = compute_next_state(last_state)
insert_state(db, next_state)
db:close()
