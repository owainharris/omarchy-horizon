#!/usr/bin/bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$repo_root"

/usr/bin/python3 -c 'import json; json.load(open("manifest.json", encoding="utf-8")); json.load(open("state.example.json", encoding="utf-8"))'
omarchy plugin validate .
/usr/bin/python3 -m py_compile helper.py supervisor.py tests/test-helper.py tests/test-supervisor.py
node tests/test-span-model.js
node tests/test-overlay.js
/usr/bin/python3 -m unittest -v tests/test-helper.py tests/test-supervisor.py
/usr/lib/qt6/bin/qmlformat Overlay.qml >/dev/null
/usr/lib/qt6/bin/qmlformat BarWidget.qml >/dev/null
/usr/lib/qt6/bin/qmlformat ManagedProcess.qml >/dev/null

echo "all checks passed"
