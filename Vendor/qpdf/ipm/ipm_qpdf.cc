// Implementação C++ da API C (ipm_qpdf.h). Código do projeto, não é upstream.
#include "ipm_qpdf.h"

#include <qpdf/QPDF.hh>
#include <qpdf/QPDFExc.hh>
#include <qpdf/QPDFObjectHandle.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFSystemError.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/QTC.hh>

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

namespace {

// Falha já classificada (argumento inválido, estado impossível).
struct Failure {
    int code;
    std::string message;
};

struct OutputPage {
    QPDFObjectHandle dict;
    std::string content; // operadores na ordem das chamadas; vira /Contents em finalize
    bool dirty = true;
    bool has_font = false;
};

} // namespace

struct ipm_doc {
    // A ordem importa: handles devem morrer antes do QPDF.
    std::shared_ptr<QPDF> pdf;
    std::vector<QPDFPageObjectHelper> sources;
    // getFormXObjectForPage cria um objeto novo a cada chamada; o cache evita duplicar o
    // content stream da origem a cada fatia.
    std::vector<QPDFObjectHandle> forms;
    std::vector<OutputPage> outputs;
    QPDFObjectHandle helvetica; // objeto de fonte compartilhado por todas as páginas
    bool sources_removed = false;
};

namespace {

void copy_message(std::string const& message, char* error, size_t capacity) {
    if (error == nullptr || capacity == 0) {
        return;
    }
    size_t n = std::min(message.size(), capacity - 1);
    std::memcpy(error, message.data(), n);
    error[n] = '\0';
}

// Sem QPDF_DISABLE_QTC (o build não usa o cmake do qpdf), QTC::TC consulta um std::map
// estático e insere nele, sem lock, na 1ª vez que vê cada escopo ("qpdf", "libtests").
// Documentos em threads distintas corrompiam o map (SIGSEGV em processFile, medido nos
// testes paralelos). Registrar os dois escopos uma vez, antes de tudo, deixa o map só
// para leitura. Sai quando o CQPDF for compilado com .define("QPDF_DISABLE_QTC").
void warm_up_qtc() {
    static std::once_flag once;
    std::call_once(once, [] {
        QTC::TC("qpdf", "ipm warm-up");
        QTC::TC("libtests", "ipm warm-up");
    });
}

// Toda exceção C++ termina aqui: nada atravessa a fronteira C.
template <typename F>
int guarded(char* error, size_t capacity, F&& body) {
    warm_up_qtc();
    if (error != nullptr && capacity > 0) {
        error[0] = '\0';
    }
    int code = IPM_OK;
    std::string message;
    try {
        body();
    } catch (Failure const& f) {
        code = f.code;
        message = f.message;
    } catch (QPDFExc const& e) {
        switch (e.getErrorCode()) {
        case qpdf_e_password: code = IPM_ERR_PASSWORD; break;
        case qpdf_e_system: code = IPM_ERR_IO; break;
        case qpdf_e_damaged_pdf:
        case qpdf_e_pages: code = IPM_ERR_DAMAGED; break;
        default: code = IPM_ERR_INTERNAL; break;
        }
        message = e.what();
    } catch (QPDFSystemError const& e) {
        code = IPM_ERR_IO;
        message = e.what();
    } catch (std::bad_alloc const&) {
        code = IPM_ERR_INTERNAL;
        message = "memoria insuficiente";
    } catch (std::exception const& e) {
        code = IPM_ERR_INTERNAL;
        message = e.what();
    } catch (...) {
        code = IPM_ERR_INTERNAL;
        message = "excecao desconhecida";
    }
    if (code != IPM_OK) {
        copy_message(message, error, capacity);
    }
    return code;
}

[[noreturn]] void fail(int code, std::string message) {
    throw Failure{code, std::move(message)};
}

ipm_doc& require_doc(ipm_doc* doc) {
    if (doc == nullptr) {
        fail(IPM_ERR_ARGUMENT, "documento nulo");
    }
    return *doc;
}

void require_finite(double const* values, int count, char const* what) {
    if (values == nullptr) {
        fail(IPM_ERR_ARGUMENT, std::string(what) + " nulo");
    }
    for (int i = 0; i < count; ++i) {
        if (!std::isfinite(values[i])) {
            fail(IPM_ERR_ARGUMENT, std::string(what) + " contem valor nao finito");
        }
    }
}

QPDFPageObjectHelper& source_at(ipm_doc& d, int index) {
    if (index < 0 || static_cast<size_t>(index) >= d.sources.size()) {
        fail(IPM_ERR_ARGUMENT, "pagina de origem fora do intervalo: " + std::to_string(index));
    }
    return d.sources[static_cast<size_t>(index)];
}

OutputPage& output_at(ipm_doc& d, int index) {
    if (index < 0 || static_cast<size_t>(index) >= d.outputs.size()) {
        fail(IPM_ERR_ARGUMENT, "pagina de saida fora do intervalo: " + std::to_string(index));
    }
    return d.outputs[static_cast<size_t>(index)];
}

// Número em notação decimal fixa e independente de locale (std::to_chars), sem zeros à direita.
void append_number(std::string& out, double v) {
    char buf[64];
    auto result = std::to_chars(buf, buf + sizeof buf, v, std::chars_format::fixed, 5);
    std::string s(buf, result.ptr);
    if (s.find('.') != std::string::npos) {
        while (s.back() == '0') {
            s.pop_back();
        }
        if (s.back() == '.') {
            s.pop_back();
        }
    }
    if (s == "-0") {
        s = "0";
    }
    out += s;
    out += ' ';
}

QPDFObjectHandle::Rectangle normalized(QPDFObjectHandle::Rectangle r) {
    return {std::min(r.llx, r.urx), std::min(r.lly, r.ury), std::max(r.llx, r.urx), std::max(r.lly, r.ury)};
}

QPDFObjectHandle::Rectangle media_box_of(QPDFPageObjectHelper& page) {
    QPDFObjectHandle box = page.getMediaBox(false);
    if (!box.isRectangle()) {
        fail(IPM_ERR_DAMAGED, "pagina sem MediaBox valida");
    }
    return normalized(box.getArrayAsRectangle());
}

// CropBox efetiva: a herdada, limitada à MediaBox; sem CropBox válida, a própria MediaBox.
QPDFObjectHandle::Rectangle crop_box_of(QPDFPageObjectHelper& page, QPDFObjectHandle::Rectangle media) {
    QPDFObjectHandle box = page.getCropBox(false, false);
    if (!box.isRectangle()) {
        return media;
    }
    auto c = normalized(box.getArrayAsRectangle());
    QPDFObjectHandle::Rectangle i{
        std::max(c.llx, media.llx), std::max(c.lly, media.lly), std::min(c.urx, media.urx), std::min(c.ury, media.ury)};
    return (i.llx < i.urx && i.lly < i.ury) ? i : media;
}

int rotation_of(QPDFPageObjectHelper& page) {
    QPDFObjectHandle r = page.getAttribute("/Rotate", false);
    if (!r.isInteger()) {
        return 0;
    }
    long long v = r.getIntValue();
    if (v % 90 != 0) {
        return 0;
    }
    return static_cast<int>(((v % 360) + 360) % 360);
}

void write_rect(double* out, QPDFObjectHandle::Rectangle r) {
    out[0] = r.llx;
    out[1] = r.lly;
    out[2] = r.urx;
    out[3] = r.ury;
}

QPDFObjectHandle form_for(ipm_doc& d, int index) {
    QPDFPageObjectHelper& page = source_at(d, index);
    QPDFObjectHandle& cached = d.forms[static_cast<size_t>(index)];
    if (!cached.isInitialized()) {
        // Sem /Rotate e /UserUnit no Form: a matriz do chamador é a única transformação. O
        // getMatrixForTransformations do qpdf ignora a origem da caixa e erra com /Rotate.
        QPDFObjectHandle form = page.getFormXObjectForPage(false);
        auto media = media_box_of(page);
        form.getDict().replaceKey("/BBox", QPDFObjectHandle::newFromRectangle(crop_box_of(page, media)));
        cached = form;
    }
    return cached;
}

std::string xobject_name(int source_page) {
    return "/IPMFm" + std::to_string(source_page);
}

void require_name(char const* name, char const* what) {
    if (name == nullptr || name[0] != '/' || name[1] == '\0') {
        fail(IPM_ERR_ARGUMENT, std::string(what) + " deve ser um nome PDF (\"/Nome\")");
    }
}

// Objeto em sintaxe PDF; "N G R" resolve no próprio documento.
QPDFObjectHandle parse_object(ipm_doc& d, char const* pdf, size_t length, char const* what) {
    if (pdf == nullptr || length == 0) {
        fail(IPM_ERR_ARGUMENT, std::string(what) + " vazio");
    }
    try {
        return QPDFObjectHandle::parse(d.pdf.get(), std::string(pdf, length), what);
    } catch (QPDFExc const& e) {
        fail(IPM_ERR_ARGUMENT, std::string(what) + " invalido: " + e.what());
    }
}

// Materializa o content stream de cada página alterada.
void finalize(ipm_doc& d) {
    for (OutputPage& p : d.outputs) {
        if (p.dirty) {
            p.dict.replaceKey("/Contents", d.pdf->newStream(p.content));
            p.dirty = false;
        }
    }
}

} // namespace

