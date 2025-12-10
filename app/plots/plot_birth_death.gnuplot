set terminal pngcairo size 1000,350 enhanced font ",10"
set output "/var/www/html/worldsim/birth_death.png"

set datafile separator "|"

set object 1 rectangle from screen 0,0 to screen 1,1 behind \
    fillcolor rgb "#eff1f5" fillstyle solid 1.0

set border lc rgb "#4c4f69"
set grid lc rgb "#ccd0da"
set tics textcolor rgb "#4c4f69"

set xdata time
set timefmt "%s"
set format x "%H:%M\n%d-%m"

now        = time(0)
twentofour_hours  = now - 24*3600
set xrange [twentyfour_hours:now]

set yrange [0:*]

unset key  # legend handled in HTML

set title "Births & Deaths (last 2 hours)" tc rgb "#4c4f69"
set xlabel "Time" tc rgb "#4c4f69"
set ylabel "Count" tc rgb "#4c4f69"

plot "< sqlite3 /opt/worldsim/db/worldsim.db \"SELECT strftime('%s', ts_utc), births, deaths FROM world_tick ORDER BY ts_utc;\"" \
    using 1:2 with impulses lw 2 lc rgb "#40a02b" title "Births", \
     "" using 1:3 with impulses lw 2 lc rgb "#dc8a78" title "Deaths"
