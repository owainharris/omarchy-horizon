#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_root"

bash -n ./*.sh tests/*.sh
jq empty manifest.json state.example.json
omarchy plugin validate .
python3 -c 'compile(open("pick-file.py", encoding="utf-8").read(), "pick-file.py", "exec")'
node tests/test-span-model.js
tests/test-crop.sh
/usr/lib/qt6/bin/qmlformat Overlay.qml >/dev/null
/usr/lib/qt6/bin/qmlformat BarWidget.qml >/dev/null

echo "all checks passed"
