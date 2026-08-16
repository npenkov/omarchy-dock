#!/bin/bash
# Re-render the mockup PNGs from the HTML sources with headless chromium.
# Sizes are per-mockup so each composition fills its frame.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

shot() {
  chromium --headless --disable-gpu --hide-scrollbars \
    --window-size="$2" --screenshot="${1%.html}.png" "file://$PWD/$1" 2>/dev/null
  echo "rendered ${1%.html}.png"
}

shot 01-sections.html 1500,560
shot 02-hover-pin.html 1100,660
shot 03-context-menu.html 1150,660
shot 04-group-stack.html 1150,760
shot 05-settings-gui.html 1500,840
