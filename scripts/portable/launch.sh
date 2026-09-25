#!/bin/sh
set -eu

bundle=$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | cut -d ' ' -f 2) || glibc=unknown
minimum=@GLIBC_MIN@
if [ "$glibc" = unknown ] || [ "$(printf '%s\n' "$minimum" "$glibc" | sort -V | head -n 1)" != "$minimum" ]; then
    printf 'Remix Studio requires glibc %s or newer (found %s).\n' "$minimum" "$glibc" >&2
    exit 1
fi

data=${REMIX_STUDIO_DATA_DIR:-"$bundle/data"}
if ! mkdir -p -- "$data"; then
    echo 'Choose a writable folder with REMIX_STUDIO_DATA_DIR=/path/to/data.' >&2
    exit 1
fi
data=$(CDPATH= cd -- "$data" && pwd)
export REMIX_STUDIO_DATA_DIR="$data"
export REMIX_STUDIO_SETTINGS_DIR=${REMIX_STUDIO_SETTINGS_DIR:-"$data/settings"}
export XDG_DATA_HOME="$data/user"
export XDG_CONFIG_HOME="$data/config"
export XDG_CACHE_HOME="$data/cache"
export REMIX_RUNTIME_PATH=${REMIX_RUNTIME_PATH:-"$bundle/runtime/libremix.so"}
export REMIX_RENDERER_WORKER=${REMIX_RENDERER_WORKER:-"$bundle/bin/remix-renderer"}
export PXR_PLUGINPATH_NAME="$bundle/lib/usd:$bundle/plugin/usd${PXR_PLUGINPATH_NAME:+:$PXR_PLUGINPATH_NAME}"
mkdir -p -- "$data/run" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$REMIX_STUDIO_SETTINGS_DIR"

# Preserve the caller's working directory for relative CLI filenames.
if [ "${1:-}" = --cli ]; then
    shift
    exec "$bundle/bin/remix-editor-cli" "$@"
fi
# Godot changes its cwd to app/. The worker wrapper separately selects data/run.
cd -- "$data/run"
exec "$bundle/bin/godot" --path "$bundle/app" "$@"
