"""
Textos da interface que precisam de tradução: lê o código Swift de PrumoPDF/ e lista os textos em
português que aparecem para o usuário. Usado pela verificação do GitHub (tools/i18n_check.py) e para manter
os catálogos scripts/locales/<idioma>.json.

Regras:
- Entra todo texto entre aspas que parece frase ou rótulo (tem espaço e letras minúsculas, ou é uma palavra
  com inicial maiúscula, ou tem acento).
- Interpolação "\\(x)" vira {} ("Página {} de {}"): no código, frases com parte variável usam LF("...", x).
- Ficam de fora: comentários, textos depois de Image(systemName:, systemImage:, forKey:, ... (ver NON_UI) e o
  que estiver em tools/i18n_ignore.txt (um por linha).
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "PrumoPDF"
LOCALES = ROOT / "scripts" / "locales"
IGNORE_FILE = Path(__file__).resolve().parent / "i18n_ignore.txt"
SKIP_FILES = {"DemoSeeder.swift", "DemoCertificate.swift", "Localization.swift"}
# o texto logo depois disto não é da interface
NON_UI = re.compile(r"(systemName:|systemImage:|forKey:|forResource:|withExtension:|ofType:|named:|"
                    r"appendingPathComponent\(|appending\(path:|UserDefaults[^\n]*\(|@AppStorage\(|identifier:|"
                    r"Logger\(|print\(|NSPredicate\(format:|NSRegularExpression\(pattern:|"
                    r"fileExtension|pathExtension ==|hasSuffix\(|hasPrefix\(|contentType|UTType\(|"
                    r"\.font\(\.custom\(|accessibilityIdentifier\(|range\(of:|components\(separatedBy:|"
                    r"replacingOccurrences\(of:|with:|split\(separator:|CodingKeys|case \w+ = |"
                    r"PDFAnnotationKey|forAnnotationKey:|key:|setValue\(|value\(forKey|Notification\.Name\(|"
                    r"\.id\(|Sym\(|symbol:|icon:)\s*$")
# Textos usados de forma indireta (chaves montadas em outro lugar), que também precisam de tradução.
EXTRA = ["{} - resumo", "{} - assinado", "{} - protegido", "{} - comprimido", "fim"]


def literals(text: str):
    """(linha, texto com {} no lugar de cada "\\(...)", começo da linha até o texto, início, fim)"""
    i, n, line = 0, len(text), 1
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i)
            line += text[i:j].count("\n")
            i = n if j < 0 else j + 2
        elif c == '"':
            multi = text.startswith('"""', i)
            start_line, start = line, i
            i += 3 if multi else 1
            out, depth = [], 0
            while i < n:
                if text[i] == "\\" and i + 1 < n:
                    if text[i + 1] == "(":
                        # interpolação: pular até o ")" correspondente (pode ter aspas dentro)
                        depth, j = 1, i + 2
                        while j < n and depth:
                            if text[j] == "(":
                                depth += 1
                            elif text[j] == ")":
                                depth -= 1
                            elif text[j] == '"':
                                k = j + 1
                                while k < n and text[k] != '"':
                                    k += 2 if text[k] == "\\" else 1
                                j = k
                            j += 1
                        out.append("{}")
                        i = j
                        continue
                    esc = text[i + 1]
                    out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(esc, esc))
                    i += 2
                    continue
                if multi and text.startswith('"""', i):
                    i += 3
                    break
                if not multi and text[i] == '"':
                    i += 1
                    break
                if text[i] == "\n":
                    line += 1
                out.append(text[i])
                i += 1
            yield start_line, "".join(out), text[text.rfind("\n", 0, start) + 1:start], start, i
        else:
            i += 1


def looks_ui(s: str) -> bool:
    t = s.strip()
    if len(t) < 2 or not re.search(r"[^\W\d_]{2}", t):
        return False
    if t.startswith(("<", "#", "%", "http", "(?", "^", "*.", "--", "/", "com.", "group.", "public.")):
        return False
    if re.search(r"\\[dswbSWD]|\(\?|\[\^", t):
        return False
    if re.fullmatch(r"[A-Za-z0-9_.\-/\\:+*$]+", t):
        return bool(re.fullmatch(r"[A-ZÀ-Ý][a-zà-ÿ]{2,}[.…]?", t))
    if re.search(r"[À-ÿ]", t):
        return True
    if re.search(r"[A-Z]{3,}", t) and re.search(r"[ ·]", t) and not re.search(r"[A-Z]{2,}[a-z]", t):
        return True                                                         # " · VENCIDO"
    if re.fullmatch(r"\([a-zà-ÿ]{3,}\)", t):                               # " (vencido)"
        return True
    return bool(re.search(r"[a-z]{2,}", t)) and (" " in t or t[:1].isupper() or "{}" in t)


