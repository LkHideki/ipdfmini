# Vendor

Código de terceiros compilado pelo SwiftPM (só Command Line Tools; sem cmake, sem brew no build).
Os targets moram aqui mesmo: `CJPEG` em `libjpeg-turbo/`, `CQPDF` em `qpdf/` (ver `Package.swift`).

## qpdf 12.4.2

- Origem: https://github.com/qpdf/qpdf/releases/download/v12.4.2/qpdf-12.4.2.tar.gz
- SHA-256 do tarball: `8a58af5b6141319287c1883bec8bd1bd545b7567b7fc5e6ce5d25a1c85f36397`
- Licença: Apache 2.0 (`LICENSE.txt`; `Artistic-2.0` e `NOTICE.md` acompanham o upstream).
- Copiado, com os caminhos do upstream:
  - `libqpdf/*.cc|c`: a lista `libqpdf_SOURCES` de `libqpdf/CMakeLists.txt` mais o crypto nativo
    (`AES_PDF_native`, `MD5_native`, `QPDFCrypto_native`, `RC4_native`, `SHA2_native`, `rijndael`,
    `sha2`, `sha2big`), **menos** `QPDFJob*`, `QPDFArgParser`, `qpdf-c`, `qpdfjob-c` e `qpdflogger-c`
    (CLI e API C do qpdf, sem uso aqui). `QPDFUsage.cc` fica porque o `QPDFWriter` o referencia.
  - `libqpdf/qpdf/*.hh|h` (headers privados, sem os de job/CLI e de crypto OpenSSL/GnuTLS) e
    `libqpdf/sph/` (`md_helper.c` é `#include`d por `sha2*.c`, não é compilado: está em `exclude`).
  - `include/qpdf/*` (headers públicos, sem `auto_job_*`, `QPDFJob.hh`, `qpdfjob-c.h`).
- **Nosso, não é upstream** (não sobrescrever ao atualizar):
  - `libqpdf/qpdf/qpdf-config.h`: equivalente escrito à mão do que o cmake gera
    (macOS arm64, crypto nativo, 11 defines).
  - `capi/ipm_qpdf.h` e `capi/module.modulemap`: API C pública (única superfície vista pelo Swift).
  - `ipm/ipm_qpdf.cc`: implementação C++ da API C; toda exceção vira código + mensagem.
- Não copiado: testes, docs, fuzz, exemplos, scripts, binários.
- Dependências do sistema: `libz` (SDK), via `linkerSettings`.

## libjpeg-turbo 3.2.1

- Origem: https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.1/libjpeg-turbo-3.2.1.tar.gz
- SHA-256 do tarball: `c27ad72a68da151177929aa969ae773a2da5ac2af9ce946079314fdac8cece7f`
- Licença: IJG + BSD-3-Clause + zlib (`LICENSE.md`, `README.ijg`). Obrigatório porque `Pl_DCT.hh`
  do qpdf inclui `jpeglib.h`.
- Copiado: as fontes de `JPEG_SOURCES` do `CMakeLists.txt` (mais `jaricom`, `jcarith`, `jdarith`),
  os `src/wrapper/*-8|12|16.c` correspondentes, os `.c` que esses wrappers incluem (`jccolext.c`,
  `jdcolext.c`, `jdcol565.c`, `jdmrgext.c`, `jdmrg565.c`, `jstdhuff.c` e os homônimos sem sufixo) e
  os headers internos. `jpeglib.h`, `jmorecfg.h` e `jerror.h` ficam em `include/` (públicos para o CQPDF).
  Sem SIMD, sem TurboJPEG, sem apps (`cjpeg`, `djpeg`, ...).
- **Gerados uma vez com cmake** (3.2.1, `WITH_SIMD=0`) e copiados: `include/jconfig.h`,
  `src/jconfigint.h`, `src/jversion.h`. O build nunca usa cmake.
- Os `.c` que só são incluídos por outros não aparecem em `sources:` do `Package.swift`
  (compilá-los direto duplicaria símbolos); por isso a lista do `CJPEG` é explícita.

## Como atualizar

1. Baixar o tarball novo, registrar o SHA-256 acima e extrair num diretório vazio.
2. qpdf: refazer a lista de fontes a partir de `libqpdf/CMakeLists.txt` (`libqpdf_SOURCES` +
   `libqpdf_crypto_native`), copiar `libqpdf/` e `include/qpdf/` com as mesmas exclusões, e
   conferir se algum `.cc`/`.hh` novo é necessário (o erro aparece como `file not found` ou
   símbolo indefinido no link do `swift build --build-tests`).
3. Revisar `qpdf-config.h` contra `libqpdf/qpdf/qpdf-config.h.in` do upstream (opções novas).
4. libjpeg-turbo: refazer a lista a partir de `JPEG_SOURCES` no `CMakeLists.txt`; para regerar os
   três headers de configuração, rodar o cmake (`~/.local/bin/cmake`) fora do repositório com
   `-DWITH_SIMD=0 -DENABLE_SHARED=0` e copiar `jconfig.h`, `jconfigint.h` e `jversion.h`.
5. Atualizar `sources:` de `CJPEG` e `exclude:` de `CQPDF` em `Package.swift`, rodar `./scripts/test.sh`.
