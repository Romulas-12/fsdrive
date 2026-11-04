#!/bin/sh
# One-time setup of FSDrive's root part on DSM; run as root. DSM 7 does not let a
# third-party package run as root, and fsdrived needs to (see fsdrive-supervise).
# This installs a systemd service that starts and stops fsdrived as Package Center says.
#
# Run it once over SSH:   sudo /var/packages/FSDrive/target/bin/fsdrive-root.sh
# or, to have it checked on every boot (it survives DSM updates that reset /etc), as a
# Task Scheduler task: Triggered Task → User-defined script, user root, event Boot-up.
# Running it again changes nothing.
set -e
[ "$(id -u)" = 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }
TARGET=/var/packages/FSDrive/target
[ -x "$TARGET/bin/fsdrive-supervise" ] || { echo "FSDrive is not installed" >&2; exit 1; }
UNIT=/etc/systemd/system/fsdrive.service
NEW=$(cat <<EOF
[Unit]
Description=FSDrive file sync (root part of the FSDrive package)
After=network-online.target syno-volume.target
StartLimitIntervalSec=0

[Service]
ExecStart=$TARGET/bin/fsdrive-supervise
Restart=always
RestartSec=3
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
)
if [ "$(cat "$UNIT" 2>/dev/null)" != "$NEW" ]; then
    printf '%s\n' "$NEW" > "$UNIT"
    chmod 644 "$UNIT"
    systemctl daemon-reload
fi
systemctl enable fsdrive.service >/dev/null 2>&1
systemctl start fsdrive.service
echo "FSDrive: the root part is set up."
