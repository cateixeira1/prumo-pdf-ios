"""
Confere, fora do simulador, os PDFs que os testes de compressão do iPhone gravaram (PrumoPDFTests/CompressTests):
o arquivo é regravado por inteiro pelo próprio app (fluxos de objetos e tabela xref em fluxo), então aqui o
pypdf, em modo estrito, lê a estrutura, o conteúdo de cada página e decodifica as imagens.
(O pikepdf não tem pacote pronto para o Python 3.14 do macOS do GitHub; o pypdf é só Python.)

    python scripts/verify_compressed.py <pasta>
"""
import sys
from pathlib import Path

from pypdf import PdfReader

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
            r = PdfReader(f, strict=True)
            widths = []
            for p in r.pages:
                p.get_contents() and p.get_contents().get_data()     # o conteúdo da página decodifica
                for img in p.images:
                    widths.append(img.image.width)                    # a imagem decodifica
            status = "OK"
            lo_hi = EXPECTED_WIDTH.get(f.name)
            if lo_hi and not all(lo_hi[0] <= w <= lo_hi[1] for w in widths if w > 100):
                status = f"LARGURA ERRADA {widths}"
                bad += 1
            print(f"{f.name}: {status} ({len(r.pages)} páginas, {f.stat().st_size} bytes, imagens {widths})")
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