extern "C" {

int ipm_open(const char* path, const char* password, ipm_doc** out_doc, char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        if (path == nullptr || out_doc == nullptr) {
            fail(IPM_ERR_ARGUMENT, "path e out_doc sao obrigatorios");
        }
        *out_doc = nullptr;
        auto doc = std::make_unique<ipm_doc>();
        doc->pdf = QPDF::create();
        // Avisos de recuperação iriam para o stderr do processo.
        doc->pdf->setSuppressWarnings(true);
        doc->pdf->processFile(path, password);
        doc->sources = QPDFPageDocumentHelper(*doc->pdf).getAllPages();
        doc->forms.resize(doc->sources.size());
        *out_doc = doc.release();
    });
}

void ipm_close(ipm_doc* doc) {
    delete doc;
}

int ipm_source_page_count(ipm_doc* doc, int* out_count, char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        if (out_count == nullptr) {
            fail(IPM_ERR_ARGUMENT, "out_count nulo");
        }
        *out_count = static_cast<int>(d.sources.size());
    });
}

int ipm_output_page_count(ipm_doc* doc, int* out_count, char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        if (out_count == nullptr) {
            fail(IPM_ERR_ARGUMENT, "out_count nulo");
        }
        *out_count = static_cast<int>(d.outputs.size());
    });
}

