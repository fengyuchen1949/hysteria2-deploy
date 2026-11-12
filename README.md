# Hysteria2 一键部署脚本

裸机部署 [Hysteria2](https://v2.hysteria.network/) 的交互式安装脚本，支持 systemd 与 OpenRC。不依赖 Docker，不碰系统已有服务，装完直接输出可导入的分享链接。

![version](https://img.shields.io/badge/Hysteria-v2.13.x-blue)
![platform](https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu%20%7C%20Rocky%20%7C%20Fedora%20%7C%20Alpine-lightgrey)
![license](https://img.shields.io/badge/license-MIT-green)

## 特性

- **完整交互向导**：地址 → 端口 → 证书方式 → 密码 → 混淆 → 伪装/调优，六步问完自动装
- **伪装站点自动探测**：内置 7 个候选站并行测速选最快，也可随机 / 关闭 / 手填
- **自动装依赖**：apt / dnf / yum / zypper / apk 全部适配，缺什么装什么
- **两种证书模式**：域名 ACME 自动签发，或自签 + pinSHA256（无需域名）
- **双 init 系统**：systemd（Debian/Ubuntu/RHEL）与 OpenRC（Alpine/Gentoo），都带开机自启和崩溃重启
- **自动放行防火墙**：ufw / firewalld / iptables 自动识别
- **内核调优**：fq + BBR + 16MB UDP 缓冲区（已存在则跳过，不覆盖）
- **装完即用**：输出 `hysteria2://` 链接、Clash Meta 片段、sing-box outbound、终端二维码
- **一条命令管全部**：装完敲 `hy` 进菜单，加减节点、看链接、改伪装、起停服务都在里面
- **中转（链式落地）**：落地机不动，中转机一条命令把 UDP 端口转过去并生成新链接，纯内核转发 0 额外进程
- **可管理**：`info / status / log / restart / upgrade / uninstall`

## 支持的系统

| 系统 | init | 状态 |
|---|---|---|
| Debian 11+ / Ubuntu 20.04+ | systemd | 直接支持 |
| Rocky 8+ / CentOS Stream 8+ / Fedora 37+ | systemd | 直接支持 |
| Alpine 3.18+ | OpenRC | 直接支持 |
| Gentoo | OpenRC | 理论支持，未实测 |
| OpenWrt | procd | **不支持**，用 Docker |
| Docker / LXC 纯容器 | 无 init | **不支持**，用 Docker |

Alpine 默认只有 busybox ash，**必须先装 bash**：

```sh
apk add bash
bash <(curl -fsSL https://raw.githubusercontent.com/fengyuchen1949/hysteria2-deploy/main/install.sh)
```

> Hysteria 官方 release 是 Go 静态链接（无 `PT_INTERP`），musl 上可直接运行，不需要装 glibc 兼容层。

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
[*] 检测到公网 IP：YOUR_SERVER_IP

[>] 1/6  客户端连接地址
? 域名或 IP [YOUR_SERVER_IP]:

[>] 2/6  监听端口
    Hysteria2 走 UDP。部分机房对 443 有 QoS，可改 8443 / 2096 等
? UDP 端口 [443]:

[>] 3/6  证书方式
   1) 域名 + ACME 自动证书（推荐，需已解析到本机）
   2) 自签证书（跳验证，配置最简单）
? 选择 [1]:

[>] 4/6  认证密码
? 认证密码（回车自动生成）:

[>] 5/6  流量混淆
    salamander 给 QUIC 包加一层异或混淆，抗主动探测，建议开启
? 启用 salamander 混淆？ [y]:
? 混淆密码（回车自动生成）:

[>] 6/6  伪装与调优
    伪装站点决定别人扫到你端口时看到什么页面
   1) 自动探测（并行测候选站，选最快的）
   2) 随机选一个（不探测，装得更快）
   3) 手动指定 URL
   4) 关闭（直接访问端口返回 404）
? 伪装站点 [1]: 1
[*] 探测候选站点可用性（并行，最多约 6 秒）
[+] 自动选定：https://www.baidu.com/
? 写入内核调优（fq + BBR + UDP 缓冲）？ [y]:
```

> 默认值只在方括号里出现一次；密码类不给默认值，回车由 `openssl rand` 现场生成，
> 避免把随机串刷在屏幕上。

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
| `--sni <域名>` | 只改分享链接里的 `sni`（默认填服务器 IP），自签模式可借真实域名伪装 ClientHello |
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

bash install.sh masq auto            # 装完只想改伪装，用 masq，不重装、不换密码证书
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
hysteria2://密码@YOUR_SERVER_IP:443/?sni=YOUR_SERVER_IP&insecure=1&pinSHA256=<64位hex>&obfs=salamander&obfs-password=xxx#HY2-YOUR_SERVER_IP
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
    fingerprint: "<64位hex>"
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

### 链接里的参数为什么和别人脚本的不一样

不同一键脚本生成的 `hysteria2://` 链接长得不一样，是各自选的服务端参数不同，不是谁对谁错：

