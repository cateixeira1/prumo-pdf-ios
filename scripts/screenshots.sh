#!/bin/bash
# Abre o app no simulador com dados de demonstração e tira capturas de cada tela.
# Uso: scripts/screenshots.sh <udid-do-simulador> <pasta-de-saida>
set -uo pipefail
SIM="$1"
OUT="$2"
BUNDLE="br.com.prumopdf.app"
APP=$(find build/Build/Products -maxdepth 2 -name "PrumoPDF.app" -path "*iphonesimulator*" | head -1)
if [ -z "$APP" ]; then
  echo "App do simulador não encontrado; compilando…"
  xcodebuild build -project PrumoPDF.xcodeproj -scheme PrumoPDF -destination "id=$SIM" \
    -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet || exit 1
  APP=$(find build/Build/Products -maxdepth 2 -name "PrumoPDF.app" -path "*iphonesimulator*" | head -1)
fi
echo "App: $APP"

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b
xcrun simctl ui "$SIM" appearance light
xcrun simctl status_bar "$SIM" override --time "9:41" --dataNetwork wifi --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$SIM" "$APP"

shot() {
  local name="$1"; local screen="$2"; local wait="${3:-6}"
  xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$SIM" "$BUNDLE" -demo -screen "$screen" >/dev/null
  sleep "$wait"
  xcrun simctl io "$SIM" screenshot "$OUT/$name.png" >/dev/null 2>&1 && echo "ok: $name"
}

shot 01-inicio home 7
shot 02-todos all
shot 03-pastas folders
shot 04-pasta folder
shot 05-documento detail
shot 06-organizar organize 7
shot 07-dividir split 7
shot 08-leitor reader 7
shot 09-aguardando-ocr pending
shot 10-pergunta-ocr ocrprompt 7
shot 11-combinar merge
shot 12-ajustes settings
shot 17-busca-no-texto search 8
shot 18-incluir-de-outro-pdf picker 9
# OCR de verdade no simulador: barra de progresso e, depois, o aviso de concluído.
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$SIM" "$BUNDLE" -demo -screen ocr >/dev/null
sleep 6
xcrun simctl io "$SIM" screenshot "$OUT/13-ocr-andamento.png" >/dev/null 2>&1 && echo "ok: 13"
sleep 40
xcrun simctl io "$SIM" screenshot "$OUT/14-ocr-concluido.png" >/dev/null 2>&1 && echo "ok: 14"

xcrun simctl ui "$SIM" appearance dark
shot 15-inicio-escuro home 7
shot 16-documento-escuro detail
xcrun simctl ui "$SIM" appearance light
exit 0
