#!/bin/bash
# Multi-user check: storage modes, adopting existing folders, isolation between users,
# access control. Fake QNAP users come from a passwd file (FSDRIVE_PASSWD_FILE).
# usage: scripts/e2e-users.sh WORKDIR   (WORKDIR is wiped)
set -euo pipefail

WORK=${1:?usage: e2e-users.sh WORKDIR}
BIN=$(swift build -c release --show-bin-path)
PORT=18741
URL=https://127.0.0.1:$PORT
rm -rf "$WORK" && mkdir -p "$WORK/home/alice" "$WORK/home/bob" "$WORK/storage/bob"
ROOT="$WORK/server" STORE="$WORK/storage"

pass() { printf '  \033[32mok\033[0m %s\n' "$1"; }
die() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
# fsdrived speaks TLS only; curl checks its key the way clients do (pinned, not by name).
curl() { [ -f "$ROOT/.system/tls/pin" ] || return 7; command curl -k --pinnedpubkey "$(cat "$ROOT/.system/tls/pin")" "$@"; }

U=$(id -u) G=$(id -g)
cat > "$WORK/passwd" <<EOF
root:x:0:0::/var/root:/bin/sh
alice:x:$U:$G::$WORK/home/alice:/bin/sh
bob:x:$U:$G::$WORK/home/bob:/bin/sh
carol:x:$U:$G::$WORK/home/carol:/bin/sh
EOF
export FSDRIVE_PASSWD_FILE="$WORK/passwd"

"$BIN/fsdrived" init --root "$ROOT" --owner admin > "$WORK/init.txt"
ADMIN=$(awk '/Access token/ {print $NF}' "$WORK/init.txt")
"$BIN/fsdrived" serve --root "$ROOT" --port $PORT 2> "$WORK/server.log" &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -sf $URL/v1/ping >/dev/null && break; sleep 0.3; done

