#!/usr/bin/env luajit

-- worldsim_tick.lua
-- One simulation tick: read latest state, compute next state, store in SQLite.
--
-- Tick frequency: 1 tick per real minute (via cron).
-- Simulated year length: 60 ticks (~1 real hour).
--
-- Features:
--   - Seasons (winter/spring/summer/autumn) affecting production.
--   - Population driven by food flow per capita and stored food per capita.
--   - Random births/deaths (low probability, food-independent).
--   - Recovery boost for small populations with plenty of food.
--   - Year-based events with real randomness and path dependence:
--       * Good years in a row  -> higher risk of poor/disastrous harvest.
--       * Bad years in a row   -> higher chance of golden harvest.
--       * High population      -> higher risk of plague.
--   - Events are drawn once per year and stored in world_year_events.

local sqlite3 = require("lsqlite3")
local config = require("worldsim_config")
local utils = require("worldsim_utils")

local DB_PATH = config.DB_PATH
local YEAR_LENGTH = 60 -- ticks per simulated year

-- Base rates before seasonal and random modifiers.
local BASE_PRODUCTION_PER_WORKER = 3.0 -- encourages growth in good conditions
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

----------------------------------------------------------------------
-- DB SETUP
----------------------------------------------------------------------

local function open_db_and_init()
	utils.ensure_dir("/opt/worldsim/db")
	local db = sqlite3.open(DB_PATH)
	db:busy_timeout(5000)

	-- Main tick table.
	local create_ticks = [[
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
	assert(db:exec(create_ticks) == sqlite3.OK, "Failed to create world_tick table")

	-- Year events: one row per simulated year.
	local create_year_events = [[
CREATE TABLE IF NOT EXISTS world_year_events (
  year_index   INTEGER PRIMARY KEY,
  harvest_type TEXT NOT NULL,  -- 'normal','poor','disastrous'
  golden       INTEGER NOT NULL, -- 0/1
  plague       INTEGER NOT NULL, -- 0/1
  rot          INTEGER NOT NULL  -- 0/1
);
  ]]
	assert(db:exec(create_year_events) == sqlite3.OK, "Failed to create world_year_events table")

	-- Meta key/value store (for streaks etc).
	local create_meta = [[
CREATE TABLE IF NOT EXISTS world_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
  ]]
	assert(db:exec(create_meta) == sqlite3.OK, "Failed to create world_meta table")

	return db
end

----------------------------------------------------------------------
-- META HELPERS
----------------------------------------------------------------------

local function get_meta(db, key)
	local stmt = db:prepare("SELECT value FROM world_meta WHERE key = ?;")
	if not stmt then
		return nil
	end
	stmt:bind_values(key)
	local value
	if stmt:step() == sqlite3.ROW then
		value = stmt:get_value(0)
	end
	stmt:finalize()
	return value
end

local function set_meta(db, key, value)
	local stmt = db:prepare([[
INSERT INTO world_meta(key, value) VALUES(?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value;
  ]])
	assert(stmt, "Failed to prepare meta upsert")
	stmt:bind_values(key, tostring(value))
	assert(stmt:step() == sqlite3.DONE, "Failed to upsert meta")
	stmt:finalize()
end

----------------------------------------------------------------------
-- BASIC HELPERS
----------------------------------------------------------------------

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
-- We use the 0-based tick index within the whole history.
-- Seasons (15 ticks each):
--   0–14:  winter  (slight deficit)
--   15–29: spring  (roughly balanced)
--   30–44: summer  (surplus)
--   45–59: autumn  (roughly balanced)
local function get_season_from_tick(tick_index)
	local season_length = 15
	local pos = tick_index % YEAR_LENGTH -- 0..59

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

-- Get latest row or nil if table is empty.
local function get_latest_state(db)
	local row
	for r in db:nrows("SELECT * FROM world_tick ORDER BY id DESC LIMIT 1;") do
		row = r
	end
	return row
end

----------------------------------------------------------------------
-- YEAR CLASSIFICATION (GOOD / NORMAL / BAD)
----------------------------------------------------------------------

-- Classify a finished year as 'good', 'bad' or 'normal' based on food.
-- We use a simple heuristic on food stores at year start/end.
local function classify_year(db, year_index)
	if year_index < 0 then
		return "normal"
	end

	local start_id = year_index * YEAR_LENGTH + 1
	local end_id = start_id + YEAR_LENGTH - 1

	local first, last

	do
		local stmt =
			db:prepare("SELECT population, food FROM world_tick WHERE id BETWEEN ? AND ? ORDER BY id ASC LIMIT 1;")
		if not stmt then
			return "normal"
		end
		stmt:bind_values(start_id, end_id)
		if stmt:step() == sqlite3.ROW then
			first = { pop = stmt:get_value(0), food = stmt:get_value(1) }
		end
		stmt:finalize()
	end

	do
		local stmt =
			db:prepare("SELECT population, food FROM world_tick WHERE id BETWEEN ? AND ? ORDER BY id DESC LIMIT 1;")
		if not stmt then
			return "normal"
		end
		stmt:bind_values(start_id, end_id)
		if stmt:step() == sqlite3.ROW then
			last = { pop = stmt:get_value(0), food = stmt:get_value(1) }
		end
		stmt:finalize()
	end

	if not first or not last then
		-- Year not fully populated (e.g. restart), treat as neutral.
		return "normal"
	end

	local start_food = tonumber(first.food) or 0
	local end_food = tonumber(last.food) or 0
	local start_pop = math.max(tonumber(first.pop) or 1, 1)
	local end_pop = math.max(tonumber(last.pop) or 1, 1)

	local delta_food = end_food - start_food
	local avg_stock_per_capita = ((start_food / start_pop) + (end_food / end_pop)) / 2.0

	if delta_food > 0 and avg_stock_per_capita > 8 then
		return "good"
	elseif delta_food < 0 and avg_stock_per_capita < 4 then
		return "bad"
	else
		return "normal"
	end
end

-- Update good/bad streaks based on classification of the previous year.
-- Returns updated (good_streak, bad_streak, class).
local function update_streaks_for_previous_year(db, year_index)
	if year_index <= 0 then
		return 0, 0, "normal"
	end

	local prev_year = year_index - 1
	local class = classify_year(db, prev_year)

	local good_streak = tonumber(get_meta(db, "good_streak")) or 0
	local bad_streak = tonumber(get_meta(db, "bad_streak")) or 0

	if class == "good" then
		good_streak = good_streak + 1
		bad_streak = 0
	elseif class == "bad" then
		bad_streak = bad_streak + 1
		good_streak = 0
	else
		good_streak = 0
		bad_streak = 0
	end

	set_meta(db, "good_streak", good_streak)
	set_meta(db, "bad_streak", bad_streak)

	return good_streak, bad_streak, class
end

----------------------------------------------------------------------
-- YEAR EVENT DRAWING
----------------------------------------------------------------------

-- Apply streak-based and population-based modifiers to event probabilities.
local function modify_for_good_streak(poor, disastrous, good_streak)
	if good_streak <= 0 then
		return poor, disastrous
	end
	local factor = 1.0 + 0.3 * good_streak -- +30% per good year in a row
	if factor > 3.0 then
		factor = 3.0
	end
	return poor * factor, disastrous * factor
end

local function modify_for_bad_streak(golden, bad_streak)
	if bad_streak <= 0 then
		return golden
	end
	local factor = 1.0 + 0.4 * bad_streak -- +40% per bad year in a row
	if factor > 4.0 then
		factor = 4.0
	end
	return golden * factor
end

local function modify_for_population(plague, population)
	if population < 200 then
		return plague
	elseif population < 500 then
		return plague * 1.5
	elseif population < 1000 then
		return plague * 2.0
	else
		return plague * 3.0
	end
end

local function clamp_prob(p)
	if p < 0 then
		return 0
	end
	if p > 0.8 then
		return 0.8
	end
	return p
end

-- Draw events for a given year based on streaks and current population.
local function draw_year_events(good_streak, bad_streak, population)
	-- Baseline probabilities per simulated year.
	local p_poor = 0.10
	local p_disastrous = 0.03
	local p_golden = 0.05
	local p_plague = 0.02
	local p_rot = 0.03

	p_poor, p_disastrous = modify_for_good_streak(p_poor, p_disastrous, good_streak)
	p_golden = modify_for_bad_streak(p_golden, bad_streak)
	p_plague = modify_for_population(p_plague, population)

	p_poor = clamp_prob(p_poor)
	p_disastrous = clamp_prob(p_disastrous)
	p_golden = clamp_prob(p_golden)
	p_plague = clamp_prob(p_plague)
	p_rot = clamp_prob(p_rot)

	-- Decide harvest type.
	local harvest_type = "normal"
	local r = math.random()
	if r < p_disastrous then
		harvest_type = "disastrous"
	elseif r < p_disastrous + p_poor then
		harvest_type = "poor"
	else
		harvest_type = "normal"
	end

	local golden = (math.random() < p_golden)
	local plague = (math.random() < p_plague)
	local rot = (math.random() < p_rot)

	return {
		harvest_type = harvest_type,
		golden = golden,
		plague = plague,
		rot = rot,
	}
end

-- Get or create year events for a given year_index.
local function get_year_events(db, year_index, last_population)
	-- First check if we already have events for this year.
	local stmt = db:prepare([[
    SELECT harvest_type, golden, plague, rot
    FROM world_year_events
    WHERE year_index = ?;
  ]])
	assert(stmt, "Failed to prepare select from world_year_events")
	stmt:bind_values(year_index)

	local harvest_type, golden, plague, rot
	if stmt:step() == sqlite3.ROW then
		harvest_type = stmt:get_value(0)
		golden = tonumber(stmt:get_value(1)) or 0
		plague = tonumber(stmt:get_value(2)) or 0
		rot = tonumber(stmt:get_value(3)) or 0
		stmt:finalize()
		return {
			harvest_type = harvest_type,
			golden = (golden ~= 0),
			plague = (plague ~= 0),
			rot = (rot ~= 0),
		}
	end
	stmt:finalize()

	-- No events stored yet -> this is the first tick of this year (or DB was reset).
	-- Update streaks based on previous year.
	local good_streak, bad_streak, prev_class = update_streaks_for_previous_year(db, year_index)

	-- Draw events using streaks and current population.
	local events = draw_year_events(good_streak, bad_streak, last_population or 100)

	local ins = db:prepare([[
    INSERT INTO world_year_events(year_index, harvest_type, golden, plague, rot)
    VALUES(?, ?, ?, ?, ?);
  ]])
	assert(ins, "Failed to prepare insert into world_year_events")
	ins:bind_values(
		year_index,
		events.harvest_type,
		events.golden and 1 or 0,
		events.plague and 1 or 0,
		events.rot and 1 or 0
	)
	assert(ins:step() == sqlite3.DONE, "Failed to insert year events")
	ins:finalize()

	return events
end

----------------------------------------------------------------------
-- MAIN STATE UPDATE
----------------------------------------------------------------------

local function compute_next_state(db, last)
	-- Determine next tick index (0-based).
	local next_tick_index
	if last and last.id then
		next_tick_index = last.id -- id starts at 1, so next tick index = last.id
	else
		next_tick_index = 0
	end

	local year_index = math.floor(next_tick_index / YEAR_LENGTH)
	local pos_in_year = next_tick_index % YEAR_LENGTH

	-- Season + year events.
	local season_name, season_factor = get_season_from_tick(next_tick_index)
	local last_population = last and last.population or 100
	local year_events = get_year_events(db, year_index, last_population)

	-- If no previous state exists, create an initial world.
	if not last then
		local population = 100
		local workers_ratio = get_workers_ratio(population)
		local workers = math.max(1, math.floor(population * workers_ratio))

		local note = string.format(
			"Initial world state; season=%s; year=%d; harvest=%s; golden=%s; plague=%s; rot=%s",
			season_name,
			year_index,
			year_events.harvest_type,
			tostring(year_events.golden),
			tostring(year_events.plague),
			tostring(year_events.rot)
		)

		return {
			population = population,
			food = 500.0, -- buffer so first winter is survivable
			workers = workers,
			births = 0,
			deaths = 0,
			notes = note,
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
	-- 2) Food dynamics with mild stochasticity, seasons and year events.
	---------------------------------------------------------------------------

	-- Small random noise for production (±5%) and consumption (±2%).
	local noise_prod = (math.random() - 0.5) * 0.10 -- -0.05 .. +0.05
	local noise_cons = (math.random() - 0.5) * 0.04 -- -0.02 .. +0.02

	local consumption_per_person = BASE_CONSUMPTION_PER_PERSON * (1.0 + noise_cons)
	if consumption_per_person < 0.1 then
		consumption_per_person = 0.1
	end

	-- Harvest factor from year events.
	local harvest_factor = 1.0
	if year_events.harvest_type == "poor" then
		harvest_factor = 0.7
	elseif year_events.harvest_type == "disastrous" then
		harvest_factor = 0.3
	end

	-- Golden harvest window: if this year has golden==true, apply boost in mid-summer.
	local golden_factor = 1.0
	if year_events.golden then
		local pos = pos_in_year
		-- Simple rule: ticks 30–34 (middle of summer) are golden.
		if pos >= 30 and pos <= 34 then
			golden_factor = 2.0
		end
	end

	local production_per_worker = BASE_PRODUCTION_PER_WORKER
		* season_factor
		* harvest_factor
		* golden_factor
		* (1.0 + noise_prod)

	if production_per_worker < 0 then
		production_per_worker = 0
	end

	local produced = workers * production_per_worker
	local consumed = population * consumption_per_person

	local delta_food = produced - consumed
	local food_next = food + delta_food
	if food_next < 0 then
		food_next = 0
	end

	local net_per_capita = 0.0
	local stock_per_capita = 0.0
	if population > 0 then
		net_per_capita = delta_food / population -- flow: surplus/deficit per person
		stock_per_capita = food_next / population -- stock: stored food per person
	end

	---------------------------------------------------------------------------
	-- 3) Population reacts to net food per capita (flow).
	---------------------------------------------------------------------------
	local population_next = population
	local births = 0
	local deaths = 0

	if population > 0 then
		local growth_factor = 0.0

		if net_per_capita > 1.0 then
			growth_factor = 0.03 -- +3% per tick when surplus is huge
		elseif net_per_capita > 0.5 then
			growth_factor = 0.02 -- +2% per tick
		elseif net_per_capita > 0.2 then
			growth_factor = 0.012 -- +1.2% per tick
		elseif net_per_capita > 0.05 then
			growth_factor = 0.006 -- +0.6% per tick
		elseif net_per_capita > -0.05 then
			growth_factor = 0.0 -- basically stable
		elseif net_per_capita > -0.2 then
			growth_factor = -0.003 -- -0.3% per tick
		else
			growth_factor = -0.01 -- -1% per tick
		end

		if growth_factor > 0 then
			local growth = math.floor(population * growth_factor)
			if growth < 1 then
				growth = 1
			end
			population_next = population + growth
			births = births + growth
		elseif growth_factor < 0 then
			local decline = math.floor(population * -growth_factor)
			if decline < 1 then
				decline = 1
			end
			population_next = population - decline
			deaths = deaths + decline
		end
	end

	---------------------------------------------------------------------------
	-- 4) Extra births when stored food per capita is high (stock).
	---------------------------------------------------------------------------
	if population_next > 0 then
		local spc = stock_per_capita

		if spc > 12 then
			-- Extremely rich society -> extra +2% per tick.
			local bonus = math.max(1, math.floor(population_next * 0.02))
			population_next = population_next + bonus
			births = births + bonus
		elseif spc > 8 then
			-- Very good situation -> extra +1% per tick.
			local bonus = math.max(1, math.floor(population_next * 0.01))
			population_next = population_next + bonus
			births = births + bonus
		elseif spc > 5 then
			-- Good situation -> small extra push.
			local bonus = math.max(1, math.floor(population_next * 0.005))
			population_next = population_next + bonus
			births = births + bonus
		end
	end

	---------------------------------------------------------------------------
	-- 5) Add low-probability random births/deaths independent of food.
	---------------------------------------------------------------------------
	if population_next > 0 then
		local expected_random_births = population_next * BASELINE_BIRTH_RATE
		local expected_random_deaths = population_next * BASELINE_DEATH_RATE

		local random_births = sample_from_expected(expected_random_births)
		local random_deaths = sample_from_expected(expected_random_deaths)

		if random_births > 0 then
			population_next = population_next + random_births
			births = births + random_births
		end

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
	-- 6) Recovery boost for small populations when there is plenty of food.
	---------------------------------------------------------------------------
	if population_next > 0 then
		local food_per_capita_next = food_next / population_next

		if population_next < 40 and food_per_capita_next > 5 then
			local bonus = math.max(1, math.floor(population_next * 0.02)) -- +2% extra
			population_next = population_next + bonus
			births = births + bonus
		end
	end

	---------------------------------------------------------------------------
	-- 7) Year events: plague and food rot (mass death / spoilage).
	---------------------------------------------------------------------------
	local notes_parts = {}

	-- Plague: if this year had plague=true, trigger once at start of winter.
	if year_events.plague and pos_in_year == 0 and population_next > 2 then
		local frac = 0.05 + math.random() * 0.15 -- 5–20%
		local lost = math.floor(population_next * frac)
		if lost > population_next - 2 then
			lost = population_next - 2
		end
		if lost > 0 then
			population_next = population_next - lost
			deaths = deaths + lost
			table.insert(notes_parts, string.format("plague: -%d pop", lost))
		end
	end

	-- Food rot: if this year had rot=true, trigger once at end of autumn.
	if year_events.rot and pos_in_year == (YEAR_LENGTH - 1) and food_next > 0 then
		local frac = 0.20 + math.random() * 0.30 -- 20–50%
		local lost = food_next * frac
		food_next = food_next - lost
		if food_next < 0 then
			food_next = 0
		end
		table.insert(notes_parts, string.format("rot: -%.0f food", lost))
	end

	---------------------------------------------------------------------------
	-- 8) Clamp population minimum.
	---------------------------------------------------------------------------
	if population_next < 2 then
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
	-- 9) Recompute workers for the new population.
	---------------------------------------------------------------------------
	local workers_next_ratio = get_workers_ratio(population_next)
	local workers_next = math.max(1, math.floor(population_next * workers_next_ratio))
	if workers_next > population_next then
		workers_next = population_next
	end

	---------------------------------------------------------------------------
	-- 10) Build notes string.
	---------------------------------------------------------------------------
	local base_note = string.format(
		"season=%s; year=%d; pos_in_year=%d; harvest=%s; golden=%s; plague=%s; rot=%s; net_per_capita=%.3f; stock_per_capita=%.3f",
		season_name,
		year_index,
		pos_in_year,
		year_events.harvest_type,
		tostring(year_events.golden),
		tostring(year_events.plague),
		tostring(year_events.rot),
		net_per_capita,
		stock_per_capita
	)

	if #notes_parts > 0 then
		base_note = base_note .. "; " .. table.concat(notes_parts, "; ")
	end

	return {
		population = population_next,
		food = food_next,
		workers = workers_next,
		births = births,
		deaths = deaths,
		notes = base_note,
	}
end

----------------------------------------------------------------------
-- INSERT RESULT
----------------------------------------------------------------------

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

----------------------------------------------------------------------
-- MAIN
----------------------------------------------------------------------

local db = open_db_and_init()
local last_state = get_latest_state(db)
local next_state = compute_next_state(db, last_state)
insert_state(db, next_state)
db:close()
