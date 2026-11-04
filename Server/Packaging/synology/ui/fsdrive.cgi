#!/bin/sh
# Backend of the FSDrive settings page in DSM. It runs as the package user. Only signed-in
# DSM administrators get an answer: the session (cookie and SynoToken) is checked by DSM
# itself. Settings calls are forwarded to fsdrived's admin API on localhost with the
# server token, which the root part (bin/fsdrive-supervise) hands over in var/cgi.
PKG=/var/packages/FSDrive
TARGET=$PKG/target
VAR=$PKG/var
PORT=$(cat "$VAR/port" 2>/dev/null | tr -cd 0-9); PORT=${PORT:-8740}
trap 'rm -f "$BODY_FILE" "$AUTH_FILE"' EXIT

reply() {
    printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n'
    [ -n "$2" ] && printf 'Status: %s\r\n' "$2"
    printf '\r\n%s\n' "$1"
    exit 0
}

param() { echo "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 | sed 's/%3A/:/gi' | tr -cd 'A-Za-z0-9_.:-'; }

# Take the request body first: anything run below inherits stdin and could eat it.
BODY_FILE=$(mktemp "$VAR/tmp-body.XXXXXX" 2>/dev/null || mktemp)
if [ "$REQUEST_METHOD" = "POST" ]; then head -c "${CONTENT_LENGTH:-0}" > "$BODY_FILE"; fi

# DSM names the user of a valid session (cookie plus the SynoToken header, which other
# sites cannot send: that is also the CSRF guard).
TOKEN_Q=$(printf %s "$HTTP_X_SYNO_TOKEN" | tr -cd 'A-Za-z0-9_.-')
DSM_USER=$(QUERY_STRING="SynoToken=$TOKEN_Q" REQUEST_METHOD=GET CONTENT_LENGTH= /usr/syno/synoman/webman/modules/authenticate.cgi </dev/null 2>/dev/null | tr -cd 'A-Za-z0-9_.@\\-')
[ -n "$DSM_USER" ] || reply '{"error":"Увійдіть у DSM"}' "401 Unauthorized"
id -Gn "$DSM_USER" 2>/dev/null | tr ' ' '\n' | grep -qx administrators || reply '{"error":"Лише для адміністраторів"}' "403 Forbidden"

mutating() {
    [ "$REQUEST_METHOD" = "POST" ] && [ "$HTTP_X_REQUESTED_WITH" = "fsdrive" ] || reply '{"error":"bad request"}' "400 Bad Request"
}

ADMIN_TOKEN=$(cat "$VAR/cgi/token" 2>/dev/null)
PIN=$(cat "$VAR/cgi/pin" 2>/dev/null)
CODE=$(cat "$VAR/cgi/code" 2>/dev/null | tr -cd 'A-Za-z0-9 -')
# The token goes to curl in a file, not on its command line, where `ps` shows it to
# every local user.
AUTH_FILE=$(mktemp "$VAR/tmp-auth.XXXXXX" 2>/dev/null || mktemp)
chmod 600 "$AUTH_FILE"
printf 'Authorization: Bearer %s\n' "$ADMIN_TOKEN" > "$AUTH_FILE"
# fsdrived speaks TLS only; its self-made certificate is checked by its pinned key.
fsdrived_curl() { curl -s -k --pinnedpubkey "$PIN" -H @"$AUTH_FILE" "$@"; }
fsdrived_api() {
    method=$1; path=$2; shift 2
    out=$(fsdrived_curl -m 120 </dev/null -X "$method" -H "Content-Type: application/json" \
        -w '\n%{http_code}' "$@" "https://127.0.0.1:$PORT$path") || reply '{"error":"Сервіс FSDrive не відповідає"}' "502 Bad Gateway"
    code=$(echo "$out" | tail -n 1)
    body=$(echo "$out" | sed '$d')
    case "$code" in 2*) reply "$body" ;; *) reply "$body" "$code Error" ;; esac
}

alive() {
    pid=$(cat "$1" 2>/dev/null)
    [ -n "$pid" ] && [ -d "/proc/$pid" ] && grep -q "$2" "/proc/$pid/cmdline" 2>/dev/null
}

