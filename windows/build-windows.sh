#!/bin/bash
# Gera o Acervo para Windows (64 bits) a partir deste Mac:
# ../dist/Acervo-<versão>-Windows-beta.zip com o Acervo.exe (não precisa instalar nada) e o LEIA-ME.
set -euo pipefail
cd "$(dirname "$0")"
DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
VERSION=$(sed -n 's#.*<Version>\(.*\)</Version>.*#\1#p' Acervo.csproj)
OUT=bin/publish/win-x64
rm -rf "$OUT"
"$DOTNET" publish Acervo.csproj -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none -o "$OUT"
STAGE=bin/publish/zip/Acervo
rm -rf bin/publish/zip && mkdir -p "$STAGE" ../dist
cp "$OUT/Acervo.exe" "$STAGE/"
cp LEIA-ME-WINDOWS.txt "$STAGE/LEIA-ME - README - LEAME.txt"
ZIP="../dist/Acervo-${VERSION%.0}-Windows-beta.zip"
rm -f "$ZIP"
(cd bin/publish/zip && zip -qr - Acervo) > "$ZIP"
echo "OK: $ZIP"
