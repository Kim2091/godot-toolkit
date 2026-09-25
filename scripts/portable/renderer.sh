#!/bin/sh
set -eu
binary_dir=$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
data=${REMIX_STUDIO_DATA_DIR:-"$binary_dir/../data"}
mkdir -p -- "$data/run"
cd -- "$data/run"
exec "$binary_dir/remix-renderer.bin" "$@"
