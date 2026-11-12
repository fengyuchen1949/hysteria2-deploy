# Hysteria2 一键部署脚本

裸机（systemd）部署 [Hysteria2](https://v2.hysteria.network/) 的交互式安装脚本。不依赖 Docker，不碰系统已有服务，装完直接输出可导入的分享链接。

![version](https://img.shields.io/badge/Hysteria-v2.13.x-blue)
![platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu%20%7C%20Rocky%20%7C%20Fedora-lightgrey)
![license](https://img.shields.io/badge/license-MIT-green)

## 特性

- **完整交互向导**：地址 → 端口 → 证书方式 → 密码 → 混淆 → 伪装/调优，六步问完自动装
- **伪装站点自动探测**：内置 7 个候选站并行测速选最快，也可随机 / 关闭 / 手填
- **自动装依赖**：apt / dnf / yum / zypper 全部适配，缺什么装什么
- **两种证书模式**：域名 ACME 自动签发，或自签 + pinSHA256（无需域名）
- **开机自启**：systemd 服务，`Restart=on-failure`，`LimitNOFILE=1048576`
- **自动放行防火墙**：ufw / firewalld / iptables 自动识别
- **内核调优**：fq + BBR + 16MB UDP 缓冲区（已存在则跳过，不覆盖）
- **装完即用**：输出 `hysteria2://` 链接、Clash Meta 片段、sing-box outbound、终端二维码
- **可管理**：`info / status / log / restart / upgrade / uninstall`

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/fengyuchen1949/hysteria2-deploy/main/install.sh)
```

> 用 `bash <(curl ...)` 而不是 `curl | bash`：脚本需要从终端读取交互输入，进程替换方式最稳妥。
> 仓库必须是 **public**，否则 raw 地址需要带 token。

也可以用短链接方式（如果你配了自定义域名）：

```bash
curl -fsSL https://example.com/hy2.sh -o hy2.sh && bash hy2.sh
```

## 先审脚本再跑

不想直接 `curl | bash` 的话，把脚本拉下来看一眼：

```bash
curl -fsSL https://raw.githubusercontent.com/fengyuchen1949/hysteria2-deploy/main/install.sh -o hy2.sh
less hy2.sh      # 确认没问题
bash hy2.sh
```

克隆整个仓库：

```bash
git clone https://github.com/fengyuchen1949/hysteria2-deploy.git
```

> 仓库是 **public**，raw 地址无需 token。若 fork 后改成私有仓库，raw 地址需要带 token，`curl` 会 404。

## 安装过程长什么样

```
▸ 1/6  客户端连接地址
[*] 检测到公网 IP：YOUR_SERVER_IP
? 域名或 IP（回车使用 YOUR_SERVER_IP）:

▸ 2/6  监听端口
   Hysteria2 走 UDP。部分机房对 443 有 QoS，可改 8443 / 2096 等
? UDP 端口 [443]:

▸ 3/6  证书方式
   1) 域名 + ACME 自动证书（推荐，需已解析到本机）
   2) 自签证书（跳验证，配置最简单）
? 选择 [1]:

▸ 4/6  认证密码
? 密码（回车使用随机值） [a3f9c1...]:

▸ 5/6  流量混淆
   salamander 会给 QUIC 包加一层异或混淆，抗主动探测，建议开启
? 启用 salamander 混淆？ [y]:

▸ 6/6  伪装与调优
   伪装站点决定别人扫到你端口时看到什么页面
   1) 自动探测（并行测候选站，选最快的）
   2) 随机选一个（不探测，装得更快）
   3) 手动指定 URL
   4) 关闭（直接访问端口返回 404）
? 伪装站点 [1]: 1
[*] 探测候选站点可用性（并行，最多约 6 秒）
[✓] 自动选定：https://www.baidu.com/
? 写入内核调优（fq + BBR + UDP 缓冲）？ [y]:

------------------------------------------------------------
 即将执行
------------------------------------------------------------
 连接地址      YOUR_SERVER_IP
 端口          443/udp
 证书          自签（pinSHA256）
 密码          a3f9c1d2e4b5...
 混淆          salamander / 8c1d55aa...
 伪装站点      https://www.bing.com/
 内核调优      是
------------------------------------------------------------
? 确认开始安装？ [y]:
```

## 非交互用法

```bash
# 全默认：自签证书 + 随机密码 + 443 端口
bash install.sh --yes

# 域名 + 自动证书
bash install.sh --domain hy.example.com --email me@example.com --yes

# 自定义：端口 8443、固定密码、关混淆
bash install.sh --host YOUR_SERVER_IP --port 8443 \
  --password 'MyStrongPass' --no-obfs --yes

# 锁定 Hysteria 版本
bash install.sh --version v2.13.0 --yes
```

全部参数：

| 参数 | 说明 |
|---|---|
| `--domain <域名>` | 域名 + ACME 自动证书，需解析到本机 |
| `--email <邮箱>` | ACME 注册邮箱 |
| `--ip` | 强制自签证书 |
| `--host <地址>` | 客户端连接地址，默认自动探测公网 IP |
| `--port <端口>` | UDP 监听端口，默认 443 |
| `--password <密码>` | 认证密码，默认随机 32 位 hex |
| `--obfs-password <密码>` | 混淆密码，默认随机 |
| `--no-obfs` | 关闭 salamander 混淆 |
| `--masquerade <值>` | 伪装站点：`auto` 自动探测（默认）/ `random` 随机 / `none` 关闭 / `<URL>` 手动指定 |
| `--bw-up` / `--bw-down` | 服务端带宽，如 `"100 mbps"` |
| `--no-tune` | 不写内核调优 |
| `--version <vX.Y.Z>` | 指定 Hysteria 版本 |
| `--yes` / `-y` | 零交互 |
| `--force` | 已安装时直接覆盖 |

## 两种证书模式

|  | 自签证书 | 域名 + ACME |
|---|---|---|
| 需要域名 | 否 | 是，且 A/AAAA 记录指向本机 |
| 客户端 | 必须 `insecure: true` 或填 `pinSHA256` | 正常配置 |
| 抗审查 | 一般，证书可疑 | 好，真证书 + 伪装站点 |
| 签发 | 脚本本地生成，10 年有效 | 首次启动自动申请 |
| 前置条件 | 无 | TCP 80/443 空闲 |

自签模式脚本会打印 **pinSHA256**（证书的 SHA256 指纹，hex）。客户端填它比无脑 `insecure: true` 安全，能防中间人。

## 伪装站点

伪装站点（`masquerade`）决定**别人直接访问你端口时看到什么**。配了它，探测者用浏览器打开 `https://你的域名:443` 会看到正常的网页；不配则返回 404，一眼就能看出这是个代理端口。

脚本提供四种策略，向导第 6 步可选：

| 策略 | 行为 | 耗时 |
|---|---|---|
| `auto`（默认） | 并行探测候选池，选反代耗时最短的 | 约 2-6 秒 |
| `random` | 不探测，从候选池随机抽一个 | 0 |
| `none` | 不写 `masquerade` 段，直接返回 404 | 0 |
| `<URL>` | 用你指定的地址 | 0 |

```bash
bash install.sh --masquerade auto    # 自动探测
bash install.sh --masquerade random  # 随机
bash install.sh --masquerade none    # 关闭
bash install.sh --masquerade https://www.example.com/   # 手动
```

### 探测具体做了什么

对候选池里的每个站点发一次带浏览器 UA 的 HTTPS 请求，只保留满足以下条件的：

- 跟随重定向后状态码是 2xx/3xx
- 响应体 ≥ 800 字节（过滤纯跳转页、空白页、Cloudflare 挑战页）
- 6 秒内返回

然后按 `time_total` 排序取最快的一个。7 个站点并行探测，总耗时取决于最慢的那个，不会累加。

候选池：`bing.com`、`apple.com`、`microsoft.com`、`cloudflare.com`、`baidu.com`、`qq.com`、`163.com`——都是全球有 CDN、无反爬挑战、首页体积可控、内容中性的站点。

### 一个必须说清楚的局限

**探测的是「你的 VPS 能不能访问目标站点」，不是「你的客户端能不能」。**

服务端只负责回源：VPS 拉不到目标站，反代就会 502，伪装直接穿帮——这是探测能保证的。但客户端在什么网络环境、那个站点在客户端那边通不通，VPS 无从得知。

所以：

- 主要面向国内用户 → 选 `baidu.com` / `qq.com`（探测时它们如果最快，说明回源线路也好）
- 主要面向海外用户 → 选 `bing.com` / `apple.com`
- 想手动控制但懒得选 → `random` 也行，候选池里的站都在全球有 CDN，误判概率不高
- 不确定 → 用 `auto`，至少保证回源不出错

