#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${DOMAIN:-seroncheng.ytcc.school}"
SERVER_IP="${SERVER_IP:-38.76.171.98}"
GATE_USER="${GATE_USER:-lb-ch}"
GATE_PASSWORD="${GATE_PASSWORD:-}"
FRP_VERSION="${FRP_VERSION:-0.69.0}"
FRP_ARCH="${FRP_ARCH:-linux_amd64}"
FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_${FRP_ARCH}.tar.gz"
FRP_TOKEN="${FRP_TOKEN:-}"

if [[ ${EUID} -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0" >&2
  exit 1
fi

if [[ -z "${GATE_PASSWORD}" ]]; then
  read -r -s -p "请输入登录页密码: " GATE_PASSWORD
  echo
fi

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx python3 openssl wget tar
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y nginx python3 openssl wget tar
  elif command -v yum >/dev/null 2>&1; then
    yum install -y nginx python3 openssl wget tar
  else
    echo "不支持的系统：请先安装 nginx python3 openssl wget tar" >&2
    exit 1
  fi
}

rand_hex() {
  openssl rand -hex 32
}

sha256_text() {
  python3 - "$1" <<'PY'
import hashlib
import sys
print(hashlib.sha256(sys.argv[1].encode()).hexdigest())
PY
}

ensure_user() {
  if ! id proxmox-auth >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/proxmox-auth-gate --shell /usr/sbin/nologin proxmox-auth 2>/dev/null \
      || useradd --system --home-dir /var/lib/proxmox-auth-gate --shell /sbin/nologin proxmox-auth
  fi
}

install_frp() {
  [[ -n "${FRP_TOKEN}" ]] || FRP_TOKEN="$(rand_hex)"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  wget -O "${tmpdir}/frp.tar.gz" "${FRP_URL}"
  tar -xzf "${tmpdir}/frp.tar.gz" -C "${tmpdir}"
  install -m 0755 "${tmpdir}/frp_${FRP_VERSION}_${FRP_ARCH}/frps" /usr/local/bin/frps

  install -d -m 0755 /etc/frp
  cat >/etc/frp/frps.toml <<EOF_FRPS
bindAddr = "0.0.0.0"
bindPort = 7000
proxyBindAddr = "127.0.0.1"

auth.token = "${FRP_TOKEN}"
transport.tls.force = true

allowPorts = [
  { single = 18006 }
]

webServer.addr = "127.0.0.1"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "$(rand_hex)"
EOF_FRPS
  chmod 600 /etc/frp/frps.toml

  cat >/etc/systemd/system/frps.service <<'EOF_SERVICE'
[Unit]
Description=frp server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

install_gate() {
  ensure_user
  install -d -m 0755 /etc/proxmox-auth-gate /var/lib/proxmox-auth-gate /etc/proxmox-auth-gate/tls

  cat >/etc/proxmox-auth-gate/gate.env <<EOF_ENV
AUTH_USER=${GATE_USER}
AUTH_PASSWORD_SHA256=$(sha256_text "${GATE_PASSWORD}")
SESSION_SECRET=$(rand_hex)
DB_PATH=/var/lib/proxmox-auth-gate/auth.db
LISTEN_ADDR=127.0.0.1
LISTEN_PORT=9090
SESSION_SECONDS=28800
WINDOW_SECONDS=86400
BAN_SECONDS=86400
BAN_THRESHOLD=3
COOKIE_NAME=pve_gate_session
EOF_ENV
  chmod 600 /etc/proxmox-auth-gate/gate.env

  cat >/usr/local/bin/proxmox-auth-gate <<'PY_GATE'
#!/usr/bin/env python3
import hashlib, hmac, html, os, secrets, sqlite3, time
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

AUTH_USER=os.environ["AUTH_USER"]; AUTH_PASSWORD_SHA256=os.environ["AUTH_PASSWORD_SHA256"]; SESSION_SECRET=os.environ["SESSION_SECRET"]
DB_PATH=os.environ.get("DB_PATH","/var/lib/proxmox-auth-gate/auth.db"); COOKIE_NAME=os.environ.get("COOKIE_NAME","pve_gate_session")
SESSION_SECONDS=int(os.environ.get("SESSION_SECONDS","28800")); WINDOW_SECONDS=int(os.environ.get("WINDOW_SECONDS","86400"))
BAN_SECONDS=int(os.environ.get("BAN_SECONDS","86400")); BAN_THRESHOLD=int(os.environ.get("BAN_THRESHOLD","3"))
LISTEN_ADDR=os.environ.get("LISTEN_ADDR","127.0.0.1"); LISTEN_PORT=int(os.environ.get("LISTEN_PORT","9090"))
def now(): return int(time.time())
def ph(v): return hashlib.sha256(v.encode()).hexdigest()
def th(v): return hmac.new(SESSION_SECRET.encode(),v.encode(),hashlib.sha256).hexdigest()
def safe(v):
    v=unquote(v or "/")
    return "/" if (not v.startswith("/") or v.startswith("//") or v.startswith("/login") or v.startswith("/__auth")) else v
def db():
    os.makedirs(os.path.dirname(DB_PATH),exist_ok=True); c=sqlite3.connect(DB_PATH)
    c.execute("CREATE TABLE IF NOT EXISTS sessions (token_hash TEXT PRIMARY KEY, expires_at INTEGER NOT NULL, ip TEXT NOT NULL, created_at INTEGER NOT NULL)")
    c.execute("CREATE TABLE IF NOT EXISTS failures (ip TEXT NOT NULL, failed_at INTEGER NOT NULL)")
    c.execute("CREATE TABLE IF NOT EXISTS bans (ip TEXT PRIMARY KEY, banned_until INTEGER NOT NULL)"); c.commit(); return c
def ip(h):
    v=h.headers.get("X-Real-IP") or h.headers.get("X-Forwarded-For","")
    return (v.split(",",1)[0].strip() if v else "") or h.client_address[0]
def clean(c):
    c.execute("DELETE FROM failures WHERE failed_at < ?",(now()-WINDOW_SECONDS,)); c.execute("DELETE FROM bans WHERE banned_until <= ?",(now(),)); c.execute("DELETE FROM sessions WHERE expires_at <= ?",(now(),)); c.commit()
def ban(c,i):
    r=c.execute("SELECT banned_until FROM bans WHERE ip=?",(i,)).fetchone(); return int(r[0]) if r else 0
def fails(c,i):
    r=c.execute("SELECT COUNT(*) FROM failures WHERE ip=? AND failed_at>=?",(i,now()-WINDOW_SECONDS)).fetchone(); return int(r[0] or 0)
def dur(s):
    h,r=divmod(max(0,s),3600); m,_=divmod(r,60); return f"{h} 小时 {m} 分钟" if h else f"{m} 分钟"
def ck(t,age):
    j=cookies.SimpleCookie(); j[COOKIE_NAME]=t; j[COOKIE_NAME]["path"]="/"; j[COOKIE_NAME]["max-age"]=str(age); j[COOKIE_NAME]["httponly"]=True; j[COOKIE_NAME]["secure"]=True; j[COOKIE_NAME]["samesite"]="Lax"; return j.output(header="").strip()
def read(raw):
    j=cookies.SimpleCookie()
    try: j.load(raw or "")
    except cookies.CookieError: return ""
    return j.get(COOKIE_NAME).value if COOKIE_NAME in j else ""
def page(note="",blocked=False,nxt="/"):
    msg=f'<p class="note">{html.escape(note)}</p>' if note else ""; title="访问已暂停" if blocked else "Proxmox"; desc="这个 IP 的登录失败次数过多，请稍后再试。" if blocked else "登录后继续访问控制台。"
    form="" if blocked else f'<form method="post" action="/login"><input type="hidden" name="next" value="{html.escape(nxt)}"><label>账号</label><input name="username" autocomplete="username" autofocus><label>密码</label><input name="password" type="password" autocomplete="current-password"><button type="submit">登录</button></form>'
    return f'''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{title}</title><style>:root{{--bg:#f7f8fa;--panel:#fff;--text:#15171a;--muted:#6b7280;--line:#d9dee7;--accent:#1769e0;--danger:#c2410c}}@media(prefers-color-scheme:dark){{:root{{--bg:#111317;--panel:#181b20;--text:#f4f6f8;--muted:#a3aab5;--line:#2e3440;--accent:#7ab0ff;--danger:#fb923c}}}}*{{box-sizing:border-box}}body{{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,"Segoe UI",sans-serif}}main{{width:min(100%,360px);padding:32px;background:var(--panel);border:1px solid var(--line);border-radius:8px;box-shadow:0 18px 50px rgba(15,23,42,.08)}}h1{{margin:0 0 6px;font-size:22px;font-weight:650;letter-spacing:0}}p{{margin:0 0 22px;color:var(--muted);line-height:1.55;font-size:14px}}label{{display:block;margin:16px 0 7px;font-size:13px;color:var(--muted)}}input{{width:100%;height:44px;border:1px solid var(--line);border-radius:6px;padding:0 12px;background:transparent;color:var(--text);font-size:15px}}button{{width:100%;height:44px;margin-top:22px;border:0;border-radius:6px;background:var(--accent);color:white;font-size:15px;font-weight:650}}.note{{margin:16px 0 0;color:var(--danger);font-size:13px}}.meta{{margin-top:18px;color:var(--muted);font-size:12px;text-align:center}}</style></head><body><main><h1>{title}</h1><p>{desc}</p>{form}<div class="meta">seroncheng.ytcc.school</div>{msg}</main></body></html>'''.encode()
class H(BaseHTTPRequestHandler):
    def html(self,s,b,h=None):
        self.send_response(s); self.send_header("Content-Type","text/html; charset=utf-8"); self.send_header("Cache-Control","no-store")
        for k,v in (h or {}).items(): self.send_header(k,v)
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        p=urlparse(self.path); i=ip(self); c=db(); clean(c); b=ban(c,i)
        if p.path=="/check":
            if b>now(): self.send_response(403); self.end_headers(); return
            t=read(self.headers.get("Cookie","")); r=c.execute("SELECT expires_at FROM sessions WHERE token_hash=?",(th(t) if t else "",)).fetchone()
            self.send_response(204 if r and int(r[0])>now() else 401); self.end_headers(); return
        if p.path=="/forbidden": self.html(403,page(f"剩余时间：{dur(b-now())}",True)); return
        if p.path=="/logout":
            t=read(self.headers.get("Cookie",""))
            if t: c.execute("DELETE FROM sessions WHERE token_hash=?",(th(t),)); c.commit()
            self.send_response(302); self.send_header("Location","/login"); self.send_header("Set-Cookie",ck("",0)); self.end_headers(); return
        if p.path!="/login": self.send_response(404); self.end_headers(); return
        if b>now(): self.html(403,page(f"剩余时间：{dur(b-now())}",True)); return
        self.html(200,page(nxt=safe(parse_qs(p.query).get("next",["/"])[0])))
    def do_POST(self):
        if urlparse(self.path).path!="/login": self.send_response(404); self.end_headers(); return
        i=ip(self); c=db(); clean(c); b=ban(c,i)
        if b>now(): self.html(403,page(f"剩余时间：{dur(b-now())}",True)); return
        f=parse_qs(self.rfile.read(min(int(self.headers.get("Content-Length","0") or "0"),4096)).decode("utf-8","replace"))
        u=f.get("username",[""])[0]; pw=f.get("password",[""])[0]; nxt=safe(f.get("next",["/"])[0])
        if hmac.compare_digest(u,AUTH_USER) and hmac.compare_digest(ph(pw),AUTH_PASSWORD_SHA256):
            t=secrets.token_urlsafe(32); c.execute("DELETE FROM failures WHERE ip=?",(i,)); c.execute("DELETE FROM bans WHERE ip=?",(i,)); c.execute("INSERT INTO sessions VALUES (?,?,?,?)",(th(t),now()+SESSION_SECONDS,i,now())); c.commit()
            self.send_response(302); self.send_header("Location",nxt); self.send_header("Set-Cookie",ck(t,SESSION_SECONDS)); self.end_headers(); return
        c.execute("INSERT INTO failures VALUES (?,?)",(i,now())); n=fails(c,i)
        if n>=BAN_THRESHOLD:
            c.execute("INSERT OR REPLACE INTO bans VALUES (?,?)",(i,now()+BAN_SECONDS)); c.commit(); self.html(403,page(f"封禁时间：{dur(BAN_SECONDS)}",True)); return
        c.commit(); self.html(401,page(f"账号或密码不正确。剩余尝试次数：{BAN_THRESHOLD-n}",False,nxt))
ThreadingHTTPServer((LISTEN_ADDR,LISTEN_PORT),H).serve_forever()
PY_GATE
  chmod 755 /usr/local/bin/proxmox-auth-gate

  cat >/etc/systemd/system/proxmox-auth-gate.service <<'EOF_SERVICE'
[Unit]
Description=Proxmox external login gate
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/proxmox-auth-gate/gate.env
ExecStart=/usr/local/bin/proxmox-auth-gate
Restart=on-failure
RestartSec=3s
User=proxmox-auth
Group=proxmox-auth
StateDirectory=proxmox-auth-gate
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/proxmox-auth-gate

[Install]
WantedBy=multi-user.target
EOF_SERVICE
  chown -R proxmox-auth:proxmox-auth /var/lib/proxmox-auth-gate
}

install_tls() {
  if [[ ! -f /etc/proxmox-auth-gate/tls/fullchain.pem || ! -f /etc/proxmox-auth-gate/tls/privkey.pem ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -subj "/CN=${DOMAIN}" \
      -addext "subjectAltName=DNS:${DOMAIN},IP:${SERVER_IP}" \
      -keyout /etc/proxmox-auth-gate/tls/privkey.pem \
      -out /etc/proxmox-auth-gate/tls/fullchain.pem
    chmod 600 /etc/proxmox-auth-gate/tls/privkey.pem
  fi
}

install_nginx() {
  cat >/etc/nginx/conf.d/proxmox-frp.conf <<EOF_NGINX
map \$http_upgrade \$pve_connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    server_name ${DOMAIN};
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    ssl_certificate /etc/proxmox-auth-gate/tls/fullchain.pem;
    ssl_certificate_key /etc/proxmox-auth-gate/tls/privkey.pem;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
    location = /login {
        proxy_pass http://127.0.0.1:9090/login;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
    location = /logout {
        proxy_pass http://127.0.0.1:9090/logout;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Cookie \$http_cookie;
    }
    location = /__auth/check {
        internal;
        proxy_pass http://127.0.0.1:9090/check;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Original-URI \$request_uri;
        proxy_set_header Cookie \$http_cookie;
    }
    location = /__auth/forbidden {
        internal;
        proxy_pass http://127.0.0.1:9090/forbidden;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
    location / {
        auth_request /__auth/check;
        error_page 401 =302 /login?next=\$request_uri;
        error_page 403 = /__auth/forbidden;
        proxy_pass https://127.0.0.1:18006;
        proxy_ssl_verify off;
        proxy_ssl_server_name off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$pve_connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
    }
}
EOF_NGINX
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow 22/tcp || true
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
    ufw allow 7000/tcp || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=http || true
    firewall-cmd --permanent --add-service=https || true
    firewall-cmd --permanent --add-port=7000/tcp || true
    firewall-cmd --reload || true
  fi
}

install_packages
install_frp
install_gate
install_tls
install_nginx
open_firewall

cat >/root/proxmox-frp-client.env <<EOF_CLIENT
SERVER_IP=${SERVER_IP}
FRP_TOKEN=${FRP_TOKEN}
LOCAL_IP=192.168.123.10
LOCAL_PORT=8006
REMOTE_PORT=18006
EOF_CLIENT
chmod 600 /root/proxmox-frp-client.env

systemctl daemon-reload
systemctl enable frps proxmox-auth-gate nginx
systemctl restart frps proxmox-auth-gate nginx
nginx -t
systemctl reload nginx

echo
echo "公网服务端部署完成。"
echo "访问地址：https://${DOMAIN}/#v1:0:=qemu%2F178:4:::::8::14"
echo "登录账号：${GATE_USER}"
echo
echo "下一步：在能访问 192.168.123.10:8006 的本地机器执行："
echo "FRP_TOKEN='${FRP_TOKEN}' bash <(wget -qO- https://raw.githubusercontent.com/HCRXchenghong/bash-test/main/scripts/proxmox-frp-local-client.sh)"
echo
echo "本机也保存了一份客户端变量：/root/proxmox-frp-client.env"
systemctl --no-pager --full status frps proxmox-auth-gate nginx || true
