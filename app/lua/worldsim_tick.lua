#!/usr/bin/env luajit

-- worldsim_tick.lua
-- One simulation tick: read latest state, compute next state, store in SQLite.
--
-- Tick frequency: 1 tick per real minute (via cron).
-- Simulated year length: 60 ticks (~1 real hour).
-- Seasons (15 ticks each):
--   ticks  0–14: winter  -> small food deficit
--   ticks 15–29: spring  -> balanced
--   ticks 30–44: summer  -> surplus
--   ticks 45–59: autumn  -> balanced
--
-- This version includes:
--   - mild stochastic variation in production and consumption
--   - low-probability random births and deaths, independent of food
--   - tuned food_per_capita thresholds (less doom-y)
--   - recovery boost for small populations when food per capita is high

local sqlite3 = require("lsqlite3")
local config = require("worldsim_config")
local utils = require("worldsim_utils")

local DB_PATH = config.DB_PATH

-- Base rates before seasonal and random modifiers.
local BASE_PRODUCTION_PER_WORKER = 2.5
local BASE_CONSUMPTION_PER_PERSON = 1.0

-- Baseline random birth/death rates per person per tick (very small).
local BASELINE_BIRTH_RATE = 0.0005 -- expected births per person per tick
local BASELINE_DEATH_RATE = 0.00015 -- expected deaths per person per tick

-- Seed RNG once per process.
math.randomseed(os.time())

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
  births      INTEGER NOT NULL DEFAULT 0,
  deaths      INTEGER NOT NULL DEFAULT 0,
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

-- Get season info from a simulated tick index.
-- We use the autoincrement id as a tick counter:
--   tick_index = 0 for the first row, 1 for the second, etc.
-- Year length: 60 ticks.
-- Seasons (15 ticks each):
--   0–14:  winter  (slight deficit)
--   15–29: spring  (roughly balanced)
--   30–44: summer  (surplus)
--   45–59: autumn  (roughly balanced)
local function get_season_from_tick(tick_index)
	local year_length = 60
	local season_length = 15

	local pos = tick_index % year_length -- 0..59

	if pos < season_length then
		return "winter", 0.9 -- 10% less than balance: small food deficit
	elseif pos < season_length * 2 then
		return "spring", 1.0 -- balanced
	elseif pos < season_length * 3 then
		return "summer", 1.2 -- surplus
	else
		return "autumn", 1.0 -- balanced
	end
end

-- Helper to turn a fractional expected value into an integer using randomness.
-- Example: expected = 0.3 -> 30% chance to get 1, otherwise 0.
local function sample_from_expected(expected)
	if expected <= 0 then
		return 0
	end
	local base = math.floor(expected)
	local frac = expected - base
	if math.random() < frac then
		return base + 1
	else
		return base
	end
end

