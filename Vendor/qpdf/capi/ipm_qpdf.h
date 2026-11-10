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

/* Remove as páginas originais da árvore de páginas; só as de saída ficam no documento. */
int ipm_remove_source_pages(ipm_doc* doc, char* error, size_t error_capacity);

/* Grava o documento com streams comprimidos e object streams; saída sem criptografia. */
int ipm_write(ipm_doc* doc, const char* path, char* error, size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif
