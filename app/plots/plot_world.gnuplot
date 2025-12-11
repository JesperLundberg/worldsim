set terminal pngcairo size 1000,350 enhanced font ",10"
set output "/var/www/html/worldsim/world.png"

set datafile separator "|"

# Light Catppuccin Latte background
set object 1 rectangle from screen 0,0 to screen 1,1 behind \
    fillcolor rgb "#eff1f5" fillstyle solid 1.0

set border lc rgb "#4c4f69"
set grid lc rgb "#ccd0da"
set tics textcolor rgb "#4c4f69"

unset key  # legend handled in HTML

# X-axis is simulation years, not real time
set xlabel "Simulation years"
set ylabel "Value" tc rgb "#4c4f69"

set yrange [0:*]

set title "World Simulation: last 24 hours (≈ 24 sim years)" tc rgb "#4c4f69"

# Last 1440 ticks (24h @ 1 tick/min), ordered oldest -> newest
# sim_year = 1 + (id-1)/60.0  (year 1 at the very beginning)
plot "< sqlite3 /opt/worldsim/db/worldsim.db \" \
    SELECT 1 + (id - 1) / 60.0 AS sim_year, population, food, workers \
    FROM ( \
      SELECT id, population, food, workers \
      FROM world_tick \
      ORDER BY id DESC \
      LIMIT 1440 \
    ) \
    ORDER BY id; \
  \"" using 1:2 with lines lw 2 lc rgb '#1e66f5', \
     '' using 1:3 with lines lw 2 lc rgb '#40a02b', \
     '' using 1:4 with lines lw 2 lc rgb '#df8e1d'