### 另外两个技术点

**`rewriteHost: true` 是必须的。** Hysteria 反代时默认转发客户端原始 `Host` 头，也就是 `你的域名:443` 或 IP。目标站点不认识这个 Host，会返回 400/404——伪装反而更可疑。脚本已经写死 `true`。

**伪装不是加密。** 它只是让端口看起来像正常网站，不改变协议特征。真要抗审查，靠的是 ACME 真证书 + salamander 混淆 + 伪装三者叠加。

## 客户端配置

安装完成会直接打印三份配置，复制即用：

**Hysteria2 分享链接**

```
hysteria2://密码@YOUR_SERVER_IP:443/?sni=YOUR_SERVER_IP&insecure=1&obfs=salamander&obfs-password=xxx#HY2-YOUR_SERVER_IP
```

**Clash Meta / mihomo**

```yaml
proxies:
  - name: "HY2-YOUR_SERVER_IP"
    type: hysteria2
    server: YOUR_SERVER_IP
    port: 443
    password: "xxx"
    sni: YOUR_SERVER_IP
    skip-cert-verify: true
    obfs: salamander
    obfs-password: "xxx"
    up: "50 Mbps"
    down: "200 Mbps"
```

**sing-box**

```json
{
  "type": "hysteria2",
  "tag": "hy2",
  "server": "YOUR_SERVER_IP",
  "server_port": 443,
  "password": "xxx",
  "tls": { "enabled": true, "server_name": "YOUR_SERVER_IP", "insecure": true, "alpn": ["h3"] },
  "obfs": { "type": "salamander", "password": "xxx" },
  "up_mbps": 50,
  "down_mbps": 200
}
```

## 管理

```bash
bash install.sh info       # 重新打印节点信息与链接
bash install.sh status     # 服务状态
bash install.sh log        # 实时日志
bash install.sh restart    # 重启
bash install.sh upgrade    # 升级到最新版
bash install.sh uninstall  # 卸载
```

或直接用 systemd：

```bash
systemctl status hysteria-server
journalctl -u hysteria-server -f
```

## 文件清单

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/hysteria` | 二进制 |
| `/etc/hysteria/config.yaml` | 服务端配置（mode 600） |
| `/etc/hysteria/cert.pem` `.key.pem` | 自签证书（仅自签模式） |
| `/etc/hysteria/.install.meta` | 安装信息，供 `info` 使用 |
| `/etc/systemd/system/hysteria-server.service` | systemd 单元 |
| `/etc/sysctl.d/99-hysteria.conf` | 内核调优（存在则跳过） |

卸载会清掉以上全部内容。二进制从 GitHub Releases 下载，失败自动切官方加速域名 `download.hysteria.network`。

## 常见问题

**服务起不来，日志 `bind: address already in use`**
UDP 端口被占用：`ss -lunp | grep 443`，换端口重装。

**服务正常但客户端连不上**
九成是云厂商安全组没放行 UDP。脚本只能改本机防火墙，改不了控制台。

**ACME 模式一直重试**
域名没解析到本机 / TCP 443 被 nginx 占用 / 80 端口被封。先用 `curl ifconfig.me` 核对 IP。

**能连但速度上不去**
部分机房对 UDP 443 做 QoS，换 `--port 8443` 试试；或客户端把 `up/down` 调高。

**客户端报 `certificate signed by unknown authority`**
自签模式忘了开 `insecure` 或没填 `pinSHA256`。

**想换端口/密码**
直接重跑 `bash install.sh --force`，向导里改完即可。

**伪装站点自动探测全部失败**
说明 VPS 出网被限制（少见，通常是内网机器或 DNS 坏了）。脚本会自动回落到 `https://www.bing.com/`。想彻底避免回源请求，用 `--masquerade none`。

**伪装站点打开后是 404 / 空白页**
```bash
curl -I https://你的伪装站点/     # 在 VPS 上测回源是否正常
journalctl -u hysteria-server -n 30 | grep -i masquerade
```
多半是目标站点变更了反爬策略，换一个：`bash install.sh --force --masquerade random`。

## 免责声明

本项目只做自动化部署，不含任何绕过监管的功能。请在**你拥有合法使用权**的服务器上使用，并遵守所在地法律法规与服务商条款。因使用不当产生的后果由使用者自行承担。

## License

MIT
