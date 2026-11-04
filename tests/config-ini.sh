#!/bin/sh
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/good.ini" <<'EOF'
# Complete desired configuration
[wtctl]
format=1
url=https://example.com/wtctl?v=1
wstunnel_url=https://example.com/wstunnel
[control]
server=main
[server main]
endpoint=wss://example.com
[tunnel ssh]
server=main
direction=reverse
listen=2222
target=localhost
port=22
EOF
check() { sh "$ROOT/wtctl" validate "$1" > "$work/output" 2>&1; }
reject() { if check "$1"; then printf 'Unexpected acceptance: %s\n' "$1" >&2; exit 1; fi; }
check "$work/good.ini"
for reserved in __control __previous_control; do
    sed "s/tunnel ssh/tunnel $reserved/" "$work/good.ini" > "$work/bad.ini"
    reject "$work/bad.ini"
done
for replacement in 'format=2' 'format=1
format=1' 'format=1
unknown=yes'; do
    REPLACEMENT=$replacement awk '{if($0=="format=1") print ENVIRON["REPLACEMENT"]; else print}' "$work/good.ini" > "$work/bad.ini"
    reject "$work/bad.ini"
done
sed 's/listen=2222/listen=8099/' "$work/good.ini" > "$work/bad.ini"
reject "$work/bad.ini"
sed 's/server=main/server=missing/' "$work/good.ini" > "$work/bad.ini"
reject "$work/bad.ini"
sed 's/url=https:/url=http:/' "$work/good.ini" > "$work/bad.ini"
reject "$work/bad.ini"
cp "$work/good.ini" "$work/bad.ini"
printf '\n[control]\nserver=main\n' >> "$work/bad.ini"
reject "$work/bad.ini"
sed '/\[control\]/a\
enabled=false' "$work/good.ini" | sed 's/listen=2222/listen=8099/' > "$work/disabled.ini"
check "$work/disabled.ini"
cp "$work/good.ini" "$work/bad.ini"
printf '\000' >> "$work/bad.ini"
reject "$work/bad.ini"
cp "$work/good.ini" "$work/bad.ini"
dd if=/dev/zero bs=65536 count=1 >> "$work/bad.ini" 2>/dev/null
reject "$work/bad.ini"
printf 'INI validation tests passed\n'