api() { local tok=$1; shift; curl -s -H "Authorization: Bearer $tok" -H "Content-Type: application/json" "$@"; }
code() { local tok=$1; shift; curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $tok" -H "Content-Type: application/json" "$@"; }
token() { api "$ADMIN" -X POST "$URL/v1/admin/users/$1/token" -d "{\"device\":\"test-$1\"}" | sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p'; }
settings() { api "$ADMIN" -X PUT "$URL/v1/admin/settings" -d "$1" > "$WORK/users.json"; }
cli() { local who=$1; shift; "$BIN/fsdrive" --config "$WORK/$who.json" "$@"; }

echo "1. shared folder mode, folders named after users"
echo "файл, що вже лежав у теці Боба" > "$STORE/bob/вже був.txt"
settings "{\"storageMode\":\"folder\",\"folderPath\":\"$STORE\",\"folderNaming\":\"name\",\"allowedUsers\":[\"alice\",\"bob\"]}"
[ -d "$STORE/alice" ] && [ -d "$ROOT/.system/libs/alice/uploads" ] && [ ! -e "$STORE/.fsdrive-system" ] || die "alice's folder or system folder missing"
pass "folders created: storage/alice, storage/bob; system folders in the server's own .system/libs"
[ "$(stat -f '%Lp' "$STORE/alice")" = 770 ] && pass "new user folder is 0770 (user + administrators)" || die "mode $(stat -f '%Lp' "$STORE/alice")"

A=$(token alice); B=$(token bob)
cli alice login $URL "$A" --device "Alice Mac" >/dev/null
cli bob login $URL "$B" --device "Bob Mac" >/dev/null

echo "2. existing files are picked up"
cli bob sync bob "$WORK/bobmac" >/dev/null 2>&1
[ -f "$WORK/bobmac/вже був.txt" ] && pass "bob's device received the file that was already in his folder" || die "existing file not adopted"

echo "3. uploads land in the user's folder with the user's rights"
mkdir -p "$WORK/alicemac/Звіти"; echo "звіт Аліси" > "$WORK/alicemac/Звіти/q3.txt"
cli alice sync alice "$WORK/alicemac" >/dev/null 2>&1
[ -f "$STORE/alice/Звіти/q3.txt" ] && pass "file stored as storage/alice/Звіти/q3.txt" || die "upload not in alice's folder"
[ "$(stat -f '%Lp' "$STORE/alice/Звіти/q3.txt")" = 660 ] && pass "file mode 0660, folder mode $(stat -f '%Lp' "$STORE/alice/Звіти")" || die "file mode $(stat -f '%Lp' "$STORE/alice/Звіти/q3.txt")"

echo "4. users cannot see each other"
LIBS=$(api "$A" $URL/v1/libs)
echo "$LIBS" | grep -q '"name":"alice"' && ! echo "$LIBS" | grep -q '"name":"bob"' && pass "alice lists only her library" || die "library list: $LIBS"
BOBLIB=$(api "$B" $URL/v1/libs | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
[ "$(code "$A" $URL/v1/libs/$BOBLIB/tree)" = 404 ] && pass "alice gets 404 for bob's library" || die "alice could read bob's library"
# Bob knows the hash of Alice's file but not its bytes: the server must neither say it
# has them nor fill his upload from her file.
UP=$(python3 -c '
import hashlib, json, sys
data = open(sys.argv[1], "rb").read()
h = hashlib.sha256(data).digest()
print(json.dumps({"path": "чуже.txt", "mtimeNs": 0, "contentHash": hashlib.sha256(h).hexdigest(),
                  "chunks": [{"h": h.hex(), "l": len(data)}], "device": "bob"}))' "$STORE/alice/Звіти/q3.txt")
CREATED=$(api "$B" -X POST $URL/v1/libs/$BOBLIB/uploads -d "$UP")
echo "$CREATED" | grep -q '"missing":\["[0-9a-f]' && pass "another user's chunk is reported missing (no dedup across users)" || die "dedup leaked: $CREATED"
UPID=$(echo "$CREATED" | sed -n 's/.*"uploadId":"\([^"]*\)".*/\1/p')
api "$B" -X POST $URL/v1/uploads/$UPID/commit | grep -q '"status":"missing"' && [ ! -e "$STORE/bob/чуже.txt" ] \
    && pass "commit is not filled from another user's file" || die "bob's upload was filled from alice's file"
ALIB0=$(api "$A" $URL/v1/libs | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
AVID=$(api "$A" $URL/v1/libs/$ALIB0/tree | python3 -c 'import json,sys; print([n["versionId"] for n in json.load(sys.stdin)["nodes"] if n["path"].endswith("q3.txt")][0])')
[ "$(code "$A" -X POST $URL/v1/libs/$ALIB0/versions/$AVID/ranges -d '{"ranges":[[9223372036854775807,1]]}')" = 400 ] \
    && curl -sf $URL/v1/ping >/dev/null && pass "an overflowing range is refused and the server stays up" || die "range overflow"

echo "5. access control"
[ "$(code "$ADMIN" -X POST $URL/v1/admin/users/carol/token -d '{"device":"x"}')" = 403 ] && pass "carol (not allowed) gets no token" || die "carol got a token"
[ "$(code nonsense $URL/v1/libs)" = 401 ] && pass "unknown token rejected" || die "unknown token accepted"
[ "$(code "$A" $URL/v1/admin/users)" = 403 ] && pass "users cannot call the admin API" || die "user reached admin API"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST $URL/v1/login -d '{"user":"alice","password":"x","device":"d"}')" = 501 ] && pass "password login is QNAP-only (501 here)" || die "login endpoint"
settings "{\"storageMode\":\"folder\",\"folderPath\":\"$STORE\",\"folderNaming\":\"name\",\"allowedUsers\":[\"alice\"]}"
[ "$(code "$B" $URL/v1/libs)" = 403 ] && pass "bob loses access as soon as the admin unticks him" || die "bob still has access"

echo "6. home folder mode"
settings "{\"storageMode\":\"home\",\"allowedUsers\":[\"alice\"]}"
[ -d "$WORK/home/alice/FSDrive" ] && [ ! -e "$WORK/home/alice/.fsdrive-system" ] || die "home/alice/FSDrive not created"
pass "alice now has home/alice/FSDrive"
cli alice sync alice "$WORK/alicemac" >/dev/null 2>&1
[ -f "$WORK/home/alice/FSDrive/Звіти/q3.txt" ] && pass "her device filled the new location" || die "file not in home/alice/FSDrive"
grep -q '"status":"ready"' "$WORK/users.json" && pass "settings page reports alice ready" || die "status: $(cat "$WORK/users.json")"

echo "6b. links in a user's folder are never followed"
LIB=$WORK/home/alice/FSDrive
mkdir -p "$WORK/outside" && echo "чужий секрет" > "$WORK/secret.txt"
ln -s "$WORK/outside" "$LIB/escape"
mkdir -p "$WORK/alicemac/escape" && echo "мало опинитися поза текою" > "$WORK/alicemac/escape/pwned.txt"
cli alice sync alice "$WORK/alicemac" >/dev/null 2>&1 || true
[ ! -e "$WORK/outside/pwned.txt" ] && pass "an upload into a folder that is a link does not land outside the library" || die "wrote through a link"
rm -rf "$WORK/alicemac/escape" "$LIB/escape"
ALIB=$(api "$A" $URL/v1/libs | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
VID=$(api "$A" $URL/v1/libs/$ALIB/tree | python3 -c 'import json,sys; print([n["versionId"] for n in json.load(sys.stdin)["nodes"] if n["path"].endswith("q3.txt")][0])')
ln -sf "$WORK/secret.txt" "$LIB/Звіти/q3.txt"
GOT=$(curl -s -H "Authorization: Bearer $A" $URL/v1/libs/$ALIB/versions/$VID/content)
[ "$(code "$A" $URL/v1/libs/$ALIB/versions/$VID/content)" = 404 ] && [ "$GOT" != "чужий секрет" ] \
    && pass "a file swapped for a link is not served (404)" || die "served through a link: $GOT"
mv "$LIB" "$LIB.real" && ln -s "$WORK/outside" "$LIB"
echo "new" > "$WORK/alicemac/new.txt"
cli alice sync alice "$WORK/alicemac" >/dev/null 2>&1 || true
[ -z "$(ls -A "$WORK/outside")" ] && pass "a library folder swapped for a link gets nothing written into the target" || die "wrote into $(ls "$WORK/outside")"
rm "$LIB" && mv "$LIB.real" "$LIB" && rm "$WORK/alicemac/new.txt"
SYS=$ROOT/.system/libs/alice
chmod 777 "$SYS"
echo "через чужу теку" > "$WORK/alicemac/open.txt"
cli alice sync alice "$WORK/alicemac" >/dev/null 2>&1 || true
[ ! -e "$LIB/open.txt" ] && grep -q "writable by others" "$WORK/server.log" && pass "a system folder others can write to is refused" || die "used a system folder writable by others"
chmod 750 "$SYS" && rm "$WORK/alicemac/open.txt"
[ "$(stat -f '%Lp' "$ROOT/.system")" = 700 ] && [ "$(stat -f '%Lp' "$ROOT/.system/db.sqlite")" = 600 ] \
    && pass "database and .system are readable by the server only" || die "modes $(stat -f '%Lp' "$ROOT/.system") $(stat -f '%Lp' "$ROOT/.system/db.sqlite")"

echo "7. password guessing is blocked"
# Stand-in for QTS authLogin.cgi: alice's password is "secret".
cat > "$WORK/authLogin.cgi" <<'CGI'
#!/bin/sh
printf 'Content-type: text/xml\n\n'
case "$QUERY_STRING" in
  "user=alice&pwd=c2VjcmV0&"*) echo '<authPassed><![CDATA[1]]></authPassed>' ;;
  *) echo '<authPassed><![CDATA[0]]></authPassed>' ;;
esac
CGI
chmod +x "$WORK/authLogin.cgi"
kill $SERVER; wait $SERVER 2>/dev/null || true
FSDRIVE_AUTH_CGI="$WORK/authLogin.cgi" "$BIN/fsdrived" serve --root "$ROOT" --host 0.0.0.0 --port $PORT 2>> "$WORK/server.log" &
SERVER=$!
for _ in $(seq 1 30); do curl -sf $URL/v1/ping >/dev/null && break; sleep 0.3; done
settings '{"storageMode":"home","allowedUsers":["alice"]}'
LANIP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
# Two real client addresses on this Mac: loopback and the LAN address.
login() {
    curl -s -o /dev/null -w '%{http_code}' -X POST "https://$1:$PORT/v1/login" \
        -d "{\"user\":\"alice\",\"password\":\"$2\",\"device\":\"t\"}" ${3:+-H "X-Forwarded-For: $3"}
}
[ "$(login 127.0.0.1 secret)" = 200 ] && pass "right password signs in" || die "login failed"
for _ in 1 2 3 4 5; do login 127.0.0.1 wrong >/dev/null; done
[ "$(login 127.0.0.1 secret)" = 429 ] && pass "after 5 wrong passwords that address is blocked, even with the right one" || die "address not blocked"
[ "$(login 127.0.0.1 secret 203.0.113.9)" = 429 ] && pass "a forged X-Forwarded-For does not get around it" || die "header honoured"
[ "$(login "$LANIP" secret)" = 200 ] && pass "other addresses still sign in" || die "other address blocked"
api "$ADMIN" $URL/v1/admin/blocked | grep -q '"value":"127.0.0.1"' && pass "admin sees the blocked address" || die "blocked list"
api "$ADMIN" -X DELETE "$URL/v1/admin/blocked?kind=ip&value=127.0.0.1" >/dev/null
[ "$(login 127.0.0.1 secret)" = 200 ] && pass "admin can unblock it" || die "unblock"
for _ in 1 2 3 4 5; do login 127.0.0.1 wrong >/dev/null; login "$LANIP" wrong >/dev/null; done
api "$ADMIN" -X DELETE "$URL/v1/admin/blocked?kind=ip&value=127.0.0.1" >/dev/null
api "$ADMIN" -X DELETE "$URL/v1/admin/blocked?kind=ip&value=$LANIP" >/dev/null
[ "$(login 127.0.0.1 secret)" = 429 ] && pass "10 wrong passwords from several addresses lock the account for a while" || die "account not locked"
api "$ADMIN" -X DELETE "$URL/v1/admin/blocked?kind=user&value=alice" >/dev/null

echo "8. home address and the SSH gateway"
INFO=$(curl -s $URL/v1/info)
echo "$INFO" | grep -q "127.0.0.1:$PORT" && pass "the server announces its own home-network address, nothing to configure" || die "info: $INFO"
[ "$(code "$ADMIN" -X PUT $URL/v1/admin/settings -d '{"storageMode":"home","allowedUsers":["alice"],"externalEnabled":true}')" = 400 ] \
    && pass "external connection needs a gateway address" || die "accepted without gateway"
settings '{"storageMode":"home","allowedUsers":["alice"],"externalEnabled":true,"gatewayHost":"gw.example.test","gatewayPort":2222}'
GWTOKEN=$(api "$ADMIN" $URL/v1/admin/settings | sed -n 's/.*"gatewayToken":"\([0-9a-f]*\)".*/\1/p')
[ -n "$GWTOKEN" ] && pass "a gateway secret is generated" || die "no gateway token"
[ "$(curl -s -o /dev/null -w '%{http_code}' $URL/v1/gateway/authorized_keys)" = 401 ] && pass "the key list needs the gateway secret" || die "keys open"
# The gateway registers from another address than the Macs at home (here: this Mac's LAN IP).
GWURL=https://$LANIP:$PORT
curl -s -o /dev/null -X POST -H "Authorization: Bearer $GWTOKEN" --data 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestHostKey root@gw' $GWURL/v1/gateway/register
curl -s $URL/v1/info | grep -q '"external":true' && pass "after registration the server reports the external connection ready" || die "not ready"
LOGIN=$(curl -s -X POST $URL/v1/login -d '{"user":"alice","password":"secret","device":"Alice Mac"}')
echo "$LOGIN" | grep -q 'BEGIN OPENSSH PRIVATE KEY' && echo "$LOGIN" | grep -q '"host":"gw.example.test"' && echo "$LOGIN" | grep -q '"port":2222' \
    && pass "signing in at home hands this device its own SSH key and the gateway details" || die "login: $LOGIN"
KEYS=$(curl -s -H "Authorization: Bearer $GWTOKEN" $GWURL/v1/gateway/authorized_keys)
echo "$KEYS" | grep -q "^restrict,port-forwarding,permitopen=\"$LANIP:$PORT\" ssh-ed25519 " \
    && pass "the gateway gets the device key, limited to forwarding to this server" || die "keys: $KEYS"
AWAY=$(curl -s -X POST $GWURL/v1/login -d '{"user":"alice","password":"secret","device":"x"}')
echo "$AWAY" | grep -q '"token"' && ! echo "$AWAY" | grep -q 'PRIVATE KEY' && pass "through the gateway no key is handed out" || die "key from outside: $AWAY"
settings '{"storageMode":"home","allowedUsers":[],"externalEnabled":true,"gatewayHost":"gw.example.test","gatewayPort":2222}'
[ -z "$(curl -s -H "Authorization: Bearer $GWTOKEN" $GWURL/v1/gateway/authorized_keys | tr -d '\n')" ] \
    && pass "unticking the user removes the device keys from the gateway at once" || die "keys still listed"

echo "9. alternative: HTTPS through a reverse proxy"
[ "$(code "$ADMIN" -X PUT $URL/v1/admin/settings -d '{"allowedUsers":["alice"],"externalEnabled":true,"externalMode":"https","publicURL":"http://files.example.test"}')" = 400 ] \
    && pass "plain http is refused as the internet address" || die "http accepted"
settings '{"storageMode":"home","allowedUsers":["alice"],"externalEnabled":true,"externalMode":"https","publicURL":"https://files.example.test","trustedProxies":["127.0.0.1"]}'
INFO=$(curl -s $URL/v1/info)
echo "$INFO" | grep -q '"publicURL":"https:\\/\\/files.example.test"' && echo "$INFO" | grep -q '"external":false' \
    && pass "/v1/info offers the proxy address instead of the SSH gateway" || die "info: $INFO"
for _ in 1 2 3 4 5; do login 127.0.0.1 wrong 198.51.100.20 >/dev/null; done
[ "$(login 127.0.0.1 secret 198.51.100.20)" = 429 ] && [ "$(login 127.0.0.1 secret 198.51.100.21)" = 200 ] \
    && pass "behind a trusted proxy the real client is blocked, not the proxy" || die "proxy handling"

echo "10. device tokens"
settings '{"storageMode":"home","allowedUsers":["alice"]}'
named() { api "$ADMIN" -X POST "$URL/v1/admin/users/alice/token" -d "{\"device\":\"$1\"}" | sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p'; }
T1=$(named "Перший Mac"); T2=$(named "Другий Mac")
D1=$(api "$ADMIN" $URL/v1/admin/users | python3 -c 'import json,sys; print([d["id"] for u in json.load(sys.stdin)["users"] for d in u["deviceList"] if d["name"]=="Перший Mac"][0])')
[ "$(code "$ADMIN" -X DELETE $URL/v1/admin/devices/$D1)" = 200 ] || die "admin could not switch off one device"
N1=$(code "$T1" $URL/v1/libs); N2=$(code "$T2" $URL/v1/libs)
[ "$N1" = 401 ] && [ "$N2" = 200 ] \
    && pass "the admin switches off one device; the user's other devices keep working" || die "revoke one: $N1 $N2"
T3=$(token alice)
[ "$(code "$T3" -X DELETE $URL/v1/devices/self)" = 204 ] && [ "$(code "$T3" $URL/v1/libs)" = 401 ] \
    && pass "signing out on a device ends its token on the server" || die "self sign-out"
limits() { code "$ADMIN" -X PUT $URL/v1/admin/users/alice/limits -d "$1"; }
[ "$(limits '{"deviceIdleDays":1}')" = 200 ] || die "could not set alice's limits"
T4=$(token alice)
sqlite3 "$ROOT/.system/db.sqlite" "UPDATE device SET last_seen = strftime('%s','now') - 2*86400, created_at = strftime('%s','now') - 3*86400 WHERE id = (SELECT MAX(id) FROM device)"
api "$T4" $URL/v1/libs | grep -q "давно не з'єднувався" && [ "$(code "$T4" $URL/v1/libs)" = 401 ] \
    && pass "a device idle for longer than allowed has to sign in again" || die "idle device still accepted"

echo "11. upload limits"
T5=$(token alice)
ALIB2=$(api "$T5" $URL/v1/libs | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
upload() {  # upload SIZE_IN_4MB_CHUNKS: starts an upload of that size, prints the HTTP status
    local body; body=$(python3 -c '
import hashlib, json, os, sys
hs = [os.urandom(32) for _ in range(int(sys.argv[1]))]
print(json.dumps({"path": "big-%s.bin" % os.urandom(4).hex(), "mtimeNs": 0, "contentHash": hashlib.sha256(b"".join(hs)).hexdigest(),
                  "chunks": [{"h": h.hex(), "l": 4 << 20} for h in hs], "device": "t"}))' "$1")
    code "$T5" -X POST $URL/v1/libs/$ALIB2/uploads -d "$body"
}
limits '{"maxFileSizeGB":1}' >/dev/null
[ "$(upload 300)" = 413 ] && [ "$(upload 10)" = 200 ] && pass "a file over the size limit is refused (413), a small one is not" || die "size limit"
limits '{"quotaGB":1}' >/dev/null
[ "$(upload 150)" = 200 ] && [ "$(upload 150)" = 507 ] \
    && pass "the quota counts open uploads too: the second 600 MB upload is refused (507)" || die "quota"
api "$ADMIN" $URL/v1/admin/users | grep -q '"usedBytes":[1-9]' && pass "the settings page gets each user's used space" || die "usedBytes"
settings '{"storageMode":"home","allowedUsers":["alice"]}'
grep -q '"quotaGB":1' "$WORK/users.json" && pass "saving the other settings keeps each user's limits" || die "limits lost: $(cat "$WORK/users.json")"
[ "$(limits '{"quotaGB":0}')" = 400 ] && pass "a limit must be positive" || die "zero quota accepted"
limits '{}' >/dev/null
api "$ADMIN" $URL/v1/admin/users | python3 -c 'import json,sys; sys.exit(0 if all(u.get("limits") is None for u in json.load(sys.stdin)["users"]) else 1)' \
    && [ "$(upload 300)" = 200 ] && pass "without limits a user has none (a 1.2 GB file is accepted)" || die "empty limits"

echo
echo "all checks passed"
