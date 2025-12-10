set terminal pngcairo size 1000,350 enhanced font ",10"
set output "/var/www/html/worldsim/world.png"

set datafile separator "|"

# Light Catppuccin Latte background
set object 1 rectangle from screen 0,0 to screen 1,1 behind \
    fillcolor rgb "#eff1f5" fillstyle solid 1.0

set border lc rgb "#4c4f69"
set grid lc rgb "#ccd0da"
set tics textcolor rgb "#4c4f69"

set xdata time
set timefmt "%s"
set format x "%H:%M\n%d-%m"

# Soft minimum at 0
set yrange [0:*]

# Last 2 hours based on epoch seconds
now        = time(0)
two_hours  = now - 2*3600
set xrange [two_hours:now]

unset key  # legend handled in HTML

set title "World Simulation: Population  Food  Workers (last 2 hours)" tc rgb "#4c4f69"
set xlabel "Time" tc rgb "#4c4f69"
set ylabel "Value" tc rgb "#4c4f69"

# epoch, population, food, workers
plot "< sqlite3 /opt/worldsim/db/worldsim.db \"SELECT strftime('%s', ts_utc), population, food, workers FROM world_tick ORDER BY ts_utc;\"" \
        using 1:2 with lines lw 2 lc rgb '#1e66f5', \
     '' using 1:3 with lines lw 2 lc rgb '#40a02b', \
     '' using 1:4 with lines lw 2 lc rgb '#df8e1d'
