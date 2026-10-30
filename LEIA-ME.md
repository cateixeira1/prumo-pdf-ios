# Prumo PDF para iPhone

Aplicativo de PDF que roda inteiramente no iPhone, sem servidor e sem custo por uso.

- **Escanear** com a câmera (o scanner da própria Apple, que detecta as bordas e corrige a perspectiva). Ao terminar, o app pergunta **“Usar OCR agora?”** com **Sim** e **Mais tarde**.
- **OCR em português** (reconhecimento de texto da Apple, no próprio aparelho). Gera um PDF novo com “- OCR” no nome. Páginas que já têm texto digital ficam intactas, e as páginas com baixa confiança são marcadas para revisão.
- **Incluir páginas** escaneando, de outro PDF da biblioteca ou do app Arquivos: dá para escolher páginas individuais, trechos como `5-15` e `10-fim`, ou todas.
- **Organizar páginas**: segure uma página, arraste e solte. A tela rola sozinha perto das bordas, e a pinça muda o tamanho das miniaturas. Também dá para girar e excluir páginas. Tocar numa página abre ela grande, em tela cheia (com zoom), na ordem e com o giro ainda não salvos.
- **Leitor com barra embaixo, no estilo do app Notas**: miniaturas das páginas na lateral esquerda (mostrar ou esconder), marca-texto, busca, resumo, ferramentas (todas as funções do app) e compartilhar.
- **Destacar**: com o marca-texto ligado, escolha a cor e passe o dedo sobre o texto (dois dedos rolam a página). O destaque fica gravado no próprio PDF, como anotação padrão, e aparece no Prumo para Windows, no Adobe, no Edge e no Chrome. Tocar num destaque apaga ou muda a cor.
- **Barrinha da seleção**: ao selecionar um trecho (toque e segure), aparece uma barra como a do Word: **Copiar**, **Destacar** (abre todas as cores; escolher uma destaca e fecha tudo), **Tirar** o destaque (só aparece se parte do trecho já estiver destacada) e **Resumo**.
- **Desfazer e refazer**: o círculo com a seta para a esquerda, no canto de baixo das páginas, desfaz destaques, troca de cor, trechos levados ao resumo e o corte ou a numeração feitos pelo leitor. Depois de desfazer, aparece logo acima o círculo de **refazer**, que some quando não há mais o que refazer. O número da página fica no canto de cima, à direita (toque para ir a outra página).
- **Resumo**: com um trecho selecionado, “Ao resumo” leva o texto para “Nome - resumo.pdf”, na mesma pasta, com “Trecho extraído da página 10” (ou “das páginas 10-11”) embaixo, em letra menor. Cada trecho novo entra no fim do mesmo resumo (o mesmo formato do Windows).
- **Cortar e girar páginas**: moldura arrastável sobre a página inteira (ou margens em milímetros, ou “Margens automáticas”), giro de 90° ou 180°, para esta página, todas, pares, ímpares ou um trecho. O corte é o recorte padrão do PDF: “Página inteira” mostra tudo de novo.
- **Numerar páginas**: seis posições, formatos “1”, “Página 1”, “Página 1 de 12”, “1/12” e “- 1 -”, número inicial e a partir de qual página.
- **Selecionar vários deslizando o dedo**: no modo Selecionar, encoste num cartão (ou página) e deslize para o lado; continuando para cima ou para baixo, todos os itens no caminho são marcados, como no app Fotos.
- **Remover**, **extrair**, **combinar** e **dividir em partes iguais**. Na divisão, o app pergunta em quantas partes. Um PDF de 200 páginas em 4 partes vira “Nome - Parte 1” a “Parte 4”, com 50 páginas cada. Se a conta não fechar, as primeiras partes ficam com uma página a mais.
- **Modo leitor**: em PDFs com OCR, “Ler” pergunta se você quer ver o documento como foi escaneado ou só o texto, em fundo branco, como uma nota. Dentro da leitura, o botão Original/Texto alterna entre os dois na mesma página. No modo leitor dá para aumentar a letra, escolher fonte e fundo (branco, sépia ou escuro), buscar, copiar e compartilhar o texto, com as mesmas funções do modo Original: miniaturas, marca-texto, barrinha da seleção, desfazer e refazer, resumo e ferramentas. Os destaques feitos no texto vão para o PDF e aparecem também no modo Original (e vice-versa). Páginas com baixa confiança no OCR aparecem marcadas.
- **Segurança**: em Ajustes, “Pedir Face ID para abrir” bloqueia o app ao sair e pede Face ID (ou o código do iPhone) ao voltar; a tela de bloqueio mostra o logo do Prumo acima do cadeado. Na tela do PDF, **Proteger com senha** cria uma cópia que só abre com a senha (letras, números e símbolos, com “Mostrar a senha” e a força da senha), em qualquer leitor de PDF (o iPhone grava com AES-128, a criptografia padrão de PDF que o sistema da Apple oferece; a versão para Windows usa AES-256); **Remover senha** cria uma cópia sem senha (sabendo a senha). PDFs com senha aparecem com um cadeado e pedem a senha ao abrir. Se a senha de um PDF for esquecida, não há como recuperar.
- **Corrigir páginas curvas**: fotos de livros e revistas (curvatura perto da lombada) e de papel ondulado ficam com o texto reto, o que também melhora o OCR. Na tela do PDF, “Corrigir páginas curvas” mostra o antes e o depois e cria uma cópia “- corrigido”. Em Ajustes, dá para corrigir automaticamente ao escanear e ao converter fotos. Usa o modelo UVDoc (licença MIT), no próprio iPhone.
- **Converter em PDF**: fotos da galeria e imagens (JPG, PNG, HEIC, TIFF), Word, Excel, PowerPoint, Pages, Numbers, Keynote, RTF, texto e HTML, tudo no próprio iPhone. Várias fotos podem virar um PDF só (uma por página A4) ou um PDF para cada; depois o app pergunta se quer fazer o OCR. O botão Importar e “Adicionar PDFs” também aceitam esses arquivos e convertem na hora.
- **Tela inicial com todas as ferramentas** (Ler, Fazer OCR, Organizar, Incluir, Remover e Extrair páginas, Dividir, Combinar). Cada uma pergunta qual PDF usar: um arquivo do app Arquivos ou um que já está no Prumo, filtrando por aba ou pasta.
- **Estrela e três pontos** em cada PDF: a estrela vazia, ao ser tocada, fica preenchida e manda o PDF para Favoritos; os três pontos ⋮, no canto inferior direito, abrem as opções (sem precisar segurar o dedo).
- **Pastas**: ao criar uma, o app abre a pasta e oferece **Adicionar PDFs**, do app Arquivos ou de qualquer parte do Prumo (outra pasta, Todos os PDFs, Favoritos…), movendo ou copiando. Busca pelo nome e pelo texto dos PDFs.
- **Compartilhar** por e-mail, WhatsApp, Arquivos ou AirDrop.
- **Desfazer** a última alteração de páginas de cada PDF.
- **Assinatura digital (PAdES)** com certificado **A1** (arquivo .pfx ou .p12): em Ajustes › Assinatura digital, ou na própria tela de assinar, escolha o arquivo e digite a senha uma vez. O certificado vai para as Chaves do iPhone, só neste aparelho (não vai para o iCloud nem para backups), e a senha não fica gravada; cada assinatura pede o Face ID ou o código. Na tela do PDF, **Assinar digitalmente** grava a assinatura, com carimbo na página (primeira ou última, em um dos cantos) ou invisível. **Depois de assinado, o PDF não pode mais ser alterado**: qualquer mudança (destaque, corte, numeração, páginas) invalida a assinatura. Por isso o Prumo assina uma cópia, “Nome - assinado”, e deixa o original como está; na cópia, as ferramentas de edição ficam desligadas e o cartão mostra “Assinado”. Outra pessoa pode assinar a mesma cópia: a nova assinatura entra no próprio arquivo e as anteriores continuam válidas. A primeira assinatura é de certificação (DocMDP) e você escolhe o **nível de proteção**: **1** (nenhuma mudança, e ninguém mais assina), **2** (novas assinaturas e preenchimento de campos; é o padrão) ou **3** (também comentários e anotações). O padrão fica em Ajustes › Proteção do PDF assinado, com a explicação de cada nível, e dá para trocar na hora de assinar; PDF com mais de um campo de assinatura usa o nível 2 automaticamente e o Prumo confirma antes de assinar. Nenhum nível impede que outro programa grave uma alteração: a assinatura deixa de valer (ou é marcada como alterada) e leitores como o Adobe Acrobat avisam. As assinaturas seguintes travam o próprio campo (FieldMDP): é o controle de mudanças que o Verificador de Conformidade do ITI (validar.iti.gov.br) exige para dar o resultado, e o Adobe Reader mostra quem certificou e quem assinou. Certificado A3 (token ou cartão) funciona no Prumo para Windows.

