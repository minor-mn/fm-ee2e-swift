#!/bin/sh
# fm-ee2e をインストールする。
#   curl -fsSL https://raw.githubusercontent.com/minor-mn/fm-ee2e-swift/main/scripts/install.sh | sh
# 横に fm-ee2e.app がなければ（curl から動かしたとき）、最新の Release の zip を取ってきて、その中の install.sh を動かす。
# 横に fm-ee2e.app があれば（zip の中）、設定のフォルダーとアプリを置いて、ダウンロードの隔離を外す。
# すでにある config.json5 は上書きしない。
set -eu
here=$(dirname "$0")

if [ ! -d "$here/fm-ee2e.app" ]; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  echo "ダウンロードしています…"
  curl -fsSL -o "$work/fm-ee2e-swift.zip" https://github.com/minor-mn/fm-ee2e-swift/releases/latest/download/fm-ee2e-swift.zip
  ditto -x -k "$work/fm-ee2e-swift.zip" "$work"
  sh "$work/fm-ee2e-swift/install.sh"
  exit
fi

cd "$here"
config="$HOME/.config/fm-ee2e"
app=/Applications/fm-ee2e.app

mkdir -p "$config"
cp -R fm-ee2e/languages fm-ee2e/images "$config/"
if [ -e "$config/config.json5" ]; then
  echo "$config/config.json5 はそのままにしました。"
else
  cp fm-ee2e/config.json5 "$config/"
fi

rm -rf "$app"
cp -R fm-ee2e.app "$app"
xattr -dr com.apple.quarantine "$app"
echo "インストールしました。「アプリケーション」フォルダーの fm-ee2e から起動できます。"
