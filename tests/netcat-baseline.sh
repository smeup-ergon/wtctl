#!/bin/sh
# Run in the supported Linux/BusyBox fixture, not with the host macOS nc.
set -eu
work=$(mktemp -d)
listener=
cleanup() {
    if [ -n "$listener" ]; then kill "$listener" 2>/dev/null || :; wait "$listener" 2>/dev/null || :; fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cat > "$work/handler" <<'EOF'
#!/bin/sh
IFS= read -r request || exit 1
printf 'OK %s\n' "$request"
EOF
chmod 700 "$work/handler"
nc -lk -s 127.0.0.1 -p 28099 -e "$work/handler" > "$work/listener.log" 2>&1 &
listener=$!
sleep 1
kill -0 "$listener"
for request in first second; do
    reply=$(printf '%s\n' "$request" | nc -w 2 127.0.0.1 28099)
    [ "$reply" = "OK $request" ] || { printf 'Netcat handler failed\n' >&2; exit 1; }
done
printf 'BusyBox loopback netcat handler tests passed\n'
