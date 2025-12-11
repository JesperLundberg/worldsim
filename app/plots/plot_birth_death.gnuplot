set terminal pngcairo size 1000,350 enhanced font ",10"
set output "/var/www/html/worldsim/birth_death.png"

set datafile separator "|"

# Light Catppuccin Latte background
set object 1 rectangle from screen 0,0 to screen 1,1 behind \
    fillcolor rgb "#eff1f5" fillstyle solid 1.0

set border lc rgb "#4c4f69"
set grid lc rgb "#ccd0da"
set tics textcolor rgb "#4c4f69"

set xlabel "Simulation years"
set ylabel "Count" tc rgb "#4c4f69"

set yrange [0:*]

set title "Births & Deaths: last 24 hours (≈ 24 sim years)" tc rgb "#4c4f69"

# Last 1440 ticks, oldest -> newest
plot "< sqlite3 /opt/worldsim/db/worldsim.db \" \
    SELECT 1 + (id - 1) / 60.0 AS sim_year, births, deaths \
    FROM ( \
      SELECT id, births, deaths \
      FROM world_tick \
      ORDER BY id DESC \
      LIMIT 1440 \
    ) \
    ORDER BY id; \
  \"" using 1:2 with impulses lw 2 lc rgb "#40a02b" title "Births", \
     "" using 1:3 with impulses lw 2 lc rgb "#dc8a78" title "Deaths"
