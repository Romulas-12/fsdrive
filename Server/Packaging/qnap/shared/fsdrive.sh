#!/bin/sh
# QNAP service script for fsdrived: start | stop | restart | status | token
CONF=/etc/config/qpkg.conf
QPKG_NAME="FSDrive"
QPKG_ROOT=$(/sbin/getcfg $QPKG_NAME Install_Path -f $CONF)
PORT=$(/sbin/getcfg $QPKG_NAME Service_Port -d 8740 -f $CONF)
PIDFILE=/var/run/fsdrive.pid
WEB_LINK=/home/httpd/cgi-bin/qpkg/$QPKG_NAME
LOG="$QPKG_ROOT/fsdrived.log"
export QNAP_QPKG=$QPKG_NAME

# Database and config live in the app folder; where user files go is chosen on the
# settings page (home folders or a shared folder). Override with:
# setcfg FSDrive DataRoot <path> -f /etc/config/qpkg.conf
data_root() {
    /sbin/getcfg $QPKG_NAME DataRoot -d "$QPKG_ROOT/data" -f $CONF
}

# Bonjour: lets Macs find this server with "Find server" (QTS runs avahi; its services
# folder is in RAM, so the file is written on every start).
AVAHI_FILE=/etc/avahi/services/fsdrive.service
publish_bonjour() {
    [ -d /etc/avahi/services ] || return 0
    VERSION=$(/sbin/getcfg $QPKG_NAME Version -f $CONF)
    MODEL=$(sed -n 's/.*displayModel=\([^,<]*\).*/\1/p' /etc/avahi/services/qdiscover.service 2>/dev/null | head -1)
    cat > "$AVAHI_FILE" <<EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
<name replace-wildcards="yes">%h</name>
<service>
<type>_fsdrive._tcp</type>
<port>$PORT</port>
<txt-record>version=$VERSION</txt-record>
<txt-record>model=${MODEL:-QNAP}</txt-record>
</service>
</service-group>
EOF
    chmod 644 "$AVAHI_FILE"   # avahi runs as guest; the service umask would hide the file
    killall -HUP avahi-daemon 2>/dev/null
}
unpublish_bonjour() {
    [ -f "$AVAHI_FILE" ] || return 0
    rm -f "$AVAHI_FILE"
    killall -HUP avahi-daemon 2>/dev/null
}

# Before 0.4 this package was called Rimfile. On the first start its data comes over:
# the old service stops and is disabled, the data folder moves into this package (or,
# if it was set elsewhere with DataRoot, stays there), and the server rewrites the paths
# its database keeps. Each user's ~/Rimfile becomes ~/FSDrive when fsdrived starts.
# The Rimfile app can then be removed in App Center.
migrate_from_rimfile() {
    OLD_QPKG=$(/sbin/getcfg Rimfile Install_Path -f $CONF)
    [ -n "$OLD_QPKG" ] || return 0
    OLD_DATA=$(/sbin/getcfg Rimfile DataRoot -d "$OLD_QPKG/data" -f $CONF)
    [ -f "$OLD_DATA/.system/config.json" ] || return 0
    log_msg "moving over from Rimfile ($OLD_DATA)"
    [ -x "$OLD_QPKG/rimfile.sh" ] && "$OLD_QPKG/rimfile.sh" stop
    /sbin/setcfg Rimfile Enable FALSE -f $CONF
    OLD_PORT=$(/sbin/getcfg Rimfile Service_Port -f $CONF)
    [ -n "$OLD_PORT" ] && /sbin/setcfg $QPKG_NAME Service_Port "$OLD_PORT" -f $CONF && PORT=$OLD_PORT
    case "$OLD_DATA" in
      "$OLD_QPKG"/*)
        # Inside the old app folder, which App Center deletes with the app: move it.
        NEW_DATA="$QPKG_ROOT/data"
        OLD_REAL=$(readlink -f "$OLD_DATA")
        rmdir "$NEW_DATA" 2>/dev/null
        [ -e "$NEW_DATA" ] && { log_msg "$NEW_DATA already exists, Rimfile data left in $OLD_DATA"; return 1; }
        mv "$OLD_DATA" "$NEW_DATA" || { log_msg "cannot move $OLD_DATA"; return 1; }
        if ! "$QPKG_ROOT/fsdrived" relocate --root "$NEW_DATA" --from "$OLD_REAL" >> "$LOG" 2>&1; then
            mv "$NEW_DATA" "$OLD_DATA"
            log_msg "relocate failed, Rimfile data put back in $OLD_DATA"
            return 1
        fi
        ;;
      *)
        /sbin/setcfg $QPKG_NAME DataRoot "$OLD_DATA" -f $CONF
        ;;
    esac
    log_msg "Rimfile data taken over; remove the Rimfile app in App Center"
}

is_running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

log_msg() { echo "$(date '+%Y-%m-%dT%H:%M:%S') fsdrive.sh: $*" >> "$LOG"; }

case "$1" in
  start)
    ENABLED=$(/sbin/getcfg $QPKG_NAME Enable -u -d FALSE -f $CONF)
    if [ "$ENABLED" != "TRUE" ]; then
        echo "$QPKG_NAME is disabled."
        exit 1
    fi
    # The QTS web root lives in RAM, so the settings page link is made on every start.
    ln -sfn "$QPKG_ROOT/www" "$WEB_LINK"
    is_running && exit 0
    # A failed move must not end in a fresh, empty server beside the old data.
    migrate_from_rimfile || exit 1
    ROOT=$(data_root)
    # The log must not hold secrets: init prints the token, so it goes nowhere.
    # Read it later with: fsdrive.sh token
    touch "$LOG" && chmod 600 "$LOG"
    if [ ! -f "$ROOT/.system/config.json" ]; then
        "$QPKG_ROOT/fsdrived" init --root "$ROOT" --owner admin > /dev/null 2>> "$LOG" || { log_msg "init failed"; exit 1; }
        log_msg "initialized $ROOT"
    fi
    umask 007
    # Keep the log small: one rotation at 10 MB.
    [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 10485760 ] && mv "$LOG" "$LOG.1"
    ulimit -n 8192 2>/dev/null
    # Low CPU priority so a large sync never makes the NAS sluggish.
    NICE=""
    command -v nice >/dev/null 2>&1 && NICE="nice -n 10"
    $NICE "$QPKG_ROOT/fsdrived" serve --root "$ROOT" --host 0.0.0.0 --port "$PORT" >> "$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 1
    is_running || { log_msg "fsdrived exited at start, see above"; exit 1; }
    publish_bonjour
    ;;

  stop)
    if is_running; then
        PID=$(cat "$PIDFILE")
        kill "$PID"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 10 ]; do sleep 1; i=$((i + 1)); done
        kill -9 "$PID" 2>/dev/null
    fi
    rm -f "$PIDFILE"
    unpublish_bonjour
    ;;

  restart)
    $0 stop
    $0 start
    ;;

  status)
    if is_running; then echo "running (pid $(cat "$PIDFILE")), data: $(data_root), port $PORT"; else echo "stopped"; exit 1; fi
    ;;

  token)
    # Access token for the Mac app (admin only: the config file is mode 600).
    sed -n 's/.*"token" *: *"\([0-9a-f]*\)".*/\1/p' "$(data_root)/.system/config.json"
    ;;

  remove)
    rm -f "$WEB_LINK"
    ;;

  *)
    echo "Usage: $0 {start|stop|restart|status|token}"
    exit 1
esac

exit 0
