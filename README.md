# bash-test

这个项目是晟鸿工作时所需要的脚本中转站。

这里的内容以“能快速落地”为优先，脚本可以按实际工作需要随时新增、修改、覆盖或删除。仓库里的脚本不承诺长期兼容，使用前请先看脚本顶部说明和变量配置。

## Proxmox frp 一键部署

用途：把内网 Proxmox Web UI 通过 frp 暴露到公网域名，并在公网 Nginx 前加一层简约登录页。

默认目标：

```text
域名：seroncheng.ytcc.school
公网服务器：38.76.171.98
本地 Proxmox：https://192.168.123.10:8006
```

公网服务器执行：

```bash
GATE_PASSWORD='你的登录密码' bash <(wget -qO- https://raw.githubusercontent.com/HCRXchenghong/bash-test/main/scripts/proxmox-frp-public-server.sh)
```

脚本完成后会打印一条本地客户端部署命令。到能访问 `192.168.123.10:8006` 的本地机器上执行那条命令即可。

部署完成后访问：

```text
https://seroncheng.ytcc.school/#v1:0:=qemu%2F178:4:::::8::14
```

默认登录账号：

```text
lb-ch
```

登录防护规则：

```text
同一个 IP 在 24 小时内最多输错 3 次；第 3 次错误后封禁 24 小时。
```

## 可选变量

公网服务端脚本支持：

```bash
DOMAIN='seroncheng.ytcc.school'
SERVER_IP='38.76.171.98'
GATE_USER='lb-ch'
GATE_PASSWORD='你的登录密码'
FRP_TOKEN='自定义frp令牌'
```

本地客户端脚本支持：

```bash
SERVER_IP='38.76.171.98'
FRP_TOKEN='服务端生成或自定义的frp令牌'
LOCAL_IP='192.168.123.10'
LOCAL_PORT='8006'
REMOTE_PORT='18006'
```

## 注意

不要把服务器 SSH 密码、真实业务密码、Cloudflare Token、GitHub Token 等敏感信息提交到这个公开仓库。需要用到密码时，用环境变量传入，或者让脚本运行时交互输入。