int ipm_source_page_info(ipm_doc* doc, int source_page, double* out_media, double* out_crop, int* out_rotate,
                         char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        if (out_media == nullptr || out_crop == nullptr || out_rotate == nullptr) {
            fail(IPM_ERR_ARGUMENT, "saidas nulas");
        }
        QPDFPageObjectHelper& page = source_at(d, source_page);
        auto media = media_box_of(page);
        write_rect(out_media, media);
        write_rect(out_crop, crop_box_of(page, media));
        *out_rotate = rotation_of(page);
    });
}

int ipm_add_page(ipm_doc* doc, const double* media_box, int* out_page, char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        require_finite(media_box, 4, "media_box");
        if (out_page == nullptr) {
            fail(IPM_ERR_ARGUMENT, "out_page nulo");
        }
        auto box = normalized({media_box[0], media_box[1], media_box[2], media_box[3]});
        if (!(box.llx < box.urx && box.lly < box.ury)) {
            fail(IPM_ERR_ARGUMENT, "media_box vazia");
        }
        auto page = QPDFObjectHandle::newDictionary();
        page.replaceKey("/Type", QPDFObjectHandle::newName("/Page"));
        page.replaceKey("/MediaBox", QPDFObjectHandle::newFromRectangle(box));
        auto resources = QPDFObjectHandle::newDictionary();
        resources.replaceKey("/XObject", QPDFObjectHandle::newDictionary());
        page.replaceKey("/Resources", resources);
        auto indirect = d.pdf->makeIndirectObject(page);
        QPDFPageDocumentHelper(*d.pdf).addPage(QPDFPageObjectHelper(indirect), false);
        d.outputs.push_back(OutputPage{indirect, {}, true, false});
        *out_page = static_cast<int>(d.outputs.size()) - 1;
    });
}

