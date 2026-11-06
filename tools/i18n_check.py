"""
Verificação das traduções (roda no GitHub antes de compilar; também dá para rodar em qualquer computador
com Python 3: python3 tools/i18n_check.py). Falha se:
1. algum texto da interface no código Swift não passa pela tradução (L/LF/LN/LD, ou posição em que o
   SwiftUI traduz sozinho) e não está em tools/i18n_ignore.txt;
2. algum texto da interface não tem tradução em algum dos 11 idiomas (scripts/locales/<idioma>.json);
3. alguma tradução tem um número de "{}" diferente do texto em português;
4. os arquivos Localizable.strings/InfoPlist.strings não foram gerados de novo (scripts/build_strings.py).
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import i18n_strings  # noqa: E402

LANGS = ["en", "es", "fr", "de", "ja", "zh-CN", "zh-TW", "nb", "sv", "da", "fi"]


def main() -> int:
    problems = []
    raw = i18n_strings.unlocalized()
    problems += [f"sem tradução no código: {r}" for r in raw]
    strings = i18n_strings.extract()
    for lang in LANGS:
        cat = json.loads((ROOT / "scripts" / "locales" / f"{lang}.json").read_text(encoding="utf-8"))
        for s, where in sorted(strings.items()):
            if s not in cat:
                problems.append(f"{lang}: falta tradução de {s!r} ({where[0]})")
        for k, v in cat.items():
            if k.count("{}") != v.count("{}"):
                problems.append(f"{lang}: {k!r} → {v!r} tem número diferente de {{}}")
    # os .strings precisam estar em dia com os catálogos
    before = {p: p.read_bytes() for p in (ROOT / "PrumoPDF" / "Localization").rglob("*.strings")}
    subprocess.run([sys.executable, str(ROOT / "scripts" / "build_strings.py")], check=True,
                   stdout=subprocess.DEVNULL)
    after = {p: p.read_bytes() for p in (ROOT / "PrumoPDF" / "Localization").rglob("*.strings")}
    for p in sorted(set(before) | set(after)):
        if before.get(p) != after.get(p):
            problems.append(f"{p.relative_to(ROOT)} estava desatualizado: rode python3 scripts/build_strings.py")
    print(f"{len(strings)} textos da interface, {len(LANGS)} idiomas")
    for p in problems:
        print("ERRO:", p)
    print("OK" if not problems else f"{len(problems)} problema(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
