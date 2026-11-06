"""
Confere, fora do simulador, os PDFs que os testes de compressão do iPhone gravaram (PrumoPDFTests/CompressTests):
o arquivo é regravado por inteiro pelo próprio app (fluxos de objetos e tabela xref em fluxo), então aqui o
qpdf (pelo pikepdf) confere a estrutura, as páginas abrem e as imagens têm o tamanho esperado.

    python scripts/verify_compressed.py <pasta>
"""
import sys
from pathlib import Path

import pikepdf

EXPECTED_WIDTH = {"scan-media.pdf": (1200, 1280), "scan-alta.pdf": (760, 830)}


def main(folder: str) -> int:
    files = sorted(Path(folder).glob("*.pdf"))
    if not files:
        print("ERRO: nenhum PDF comprimido encontrado")
        return 1
    bad = 0
    sizes = {}
    for f in files:
        sizes[f.name] = f.stat().st_size
        try:
            with pikepdf.open(f) as pdf:
                problems = pdf.check_pdf_syntax()
                n = len(pdf.pages)
                for p in pdf.pages:            # o conteúdo de cada página precisa ser lido
                    pikepdf.parse_content_stream(p)
                widths = []
                masks = {o.SMask.objgen for o in pdf.objects
                         if isinstance(o, pikepdf.Stream) and "/SMask" in o}
                for o in pdf.objects:
                    if isinstance(o, pikepdf.Stream) and o.get("/Subtype") == "/Image" and o.objgen not in masks:
                        pikepdf.PdfImage(o).as_pil_image()      # a imagem decodifica
                        widths.append(int(o.Width))
            status = "OK"
            if problems:
                status = "PROBLEMAS: " + "; ".join(problems[:5])
                bad += 1
            lo_hi = EXPECTED_WIDTH.get(f.name)
            if lo_hi and not all(lo_hi[0] <= w <= lo_hi[1] for w in widths if w > 100):
                status = f"LARGURA ERRADA {widths}"
                bad += 1
            print(f"{f.name}: {status} ({n} páginas, {f.stat().st_size} bytes, imagens {widths})")
        except Exception as exc:  # noqa: BLE001
            print(f"{f.name}: ERRO {exc}")
            bad += 1
    if "scan-original.pdf" in sizes:
        o = sizes["scan-original.pdf"]
        for k in ("scan-media.pdf", "scan-alta.pdf"):
            if k in sizes:
                print(f"{k}: {round(100 * (1 - sizes[k] / o))}% menor que o original")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