| 参数 | 本脚本（自签模式） | 其它脚本常见写法 | 说明 |
|---|---|---|---|
| `sni` | 服务器 IP | 借一个真实域名（如 `www.amd.com`） | 自签 + `sniGuard: disable` 时服务端不校 SNI，填什么都能握手；填域名只是让 ClientHello 更像正常访问。想换成域名用 `--sni` |
| `insecure=1` | 有 | 有 | 跳过证书链校验，自签证书必需 |
| `pinSHA256` | 有（证书指纹 hex） | 有时有 | 固定证书指纹，能防中间人；比裸 `insecure=1` 安全 |
| `obfs=salamander` | 有，`--no-obfs` 可关 | 常没有 | QUIC 载荷再套一层混淆，抗 QUIC 特征识别；客户端必须支持并填同一密码 |

- 端口、密码、备注名每次安装都不同，正常
- 旧客户端不认 `obfs` 时表现为超时或「密码错误」：升级客户端，或服务端 `--no-obfs` 重装
- 只有 `insecure=1` 没有 `pinSHA256` 也能用，只是少一层防护；`bash install.sh info` 现在会带上指纹

## 管理

装完之后不用记命令，敲 `hy` 就是菜单：

```
------------------------------------------------------------
 Hysteria2 管理台   v1.1.0
------------------------------------------------------------
 本机    1.2.3.4   Debian GNU/Linux 12   systemd
 服务端  运行中   转发 2 条
------------------------------------------------------------
  1) 安装 / 重装服务端
  2) 节点信息与分享链接
  3) 添加转发（落地机 → 本机）
  4) 转发管理（改 / 删 / 启停 / 排障）
  5) 服务状态、重启、日志
  6) 修改伪装站点
  7) 升级 Hysteria / 卸载
  8) 更新 hy 命令
  0) 退出
------------------------------------------------------------
```

`hy` 是 `hy2` 的快捷方式，带参数时等同子命令：`hy relay list` == `hy2 relay list`。第一次装服务端时脚本会自动把这两个命令写到 `/usr/local/bin`；只做中转、没装服务端的机器，跑一次 `bash install.sh menu` 也会装上。

不想进菜单也可以直接调：

```bash
hy2 info       # 重新打印节点信息与链接
hy2 masq auto  # 只换伪装站点：auto/random/none/<URL>，密码与证书不变
hy2 status     # 服务状态
hy2 log        # 实时日志
hy2 restart    # 重启
hy2 upgrade    # 升级到最新版
hy2 uninstall  # 卸载
```

或直接用原生服务管理命令：

```bash
# systemd
systemctl status hysteria-server
journalctl -u hysteria-server -f

# OpenRC（Alpine）
rc-service hysteria-server status
tail -f /var/log/hysteria.log
```

脚本会自动识别当前 init 系统，`status` / `log` / `restart` 这些子命令内部会调用对应的工具，不用你自己判断。

## 中转（把 VPS1 的节点从 VPS2 转出去）

典型场景：VPS1 是落地机（便宜、带宽大、线路差），VPS2 是中转机（线路好）。让客户端连 VPS2，由 VPS2 把 UDP 原样转给 VPS1。

```
    ┌────────┐   连 VPS2 的端口    ┌──────────────┐   UDP DNAT    ┌──────────────┐
    │ 客户端 │ ─────────────────▶ │ 中转机 VPS2  │ ────────────▶ │ 落地机 VPS1  │
    └────────┘   hysteria2://     └──────────────┘               └──────────────┘
                  （新链接）        纯 iptables，不装 Hysteria      原节点不用改
```

### 三步

**① 落地机 VPS1**：敲 `hy` → `2`，复制打印出来的链接（这步跟以前一样，不用做任何改动）

**② 中转机 VPS2**：敲 `hy` → `3`，把链接粘进去

