#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_DIR="${METEOR_LOCAL3D_ENV:-$HOME/.meteor-papercraft/local3d}"
mkdir -p "$ENV_DIR"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This local backend targets Apple Silicon (arm64)." >&2
  exit 2
fi
if command -v brew >/dev/null 2>&1; then
  if ! brew list --versions libusb >/dev/null 2>&1; then
    echo "Installing Homebrew libusb for the Open3D native dependency…"
    brew install libusb
  elif [[ ! -f "$(brew --prefix libusb)/lib/libusb-1.0.0.dylib" ]]; then
    echo "Repairing the Homebrew libusb installation for Open3D…"
    brew reinstall libusb
  fi
else
  echo "Warning: Homebrew was not found; Open3D may require libusb to be installed manually." >&2
fi
PYTHON_BIN="${METEOR_PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  for candidate in python3.13 python3.12 python3.11 /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11; do
    if command -v "$candidate" >/dev/null 2>&1; then
      version_ok=$("$candidate" -c 'import sys; print(int(sys.version_info >= (3, 11)))')
      if [[ "$version_ok" == "1" ]]; then PYTHON_BIN="$(command -v "$candidate")"; break; fi
    fi
  done
fi
if [[ -z "$PYTHON_BIN" && -x "$(command -v brew 2>/dev/null || true)" ]]; then
  echo "Python 3.11+ was not found; installing Homebrew python@3.12…"
  brew install python@3.12
  PYTHON_BIN="$(brew --prefix python@3.12)/bin/python3.12"
fi
if [[ -z "$PYTHON_BIN" ]]; then
  echo "Python 3.11 or newer is required. Install Homebrew Python 3.12, then rerun this script." >&2
  echo "Example: brew install python@3.12" >&2
  exit 4
fi
if [[ "${METEOR_REBUILD_VENV:-0}" == "1" ]]; then
  rm -rf "$ENV_DIR/.venv"
fi
if [[ -x "$ENV_DIR/.venv/bin/python" ]]; then
  old_ok=$("$ENV_DIR/.venv/bin/python" -c 'import sys; print(int(sys.version_info >= (3, 11)))' || echo 0)
  if [[ "$old_ok" != "1" ]]; then rm -rf "$ENV_DIR/.venv"; fi
fi
if [[ ! -x "$ENV_DIR/.venv/bin/python" ]]; then
  "$PYTHON_BIN" -m venv --copies "$ENV_DIR/.venv"
fi
source "$ENV_DIR/.venv/bin/activate"
python -m pip install --upgrade pip setuptools wheel
python -m pip install "open3d" "cadquery" "opencv-python"

if ! command -v git >/dev/null 2>&1; then
  echo "git is required to install the local MLX-MASt3R backend." >&2
  exit 3
fi
REPO_DIR="$ENV_DIR/mlx-mast3r"
if [[ -e "$REPO_DIR" && ! -d "$REPO_DIR/.git" ]]; then
  rm -rf "$REPO_DIR"
fi
if [[ ! -d "$REPO_DIR/.git" ]]; then
  git clone --recurse-submodules https://github.com/Aedelon/mlx-mast3r.git "$REPO_DIR"
else
  git -C "$REPO_DIR" pull --ff-only
  git -C "$REPO_DIR" submodule update --init --recursive
fi
python -m pip install -e "$REPO_DIR"

cat <<EOF
Local 3D backend installed.
Python: $PYTHON_BIN
Environment: $ENV_DIR/.venv
Model weights are downloaded by MLX-MASt3R on the first local run and then reused from the local cache.
Runtime entry point:
  $ROOT/scripts/local_multiview_reconstruct.py
EOF
