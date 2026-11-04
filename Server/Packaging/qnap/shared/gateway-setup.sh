#!/bin/bash
# FSDrive: sets up an existing Debian/Ubuntu SSH server as the gateway for using
# FSDrive away from home. Run as root on the gateway. The settings page fills in the
# values below.
#
# What it adds, and nothing else:
#   - user @USER@: no password, no shell, may only forward to the FSDrive server;
#   - /usr/local/bin/fsdrive-authorized-keys: asks FSDrive on the NAS (over TLS, checking
#     its pinned key) which device keys are allowed right now (a device switched off in
#     QTS loses access immediately);
#   - /etc/ssh/sshd_config.d/20-fsdrive.conf with a Match block for @USER@ only.
set -euo pipefail

NAS_HOST=@NAS_HOST@
NAS_PORT=@NAS_PORT@
TOKEN=@TOKEN@
TUNNEL_USER=@USER@
# FSDrive speaks TLS only with a certificate of its own; the gateway checks its key.
PIN='@PIN@'

command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl; }

# Before 0.4 FSDrive was called Rimfile: a gateway set up then is set up anew here.
rm -f /etc/ssh/sshd_config.d/20-rimfile.conf /usr/local/bin/rimfile-authorized-keys
rm -rf /etc/rimfile
if id rimfile-keys >/dev/null 2>&1; then userdel rimfile-keys; fi

id fsdrive-keys >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin fsdrive-keys
if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$TUNNEL_USER"
fi
usermod -p '*' "$TUNNEL_USER"   # no password, but not locked: keys only

install -d -m 0750 -o root -g fsdrive-keys /etc/fsdrive
umask 027
cat > /etc/fsdrive/gateway.conf <<CONF
NAS_HOST=$NAS_HOST
NAS_PORT=$NAS_PORT
PIN='$PIN'
CONF
# The secret goes to curl as a header file: on its command line ps would show it.
printf 'Authorization: Bearer %s\n' "$TOKEN" > /etc/fsdrive/auth-header
chown root:fsdrive-keys /etc/fsdrive/gateway.conf /etc/fsdrive/auth-header
umask 022

cat > /usr/local/bin/fsdrive-authorized-keys <<'KEYS'
#!/bin/bash
# AuthorizedKeysCommand for the FSDrive tunnel user (see /etc/ssh/sshd_config.d/20-fsdrive.conf).
. /etc/fsdrive/gateway.conf
# TLS to the NAS, accepted only with FSDrive's own key (-k: no authority signs it).
exec curl -sf --max-time 5 --tlsv1.3 -k --pinnedpubkey "$PIN" -H @/etc/fsdrive/auth-header \
    "https://$NAS_HOST:$NAS_PORT/v1/gateway/authorized_keys"
KEYS
chmod 0755 /usr/local/bin/fsdrive-authorized-keys

cat > /etc/ssh/sshd_config.d/20-fsdrive.conf <<CONF
# FSDrive: the tunnel user may only forward to the FSDrive server (the key options
# from FSDrive name the exact address). No shell, no SFTP, no other forwarding.
Match User $TUNNEL_USER
    AuthorizedKeysFile none
    AuthorizedKeysCommand /usr/local/bin/fsdrive-authorized-keys
    AuthorizedKeysCommandUser fsdrive-keys
    AllowTcpForwarding local
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
    ForceCommand /usr/sbin/nologin
CONF

install -d -m 0755 /run/sshd   # sshd -t needs it; socket-activated systems create it per connection
sshd -t
# Socket-activated sshd (Debian 13+) starts on the next connection with the new config.
# A daemon still running from before keeps the old one, and a reload makes it rebind the
# port the socket holds and exit: stop it instead (sessions stay up, the socket takes
# over). Otherwise reload the daemon so existing sessions stay up.
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl stop ssh.service 2>/dev/null || true
elif systemctl is-active --quiet ssh 2>/dev/null; then
    systemctl reload ssh
elif systemctl is-active --quiet sshd 2>/dev/null; then
    systemctl reload sshd
elif [ -f /run/sshd.pid ]; then
    kill -HUP "$(cat /run/sshd.pid)"
fi

# Tell FSDrive this gateway's host key, so Macs connect only to it.
KEY=$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)
status=$(curl -s --max-time 10 --tlsv1.3 -k --pinnedpubkey "$PIN" -H @/etc/fsdrive/auth-header -H "Content-Type: text/plain" \
    --data-binary "$KEY" -o /dev/null -w '%{http_code}' "https://$NAS_HOST:$NAS_PORT/v1/gateway/register" || true)
case "$status" in 204) echo "FSDrive gateway ready." ;; *) echo "Registration failed: HTTP $status" >&2; exit 1 ;; esac
