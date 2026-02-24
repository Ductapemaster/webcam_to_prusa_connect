#!/bin/bash
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

cat > /lib/systemd/system/camtoprusaconnect.service <<EOL
[Unit]
Description=Uploads snapshots from cameras to Prusa Connect
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SCRIPT_DIR}/webcam_to_prusa_connect.sh
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=prusa-cam

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable camtoprusaconnect.service
systemctl start camtoprusaconnect.service
echo "Service started. Monitor with: journalctl -u camtoprusaconnect -f"