```
[>] 添加转发节点
    在落地机上执行 hy → 2，把它给出的一条 hysteria2:// 链接整条粘贴过来
    落地机不用做任何改动，也不用知道中转机的存在

? 落地机链接（回车改为手填）: ← 粘贴
 落地地址      1.2.3.4:58443 (UDP)
 密码          ****
 SNI           1.2.3.4
 pinSHA256     350bc6eb...
 混淆          salamander / ****
? 本机监听端口 [58443]: ← 回车用同一个端口，或自己填一个
? 名字（字母数字，用于区分多条） [1-2-3-4]:
```

回车之后 VPS2 会打印一条**新链接**，把它导入客户端就完事了。

**③ 客户端**：用新链接替换旧的。

### 为什么客户端不用改其它参数

`hysteria2://` 链接里只有「地址:端口」被换成了 VPS2 的，`sni`、`pinSHA256`、`obfs-password` 一个都没动。因为 TLS 握手和混淆都是**客户端 ↔ 落地机**的端到端行为，中转机只看 UDP 五元组，看不懂也不该看懂里面是什么。

### 命令

```bash
hy2 relay add --link 'hysteria2://...' --listen 20001 --name hk   # 加一条
hy2 relay list --links     # 列表 + 全部中转链接
hy2 relay link hk          # 只看某一条的链接
hy2 relay edit hk          # 改端口 / 备注 / 启停
hy2 relay del hk           # 删除（只删本机规则，不动落地机）
hy2 relay apply            # 规则被人清掉了，重新下发
hy2 relay diag             # 排障：看每条规则命中了多少包
```

### 实现方式与理由

用的是 **iptables 的 DNAT + MASQUERADE**，不是 realm / gost / nginx：

- Hysteria2 只有 QUIC(UDP)，内核转发是零拷贝，不引入用户态进程，也不多一跳延迟
- 规则活在 netfilter 里，代理进程被 OOM 杀掉、崩溃重启都不会断流
- 中转机不用装 Hysteria，转发和服务端完全解耦，落地机换系统也不影响

规则写在自定义链 `HY2R_PRE` / `HY2R_POST` 里，**只动自己的链，不碰系统上已有的规则**。每次修改都会把整份规则重新渲染成 `/etc/hy2-relay/apply.sh` 再执行，所以规则永远和配置一致，不会出现残留。这个脚本同时被开机自启服务调用——即使脚本本体被删了，重启后规则照样恢复。

**只做 DNAT 不行**：落地机看到的源地址会是真实客户端 IP，回包绕过中转机直接发给客户端；而客户端 socket 连的是中转机，源地址对不上就被内核丢掉，表现是「握手成功，一发数据就卡死」。加上 MASQUERADE 后回程才会走回中转机。

### 四个要注意的地方

| 事项 | 说明 |
|---|---|
| 安全组 | 中转机放行 **UDP 监听端口**，落地机放行 **UDP 原端口**，云厂商控制台各看一遍 |
| 落地机不能停 | 中转只是转发，VPS1 上的 Hysteria 停了，两边一起断 |
| 客户端 IP 变了 | 落地机看到的都是中转机 IP，按 IP 限速/计费的功能会失效 |
| 只有 UDP | Hysteria2 是纯 UDP 协议，转发也只转 UDP；**端口跳跃（mport）会失效**，中转只认单端口 |

**连不上怎么查**：在 VPS2 上 `hy relay diag`，看 `HY2R_PRE` 的包数。

- 包数是 0 → 客户端连的地址/端口不对，或 VPS2 安全组没放行
- 包数在涨但连不上 → VPS1 没放行 UDP，或 VPS1 上服务没起（`hy status` 看）
- 两边都正常还是断 → 多半是客户端缓存了旧链接，删掉节点重新导入

