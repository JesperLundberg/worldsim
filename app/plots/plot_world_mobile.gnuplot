set terminal png size 600,400
set output "/var/www/html/worldsim/world_mobile.png"

set xdata time
set timefmt "%Y-%m-%dT%H:%M:%SZ"
set format x "%H:%M"

set grid
set xlabel "Time (UTC)"
set ylabel "Population / Food"

plot "< sqlite3 /opt/worldsim/db/worldsim.db \"SELECT ts_utc, population, food FROM world_tick ORDER BY id;\"" \
     using 1:2 with lines title "Population", \
     "" using 1:3 with lines title "Food"
