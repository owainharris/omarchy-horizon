#!/usr/bin/env bash
set -euo pipefail

action=${1:-}
state_root=${2:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/span-wallpaper}
state_file="$state_root/state.json"

case "$action" in
  init)
    mkdir -p "$state_root"
    [[ -e $state_file ]] && exit 0
    ;;
  clear)
    mkdir -p "$state_root"
    ;;
  *)
    printf 'usage: state.sh init|clear [STATE_DIR]\n' >&2
    exit 2
    ;;
esac

temporary=$(mktemp "$state_root/.state.XXXXXXXX")
trap 'rm -f -- "$temporary"' EXIT
printf '%s\n' '{"version":1,"source":"","createdAt":"","scaleMode":"fill","bounds":{"x":0,"y":0,"width":0,"height":0},"monitors":[]}' > "$temporary"
mv -- "$temporary" "$state_file"
trap - EXIT
