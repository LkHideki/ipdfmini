# Contribuindo

Obrigado pelo interesse. Relatos de bug, PDFs que saem mal adaptados e pull requests são bem-vindos.

## Antes de abrir uma issue

Se um PDF sai mal adaptado, diga qual estratégia o app escolheu (aparece no inspetor), a versão do macOS e, se puder, mande um PDF de exemplo que reproduza o problema. Não anexe documentos com dados pessoais ou protegidos por direito autoral; um trecho recriado ou uma página de teste costuma bastar.

Falhas de segurança não vão em issue pública: veja [SECURITY.md](SECURITY.md).

## Ambiente

- macOS 26 ou mais recente, Apple Silicon
- Swift 6.2 (Xcode 26 ou só as Command Line Tools)

```sh
swift build
scripts/test.sh          # suíte completa
scripts/build-app.sh     # monta e instala o app em ~/Applications
```

Com o Xcode selecionado, `swift test` também funciona; o `scripts/test.sh` existe para quem tem só as Command Line Tools.

## Organização do código

| Módulo | Papel |
|---|---|
| `MiniGeometry` | Medidas do iPad mini 7, perfis de leitor e modelo de legibilidade |
| `PDFAnalysis` | Lê o PDF: caixas, tinta, linhas de texto, colunas e blocos |
| `LayoutEngine` | Estratégias de recorte e fatiamento e o motor de decisão |
| `PDFWriting` | Grava a saída (PDFKit para recorte, qpdf para colocações) e leva links e sumário junto |
| `MiniKit` | Junta tudo e valida cada saída |
| `AppCore`, `iPDFminiApp` | O app SwiftUI; a análise roda num processo filho (a CLI embutida) |
| `ipdfmini-cli` | A CLI `ipdfmini` |
| `SyntheticCorpus` | Gera os PDFs de teste com a geometria conhecida |
| `Vendor/` | qpdf e libjpeg-turbo, compilados pelo SwiftPM; ver `Vendor/README.md` |

## Pull requests

- Um assunto por PR, com teste quando a mudança tem comportamento verificável.
- A suíte precisa passar; o CI roda em `macos-26`.
- Comentários e mensagens da interface estão em português; mensagens de commit, em inglês.
- Ao mexer em `Vendor/`, siga o roteiro de atualização de `Vendor/README.md` e mantenha os avisos de licença.

Ao contribuir, você concorda que sua contribuição seja licenciada sob a [Apache 2.0](LICENSE), como o resto do projeto.
