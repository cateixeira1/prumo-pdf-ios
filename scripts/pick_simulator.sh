#!/bin/bash
# Escolhe um simulador de iPhone disponível (de preferência o mais novo, sem "Pro Max"/"Plus"/"mini").
set -euo pipefail
xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, re, sys
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devices in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        name = d["name"]
        if not name.startswith("iPhone"):
            continue
        plain = not re.search(r"Max|Plus|mini|SE|Air|e$", name)
        num = re.search(r"iPhone (\d+)", name)
        key = (version, plain, int(num.group(1)) if num else 0, " Pro" not in name)
        if best is None or key > best[0]:
            best = (key, d["udid"], name, runtime)
if best is None:
    sys.exit("Nenhum simulador de iPhone disponível")
print(best[1])
sys.stderr.write(f"Simulador: {best[2]} ({best[3]})\n")
'