case "$(param action)" in
  status)
    # enabled: Package Center started the package. rootReady: the one-time root setup
    # is done and its service runs. running: fsdrived itself answers.
    alive "$VAR/fsdrived.pid" fsdrived && RUNNING=true || RUNNING=false
    alive "$VAR/supervisor.pid" fsdrive-supervise && ROOT_READY=true || ROOT_READY=false
    [ -f "$VAR/run" ] && ENABLED=true || ENABLED=false
    VERSION=$(sed -n 's/^version="\([^"-]*\).*/\1/p' "$PKG/INFO")
    reply "{\"running\":$RUNNING,\"enabled\":$ENABLED,\"rootReady\":$ROOT_READY,\"version\":\"$VERSION\",\"port\":$PORT,\"code\":\"$CODE\",\"setup\":\"$TARGET/bin/fsdrive-root.sh\"}"
    ;;
  shares)
    # Shared folders from DSM's SMB config, for the "separate folder" option.
    LIST=$(awk '
        /^\[.*\]$/ { name = substr($0, 2, length($0) - 2); next }
        /^[ \t]*path[ \t]*=/ {
            path = $0; sub(/^[ \t]*path[ \t]*=[ \t]*/, "", path)
            if (name == "global" || name == "homes" || name == "printers" || name ~ /^(web|web_packages|docker|NetBackup|surveillance|ActiveBackupforBusiness|chat|PlexMediaServer)$/ || name ~ /^usbshare/) next
            gsub(/["\\]/, "", name); gsub(/["\\]/, "", path)
            printf "%s{\"name\":\"%s\",\"path\":\"%s\"}", sep, name, path; sep = ","
        }' /etc/samba/smb.share.conf 2>/dev/null)
    reply "{\"shares\":[$LIST]}"
    ;;
  settings)
    if [ "$REQUEST_METHOD" = "POST" ]; then
        mutating
        fsdrived_api PUT /v1/admin/settings --data-binary @"$BODY_FILE"
    fi
    fsdrived_api GET /v1/admin/settings
    ;;
  users)
    fsdrived_api GET /v1/admin/users
    ;;
  rebind)
    mutating
    fsdrived_api POST "/v1/admin/users/$(param user)/rebind"
    ;;
  gateway-script)
    # Setup script for the SSH gateway with this server's address and secret filled in.
    # The NAS address is the one this page was opened with, as the gateway sees it.
    S=$(fsdrived_curl -m 10 </dev/null "https://127.0.0.1:$PORT/v1/admin/settings")
    GW_TOKEN=$(echo "$S" | sed -n 's/.*"gatewayToken":"\([0-9a-f]*\)".*/\1/p')
    GW_USER=$(echo "$S" | sed -n 's/.*"gatewayUser":"\([A-Za-z0-9_.-]*\)".*/\1/p')
    [ -n "$GW_TOKEN" ] || reply '{"error":"Спершу ввімкніть зовнішнє з'"'"'єднання і збережіть"}' "409 Conflict"
    NAS_HOST=$(echo "${HTTP_HOST%:*}" | tr -cd 'A-Za-z0-9_.-')
    printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
    # The pin is base64 (A-Z a-z 0-9 + / =): "|" cannot occur in it.
    sed -e "s/@NAS_HOST@/$NAS_HOST/" -e "s/@NAS_PORT@/$PORT/" -e "s/@TOKEN@/$GW_TOKEN/" -e "s/@USER@/${GW_USER:-fsdrive}/g" \
        -e "s|@PIN@|$PIN|" "$TARGET/bin/gateway-setup.sh"
    exit 0
    ;;
  blocked)
    fsdrived_api GET /v1/admin/blocked
    ;;
  unblock)
    mutating
    fsdrived_api DELETE "/v1/admin/blocked?kind=$(param kind)&value=$(param value)"
    ;;
  revoke)
    mutating
    fsdrived_api DELETE "/v1/admin/users/$(param user)/devices"
    ;;
  limits)
    mutating
    fsdrived_api PUT "/v1/admin/users/$(param user)/limits" --data-binary @"$BODY_FILE"
    ;;
  revoke-device)
    mutating
    fsdrived_api DELETE "/v1/admin/devices/$(param id)"
    ;;
  *)
    reply '{"error":"unknown action"}' "400 Bad Request"
    ;;
esac
