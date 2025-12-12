set terminal pngcairo size 1000,350 enhanced font ",10"
set output "/var/www/html/worldsim/food.png"

set datafile separator "|"

# Light Catppuccin Latte background
set object 1 rectangle from screen 0,0 to screen 1,1 behind \
    fillcolor rgb "#eff1f5" fillstyle solid 1.0

set border lc rgb "#4c4f69"
set grid lc rgb "#ccd0da"
set tics textcolor rgb "#4c4f69"

# X axis: simulation years (derived from tick id)
set xlabel "Simulation years" tc rgb "#4c4f69"
set ylabel "Food" tc rgb "#4c4f69"
set title "Food stores: last 24 hours (≈ 24 sim years)" tc rgb "#4c4f69"

set yrange [0:*]
unset key  # legend handled in HTML

# id is 1-based tick number. 60 ticks per sim year.
plot "< sqlite3 /opt/worldsim/db/worldsim.db \"SELECT id, food FROM world_tick ORDER BY id;\"" \
  using ($1/60.0):2 with lines lw 2 lc rgb '#40a02b'
