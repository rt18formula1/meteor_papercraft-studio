#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Meteor PaperCraft Studio"
APP="$ROOT/dist/$APP_NAME.app"
ARCHIVE="$ROOT/dist/Meteor-PaperCraft-Studio-macOS-arm64.zip"

LOCAL_ENV="${METEOR_LOCAL3D_ENV:-$HOME/.meteor-papercraft/local3d}"
if [[ ! -x "$LOCAL_ENV/.venv/bin/python" ]]; then
  echo "Local backend is missing. Run scripts/setup-local-3d.sh first." >&2
  exit 4
fi
"$LOCAL_ENV/.venv/bin/python" - <<'PY'
import importlib.util
missing = [name for name in ("mlx", "open3d", "cv2") if importlib.util.find_spec(name) is None]
if missing:
    raise SystemExit("Missing local backend modules: " + ", ".join(missing))
PY

"$ROOT/scripts/build-app.sh"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
printf 'Packaged distributable: %s\n' "$ARCHIVE"
printf 'Customers only need to unzip it and open the .app; no terminal setup is required.\n'
