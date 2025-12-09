#!/bin/sh
set -e

# Ensure DB directory exists on tmpfs
mkdir -p /opt/worldsim/db

# If a backup exists on disk, restore it into tmpfs
if [ -f /opt/worldsim/backups/worldsim.db ]; then
  cp /opt/worldsim/backups/worldsim.db /opt/worldsim/db/worldsim.db
fi

export LUA_PATH="/opt/worldsim/lua/?.lua;/opt/worldsim/lua/?/init.lua;;"

# Start cron in the foreground
exec cron -f