int ipm_place_page(ipm_doc* doc, int output_page, int source_page, const double* clip, const double* matrix,
                   char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        require_finite(clip, 4, "clip");
        require_finite(matrix, 6, "matrix");
        OutputPage& out = output_at(d, output_page);
        QPDFObjectHandle form = form_for(d, source_page); // valida source_page
        auto r = normalized({clip[0], clip[1], clip[2], clip[3]});
        std::string name = xobject_name(source_page);
        out.dict.getKey("/Resources").getKey("/XObject").replaceKey(name, form);

        std::string ops = "q ";
        for (int i = 0; i < 6; ++i) {
            append_number(ops, matrix[i]);
        }
        ops += "cm ";
        append_number(ops, r.llx);
        append_number(ops, r.lly);
        append_number(ops, r.urx - r.llx);
        append_number(ops, r.ury - r.lly);
        ops += "re W n " + name + " Do Q\n";
        out.content += ops;
        out.dirty = true;
    });
}

int ipm_append_content(ipm_doc* doc, int output_page, const char* data, size_t length, char* error,
                       size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        if (data == nullptr && length > 0) {
            fail(IPM_ERR_ARGUMENT, "data nulo");
        }
        OutputPage& out = output_at(d, output_page);
        if (!out.has_font) {
            if (!d.helvetica.isInitialized()) {
                auto font = QPDFObjectHandle::newDictionary();
                font.replaceKey("/Type", QPDFObjectHandle::newName("/Font"));
                font.replaceKey("/Subtype", QPDFObjectHandle::newName("/Type1"));
                font.replaceKey("/BaseFont", QPDFObjectHandle::newName("/Helvetica"));
                font.replaceKey("/Encoding", QPDFObjectHandle::newName("/WinAnsiEncoding"));
                d.helvetica = d.pdf->makeIndirectObject(font);
            }
            auto resources = out.dict.getKey("/Resources");
            if (!resources.hasKey("/Font")) {
                resources.replaceKey("/Font", QPDFObjectHandle::newDictionary());
            }
            resources.getKey("/Font").replaceKey("/" IPM_HELVETICA_NAME, d.helvetica);
            out.has_font = true;
        }
        if (length > 0) {
            out.content.append(data, length);
        }
        out.content += '\n'; // evita colar o último token no operador seguinte
        out.dirty = true;
    });
}

int ipm_output_page_object(ipm_doc* doc, int output_page, int* out_number, int* out_generation, char* error,
                           size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        if (out_number == nullptr || out_generation == nullptr) {
            fail(IPM_ERR_ARGUMENT, "saidas nulas");
        }
        OutputPage& out = output_at(d, output_page);
        *out_number = out.dict.getObjectID();
        *out_generation = out.dict.getGeneration();
    });
}