## 文件清单

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/hysteria` | 二进制 |
| `/usr/local/bin/hy` `/usr/local/bin/hy2` | 管理命令（`hy` 进菜单，`hy2` 走子命令） |
| `/etc/hysteria/config.yaml` | 服务端配置（mode 600） |
| `/etc/hysteria/cert.pem` `.key.pem` | 自签证书（仅自签模式） |
| `/etc/hysteria/.install.meta` | 安装信息，供 `info` 使用 |
| `/etc/hy2-relay/nodes/*.conf` | 中转规则，一条一个文件（mode 600） |
| `/etc/hy2-relay/apply.sh` `clear.sh` | 由配置渲染出的 iptables 脚本，开机自启调用 |
| `/etc/systemd/system/hysteria-server.service` | systemd 单元（systemd 系统） |
| `/etc/init.d/hysteria-server` | OpenRC 服务脚本（Alpine / Gentoo） |
| `/etc/systemd/system/hy2-relay.service` | 中转规则的开机自启（有转发时，systemd） |
| `/etc/init.d/hy2-relay` | 中转规则的开机自启（有转发时，OpenRC） |
| `/var/log/hysteria.log` | 服务输出日志（仅 OpenRC，systemd 走 journald） |
| `/etc/sysctl.d/99-hysteria.conf` | 内核调优（存在则跳过） |
| `/etc/sysctl.d/99-hy2-relay.conf` | 转发开关 + conntrack 超时（有转发时） |

卸载会清掉以上全部内容（`uninstall` 不管中转规则，用 `hy relay clear` 单独清）。二进制从 GitHub Releases 下载，失败自动切官方加速域名 `download.hysteria.network`。

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

**链接里的 `sni` 是服务器 IP，是不是伪装站点没填进去？**
不是。`masquerade` 是纯服务端配置，`hysteria2://` 链接里没有这个字段——任何脚本生成的链接都没有。`sni` 是 TLS 服务器名，自签 + `sniGuard: disable` 时填 IP 完全正常；想让它看起来像在访问某个域名，用 `--sni www.apple.com`。

伪装站点是否生效只看两处：`bash install.sh info` 的「伪装站点」一行（读的是 `config.yaml`，不是安装记录），以及浏览器打开 `https://你的IP:端口/` 是否显示那个网站。改它用 `bash install.sh masq auto`，不用重装。

**伪装站点能填自己的 IP 吗**
不能。别人用浏览器访问你的端口时，Hysteria 会把请求反向代理到伪装站点；填自己的地址等于自己代理自己，稳定 502，比不配（直接 404）更容易露馅。脚本现在会直接拦掉这种填写。换成任意正常网站，或者选 4 关闭——**伪装关掉不影响节点可用性**。

**伪装站点打开后是 404 / 空白页**
```bash
curl -I https://你的伪装站点/     # 在 VPS 上测回源是否正常
```
systemd 用 `journalctl -u hysteria-server -n 30 | grep -i masquerade`，OpenRC 用 `tail -n 30 /var/log/hysteria.log`。多半是目标站点变更了反爬策略，换一个：`bash install.sh --force --masquerade random`。

**Alpine 报 `bash: not found`**
Alpine 默认只有 busybox ash。先 `apk add bash` 再跑脚本。

**Alpine 上服务起不来**
```sh
rc-service hysteria-server status
tail -n 50 /var/log/hysteria.log
rc-service hysteria-server start    # 前台看报错
```
常见原因：`supervise-daemon` 缺失（OpenRC < 0.42，升级 openrc 包）、`/var/log` 不可写、二进制架构不匹配。

**Alpine 重启后内核参数丢了**
脚本会把配置追加到 `/etc/sysctl.conf`，但要确保 `sysctl` 服务在默认运行级：`rc-update add sysctl default`。没装 `procps` 时脚本直接写 `/proc`，重启后需要 sysctl 服务重新加载。

**中转加了以后，落地机的链接还能用吗**
能，两条都能用。中转只是多开一个入口，落地机上的服务和链接一点没变，想直连就直连，想走中转就导入新链接。

**中转链接连不上，直连落地机正常**
按顺序查三件事：① 客户端里是不是还留着旧节点，删掉重新导入；② VPS2 的安全组放行 UDP 监听端口了没；③ `hy relay diag` 看包数——一直 0 说明包根本没到 VPS2，在涨说明问题在 VPS1 那一侧（安全组或服务没起）。

**中转机会不会很吃 CPU**
不会。转发走的是内核 netfilter，不进用户态，也不做加解密（TLS 是客户端和落地机端到端握的，中转机看不懂）。一台 1 核小机器跑几条规则没有可感负载，瓶颈只在中转机的带宽。

**能不能多层中转（VPS3 → VPS2 → VPS1）**
可以，把 VPS2 生成的中转链接拿到 VPS3 上再 `hy relay add` 一次即可，每层只是把上一层的地址当成落地地址。但每加一层就多一次转发，延迟和故障点都跟着涨，一般两层够用。

## 免责声明

本项目只做自动化部署，不含任何绕过监管的功能。请在**你拥有合法使用权**的服务器上使用，并遵守所在地法律法规与服务商条款。因使用不当产生的后果由使用者自行承担。

## License

MIT
