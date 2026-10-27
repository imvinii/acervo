#!/bin/bash
# Compila o app e monta o "Acervo.app" em ./build
set -euo pipefail
cd "$(dirname "$0")"
VERSION="2.0"
APP="build/Acervo.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset
# Universal: roda em Mac com Apple Silicon e com Intel
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -enable-bare-slash-regex -target $arch-apple-macos14.0 -parse-as-library \
    Sources/*.swift -o "build/Acervo-$arch"
done
lipo -create "build/Acervo-arm64" "build/Acervo-x86_64" -output "$APP/Contents/MacOS/Acervo"
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
  <key>CFBundleName</key><string>Acervo</string>
  <key>CFBundleDisplayName</key><string>Acervo</string>
  <key>CFBundleIdentifier</key><string>com.vertice.acervo</string>
  <key>CFBundleExecutable</key><string>Acervo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemovableVolumesUsageDescription</key><string>Para ler os arquivos do cartão de memória.</string>
  <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
  <key>CFBundleLocalizations</key><array><string>pt-BR</string><string>en</string><string>es</string></array>
</dict></plist>
PLIST
# Pastas de idioma: fazem o macOS usar o idioma certo nos menus e janelas do sistema
for l in pt-BR en es; do mkdir -p "$APP/Contents/Resources/$l.lproj"; touch "$APP/Contents/Resources/$l.lproj/Localizable.strings"; done
echo '"NSRemovableVolumesUsageDescription" = "To read the files on the memory card.";' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
echo '"NSRemovableVolumesUsageDescription" = "Para leer los archivos de la tarjeta de memoria.";' > "$APP/Contents/Resources/es.lproj/InfoPlist.strings"
codesign --force --deep -s - "$APP"
echo "OK: $APP"
