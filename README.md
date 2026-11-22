# iPDFmini

[![CI](https://github.com/LkHideki/ipdfmini/actions/workflows/ci.yml/badge.svg)](https://github.com/LkHideki/ipdfmini/actions/workflows/ci.yml)

App de Mac que adapta PDFs para ler no iPad mini 7. Ele corta as margens, escolhe uma escala que deixa a letra num tamanho legível na tela de 8,3" e mantém sumário, links e anotações funcionando.

Você arrasta um PDF ou uma pasta inteira, confere o resultado numa prévia com a moldura do iPad e manda para o iPad por AirDrop. O arquivo original nunca é alterado.

## Como funciona

Para cada documento, o app mede o corpo do texto e testa algumas estratégias: recortar as margens, recortar também cabeçalho e rodapé, ou dividir a página em fatias ou colunas. Ele fica com a que altera menos o documento e ainda deixa o texto acima do tamanho mínimo. Você pode trocar a escolha no inspetor.

Por padrão cada página do original vira uma página no iPad. Dividir páginas é opcional.

Toda saída passa por uma validação antes de ser entregue: nada de texto cortado, escala igual entre páginas do mesmo tipo, sumário e links apontando para as páginas certas.

## Requisitos

- macOS 26 ou mais recente, Apple Silicon
- Swift 6.2 (as Command Line Tools bastam; o Xcode não é necessário)

## Instalar

```sh
scripts/build-app.sh
```

Compila e instala o app em `~/Applications/iPDFmini.app`. Para só montar o bundle, sem instalar, use `--no-install`.

## Linha de comando

O mesmo motor está disponível como CLI:

```sh
swift build -c release
.build/release/ipdfmini convert livro.pdf -o livro-mini.pdf
.build/release/ipdfmini plan livro.pdf   # mostra os candidatos sem gravar
```

## Testes

```sh
scripts/test.sh
```

O script existe porque as Command Line Tools não acham sozinhas o plugin do Swift Testing. Os testes geram os próprios PDFs, com a geometria conhecida, e não precisam de arquivos externos.

## Contribuindo

Bugs, PDFs que saem mal adaptados e pull requests são bem-vindos; veja [CONTRIBUTING.md](CONTRIBUTING.md).

## Licença

Apache 2.0, ver [LICENSE](LICENSE). O projeto inclui o qpdf e a libjpeg-turbo, cada um com a sua licença; os créditos estão em [NOTICE](NOTICE).
