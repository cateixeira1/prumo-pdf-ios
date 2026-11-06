"""
Gera PrumoPDF/Localization/<idioma>.lproj/Localizable.strings e InfoPlist.strings a partir de
scripts/locales/*.json. A chave é o texto em português; os catálogos são os mesmos do Prumo para Windows
(app/locales/*.json lá), mais os textos que só o iPhone tem. Rodar: python3 scripts/build_strings.py

- "{}" marca a parte variável (LF/LN no código, ver PrumoPDF/Core/Localization.swift).
- pt.lproj não tem traduções (a chave já é o texto), mas precisa existir para o iOS saber que o app tem
  português; sem ela, quem usa o iPhone em português veria o idioma de desenvolvimento (inglês).
- O que faltar num idioma aparece em inglês (a verificação tools/i18n_check.py falha se faltar algo).
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOC = ROOT / "scripts" / "locales"
OUT = ROOT / "PrumoPDF" / "Localization"
MAP = {"en": "en", "es": "es", "fr": "fr", "de": "de", "ja": "ja", "zh-CN": "zh-Hans", "zh-TW": "zh-Hant",
       "nb": "nb", "sv": "sv", "da": "da", "fi": "fi"}
HEADER = "/* Gerado por scripts/build_strings.py a partir de scripts/locales. Não editar à mão. */\n"


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write(lproj: str, name: str, pairs: dict) -> int:
    d = OUT / f"{lproj}.lproj"
    d.mkdir(parents=True, exist_ok=True)
    lines = [f'"{esc(k)}" = "{esc(v)}";' for k, v in sorted(pairs.items())]
    (d / name).write_text(HEADER + "\n".join(lines) + "\n", encoding="utf-8")
    return len(lines)


def main() -> None:
    en = json.loads((LOC / "en.json").read_text(encoding="utf-8"))
    plist = json.loads((LOC / "infoplist.json").read_text(encoding="utf-8"))
    for src, lproj in MAP.items():
        cat = json.loads((LOC / f"{src}.json").read_text(encoding="utf-8"))
        cat = {**en, **cat}
        n = write(lproj, "Localizable.strings", cat)
        write(lproj, "InfoPlist.strings", plist[lproj] if lproj in plist else plist[src])
        print(lproj, n)
    write("pt", "Localizable.strings", {"Prumo PDF": "Prumo PDF"})
    write("pt", "InfoPlist.strings", plist["pt"])
    old = OUT / "pt-BR.lproj"
    if old.exists():
        for f in old.iterdir():
            f.unlink()
        old.rmdir()


if __name__ == "__main__":
    main()