-- Compute the next state of the world based on the previous state.
local function compute_next_state(last)
	-- Decide tick index.
	-- For the very first row we treat tick_index as 0.
	local tick_index = 0
	if last and last.id then
		-- last.id == 1 for first row; using id directly as tick index is fine.
		tick_index = last.id
	end

	local season_name, season_factor = get_season_from_tick(tick_index)

	-- If no previous state exists, create an initial world.
	if not last then
		local population = 100
		local workers_ratio = get_workers_ratio(population)
		local workers = math.max(1, math.floor(population * workers_ratio))

		return {
			population = population,
			food = 500.0, -- enough buffer to survive the first simulated winter
			workers = workers,
			births = 0,
			deaths = 0,
			notes = string.format("Initial world state; season=%s", season_name),
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

	---------------------------------------------------------------------------
	-- 2) Food dynamics with mild stochasticity.
	---------------------------------------------------------------------------

	-- Small random noise for production (±5%) and consumption (±2%).
	-- This keeps the model mostly stable but slightly "alive".
	local noise_prod = (math.random() - 0.5) * 0.10 -- -0.05 .. +0.05
	local noise_cons = (math.random() - 0.5) * 0.04 -- -0.02 .. +0.02

	local consumption_per_person = BASE_CONSUMPTION_PER_PERSON * (1.0 + noise_cons)
	if consumption_per_person < 0.1 then
		consumption_per_person = 0.1
	end

	local production_per_worker = BASE_PRODUCTION_PER_WORKER * season_factor * (1.0 + noise_prod)
	if production_per_worker < 0 then
		production_per_worker = 0
	end

	local produced = workers * production_per_worker
	local consumed = population * consumption_per_person

	local food_next = food + produced - consumed
	if food_next < 0 then
		food_next = 0
	end

	---------------------------------------------------------------------------
	-- 3) Population reacts to food per capita (tuned to be less doom-y).
	---------------------------------------------------------------------------
	local population_next = population
	local births = 0
	local deaths = 0

	if population > 0 then
		local food_per_capita = food_next / population

		-- Very high abundance -> strong growth.
		if food_per_capita > 8 then
			local growth = math.max(1, math.floor(population * 0.02)) -- +2.0% per tick
			population_next = population + growth
			births = births + growth

		-- Good abundance -> steady growth.
		elseif food_per_capita > 5 then
			local growth = math.max(1, math.floor(population * 0.012)) -- +1.2% per tick
			population_next = population + growth
			births = births + growth

		-- Slight surplus -> small growth.
		elseif food_per_capita > 3 then
			local growth = math.max(1, math.floor(population * 0.006)) -- +0.6% per tick
			population_next = population + growth
			births = births + growth

		-- Barely enough -> roughly stable.
		elseif food_per_capita > 1.8 then
			population_next = population

		-- Low food -> gentle decline.
		elseif food_per_capita > 1.0 then
			local decline = math.max(1, math.floor(population * 0.003)) -- -0.3% per tick
			population_next = population - decline
			deaths = deaths + decline

		-- Starvation -> stronger decline.
		else
			local decline = math.max(1, math.floor(population * 0.01)) -- -1.0% per tick
			population_next = population - decline
			deaths = deaths + decline
		end
	end

	---------------------------------------------------------------------------
	-- 4) Add low-probability random births/deaths independent of food.
	---------------------------------------------------------------------------
	if population_next > 0 then
		-- Expected random births and deaths based on current population.
		local expected_random_births = population_next * BASELINE_BIRTH_RATE
		local expected_random_deaths = population_next * BASELINE_DEATH_RATE

		local random_births = sample_from_expected(expected_random_births)
		local random_deaths = sample_from_expected(expected_random_deaths)

		-- Apply random births.
		if random_births > 0 then
			population_next = population_next + random_births
			births = births + random_births
		end

		-- Apply random deaths, but never drop below 2 here.
		if random_deaths > 0 then
			if population_next - random_deaths < 2 then
				random_deaths = math.max(0, population_next - 2)
			end
			if random_deaths > 0 then
				population_next = population_next - random_deaths
				deaths = deaths + random_deaths
			end
		end
	end

	---------------------------------------------------------------------------
	-- 5) Recovery boost for small populations when there is plenty of food.
	---------------------------------------------------------------------------
	if population_next > 0 then
		local food_per_capita_next = food_next / population_next

		-- If the population is small but food per capita is high,
		-- add an extra burst of births to help recovery.
		if population_next < 40 and food_per_capita_next > 5 then
			local bonus = math.max(1, math.floor(population_next * 0.02)) -- +2% extra
			population_next = population_next + bonus
			births = births + bonus
		end
	end

	---------------------------------------------------------------------------
	-- 6) Clamp population minimum.
	---------------------------------------------------------------------------
	if population_next < 2 then
		-- If we clamp up, adjust deaths to not count "impossible" deaths.
		if population_next < population then
			local diff = 2 - population_next
			deaths = deaths - diff
			if deaths < 0 then
				deaths = 0
			end
		end
		population_next = 2
	end

	---------------------------------------------------------------------------
	-- 7) Recompute workers for the new population.
	---------------------------------------------------------------------------
	local workers_next_ratio = get_workers_ratio(population_next)
	local workers_next = math.max(1, math.floor(population_next * workers_next_ratio))
	if workers_next > population_next then
		workers_next = population_next
	end

	local note = string.format(
		"season=%s; season_factor=%.2f; prod_per_worker=%.2f; tick_index=%d; births=%d; deaths=%d",
		season_name,
		season_factor,
		production_per_worker,
		tick_index,
		births,
		deaths
	)

	return {
		population = population_next,
		food = food_next,
		workers = workers_next,
		births = births,
		deaths = deaths,
		notes = note,
	}
end

local function insert_state(db, state)
	local sql = [[
INSERT INTO world_tick (ts_utc, population, food, workers, births, deaths, notes)
VALUES (?, ?, ?, ?, ?, ?, ?);
  ]]
	local stmt = db:prepare(sql)
	assert(stmt, "Failed to prepare insert")

	stmt:bind_values(
		now_utc_iso(),
		state.population,
		state.food,
		state.workers,
		state.births or 0,
		state.deaths or 0,
		state.notes
	)

	assert(stmt:step() == sqlite3.DONE, "Failed to insert world state")
	stmt:finalize()
end

-- Main
local db = open_db_and_init()
local last_state = get_latest_state(db)
local next_state = compute_next_state(last_state)
insert_state(db, next_state)
db:close()
