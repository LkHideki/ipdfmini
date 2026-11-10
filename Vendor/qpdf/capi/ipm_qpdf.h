/*
 * API C mínima sobre o qpdf, base do PlacementWriter (PLAN §9.1).
 *
 * Por que C puro: o Swift 6.4 não importa a classe QPDF pela interop C++ e não converte
 * String <-> std::string; com C nenhum target Swift precisa de .interoperabilityMode(.Cxx).
 * Nenhuma exceção C++ atravessa esta fronteira: todas viram código de retorno + mensagem.
 *
 * Convenções
 *  - Retorno: 0 (IPM_OK) ou um código ipm_status. Toda função que pode falhar recebe
 *    `char* error, size_t error_capacity` (ambos opcionais); a mensagem é copiada, UTF-8,
 *    terminada em NUL e truncada à capacidade.
 *  - Índices começam em 0. "Páginas de origem" são as do arquivo aberto; "páginas de saída"
 *    são as criadas por ipm_add_page, na ordem de criação.
 *  - Retângulos: double[4] = llx, lly, urx, ury. Matrizes: double[6] = a b c d e f (PDF).
 *  - Um ipm_doc não é thread-safe; documentos distintos são independentes.
 *  - Espaço de origem = espaço de usuário bruto da página de origem (o dos content streams):
 *    /Rotate e /UserUnit NÃO são aplicados ao Form XObject. Quem posiciona compõe a rotação
 *    na matriz (ipm_source_page_info devolve /Rotate).
 */
#ifndef IPM_QPDF_H
#define IPM_QPDF_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ipm_doc ipm_doc;

typedef enum ipm_status {
    IPM_OK = 0,
    IPM_ERR_ARGUMENT = 1, /* ponteiro nulo, índice fora do intervalo, número não finito */
    IPM_ERR_IO = 2,       /* arquivo inexistente, ilegível ou não gravável */
    IPM_ERR_PASSWORD = 3, /* documento cifrado: senha ausente ou incorreta */
    IPM_ERR_DAMAGED = 4,  /* não é PDF ou estrutura irrecuperável */
    IPM_ERR_INTERNAL = 5  /* qualquer outra falha do qpdf */
} ipm_status;

/* Nome de recurso (sem a barra) da Helvetica registrada por ipm_append_content. */
#define IPM_HELVETICA_NAME "IPMHelv"

/* Abre um PDF. `password` pode ser NULL. Em sucesso, *out_doc é de propriedade do chamador. */
int ipm_open(const char* path, const char* password, ipm_doc** out_doc, char* error, size_t error_capacity);
/* Libera o documento; aceita NULL. */
void ipm_close(ipm_doc* doc);

int ipm_source_page_count(ipm_doc* doc, int* out_count, char* error, size_t error_capacity);
int ipm_output_page_count(ipm_doc* doc, int* out_count, char* error, size_t error_capacity);

/*
 * Caixas e rotação de uma página de origem. media: /MediaBox herdada; crop: /CropBox herdada
 * ou, se ausente, igual à media; rotate: /Rotate herdado, normalizado para 0, 90, 180 ou 270
 * (valor inválido vira 0). Retângulos normalizados (llx<urx, lly<ury).
 */
int ipm_source_page_info(ipm_doc* doc, int source_page, double* out_media /*[4]*/, double* out_crop /*[4]*/,
                         int* out_rotate, char* error, size_t error_capacity);

/* Cria uma página de saída vazia com a MediaBox dada, no fim do documento; devolve seu índice. */
int ipm_add_page(ipm_doc* doc, const double* media_box /*[4]*/, int* out_page, char* error, size_t error_capacity);

/*
 * Coloca a página de origem na página de saída:  q <matrix> cm <clip> re W n /FmN Do Q
 * `clip` está no espaço da página de origem; `matrix` leva origem -> saída. O Form XObject da
 * origem é criado uma única vez por documento (cache) e compartilhado entre colocações, de modo
 * que o content stream original é gravado uma só vez. O BBox do Form é a CropBox efetiva.
 * Colocações e conteúdo bruto são emitidos na ordem das chamadas.
 */
