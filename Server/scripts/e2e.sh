#!/bin/bash
# End-to-end check: one fsdrived and two client "devices" on this machine.
# usage: scripts/e2e.sh WORKDIR   (WORKDIR is wiped)
set -euo pipefail

WORK=${1:?usage: e2e.sh WORKDIR}
BIN=$(swift build -c release --show-bin-path)
PORT=18740
rm -rf "$WORK" && mkdir -p "$WORK"
ROOT="$WORK/server" A="$WORK/deviceA" B="$WORK/deviceB"

pass() { printf '  \033[32mok\033[0m %s\n' "$1"; }
die() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
# fsdrived speaks TLS only; curl checks its key the way clients do (pinned, not by name).
curl() { [ -f "$ROOT/.system/tls/pin" ] || return 7; command curl -k --pinnedpubkey "$(cat "$ROOT/.system/tls/pin")" "$@"; }
same() { diff -r -x .DS_Store "$1" "$2" >/dev/null || { diff -r "$1" "$2" | head; die "$3"; }; pass "$3"; }

# LINUX_FSDRIVED=build/linux/aarch64/fsdrived runs the server as that Linux binary in a
# throwaway container instead of the macOS build.
if [ -n "${LINUX_FSDRIVED:-}" ]; then
    # busybox has no C library of its own to lean on: the bundle must be self-contained.
    RUN=(docker run --rm --platform linux/arm64 -v "$WORK:$WORK" -v "$PWD/$(dirname "$LINUX_FSDRIVED"):/opt/fsdrive:ro")
    "${RUN[@]}" busybox /opt/fsdrive/fsdrived init --root "$ROOT" --owner tester > "$WORK/init.txt"
    docker rm -f fsdrive-e2e >/dev/null 2>&1 || true
    "${RUN[@]}" -d --name fsdrive-e2e -p $PORT:$PORT busybox /opt/fsdrive/fsdrived serve --root "$ROOT" --host 0.0.0.0 --port $PORT >/dev/null
    trap 'docker logs fsdrive-e2e > "$WORK/server.log" 2>&1; docker rm -f fsdrive-e2e >/dev/null' EXIT
else
    "$BIN/fsdrived" init --root "$ROOT" --owner tester > "$WORK/init.txt"
    "$BIN/fsdrived" serve --root "$ROOT" --port $PORT 2> "$WORK/server.log" &
    SERVER=$!
    trap 'kill $SERVER 2>/dev/null' EXIT
fi
TOKEN=$(awk '/Access token/ {print $NF}' "$WORK/init.txt")
for _ in $(seq 1 30); do curl -sf https://127.0.0.1:$PORT/v1/ping >/dev/null && break; sleep 0.3; done

va() { "$BIN/fsdrive" --config "$WORK/a.json" "$@"; }
vb() { "$BIN/fsdrive" --config "$WORK/b.json" "$@"; }
va login https://127.0.0.1:$PORT "$TOKEN" --device A >/dev/null
vb login https://127.0.0.1:$PORT "$TOKEN" --device B >/dev/null
grep -q '"serverPin":"sha256' "$WORK/a.json" && pass "signing in pinned the server's TLS key" || die "no pin in the config"
[ "$(command curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:$PORT/v1/ping)" = 000 ] \
    && pass "plain HTTP gets no answer: TLS only" || die "plain HTTP answered"
"$BIN/fsdrive" --config "$WORK/c.json" login https://127.0.0.1:$PORT "$TOKEN" --pin sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= >/dev/null 2>&1 \
    && die "signed in to a server with another key" || pass "a server whose key differs from the expected one is refused"
va create "Документи" >/dev/null
LIB="$ROOT/files/tester/Документи"
syncA() { va sync "Документи" "$A" 2>&1 | tail -1; }
syncB() { vb sync "Документи" "$B" 2>&1 | tail -1; }

echo "1. initial upload"
mkdir -p "$A/Звіти/2026" "$A/Порожня тека"
echo "привіт" > "$A/Звіти/нотатка.txt"
head -c 40000000 /dev/urandom > "$A/Звіти/2026/великий.bin"
cp "$A/Звіти/2026/великий.bin" "$A/копія.bin"
syncA
same "$A" "$LIB" "server folder is a plain copy of device A (open it in Finder)"

echo "2. second device"
syncB
same "$A" "$B" "device B matches A"

