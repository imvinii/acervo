#!/bin/bash
# Compila e monta o instalador para compartilhar: dist/Offload-<versão>.dmg
# (o app + atalho para a pasta Aplicativos + instruções da primeira abertura)
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/Offload.app/Contents/Info.plist")
STAGE=build/dmg
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R "build/Offload.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "LEIA-ME.txt" "$STAGE/LEIA-ME · README · LÉAME.txt"
DMG="dist/Offload-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Offload $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "OK: $DMG"
