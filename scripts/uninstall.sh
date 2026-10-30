#!/bin/sh
# fm-ee2e を消す。
#   curl -fsSL https://raw.githubusercontent.com/minor-mn/fm-ee2e-swift/main/scripts/uninstall.sh | sh
# アプリと、~/.config/fm-ee2e の languages・images を消す。config.json5 と Google Drive の鍵（.fm-ee2e.key）は残す。
set -eu
config="$HOME/.config/fm-ee2e"
app=/Applications/fm-ee2e.app

rm -rf "$app" "$config/languages" "$config/images"
echo "アンインストールしました。$config の config.json5 と .fm-ee2e.key は残してあります。"
