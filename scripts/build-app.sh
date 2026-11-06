#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Meteor PaperCraft Studio"
FINAL_APP="$ROOT/dist/$APP_NAME.app"
APP="$ROOT/dist/.Meteor PaperCraft Studio.building.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/scripts/local_multiview_reconstruct.py" "$CONTENTS/Resources/local_multiview_reconstruct.py"
cp "$ROOT/scripts/cad_profile_loft.py" "$CONTENTS/Resources/cad_profile_loft.py"
cp "$ROOT/scripts/spark_f1_cad_model.py" "$CONTENTS/Resources/spark_f1_cad_model.py"
cp "$ROOT/scripts/cad_parametric_builder.py" "$CONTENTS/Resources/cad_parametric_builder.py"

# Release builds carry the local backend so customers never need a terminal,
# Homebrew, or a separate Python environment. Build this on the target
# Apple-Silicon Mac after running setup-local-3d.sh once.
LOCAL_ENV="${METEOR_LOCAL3D_ENV:-$HOME/.meteor-papercraft/local3d}"
BUNDLE_BACKEND="$CONTENTS/Resources/local3d"
if [[ ! -x "$LOCAL_ENV/.venv/bin/python" ]]; then
  echo "Missing local backend: run scripts/setup-local-3d.sh once before building the distributable app." >&2
  exit 4
fi
mkdir -p "$BUNDLE_BACKEND" "$CONTENTS/Frameworks"
cp -R -L "$LOCAL_ENV/.venv" "$BUNDLE_BACKEND/"
if command -v brew >/dev/null 2>&1 && brew list --versions libusb >/dev/null 2>&1; then
  LIBUSB_DIR="$(brew --prefix libusb)"
  LIBUSB="$LIBUSB_DIR/lib/libusb-1.0.0.dylib"
  if [[ ! -f "$LIBUSB" ]]; then
    echo "Homebrew libusb is installed but its dylib is missing: $LIBUSB" >&2
    exit 5
  fi
  cp -L "$LIBUSB" "$CONTENTS/Frameworks/libusb-1.0.0.dylib"
  while IFS= read -r -d '' dylib; do
    install_name_tool -change "$LIBUSB" "@rpath/libusb-1.0.0.dylib" "$dylib" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path/../../../../../Frameworks" "$dylib" 2>/dev/null || true
  done < <(find "$BUNDLE_BACKEND/.venv" -type f -name '*.dylib' -print0)
else
  echo "Homebrew libusb is required to package the Open3D backend." >&2
  exit 6
fi
swiftc -O -whole-module-optimization \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework UniformTypeIdentifiers -framework ModelIO -framework RealityKit -framework CoreVideo -framework ImageIO -framework PDFKit -framework Vision \
  "$ROOT/Sources/MeteorPaperCraftStudio/main.swift" \
  "$ROOT/Sources/MeteorPaperCraftStudio/MeshUnfolding.swift" \
  "$ROOT/Sources/MeteorPaperCraftStudio/Transparency.swift" \
  -o "$CONTENTS/MacOS/MeteorPaperCraftStudio"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Meteor PaperCraft Studio</string>
  <key>CFBundleDisplayName</key><string>Meteor PaperCraft Studio</string>
  <key>CFBundleIdentifier</key><string>studio.meteor.papercraft</string>
  <key>CFBundleExecutable</key><string>MeteorPaperCraftStudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Meteor PaperCraft Project</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>studio.meteor.papercraft.project</string></array>
    <key>CFBundleTypeExtensions</key><array><string>meteorcraft</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key>
  <array><dict>
    <key>UTTypeIdentifier</key><string>studio.meteor.papercraft.project</string>
    <key>UTTypeDescription</key><string>Meteor PaperCraft Studio Project</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>meteorcraft</string></array><key>public.mime-type</key><string>application/json</string></dict>
  </dict></array>
</dict></plist>
PLIST

xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
rm -rf "$FINAL_APP"
mv "$APP" "$FINAL_APP"
echo "Built: $FINAL_APP"
