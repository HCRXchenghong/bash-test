#!/usr/bin/env bash
set -euo pipefail

SERVER_IP="${SERVER_IP:-38.76.171.98}"
FRP_VERSION="${FRP_VERSION:-0.69.0}"
FRP_ARCH="${FRP_ARCH:-linux_amd64}"
FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_${FRP_ARCH}.tar.gz"
LOCAL_IP="${LOCAL_IP:-192.168.123.10}"
LOCAL_PORT="${LOCAL_PORT:-8006}"
REMOTE_PORT="${REMOTE_PORT:-18006}"
FRP_TOKEN="${FRP_TOKEN:-}"

if [[ ${EUID} -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0" >&2
  exit 1
fi

if [[ -z "${FRP_TOKEN}" ]]; then
  read -r -s -p "请输入服务端生成的 FRP_TOKEN: " FRP_TOKEN
  echo
fi

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wget tar
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wget tar
  elif command -v yum >/dev/null 2>&1; then
    yum install -y wget tar
  fi
}

install_packages

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
wget -O "${tmpdir}/frp.tar.gz" "${FRP_URL}"
tar -xzf "${tmpdir}/frp.tar.gz" -C "${tmpdir}"
install -m 0755 "${tmpdir}/frp_${FRP_VERSION}_${FRP_ARCH}/frpc" /usr/local/bin/frpc

install -d -m 0755 /etc/frp
cat >/etc/frp/frpc.toml <<EOF_FRPC
serverAddr = "${SERVER_IP}"
serverPort = 7000

auth.token = "${FRP_TOKEN}"
transport.tls.enable = true

[[proxies]]
name = "proxmox-web-8006"
type = "tcp"
localIP = "${LOCAL_IP}"
localPort = ${LOCAL_PORT}
remotePort = ${REMOTE_PORT}
EOF_FRPC
chmod 600 /etc/frp/frpc.toml

cat >/etc/systemd/system/frpc.service <<'EOF_SERVICE'
[Unit]
Description=frp client for Proxmox web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl enable --now frpc

echo
echo "本地 frpc 部署完成。"
echo "检查日志：journalctl -u frpc -f"
