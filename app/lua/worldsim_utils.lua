local sqlite3 = require("lsqlite3")
local config = require("worldsim_config")

local M = {}

-- Ensure that a directory exists.
function M.ensure_dir(path)
  os.execute(string.format('mkdir -p "%s"', path))
end

-- Run shell command and capture stdout.
function M.run_cmd(cmd)
  local f = io.popen(cmd, "r")
  if not f then
    return ""
  end
  local out = f:read("*a") or ""
  f:close()
  return out
end

-- Open SQLite database with busy timeout.
function M.open_db(path)
  local db, err = sqlite3.open(path or config.DB_PATH)
  assert(db, "Failed to open database: " .. (err or path or config.DB_PATH))
  db:busy_timeout(5000)
  return db
end

return M
