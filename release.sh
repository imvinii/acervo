#!/bin/bash
# Compila e monta o instalador para compartilhar: dist/Importar-Cartao-<versão>.dmg
# (o app + atalho para a pasta Aplicativos + instruções da primeira abertura)
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/Importar Cartão.app/Contents/Info.plist")
STAGE=build/dmg
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
cp -R "build/Importar Cartão.app" "$STAGE/"
ln -s /Applications "$STAGE/Aplicativos"
cp "LEIA-ME.txt" "$STAGE/LEIA-ME.txt"
DMG="dist/Importar-Cartao-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Importar Cartão $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "OK: $DMG"
