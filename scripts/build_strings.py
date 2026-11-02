"""
Gera PrumoPDF/Localization/<idioma>.lproj/Localizable.strings a partir de scripts/locales/*.json
(as mesmas traduções do Prumo para Windows; a chave é o texto em português). Rodar: python3 scripts/build_strings.py
Textos com parte variável ({} ou %) ficam de fora: no iOS, as interpolações são tratadas à parte.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAP = {"en": "en", "es": "es", "fr": "fr", "de": "de", "ja": "ja", "zh-CN": "zh-Hans", "zh-TW": "zh-Hant",
       "nb": "nb", "se": "se", "sv": "sv", "da": "da", "fi": "fi"}


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


for src, lproj in MAP.items():
    cat = json.loads((ROOT / "scripts" / "locales" / f"{src}.json").read_text(encoding="utf-8"))
    if src != "en":   # o que falta num idioma aparece em inglês, não em português
        en = json.loads((ROOT / "scripts" / "locales" / "en.json").read_text(encoding="utf-8"))
        cat = {**en, **cat}
    lines = [f'"{esc(k)}" = "{esc(v)}";' for k, v in sorted(cat.items()) if "{" not in k and "%" not in k]
    out = ROOT / "PrumoPDF" / "Localization" / f"{lproj}.lproj"
    out.mkdir(parents=True, exist_ok=True)
    (out / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(lproj, len(lines))
