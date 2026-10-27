#!/bin/bash
# Compila o app e monta o "Importar Cartão.app" em ./build
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Importar Cartão.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset
swiftc -O -swift-version 5 -enable-bare-slash-regex -target arm64-apple-macos14.0 -parse-as-library \
  Sources/Engine.swift Sources/App.swift -o "$APP/Contents/MacOS/Importar Cartao"
swiftc -swift-version 5 MakeIcon.swift -o build/makeicon && build/makeicon build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Importar Cartão</string>
  <key>CFBundleDisplayName</key><string>Importar Cartão</string>
  <key>CFBundleIdentifier</key><string>com.vertice.importar-cartao</string>
  <key>CFBundleExecutable</key><string>Importar Cartao</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>Para ler os arquivos do cartão de memória.</string>
  <key>CFBundleDevelopmentRegion</key><string>pt_BR</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
echo "OK: $APP"