# O SwiftUI traduz sozinho o texto fixo (sem "\(...)") passado como primeiro argumento destes.
AUTO_CALLS = {"Text", "Button", "Label", "Toggle", "TextField", "SecureField", "Section", "Picker", "Menu",
              "navigationTitle", "alert", "confirmationDialog", "Link", "accessibilityLabel", "accessibilityHint",
              "help", "ProgressView", "ContentUnavailableView", "LabeledContent", "DisclosureGroup", "Stepper",
              "ShareLink", "Tab", "ControlGroup"}
WRAP_CALLS = {"L", "LF", "LN", "LD", "LDF"}


def enclosing(text: str, start: int, end: int):
    """(nome da chamada que contém o texto, rótulo do argumento, o texto é o argumento inteiro)"""
    depth, i = 0, start - 1
    while i >= 0:
        c = text[i]
        if c in ")]}":
            depth += 1
        elif c in "([{":
            if depth == 0:
                break
            depth -= 1
        i -= 1
    name = ""
    if i >= 0 and text[i] == "(":
        m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", text[:i])
        name = m.group(1) if m else ""
    head = text[i + 1:start] if i >= 0 else ""
    seg = head.rsplit(",", 1)[-1]              # o que vem logo antes, depois da última vírgula
    lab = re.match(r"\s*([A-Za-z_]\w*)\s*:\s*$", seg)
    label = lab.group(1) if lab else ("" if not seg.strip() else None)
    after = text[end:end + 40].lstrip()
    whole = label is not None and (after[:1] in (",", ")") or after.startswith(("{", "\n")))
    return name, label, whole


def classify(path: Path):
    """[(linha, texto, situação)]: 'L' (passa por L/LF/LN/LD ou tem "// i18n" na linha), 'auto' (o SwiftUI
    traduz sozinho) ou 'raw' (texto da interface sem tradução: erro)."""
    text = path.read_text(encoding="utf-8")
    out = []
    for line, s, before, start, end in literals(text):
        name, label, whole = enclosing(text, start, end)
        line_end = text.find("\n", end)
        if name in WRAP_CALLS or "// i18n" in text[end:line_end if line_end >= 0 else len(text)]:
            kind = "L"
        elif NON_UI.search(before) or not looks_ui(s) or not re.search(r"[^\W\d_]", s):
            continue
        elif name in AUTO_CALLS and label == "" and whole and "{}" not in s:
            kind = "auto"
        else:
            kind = "raw"
        out.append((line, s, kind))
    return out


def extract() -> dict[str, list[str]]:
    """{texto: [arquivo:linha, ...]} de todos os textos da interface (os que passam por L/LF/LN/LD e os
    que o SwiftUI traduz sozinho)."""
    found: dict[str, list[str]] = {}
    ignore = load_ignore()
    for path in sorted(SRC.rglob("*.swift")):
        if path.name in SKIP_FILES:
            continue
        for line, s, kind in classify(path):
            if kind == "raw" or s in ignore or not s.strip():
                continue
            found.setdefault(s, []).append(f"{path.relative_to(ROOT)}:{line}")
    for s in EXTRA:
        found.setdefault(s, []).append("tools/i18n_strings.py:EXTRA")
    return found


def unlocalized() -> list[str]:
    """Textos da interface escritos no código sem passar pela tradução (devem ficar vazios)."""
    out = []
    ignore = load_ignore()
    for path in sorted(SRC.rglob("*.swift")):
        if path.name in SKIP_FILES:
            continue
        for line, s, kind in classify(path):
            if kind == "raw" and s not in ignore:
                out.append(f"{path.relative_to(ROOT)}:{line}: {s!r}")
    return out


def load_ignore() -> set[str]:
    if not IGNORE_FILE.exists():
        return set()
    # "\\n" no arquivo é uma quebra de linha no texto
    return {ln.rstrip("\n").replace("\\n", "\n") for ln in IGNORE_FILE.read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.startswith("# ")}


def main() -> int:
    strings = extract()
    print(len(strings), "textos")
    if "--raw" in sys.argv:
        bad = unlocalized()
        print("\n".join(bad))
        print(len(bad), "sem tradução no código")
    if "--list" in sys.argv:
        for k, v in sorted(strings.items(), key=lambda kv: kv[1][0]):
            print(repr(k), v[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
