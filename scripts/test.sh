#!/bin/sh
# Suíte completa. As Command Line Tools não registram o plugin de macros do
# Swift Testing (erro "plugin for module 'TestingMacros' not found"); o
# -plugin-path aponta para ele explicitamente. Com Xcode instalado é inócuo.
set -eu
cd "$(dirname "$0")/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
