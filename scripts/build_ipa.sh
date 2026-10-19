#!/bin/bash
# Compila para iPhone (Release, sem assinatura) e empacota como PrumoPDF.ipa.
# O Sideloadly assina o app com o seu Apple ID na hora de instalar.
set -euo pipefail
OUT="$1"
xcodebuild build \
  -project PrumoPDF.xcodeproj -scheme PrumoPDF -configuration Release \
  -sdk iphoneos -destination "generic/platform=iOS" \
  -derivedDataPath build-device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -quiet
APP="build-device/Build/Products/Release-iphoneos/PrumoPDF.app"
test -d "$APP"
rm -rf Payload
mkdir Payload
cp -R "$APP" Payload/
zip -qry "$OUT/PrumoPDF.ipa" Payload
rm -rf Payload
ls -la "$OUT/PrumoPDF.ipa"