int ipm_add_annotation(ipm_doc* doc, int output_page, const char* pdf, size_t length, char* error,
                       size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        OutputPage& out = output_at(d, output_page);
        auto annot = parse_object(d, pdf, length, "anotacao");
        if (!annot.isDictionary()) {
            fail(IPM_ERR_ARGUMENT, "anotacao nao e dicionario");
        }
        annot.replaceKey("/P", out.dict);
        if (!out.dict.hasKey("/Annots") || !out.dict.getKey("/Annots").isArray()) {
            out.dict.replaceKey("/Annots", QPDFObjectHandle::newArray());
        }
        out.dict.getKey("/Annots").appendItem(d.pdf->makeIndirectObject(annot));
    });
}

int ipm_set_catalog_entry(ipm_doc* doc, const char* key, const char* subkey, const char* pdf, size_t length,
                          char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        require_name(key, "key");
        QPDFObjectHandle target = d.pdf->getRoot();
        std::string name = key;
        if (subkey != nullptr) {
            require_name(subkey, "subkey");
            QPDFObjectHandle inner = target.getKey(key);
            if (!inner.isDictionary()) {
                if (pdf == nullptr) {
                    return;
                }
                inner = QPDFObjectHandle::newDictionary();
                target.replaceKey(key, inner);
            }
            target = inner;
            name = subkey;
        }
        if (pdf == nullptr) {
            target.removeKey(name);
        } else {
            target.replaceKey(name, parse_object(d, pdf, length, name.c_str()));
        }
    });
}

int ipm_set_info_entry(ipm_doc* doc, const char* key, const char* value, char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        require_name(key, "key");
        QPDFObjectHandle trailer = d.pdf->getTrailer();
        QPDFObjectHandle info = trailer.getKey("/Info");
        if (!info.isDictionary()) {
            if (value == nullptr) {
                return;
            }
            info = d.pdf->makeIndirectObject(QPDFObjectHandle::newDictionary());
            trailer.replaceKey("/Info", info);
        }
        if (value == nullptr) {
            info.removeKey(key);
        } else {
            info.replaceKey(key, QPDFObjectHandle::newUnicodeString(value));
        }
    });
}

int ipm_set_outline(ipm_doc* doc, int count, const char* const* titles, const int* parents,
                    const char* const* destinations, const int* open, char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        if (count < 0) {
            fail(IPM_ERR_ARGUMENT, "count negativo");
        }
        QPDFObjectHandle root = d.pdf->getRoot();
        if (count == 0) {
            root.removeKey("/Outlines");
            return;
        }
        if (titles == nullptr || parents == nullptr || destinations == nullptr || open == nullptr) {
            fail(IPM_ERR_ARGUMENT, "vetores nulos");
        }
        auto n = static_cast<size_t>(count);
        auto top = d.pdf->makeIndirectObject(QPDFObjectHandle::newDictionary());
        top.replaceKey("/Type", QPDFObjectHandle::newName("/Outlines"));
        std::vector<QPDFObjectHandle> items(n);
        std::vector<std::vector<size_t>> children(n);
        std::vector<size_t> roots;
        for (size_t i = 0; i < n; ++i) {
            int p = parents[i];
            if (p < -1 || p >= static_cast<int>(i)) {
                fail(IPM_ERR_ARGUMENT, "pai invalido no item " + std::to_string(i));
            }
            auto item = d.pdf->makeIndirectObject(QPDFObjectHandle::newDictionary());
            item.replaceKey("/Title", QPDFObjectHandle::newUnicodeString(titles[i] != nullptr ? titles[i] : ""));
            if (destinations[i] != nullptr) {
                item.replaceKey("/Dest", parse_object(d, destinations[i], std::strlen(destinations[i]), "destino"));
            }
            items[i] = item;
            (p < 0 ? roots : children[static_cast<size_t>(p)]).push_back(i);
        }
        // Encadeia irmãos e calcula /Count de trás para frente (filhos têm índice maior que o pai).
        std::vector<long long> visible(n, 0);
        auto link = [&](QPDFObjectHandle parent, std::vector<size_t> const& kids) {
            for (size_t k = 0; k < kids.size(); ++k) {
                auto item = items[kids[k]];
                item.replaceKey("/Parent", parent);
                if (k > 0) {
                    item.replaceKey("/Prev", items[kids[k - 1]]);
                }
                if (k + 1 < kids.size()) {
                    item.replaceKey("/Next", items[kids[k + 1]]);
                }
            }
            if (!kids.empty()) {
                parent.replaceKey("/First", items[kids.front()]);
                parent.replaceKey("/Last", items[kids.back()]);
            }
        };
        for (size_t i = n; i-- > 0;) {
            link(items[i], children[i]);
            long long sum = 0;
            for (size_t c : children[i]) {
                sum += 1 + (open[c] != 0 ? visible[c] : 0);
            }
            visible[i] = sum;
            if (!children[i].empty()) {
                // Positivo = aberto (descendentes visíveis); negativo = fechado.
                long long shown = open[i] != 0 ? sum : -static_cast<long long>(children[i].size());
                items[i].replaceKey("/Count", QPDFObjectHandle::newInteger(shown));
            }
        }
        link(top, roots);
        long long total = 0;
        for (size_t r : roots) {
            total += 1 + (open[r] != 0 ? visible[r] : 0);
        }
        top.replaceKey("/Count", QPDFObjectHandle::newInteger(total));
        root.replaceKey("/Outlines", top);
    });
}

