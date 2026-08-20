#!/bin/bash
#
# Reload the shell whenever plugin source in this repo changes.
#
# The shell watches ~/.config/omarchy/plugins with `inotifywait -r`, and that
# does not traverse symlinks (see inotifywait(1): "Symbolic links are not
# traversed"). Since install.sh links the plugin directory back here, edits
# in this checkout never reach the shell's watcher — the dock keeps running
# the code it loaded at startup and nothing warns you.
#
# This script closes that gap: it watches the real files and asks the shell
# to rescan, which clears Qt's component cache and reloads the QML from disk.
#
# Usage: ./scripts/dev-watch.sh   (Ctrl-C to stop)

set -euo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

command -v inotifywait >/dev/null 2>&1 || {
  echo "inotify-tools is required: omarchy pkg add inotify-tools" >&2
  exit 1
}

echo "Watching $REPO — Ctrl-C to stop."
omarchy-shell -q shell rescanPlugins

# --format keeps the output to one line per change so the log stays readable.
# Reloads are coalesced: editors often write a file two or three times in a
# row, and each rescan tears down and rebuilds the dock.
inotifywait -m -q -r -e close_write,create,delete,move \
  --format '%w%f' "$REPO" |
  while read -r changed; do
    printf '\033[36m::\033[0m %s\n' "${changed#"$REPO/"}"
    # Swallow any writes that land within the next moment, then reload once.
    while read -r -t 0.3 _; do :; done
    omarchy-shell -q shell rescanPlugins &&
      printf '\033[32m ✓\033[0m reloaded\n' ||
      printf '\033[33m !\033[0m shell not reachable\n'
  done
