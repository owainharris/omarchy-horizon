#!/usr/bin/env bash
set -euo pipefail

state_root=${1:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/span-wallpaper}
selected_image=${2:-}
mkdir -p "$state_root"

request_dir=$(mktemp -d "$state_root/.picker.XXXXXXXX")
selection_file="$request_dir/selection"
done_file="$request_dir/done"
waiting=1

cleanup() {
  if (( waiting )); then
    omarchy-shell -q image-selector cancel "$done_file" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$request_dir"
}
trap cleanup EXIT

image_dirs=""
add_dir() {
  [[ -d $1 ]] || return 0
  image_dirs+="${image_dirs:+$'\n'}$1"
}

add_dir "${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/current/theme/backgrounds"

while IFS= read -r directory; do add_dir "$directory"; done < <({
  find "$HOME/.config/omarchy/backgrounds" \
    -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null
  find "$HOME/.config/omarchy/themes" \
    -mindepth 2 -maxdepth 2 -type d -name backgrounds -print 2>/dev/null
} | sort -u)

[[ -n $image_dirs ]] || {
  printf 'span-wallpaper: no Omarchy background directories were found\n' >&2
  exit 1
}

omarchy-shell image-selector open \
  "$image_dirs" "" "$selected_image" "$selection_file" "$done_file" true true \
  >/dev/null

while [[ ! -e $done_file ]]; do sleep 0.1; done
waiting=0

if [[ -s $selection_file ]]; then
  IFS= read -r selection < "$selection_file"
  printf '%s\n' "$selection"
fi
