#!/bin/sh
# Monta, assina (ad hoc) e instala o iPDFmini.app em ~/Applications.
#
# Sem Xcode: o app é o executável SwiftUI do SwiftPM empacotado à mão. A CLI vai
# em Contents/Helpers e é o processo filho que analisa e converte.
# O ícone é gerado do zero por scripts/make-icon.swift a cada build.
#
# Uso: scripts/build-app.sh [--no-install]
#   IPDFMINI_BUILD_DIR  diretório de trabalho (padrão: .build/app)
set -eu
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

WORK="${IPDFMINI_BUILD_DIR:-$ROOT/.build/app}"
APP="$WORK/iPDFmini.app"
DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/iPDFmini.app"
VERSION="0.1.0"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "==> swift build -c release (app e CLI)"
swift build -c release --product iPDFminiApp
swift build -c release --product ipdfmini
BIN="$(swift build -c release --show-bin-path)"

echo "==> ícone"
rm -rf "$WORK/icon"
mkdir -p "$WORK/icon"
swift scripts/make-icon.swift "$WORK/icon" >/dev/null
iconutil -c icns "$WORK/icon/AppIcon.iconset" -o "$WORK/icon/AppIcon.icns"

echo "==> bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
# O produto do app tem outro nome para não colidir com "ipdfmini" em disco sem distinção de maiúsculas.
cp "$BIN/iPDFminiApp" "$APP/Contents/MacOS/iPDFmini"
cp "$BIN/ipdfmini" "$APP/Contents/Helpers/ipdfmini"
cp "$WORK/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Licenças: a do projeto e as de terceiros embutidos (Apache 2.0 §4(d), IJG (2)).
LIC="$APP/Contents/Resources/Licenses"
mkdir -p "$LIC/qpdf" "$LIC/libjpeg-turbo" "$LIC/swift-argument-parser"
cp LICENSE NOTICE "$LIC/"
cp Vendor/qpdf/LICENSE.txt Vendor/qpdf/NOTICE.md Vendor/qpdf/Artistic-2.0 "$LIC/qpdf/"
cp Vendor/libjpeg-turbo/LICENSE.md Vendor/libjpeg-turbo/README.ijg "$LIC/libjpeg-turbo/"
SAP_LICENSE="$(find .build/checkouts/swift-argument-parser -maxdepth 1 -name 'LICENSE*' | head -1)"
[ -n "$SAP_LICENSE" ] || { echo "licença do swift-argument-parser não encontrada em .build/checkouts" >&2; exit 1; }
cp "$SAP_LICENSE" "$LIC/swift-argument-parser/LICENSE.txt"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>pt-BR</string>
    <key>CFBundleName</key><string>iPDFmini</string>
    <key>CFBundleDisplayName</key><string>iPDFmini</string>
    <key>CFBundleIdentifier</key><string>app.ipdfmini.mac</string>
    <key>CFBundleExecutable</key><string>iPDFmini</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 LkHideki · Apache License 2.0</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Documento PDF</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <!-- Alternate: aparece em "Abrir com" sem tomar o lugar do Pré-Visualização. -->
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
        </dict>
        <dict>
            <!-- Pasta solta no ícone do Dock: entra com os PDFs das subpastas (lote). -->
            <key>CFBundleTypeName</key><string>Pasta</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> assinatura ad hoc"
# Helper primeiro, depois o bundle (--deep cobre Contents/Helpers também).
codesign --force -s - "$APP/Contents/Helpers/ipdfmini"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"

if [ "$INSTALL" = 1 ]; then
    echo "==> instalação em $DEST"
    mkdir -p "$DEST_DIR"
    # Encerra a instância em execução para a cópia nova não conviver com a velha.
    if pgrep -f "$DEST/Contents/MacOS/iPDFmini" >/dev/null 2>&1; then
        osascript -e 'tell application id "app.ipdfmini.mac" to quit' >/dev/null 2>&1 || true
        sleep 1
        pkill -f "$DEST/Contents/MacOS/iPDFmini" >/dev/null 2>&1 || true
    fi
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    "$LSREGISTER" -f "$DEST"
    echo "instalado: $DEST"
else
    echo "bundle: $APP"
fi
