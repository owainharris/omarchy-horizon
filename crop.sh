#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'span-wallpaper: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 2 && $# -le 4 ]] || fail "usage: crop.sh SOURCE MONITORS_JSON [STATE_DIR] [SCALE_MODE]"

command -v magick >/dev/null 2>&1 || fail "ImageMagick (magick) is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
command -v timeout >/dev/null 2>&1 || fail "timeout is required (provided by coreutils)"

source_path=$1
monitors_json=$2
state_root=${3:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/span-wallpaper}
scale_mode=${4:-fill}

case "$scale_mode" in
  fill|fit|stretch) ;;
  *) fail "scale mode must be fill, fit, or stretch" ;;
esac

[[ -f $source_path ]] || fail "image does not exist: $source_path"

normalized=$(jq -ce '
  if type != "array" or length == 0 then error("select at least one monitor") else . end
  | map({
      name: (.name | tostring),
      x: (.x | tonumber | floor),
      y: (.y | tonumber | floor),
      width: (.width | tonumber | floor),
      height: (.height | tonumber | floor)
    })
  | if any(.[]; .name == "" or .width <= 0 or .height <= 0)
      then error("monitor geometry is invalid") else . end
  | if ([.[].name] | unique | length) != length
      then error("monitor names must be unique") else . end
' <<<"$monitors_json") || fail "monitor geometry is invalid"

read -r bbox_x bbox_y bbox_width bbox_height < <(
  jq -r '
    ([.[].x] | min) as $x
    | ([.[].y] | min) as $y
    | ([.[] | .x + .width] | max) as $right
    | ([.[] | .y + .height] | max) as $bottom
    | [$x, $y, ($right - $x), ($bottom - $y)] | @tsv
  ' <<<"$normalized"
)

(( bbox_width > 0 && bbox_height > 0 )) || fail "monitor bounding box is empty"

mkdir -p "$state_root/sources"
source_path=$(realpath -- "$source_path")
source_hash=$(sha256sum -- "$source_path" | cut -d ' ' -f 1)
extension=${source_path##*.}
extension=${extension,,}
[[ $extension =~ ^[a-z0-9]{1,8}$ ]] || extension=img
stored_source="$state_root/sources/$source_hash.$extension"
if [[ ! -e $stored_source ]]; then
  cp -- "$source_path" "$stored_source"
fi

stamp=$(date -u +'%Y%m%dT%H%M%S')-$$
output_dir="$state_root/$stamp"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/span-wallpaper.XXXXXXXX")
stage_dir=$(mktemp -d "$state_root/.stage.XXXXXXXX")
state_tmp=$(mktemp "$state_root/.state.XXXXXXXX")
export MAGICK_TEMPORARY_PATH="$work_dir"

cleanup() {
  if [[ -n ${work_dir:-} && -d $work_dir ]]; then rm -rf -- "$work_dir"; fi
  if [[ -n ${stage_dir:-} && -d $stage_dir ]]; then rm -rf -- "$stage_dir"; fi
  if [[ -n ${state_tmp:-} && -f $state_tmp ]]; then rm -f -- "$state_tmp"; fi
}
trap cleanup EXIT

magick_limits=(-limit thread 4 -limit memory 256MiB -limit map 512MiB -limit disk 2GiB)
decoder_options=()

# Let libjpeg discard unneeded DCT detail before ImageMagick allocates the
# source pixel cache. A 16K panorama otherwise expands to hundreds of MiB even
# when the requested virtual canvas is only a few thousand pixels wide. Asking
# for twice the destination size preserves enough detail for the final resize.
if [[ $extension == jpg || $extension == jpeg ]]; then
  decoder_options=(-define "jpeg:size=${bbox_width}x${bbox_height}")
fi

case "$scale_mode" in
  fill)
    scale_options=(-resize "${bbox_width}x${bbox_height}^" -gravity center -extent "${bbox_width}x${bbox_height}")
    ;;
  fit)
    scale_options=(-resize "${bbox_width}x${bbox_height}" -gravity center -background black -extent "${bbox_width}x${bbox_height}")
    ;;
  stretch)
    scale_options=(-resize "${bbox_width}x${bbox_height}!")
    ;;
esac

timeout --signal=TERM --kill-after=5s 90s \
  magick "${magick_limits[@]}" "${decoder_options[@]}" "$stored_source" -auto-orient \
  "${scale_options[@]}" \
  -define png:compression-level=1 \
  "$work_dir/virtual.png" || fail "ImageMagick could not read or prepare the selected image"

entries_file="$work_dir/monitors.jsonl"
: > "$entries_file"

while IFS= read -r monitor; do
  name=$(jq -r '.name' <<<"$monitor")
  x=$(jq -r '.x' <<<"$monitor")
  y=$(jq -r '.y' <<<"$monitor")
  width=$(jq -r '.width' <<<"$monitor")
  height=$(jq -r '.height' <<<"$monitor")
  crop_x=$((x - bbox_x))
  crop_y=$((y - bbox_y))

  safe_name=${name//[^A-Za-z0-9._-]/_}
  name_hash=$(printf '%s' "$name" | sha256sum | cut -c1-12)
  file_name="${safe_name}-${name_hash}.png"
  final_path="$output_dir/$file_name"

  timeout --signal=TERM --kill-after=5s 30s \
    magick "${magick_limits[@]}" "$work_dir/virtual.png" \
    -crop "${width}x${height}+${crop_x}+${crop_y}" +repage \
    -define png:compression-level=1 \
    "$work_dir/$file_name" || fail "could not crop monitor $name"

  jq -nc \
    --arg name "$name" --arg file "$final_path" \
    --argjson x "$x" --argjson y "$y" \
    --argjson width "$width" --argjson height "$height" \
    '{name:$name,x:$x,y:$y,width:$width,height:$height,file:$file}' \
    >> "$entries_file"
done < <(jq -c '.[]' <<<"$normalized")

monitors_state=$(jq -s '.' "$entries_file")
created_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

jq -n \
  --arg source "$stored_source" \
  --arg createdAt "$created_at" \
  --arg scaleMode "$scale_mode" \
  --argjson x "$bbox_x" --argjson y "$bbox_y" \
  --argjson width "$bbox_width" --argjson height "$bbox_height" \
  --argjson monitors "$monitors_state" \
  '{version:1,source:$source,createdAt:$createdAt,scaleMode:$scaleMode,bounds:{x:$x,y:$y,width:$width,height:$height},monitors:$monitors}' \
  > "$state_tmp"

rm -f -- "$work_dir/virtual.png" "$entries_file"
cp -- "$work_dir"/*.png "$stage_dir/"
mv -- "$stage_dir" "$output_dir"
stage_dir=""
mv -- "$state_tmp" "$state_root/state.json"
state_tmp=""

printf '%s\n' "$state_root/state.json"
