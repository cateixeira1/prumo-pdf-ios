"""
Confere, fora do simulador, os PDFs que PrumoPDFTests/FormTests gravou (preencher formulário, versão 1.15.0):

- preenchido.pdf: o campo "nome" tem o valor e a aparência (/AP); a caixa de marcar está ligada; as caixas do
  Prumo têm /NM "prumo-tx-"/"prumo-mk-", aparência própria e (aviso) o estilo em /PrumoStyle, que o Windows lê.
  No pdfium (o leitor do Prumo para Windows e do Chrome), cada caixa e cada marca aparece dentro do retângulo dela.
- finalizado.pdf: sem campos e sem caixas (tudo virou desenho da página), o destaque continua, e o que estava
  nas caixas continua visível no mesmo lugar.

    python scripts/verify_forms.py <pasta>
"""
import sys
from pathlib import Path

from pypdf import PdfReader


def annots(reader):
    out = []
    for i, page in enumerate(reader.pages):
        for ref in page.get("/Annots") or []:
            a = ref.get_object()
            out.append((i, a))
    return out


def dark_pixels(path, page_index, rect, page_height, scale=2.0):
    """Quantos pixels escuros ou coloridos há dentro de `rect` (coordenadas do PDF) desenhado pelo pdfium."""
    import pypdfium2 as pdfium
    pdf = pdfium.PdfDocument(str(path))
    try:
        pdf.init_forms()
        img = pdf[page_index].render(scale=scale, may_draw_forms=True).to_pil().convert("RGB")
    finally:
        pdf.close()
    l, b, r, t = rect
    box = (int(l * scale) - 1, int((page_height - t) * scale) - 1, int(r * scale) + 1, int((page_height - b) * scale) + 1)
    crop = img.crop(box)
    data = crop.tobytes()
    n = 0
    for k in range(0, len(data), 3):
        rr, gg, bb = data[k], data[k + 1], data[k + 2]
        if min(rr, gg, bb) < 140 or max(rr, gg, bb) - min(rr, gg, bb) > 80:
            n += 1
    return n


def main(folder: str) -> int:
    folder = Path(folder)
    filled, final = folder / "preenchido.pdf", folder / "finalizado.pdf"
    bad = 0
    if not filled.exists() or not final.exists():
        print("ERRO: os PDFs do teste de formulários não foram gravados")
        return 1
    r = PdfReader(filled, strict=True)
    fields = r.get_fields() or {}
    nome = fields.get("nome", {})
    aceito = fields.get("aceito", {})
    estado = fields.get("estado", {})
    print(f"campo nome: {nome.get('/V')!r}; aceito: {aceito.get('/V')!r}; estado: {estado.get('/V')!r}")
    if estado.get("/V") != "RJ":
        print("ERRO: o valor da lista suspensa 'estado' não foi gravado")
        bad += 1
    if nome.get("/V") != "Maria Ação":
        print("ERRO: o valor do campo 'nome' não foi gravado")
        bad += 1
    if str(aceito.get("/V", "/Off")) in ("/Off", "None"):
        print("ERRO: a caixa de marcar não ficou ligada")
        bad += 1
    try:
        import pypdfium2  # noqa: F401
        can_render = True
    except Exception as exc:  # noqa: BLE001
        print(f"AVISO: pypdfium2 indisponível ({exc}); o desenho não será conferido")
        can_render = False
    boxes = []
    for i, a in annots(r):
        sub = a.get("/Subtype")
        nm = str(a.get("/NM", "") or a.get("/PrumoID", ""))
        if sub == "/Widget":
            ap = a.get("/AP")
            print(f"  widget {a.get('/T') or (a.get('/Parent') or dict()).get('/T')}: aparência {'sim' if ap else 'NÃO'}")
            if not ap:
                bad += 1
        if nm.startswith(("prumo-tx-", "prumo-mk-")):
            rect = [float(v) for v in a["/Rect"]]
            style = a.get("/PrumoStyle")
            print(f"  caixa {nm} {sub} página {i + 1} rect {[round(v, 1) for v in rect]} "
                  f"AP={'sim' if a.get('/AP') else 'NÃO'} contents={a.get('/Contents')!r} "
                  f"PrumoStyle={'sim' if style else 'não'} DS={'sim' if a.get('/DS') else 'não'}")
            if not a.get("/AP"):
                print("ERRO: caixa sem aparência")
                bad += 1
            if not style:
                print("AVISO: /PrumoStyle não foi gravado pelo PDFKit (o Windows usa /DS ou /DA)")
            boxes.append((i, rect, nm))
    if len(boxes) != 4:
        print(f"ERRO: esperava 4 caixas, achou {len(boxes)}")
        bad += 1
    rf = PdfReader(final, strict=True)
    left = [(i, a.get("/Subtype")) for i, a in annots(rf)]
    print(f"finalizado: anotações {left}; AcroForm campos {len((rf.trailer['/Root'].get('/AcroForm') or {}).get('/Fields', []))}")
    if any(s == "/Widget" for _, s in left) or any(str(a.get("/NM", "") or a.get("/PrumoID", "")).startswith("prumo-") for _, a in annots(rf)):
        print("ERRO: o PDF finalizado ainda tem campos ou caixas editáveis")
        bad += 1
    if [s for _, s in left] != ["/Highlight"]:
        print("ERRO: o destaque devia continuar (e só ele) no PDF finalizado")
        bad += 1
    if can_render:
        h = float(r.pages[0].mediabox.height)
        for i, rect, nm in boxes:
            a = dark_pixels(filled, i, rect, h)
            b = dark_pixels(final, i, rect, h)
            ok = a > 8 and b > 8
            print(f"  desenho de {nm}: preenchido {a} px, finalizado {b} px {'OK' if ok else 'ERRO'}")
            bad += 0 if ok else 1
    print("OK" if not bad else f"{bad} problema(s)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
