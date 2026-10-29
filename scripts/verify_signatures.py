"""
Confere com o pyHanko (biblioteca independente) os PDFs assinados pelos testes do iPhone.

Cada assinatura precisa estar íntegra (o resumo do conteúdo bate), válida (a assinatura CMS confere com
o certificado), com o SubFilter PAdES e, nas assinaturas anteriores, com as mudanças posteriores
permitidas pelo DocMDP/FieldMDP. Os certificados de teste são autoassinados: cada um é usado como raiz
confiável só para esta conferência.

Uso: python verify_signatures.py PASTA
"""

import sys
from pathlib import Path

from pyhanko.pdf_utils.reader import PdfFileReader
from pyhanko.sign.validation import validate_pdf_signature
from pyhanko_certvalidator import ValidationContext


def main(folder: str) -> int:
    files = sorted(Path(folder).glob("*.pdf"))
    if not files:
        print("Nenhum PDF assinado encontrado.")
        return 1
    bad = 0
    for path in files:
        with open(path, "rb") as f:
            r = PdfFileReader(f, strict=False)
            sigs = r.embedded_signatures
            print(f"{path.name}: {len(sigs)} assinatura(s)")
            if not sigs:
                bad += 1
            for s in sigs:
                vc = ValidationContext(trust_roots=[s.signer_cert])
                st = validate_pdf_signature(s, vc)
                sub = s.sig_object.get("/SubFilter")
                ok = st.intact and st.valid and str(sub) == "/ETSI.CAdES.detached"
                if st.modification_level is not None and st.docmdp_ok is False:
                    ok = False
                cn = s.signer_cert.subject.native.get("common_name")
                print(f"  - {s.field_name}: {cn} | íntegra={st.intact} válida={st.valid} confiável={st.trusted} "
                      f"subfilter={sub} docmdp_ok={st.docmdp_ok} cobertura={st.coverage} "
                      f"mudanças={st.modification_level} -> {'OK' if ok else 'FALHOU'}")
                if not ok:
                    print(st.pretty_print_details())
                    bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