echo "3. small edit in a big file moves only nearby chunks"
python3 - "$A/Звіти/2026/великий.bin" <<'EOF'
import sys
p = sys.argv[1]
d = open(p, 'rb').read()
open(p, 'wb').write(d[:20_000_000] + b'INSERTED' + d[20_000_000:])
EOF
OUT=$(syncA); echo "  $OUT"
UP=$(echo "$OUT" | sed -E 's/.*↑ 1 \(([^)]*)\).*/\1/')
python3 - "$UP" <<'EOF2' || die "uploaded too much: $UP"
import re, sys
num, unit = re.match(r"([\d.,]+)\s*(\w+)", sys.argv[1]).groups()
mb = float(num.replace(",", ".")) * {"KB": 1e-3, "MB": 1, "GB": 1e3}.get(unit, 1)
sys.exit(0 if mb < 10 else 1)
EOF2
pass "upload was a delta ($UP of 40 MB)"
OUT=$(syncB); echo "  $OUT"
same "$A" "$B" "device B has the edit"
ls "$ROOT/.system/versions/"*/*/* >/dev/null 2>&1 && pass "previous version kept in .system/versions" || die "no previous version"

echo "4. rename"
mv "$A/копія.bin" "$A/Звіти/перейменована.bin"
OUT=$(syncA); echo "  $OUT"
echo "$OUT" | grep -q "moved 1" || die "rename not detected"
syncB >/dev/null
same "$A" "$B" "rename propagated without re-upload"

echo "5. delete"
rm "$A/Звіти/нотатка.txt"
syncA >/dev/null; syncB >/dev/null
[ ! -e "$B/Звіти/нотатка.txt" ] || die "delete did not reach B"
same "$A" "$LIB" "delete propagated; server copy is in .system/trash"

echo "5b. delete a whole folder"
mkdir -p "$A/На видалення/вкладена"; echo 1 > "$A/На видалення/a.txt"; echo 2 > "$A/На видалення/вкладена/b.txt"
syncA >/dev/null; syncB >/dev/null
[ -f "$B/На видалення/вкладена/b.txt" ] || die "folder did not reach B"
rm -rf "$A/На видалення"
syncA >/dev/null; syncA >/dev/null; syncB >/dev/null
[ ! -e "$LIB/На видалення" ] && [ ! -e "$A/На видалення" ] && [ ! -e "$B/На видалення" ] \
    && pass "a deleted folder disappears everywhere and is not brought back" || die "folder came back: $(ls "$LIB" "$A")"

echo "6. edit directly on the server in Finder"
echo "змінено на сервері" > "$LIB/з сервера.txt"
curl -sf -X POST -H "Authorization: Bearer $TOKEN" https://127.0.0.1:$PORT/v1/libs/1/scan
syncB >/dev/null
same "$LIB" "$B" "server-side change reached B"

echo "7. conflict: same file edited on both devices"
syncA >/dev/null
echo "версія A" > "$A/з сервера.txt"
echo "версія B" > "$B/з сервера.txt"
syncA >/dev/null
syncB >/dev/null
ls "$B" | grep -q "conflict, B" || die "no conflict copy on B"
syncA >/dev/null
same "$A" "$B" "both versions kept, devices converge"
grep -q "версія A" "$B/з сервера.txt" && pass "first writer wins the original name" || die "unexpected winner"

echo "8. empty folder and server restart"
same "$LIB/Порожня тека" "$B/Порожня тека" "empty folder synced"

if [ -z "${LINUX_FSDRIVED:-}" ]; then
    echo "9. a server with another TLS key is refused"
    kill $SERVER; wait $SERVER 2>/dev/null || true
    mv "$ROOT/.system/tls" "$WORK/tls-original"
    "$BIN/fsdrived" serve --root "$ROOT" --port $PORT 2>> "$WORK/server.log" &
    SERVER=$!
    for _ in $(seq 1 30); do curl -sf https://127.0.0.1:$PORT/v1/ping >/dev/null && break; sleep 0.3; done
    echo "не має дійти" > "$A/підміна.txt"
    va sync "Документи" "$A" >/dev/null 2>&1 && die "device synced with an impostor" || true
    [ ! -e "$LIB/підміна.txt" ] && pass "the pinned device refuses a server with a new key" || die "file reached the impostor"
    rm "$A/підміна.txt"
fi
echo
echo "all checks passed"