int ipm_place_page(ipm_doc* doc, int output_page, int source_page, const double* clip /*[4]*/,
                   const double* matrix /*[6]*/, char* error, size_t error_capacity);

/*
 * Acrescenta operadores PDF brutos ao fim do conteúdo da página de saída (overlays).
 * A fonte Helvetica padrão (Type1, WinAnsi, não embutida) fica disponível como /IPMHelv.
 */
int ipm_append_content(ipm_doc* doc, int output_page, const char* data, size_t length, char* error,
                       size_t error_capacity);

/*
 * Navegação e metadados (PlacementWriter, PLAN §9.2). Regravar pelo PDFKit achata os Form
 * XObjects (o Quartz reemite o conteúdo por colocação: até 3,3x o tamanho), por isso links,
 * sumário, anotações e Info são gravados aqui.
 *
 * Objetos em sintaxe PDF (`pdf`, `length`) são lidos com o documento como contexto: "N G R"
 * referencia objetos dele, como as páginas de saída (ipm_output_page_object).
 */

/* Número e geração do objeto da página de saída, para referências "N G R" em destinos. */
int ipm_output_page_object(ipm_doc* doc, int output_page, int* out_number, int* out_generation, char* error,
                           size_t error_capacity);

/* Acrescenta uma anotação (dicionário em sintaxe PDF) a /Annots da página de saída; /P é preenchido. */
int ipm_add_annotation(ipm_doc* doc, int output_page, const char* pdf, size_t length, char* error,
                       size_t error_capacity);

/*
 * Grava (`pdf` != NULL) ou remove (`pdf` == NULL) uma chave do catálogo, ex. "/PageLabels".
 * `subkey` != NULL atua dentro do dicionário em `key` (ex. "/Names", "/Dests"); remover de um
 * dicionário ausente não é erro.
 */
int ipm_set_catalog_entry(ipm_doc* doc, const char* key, const char* subkey, const char* pdf, size_t length,
                          char* error, size_t error_capacity);

/* Grava (UTF-8) ou remove (`value` == NULL) uma chave do dicionário Info, criando-o se preciso. */
int ipm_set_info_entry(ipm_doc* doc, const char* key, const char* value, char* error, size_t error_capacity);

/*
 * Substitui o sumário. Item i: título UTF-8 `titles[i]`, pai `parents[i]` (-1 = raiz; o pai vem
 * antes do filho), destino `destinations[i]` em sintaxe PDF (ex. "[12 0 R /XYZ 10 700 null]")
 * ou NULL, aberto se `open[i]` != 0. Filhos na ordem do vetor. count == 0 remove o sumário.
 */
int ipm_set_outline(ipm_doc* doc, int count, const char* const* titles, const int* parents,
                    const char* const* destinations, const int* open, char* error, size_t error_capacity);

/*
 * Escritor por caixas: grava `box` (espaço do usuário da página, sem /Rotate) como MediaBox,
 * CropBox, TrimBox, BleedBox e ArtBox da página de origem, sem tocar no content stream. Com
 * `clip` != NULL, envolve o conteúdo em "q clip re W n … Q": o que estava fora da área visível
 * original (sangria) continua invisível mesmo com a caixa maior que a página.
 */
int ipm_set_source_page_boxes(ipm_doc* doc, int source_page, const double* box /*[4]*/, const double* clip /*[4]*/,
                              char* error, size_t error_capacity);

/* Remove uma página de origem da árvore de páginas (índice da abertura; os demais não mudam). */
int ipm_remove_source_page(ipm_doc* doc, int source_page, char* error, size_t error_capacity);

/* Remove as páginas originais da árvore de páginas; só as de saída ficam no documento. */
int ipm_remove_source_pages(ipm_doc* doc, char* error, size_t error_capacity);

/* Grava o documento com streams comprimidos e object streams; saída sem criptografia. */
int ipm_write(ipm_doc* doc, const char* path, char* error, size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif
