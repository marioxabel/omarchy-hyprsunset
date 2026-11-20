#!/bin/sh
# Build the per-monitor night-light helper. Safe to re-run.
set -eu
base=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
build="$base/helper/build"
mkdir -p "$build" "$base/bin"
wayland-scanner client-header "$base/helper/hyprland-ctm-control-v1.xml" "$build/ctm-client.h"
wayland-scanner private-code "$base/helper/hyprland-ctm-control-v1.xml" "$build/ctm-protocol.c"
gcc -O2 -Wall -Wextra -o "$base/bin/sunset-ctm.bin" \
  -I"$build" \
  "$base/helper/sunset-ctm.c" "$build/ctm-protocol.c" \
  -lwayland-client -lm
echo "built $base/bin/sunset-ctm.bin" >&2
