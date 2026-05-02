#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/TigerSummarizerMenuBar.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BACKEND_DIR="$RESOURCES_DIR/backend"

cd "$ROOT_DIR"
npm run build:web
swift build

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$BACKEND_DIR"
cp "$ROOT_DIR/.build/debug/TigerSummarizerMenuBar" "$MACOS_DIR/TigerSummarizerMenuBar"
cp -R "$ROOT_DIR/build/web" "$RESOURCES_DIR/web"
cp "$ROOT_DIR/run_tigersummarizer.sh" "$BACKEND_DIR/run_tigersummarizer.sh"
cp "$ROOT_DIR/summarize_thread.py" "$BACKEND_DIR/summarize_thread.py"
cp "$ROOT_DIR/requirements.txt" "$BACKEND_DIR/requirements.txt"
chmod +x "$BACKEND_DIR/run_tigersummarizer.sh"

if [[ -d "$ROOT_DIR/.venv" ]]; then
  cp -R "$ROOT_DIR/.venv" "$BACKEND_DIR/.venv"
else
  echo "warning: .venv was not bundled; packaged app will use python3 from PATH"
fi

if [[ -f "$ROOT_DIR/.env" ]]; then
  cp "$ROOT_DIR/.env" "$BACKEND_DIR/.env"
  chmod 600 "$BACKEND_DIR/.env"
else
  echo "warning: .env was not bundled; packaged app will need OPENAI_API_KEY in its environment"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>TigerSummarizerMenuBar</string>
  <key>CFBundleIdentifier</key>
  <string>com.savantsoftwaresystems.TigerSummarizerMenuBar</string>
  <key>CFBundleName</key>
  <string>TigerDroppings Summarizer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "$APP_DIR"
