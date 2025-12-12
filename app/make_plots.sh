#!/bin/sh
set -eu

PLOT_DIR="/opt/worldsim/plots"
OUT_DIR="/var/www/html/worldsim"

mkdir -p "$OUT_DIR"

# Generate split charts (desktop + mobile)
gnuplot "$PLOT_DIR/plot_food.gnuplot"
gnuplot "$PLOT_DIR/plot_food_mobile.gnuplot"

gnuplot "$PLOT_DIR/plot_pop_workers.gnuplot"
gnuplot "$PLOT_DIR/plot_pop_workers_mobile.gnuplot"
