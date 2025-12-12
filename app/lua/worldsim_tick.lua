-- worldsim_tick.lua
--
-- One simulation tick (1 minute real time)
-- 60 ticks = 1 simulated year
--
-- Core goals of this version:
-- - Prevent food from hitting 0 and staying there
-- - Introduce rationing when food is scarce
-- - Shorten bad-food streaks, allow good-food streaks
-- - Keep the system stochastic, not deterministic

local sqlite3 = require("lsqlite3")
local math_random = math.random

-- ---------------------------------------------------------------------------
-- Configuration parameters (tune slowly)
-- ---------------------------------------------------------------------------

local MIN_POPULATION = 2

local BASE_FOOD_PER_WORKER = 1.0 -- baseline yearly production
local BASE_FOOD_CONSUMPTION = 1.0 -- baseline yearly consumption per person

local BASE_BIRTH_RATE = 0.015 -- per year
local BASE_DEATH_RATE = 0.010 -- per year

local MAX_WORKER_RATIO = 0.80
local MIN_WORKER_RATIO = 0.20

-- Rationing thresholds (food per capita)
local RATION_START = 1.2 -- start eating less below this
local RATION_HARD = 0.4 -- severe rationing below this

-- Worker mobilization when hungry
local HUNGER_MOBILIZE_START = 1.0
local HUNGER_MOBILIZE_MAX = 0.20 -- temporary boost to worker ratio

-- Bad streak dampening
local BAD_YEAR_RECOVERY_BONUS = 0.25 -- extra production bias after bad years

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function clamp(x, lo, hi)
	if x < lo then
		return lo
	end
	if x > hi then
		return hi
	end
	return x
end

-- Smooth rationing curve based on food per capita
local function ration_factor(food_per_capita)
	if food_per_capita >= RATION_START then
		return 1.0
	end

	if food_per_capita <= RATION_HARD then
		return 0.35
	end

	-- Linear interpolation between start and hard rationing
	local t = (food_per_capita - RATION_HARD) / (RATION_START - RATION_HARD)
	return 0.35 + t * (1.0 - 0.35)
end

-- Extra workers when hungry (temporary survival behavior)
local function hunger_worker_boost(food_per_capita)
	if food_per_capita >= HUNGER_MOBILIZE_START then
		return 0.0
	end

	local t = clamp((HUNGER_MOBILIZE_START - food_per_capita) / HUNGER_MOBILIZE_START, 0.0, 1.0)

	return t * HUNGER_MOBILIZE_MAX
end

-- ---------------------------------------------------------------------------
-- Load DB
-- ---------------------------------------------------------------------------

local db = sqlite3.open("worldsim.db")
db:exec("BEGIN")

-- Current state (latest row)
local state = {}
for row in
	db:nrows([[
  SELECT *
  FROM state
  ORDER BY tick DESC
  LIMIT 1
]])
do
	state = row
end

-- Defensive defaults (first tick)
local tick = (state.tick or 0) + 1
local population = tonumber(state.population) or 10
local food = tonumber(state.food) or 20
local workers = tonumber(state.workers) or math.floor(population * 0.5)

-- ---------------------------------------------------------------------------
-- Derived values
-- ---------------------------------------------------------------------------

population = math.max(population, MIN_POPULATION)

local food_per_capita = food / population

-- Base worker ratio dynamics
local base_worker_ratio = clamp(1.0 - (population / (population + 20.0)), MIN_WORKER_RATIO, MAX_WORKER_RATIO)

-- Hunger-driven temporary worker boost
local worker_ratio = clamp(base_worker_ratio + hunger_worker_boost(food_per_capita), MIN_WORKER_RATIO, MAX_WORKER_RATIO)

workers = math.max(1, math.floor(population * worker_ratio))

-- ---------------------------------------------------------------------------
-- Production
-- ---------------------------------------------------------------------------

-- Mild seasonal randomness
local season_factor = 0.9 + math_random() * 0.2

-- If food is very low, bias slightly upward to avoid long famine streaks
if food_per_capita < 0.8 then
	season_factor = season_factor + BAD_YEAR_RECOVERY_BONUS
end

local food_produced = workers * BASE_FOOD_PER_WORKER * season_factor / 60.0

-- ---------------------------------------------------------------------------
-- Consumption (with rationing)
-- ---------------------------------------------------------------------------

local ration = ration_factor(food_per_capita)

local food_consumed = population * BASE_FOOD_CONSUMPTION * ration / 60.0

-- ---------------------------------------------------------------------------
-- Update