int ipm_set_source_page_boxes(ipm_doc* doc, int source_page, const double* box, const double* clip, char* error,
                              size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        require_finite(box, 4, "box");
        QPDFPageObjectHelper& page = source_at(d, source_page);
        auto r = normalized({box[0], box[1], box[2], box[3]});
        if (!(r.llx < r.urx && r.lly < r.ury)) {
            fail(IPM_ERR_ARGUMENT, "box vazia");
        }
        QPDFObjectHandle dict = page.getObjectHandle();
        for (char const* key : {"/MediaBox", "/CropBox", "/TrimBox", "/BleedBox", "/ArtBox"}) {
            dict.replaceKey(key, QPDFObjectHandle::newFromRectangle(r));
        }
        if (clip != nullptr) {
            require_finite(clip, 4, "clip");
            auto c = normalized({clip[0], clip[1], clip[2], clip[3]});
            std::string ops = "q ";
            append_number(ops, c.llx);
            append_number(ops, c.lly);
            append_number(ops, c.urx - c.llx);
            append_number(ops, c.ury - c.lly);
            ops += "re W n\n";
            // Quebras de linha nas pontas: streams vizinhos não colam tokens.
            page.addPageContents(d.pdf->newStream(ops), true);
            page.addPageContents(d.pdf->newStream("\nQ\n"), false);
        }
    });
}

int ipm_remove_source_page(ipm_doc* doc, int source_page, char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        QPDFPageObjectHelper& page = source_at(d, source_page);
        QPDFPageDocumentHelper(*d.pdf).removePage(page);
    });
}

int ipm_remove_source_pages(ipm_doc* doc, char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        if (d.sources_removed) {
            return;
        }
        QPDFPageDocumentHelper helper(*d.pdf);
        for (auto& page : d.sources) {
            helper.removePage(page);
        }
        d.sources_removed = true;
    });
}

int ipm_write(ipm_doc* doc, const char* path, char* error, size_t error_capacity) {
    return guarded(error, error_capacity, [&] {
        ipm_doc& d = require_doc(doc);
        if (path == nullptr) {
            fail(IPM_ERR_ARGUMENT, "path nulo");
        }
        finalize(d);
        QPDFWriter writer(*d.pdf, path);
        writer.setObjectStreamMode(qpdf_o_generate);
        writer.setCompressStreams(true);
        writer.setStreamDataMode(qpdf_s_compress);
        writer.setPreserveEncryption(false);
        writer.write();
    });
}

} // extern "C"