Os arquivos ficam no app Arquivos, em **No meu iPhone › Prumo PDF**. Em Ajustes (ícone de engrenagem) você escolhe se os PDFs entram no backup do iCloud. Por padrão, entram.

**Cópia de segurança na nuvem que você escolher:** em Ajustes, “Salvar uma cópia em…” grava a biblioteca inteira (PDFs, pastas e favoritos) como uma pasta comum onde você quiser: iCloud Drive, Google Drive, OneDrive, pendrive. “Restaurar…” traz os PDFs de volta sem duplicar. A cópia usa o mesmo formato da versão para Windows: dá para fazer a cópia num aparelho e restaurar no outro.

## Como instalar no iPhone (pelo Windows, sem Mac)

O app é compilado automaticamente no GitHub a cada mudança. O arquivo pronto fica na página **Releases** deste repositório (“Prumo PDF para iPhone (última versão)”), com o nome `PrumoPDF.ipa`.

1. No PC, instale o **iTunes baixado do site da Apple**. A versão da Microsoft Store não funciona com o Sideloadly.
2. Instale o **Sideloadly** (sideloadly.io).
3. Ligue o iPhone no PC pelo cabo e toque em **Confiar** no iPhone.
4. Abra o Sideloadly, arraste o `PrumoPDF.ipa` para ele, informe seu **Apple ID** e clique em **Start**. Use um Apple ID que já tenha sido usado em algum iPhone ou iPad; um Apple ID novo não funciona.
5. No iPhone:
   - Vá em **Ajustes › Privacidade e Segurança › Modo de Desenvolvedor**, ative e reinicie quando o iPhone pedir. Isso é necessário a partir do iOS 16.
   - Se o app avisar que o desenvolvedor não é confiável, vá em **Ajustes › Geral › VPN e Gerenciamento de Dispositivos**, toque no seu Apple ID e em **Confiar**.

**Validade:** com Apple ID gratuito, o app para de abrir depois de 7 dias. Para renovar, repita o passo 4 com o mesmo `.ipa`. **Não apague o app antes**, senão os PDFs guardados nele se perdem. Os PDFs continuam no aparelho enquanto o app estiver instalado. Com uma conta paga do Apple Developer Program (US$ 99 por ano), esse limite deixa de existir.

## Estrutura do código

```
PrumoPDF/Core   PDF (inserir, remover, organizar, dividir), OCR, scanner, biblioteca, assinatura digital (CMS e PAdES)
PrumoPDF/UI     telas em SwiftUI no estilo de cartões; organizar páginas em UIKit
PrumoPDF/App    navegação, fila do OCR, dados de demonstração para capturas de tela
PrumoPDFTests   testes automáticos (rodam no simulador a cada mudança)
project.yml     projeto do Xcode (gerado com XcodeGen)
.github         compilação, testes, capturas de tela e geração do .ipa
```

Requer iOS 17 ou mais novo (iPhone XS/XR em diante).
