#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
D=Sources/NitidoUI/Fonts
mkdir -p "$D"
B=https://raw.githubusercontent.com/google/fonts/main/ofl
curl -fsSL "$B/cormorantgaramond/CormorantGaramond-Italic%5Bwght%5D.ttf" -o "$D/CormorantGaramond-Italic.ttf"
curl -fsSL "$B/marcellus/Marcellus-Regular.ttf" -o "$D/Marcellus-Regular.ttf"
curl -fsSL "$B/cormorantgaramond/OFL.txt" -o "$D/OFL-CormorantGaramond.txt"
curl -fsSL "$B/marcellus/OFL.txt" -o "$D/OFL-Marcellus.txt"
ls -la "$D"
