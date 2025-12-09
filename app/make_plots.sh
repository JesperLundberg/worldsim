#!/usr/bin/env bash
set -euo pipefail

PLOT_DIR="/opt/worldsim/plots"
OUT_DIR="/var/www/html/worldsim"

mkdir -p "$OUT_DIR"

gnuplot "$PLOT_DIR/plot_world.gnuplot"
gnuplot "$PLOT_DIR/plot_world_mobile.gnuplot"
