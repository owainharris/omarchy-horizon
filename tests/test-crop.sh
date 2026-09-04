#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d /tmp/span-wallpaper-test.XXXXXXXX)
trap 'rm -rf -- "$work_dir"' EXIT

magick -size 100x200 gradient:'#ff0000-#0000ff' -rotate 90 "$work_dir/source.png"

geometry='[
  {"name":"LEFT","x":0,"y":0,"width":100,"height":100},
  {"name":"RIGHT","x":120,"y":0,"width":100,"height":100}
]'

"$repo_root/crop.sh" \
  "$work_dir/source.png" "$geometry" "$work_dir/state" >/dev/null

state="$work_dir/state/state.json"
jq -e '
  .version == 1
  and .scaleMode == "fill"
  and .bounds == {"x":0,"y":0,"width":220,"height":100}
  and (.monitors | length) == 2
' "$state" >/dev/null

stored_source=$(jq -r '.source' "$state")
left=$(jq -r '.monitors[] | select(.name == "LEFT") | .file' "$state")
right=$(jq -r '.monitors[] | select(.name == "RIGHT") | .file' "$state")
[[ -f $stored_source && -f $left && -f $right ]]
[[ $(magick identify -format '%wx%h' "$left") == 100x100 ]]
[[ $(magick identify -format '%wx%h' "$right") == 100x100 ]]

magick "$stored_source" -auto-orient \
  -resize '220x100^' -gravity center -extent '220x100' "$work_dir/expected.png"
magick "$work_dir/expected.png" -crop '100x100+0+0' +repage "$work_dir/expected-left.png"
magick "$work_dir/expected.png" -crop '100x100+120+0' +repage "$work_dir/expected-right.png"

left_difference=$(compare -metric AE "$left" "$work_dir/expected-left.png" null: 2>&1 || true)
right_difference=$(compare -metric AE "$right" "$work_dir/expected-right.png" null: 2>&1 || true)
[[ $left_difference =~ ^0([[:space:]]|$) && $right_difference =~ ^0([[:space:]]|$) ]]

"$repo_root/crop.sh" \
  "$work_dir/source.png" "$geometry" "$work_dir/stretch-state" stretch >/dev/null
jq -e '.scaleMode == "stretch"' "$work_dir/stretch-state/state.json" >/dev/null

stretch_left=$(jq -r '.monitors[] | select(.name == "LEFT") | .file' "$work_dir/stretch-state/state.json")
magick "$stored_source" -resize '220x100!' -crop '100x100+0+0' +repage "$work_dir/expected-stretch-left.png"
stretch_difference=$(compare -metric AE "$stretch_left" "$work_dir/expected-stretch-left.png" null: 2>&1 || true)
[[ $stretch_difference =~ ^0([[:space:]]|$) ]]

"$repo_root/state.sh" clear "$work_dir/state"
jq -e '.source == "" and (.monitors | length) == 0' "$state" >/dev/null

echo "crop and state tests passed"
