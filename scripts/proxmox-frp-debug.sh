#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${DOMAIN:-seroncheng.ytcc.school}"
LOCAL_IP="${LOCAL_IP:-192.168.123.10}"
LOCAL_PORT="${LOCAL_PORT:-8006}"

mask_token() {
  sed -E 's/(token *= *")[^"]+/\1***REDACTED***/g; s/(FRP_TOKEN=).+/\1***REDACTED***/g; s/(AUTH_PASSWORD_SHA256=).+/\1***REDACTED***/g; s/(SESSION_SECRET=).+/\1***REDACTED***/g'
}

section() {
  printf '\n===== %s =====\n' "$1"
}

try_cmd() {
  local title="$1"
  shift
  section "$title"
  "$@" || true
}

http_probe() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -k -I --max-time 8 "$url" || true
  elif command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate --spider -S -T 8 -t 1 "$url" 2>&1 || true
  else
    echo "curl/wget not found"
  fi
}

tcp_probe() {
  local host="$1"
  local port="$2"
  timeout 4 bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1 \
    && echo "OK: ${host}:${port} 可连接" \
    || echo "FAIL: ${host}:${port} 不可连接"
}

section "基本判断"
echo "如果登录后出现 502/Bad Gateway：通常是公网 frps 后端 127.0.0.1:18006 没起来，也就是本地 frpc 没连上。"
echo "如果登录后 Proxmox 页面能开但 noVNC 黑屏：看 Nginx WebSocket 和 Cloudflare WebSocket。"

try_cmd "服务状态" systemctl --no-pager --full status frps proxmox-auth-gate nginx frpc

section "公网服务器端口"
tcp_probe 127.0.0.1 9090
tcp_probe 127.0.0.1 18006
tcp_probe 127.0.0.1 7500
tcp_probe 127.0.0.1 7000

section "HTTP 探测"
echo "[登录网关，无 cookie 正常应返回 401]"
http_probe "http://127.0.0.1:9090/check"
echo
echo "[Proxmox 隧道，正常应看到 pve-api-daemon 或 Proxmox HTML；失败说明 frpc 未连上]"
http_probe "https://127.0.0.1:18006/"
echo
echo "[公网域名，未登录正常应 302 到 /login]"
http_probe "https://${DOMAIN}/"

try_cmd "frps 配置" bash -c 'test -f /etc/frp/frps.toml && mask_token < /etc/frp/frps.toml || true'
try_cmd "frpc 配置" bash -c 'test -f /etc/frp/frpc.toml && mask_token < /etc/frp/frpc.toml || true'
try_cmd "客户端变量" bash -c 'test -f /root/proxmox-frp-client.env && mask_token < /root/proxmox-frp-client.env || true'

try_cmd "frps 最近日志" journalctl -u frps -n 80 --no-pager
try_cmd "frpc 最近日志" journalctl -u frpc -n 80 --no-pager
try_cmd "Nginx 最近错误" tail -n 80 /var/log/nginx/error.log

section "本地机器检查提示"
cat <<EOF_HINT
如果你是在本地机器上运行这个 debug 脚本，请确认：
1. 能访问 Proxmox：
   wget --no-check-certificate -qO- https://${LOCAL_IP}:${LOCAL_PORT}/ | head

2. frpc 正在运行：
   systemctl status frpc
   journalctl -u frpc -f

3. frpc 的 token 必须和公网服务器 /etc/frp/frps.toml 里的 auth.token 一致。

如果你是在公网服务器上运行这个 debug 脚本，最关键看上面的：
  127.0.0.1:18006 是否可连接
如果不可连接，先去本地机器执行服务端部署完成时打印的 frpc 一键命令。
EOF_HINT
