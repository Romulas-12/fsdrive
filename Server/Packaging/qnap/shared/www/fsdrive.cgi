#!/bin/sh
# Backend of the FSDrive settings page in QTS. Only signed-in QTS administrators get
# an answer: the session (NAS_SID cookie) is checked with QTS itself. Settings calls
# are forwarded to fsdrived's admin API on localhost with the server token.
CONF=/etc/config/qpkg.conf
QPKG_ROOT=$(/sbin/getcfg FSDrive Install_Path -f $CONF)
PORT=$(/sbin/getcfg FSDrive Service_Port -d 8740 -f $CONF)
ROOT=$(/sbin/getcfg FSDrive DataRoot -d "$QPKG_ROOT/data" -f $CONF)
trap 'rm -f /tmp/fsdrive-settings.$$ /tmp/fsdrive-auth.$$' EXIT

reply() {
    printf 'Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n'
    [ -n "$2" ] && printf 'Status: %s\r\n' "$2"
    printf '\r\n%s\n' "$1"
    exit 0
}

param() { echo "$QUERY_STRING" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1 | sed 's/%3A/:/gi' | tr -cd 'A-Za-z0-9_.:-'; }

# Take the request body first: anything run below inherits stdin and could eat it.
BODY_FILE=/tmp/fsdrive-settings.$$
if [ "$REQUEST_METHOD" = "POST" ]; then head -c "${CONTENT_LENGTH:-0}" > "$BODY_FILE"; fi

# Only the cookie: a session ID in the URL would end up in logs and browser history.
SID=$(echo "$HTTP_COOKIE" | tr ';' '\n' | sed -n 's/^ *NAS_SID=//p' | head -1 | tr -cd 'A-Za-z0-9_-')
# authLogin.cgi reads stdin when it has a body length, so give it neither.
AUTH=$(QUERY_STRING="sid=$SID" REQUEST_METHOD=GET CONTENT_LENGTH= /home/httpd/cgi-bin/authLogin.cgi </dev/null 2>/dev/null)
echo "$AUTH" | grep -q '<authPassed><!\[CDATA\[1\]\]></authPassed>' || reply '{"error":"Увійдіть у QTS"}' "401 Unauthorized"
echo "$AUTH" | grep -q '<isAdmin><!\[CDATA\[1\]\]></isAdmin>' || reply '{"error":"Лише для адміністраторів"}' "403 Forbidden"

# Changes need a header other sites cannot send without a CORS preflight (CSRF guard).
mutating() {
    [ "$REQUEST_METHOD" = "POST" ] && [ "$HTTP_X_REQUESTED_WITH" = "fsdrive" ] || reply '{"error":"bad request"}' "400 Bad Request"
}

ADMIN_TOKEN=$(sed -n 's/.*"token" *: *"\([0-9a-f]*\)".*/\1/p' "$ROOT/.system/config.json" 2>/dev/null)
# The token goes to curl in a file, not on its command line, where `ps` shows it to
# every local user.
AUTH_FILE=/tmp/fsdrive-auth.$$
(umask 077; printf 'Authorization: Bearer %s\n' "$ADMIN_TOKEN" > "$AUTH_FILE")
# fsdrived speaks TLS only; its self-made certificate is checked by its pinned key.
PIN=$(cat "$ROOT/.system/tls/pin" 2>/dev/null)
CODE=$(cat "$ROOT/.system/tls/code" 2>/dev/null)
fsdrived_curl() { curl -s -k --pinnedpubkey "$PIN" -H @"$AUTH_FILE" "$@"; }
fsdrived_api() {
    method=$1; path=$2; shift 2
    out=$(fsdrived_curl -m 120 </dev/null -X "$method" -H "Content-Type: application/json" \
        -w '\n%{http_code}' "$@" "https://127.0.0.1:$PORT$path") || reply '{"error":"Сервіс FSDrive не відповідає"}' "502 Bad Gateway"
    code=$(echo "$out" | tail -n 1)
    body=$(echo "$out" | sed '$d')
    case "$code" in 2*) reply "$body" ;; *) reply "$body" "$code Error" ;; esac
}

status_reply() {
    STATUS=$(/etc/init.d/fsdrive.sh status)
    case "$STATUS" in running*) RUNNING=true ;; *) RUNNING=false ;; esac
    ENABLED=$(/sbin/getcfg FSDrive Enable -u -d FALSE -f $CONF)
    [ "$ENABLED" = "TRUE" ] && ENABLED=true || ENABLED=false
    VERSION=$(/sbin/getcfg FSDrive Version -f $CONF)
    reply "{\"running\":$RUNNING,\"enabled\":$ENABLED,\"version\":\"$VERSION\",\"port\":$PORT,\"code\":\"$CODE\"}"
}

case "$(param action)" in
  status)
    status_reply
    ;;
  service)
    # Switches the app on or off the same way App Center does: the Enable flag, then the
    # service script. The server runs in its own session so it outlives this request.
    mutating
    SETSID=""
    command -v setsid >/dev/null 2>&1 && SETSID=setsid
    case "$(param state)" in
      on)  /sbin/setcfg FSDrive Enable TRUE -f $CONF
           $SETSID /etc/init.d/fsdrive.sh start </dev/null >/dev/null 2>&1 ;;
      off) /sbin/setcfg FSDrive Enable FALSE -f $CONF
           /etc/init.d/fsdrive.sh stop </dev/null >/dev/null 2>&1 ;;
      *)   reply '{"error":"bad request"}' "400 Bad Request" ;;
    esac
    status_reply
    ;;
  shares)
    # Shared folders from the SMB config, for the "separate folder" option.
    LIST=$(awk -F' = ' '
        /^\[.*\]$/ { name = substr($0, 2, length($0) - 2); next }
        $1 == "path" && name != "global" && name != "homes" && name != "printers" && name !~ /^(Web|Multimedia|Recordings|Download|Container|TimeMachine)$/ {
            gsub(/"/, "", name); printf "%s{\"name\":\"%s\",\"path\":\"/share/%s\"}", sep, name, name; sep = ","
        }' /etc/config/smb.conf)
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
    TOKEN=$(echo "$S" | sed -n 's/.*"gatewayToken":"\([0-9a-f]*\)".*/\1/p')
    USER_=$(echo "$S" | sed -n 's/.*"gatewayUser":"\([A-Za-z0-9_.-]*\)".*/\1/p')
    [ -n "$TOKEN" ] || reply '{"error":"Спершу ввімкніть зовнішнє з'"'"'єднання і збережіть"}' "409 Conflict"
    NAS_HOST=$(echo "${HTTP_HOST%:*}" | tr -cd 'A-Za-z0-9_.-')
    printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
    # The pin is base64 (A-Z a-z 0-9 + / =): "|" cannot occur in it.
    sed -e "s/@NAS_HOST@/$NAS_HOST/" -e "s/@NAS_PORT@/$PORT/" -e "s/@TOKEN@/$TOKEN/" -e "s/@USER@/${USER_:-fsdrive}/g" \
        -e "s|@PIN@|$PIN|" "$QPKG_ROOT/gateway-setup.sh"
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
