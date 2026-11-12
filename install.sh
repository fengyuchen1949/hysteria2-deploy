#!/usr/bin/env bash
# ==============================================================================
#  Hysteria2 一键部署脚本（裸机 / systemd 或 OpenRC，非 Docker）
#
#  适用系统：Debian 11+ / Ubuntu 20.04+ / Rocky 8+ / CentOS Stream 8+ / Fedora 37+
#           Alpine 3.18+（OpenRC）
#  init 系统：systemd（主流发行版）/ OpenRC（Alpine、Gentoo）
#  协议版本：Hysteria v2.13.x（自动拉取 GitHub 最新 release）
#  脚本版本：1.1.0
#
#  用法：
#    bash install.sh                          # 交互式向导（推荐）
#    bash install.sh --yes                    # 全默认，零交互
#    bash install.sh --domain a.com --email me@a.com --yes
#    bash install.sh menu                     # 管理菜单（装好后直接敲 hy）
#    bash install.sh info | status | log | restart | upgrade | uninstall
#    bash install.sh relay add --link 'hysteria2://...' --listen 20001 --name hk
#
#  在线执行：
#    bash <(curl -fsSL https://raw.githubusercontent.com/<你>/<仓库>/main/install.sh)
#
#  脚本只会改动这些路径：
#    /usr/local/bin/hysteria
#    /usr/local/bin/hy2  /usr/local/bin/hy        （管理命令，装好后直接敲 hy）
#    /etc/hysteria/{config.yaml,cert.pem,key.pem,.install.meta}
#    /etc/hy2-relay/{nodes/*.conf,apply.sh,clear.sh}   （中转规则，纯 iptables）
#    /etc/systemd/system/hysteria-server.service   （systemd）
#    /etc/init.d/hysteria-server                   （OpenRC）
#    /etc/systemd/system/hy2-relay.service         （systemd，有转发时）
#    /etc/init.d/hy2-relay                         （OpenRC，有转发时）
#    /var/log/hysteria.log                         （OpenRC 下的输出日志）
#    /etc/sysctl.d/99-hysteria.conf
#    /etc/sysctl.d/99-hy2-relay.conf               （有转发时）
# ==============================================================================

set -Eeuo pipefail

# Alpine 的 busybox ash 不支持 [[ ]] 与数组，必须用 bash 运行
if [ -z "${BASH_VERSION:-}" ]; then
  echo "[x] 本脚本需要 bash。Alpine 请先执行：apk add bash" >&2
  exit 1
fi

SCRIPT_VERSION="1.1.0"

# ------------------------------ 常量与默认值 ------------------------------
HY2_BIN="/usr/local/bin/hysteria"
HY2_DIR="/etc/hysteria"
HY2_CONF="${HY2_DIR}/config.yaml"
META="${HY2_DIR}/.install.meta"
UNIT=""                     # 服务文件路径，由 detect_init 按实际 init 系统决定
INIT_SYS=""                 # systemd / openrc / none
SYSCTL_FILE="/etc/sysctl.d/99-hysteria.conf"
SVC="hysteria-server"
LOG_FILE="/var/log/hysteria.log"   # OpenRC 下的输出日志

# 中转（转发）相关
RELAY_DIR="/etc/hy2-relay"
RELAY_NODES="${RELAY_DIR}/nodes"
RELAY_APPLY="${RELAY_DIR}/apply.sh"
RELAY_CLEAR="${RELAY_DIR}/clear.sh"
RELAY_SYSCTL="/etc/sysctl.d/99-hy2-relay.conf"
RELAY_SVC="hy2-relay"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
OPENRC_DIR="${OPENRC_DIR:-/etc/init.d}"
RELAY_RULE_COUNT=0
MENU_IP=""

# 自更新用：hy 命令第一次由这个地址拿脚本，之后本机就有副本了
SELF_URL="${SELF_URL:-https://raw.githubusercontent.com/fengyuchen1949/hysteria2-deploy/main/install.sh}"
CLI_BIN="/usr/local/bin/hy2"

PORT="${PORT:-443}"
DOMAIN=""
EMAIL=""
HOST=""
MODE="selfsigned"
MODE_SET=0
PASSWORD=""
OBFS_PASSWORD=""
USE_OBFS=1
MASQ_URL="https://www.bing.com/"
MASQ_MODE="auto"          # auto=自动探测 / random=随机 / manual=手填 / none=关闭
MASQ_MODE_SET=0           # 是否已由命令行指定，指定后不再询问
BW_UP=""
BW_DOWN=""
PINNED_VERSION=""
SNI_OVERRIDE=""             # --sni：只影响分享链接里的 sni，不改服务端
DL_VERSION=""               # 实际下载到的版本，二进制自报版本失败时兜底
TUNE=1
ASSUME_YES=0
FORCE=0
ACTION="install"
SUB=()                      # relay 后面的子命令与位置参数
RELAY_LINK=""
RELAY_NAME=""
RELAY_NOTE=""
RELAY_LISTEN_ARG=""
URI_RAW=""                  # 落地机原始链接，便于排错时回溯
PICK_NAME=""

# ------------------------------ 输出样式 ------------------------------
# 颜色必须用 $'\e[..m' 定义成真实 ESC 字节。
# 若写成双引号的 "\033[1m"，只有落在 printf 的 format 串里才会被解释，
# 一旦作为 %s 的参数或经 echo 输出，终端就会看到字面的 \033[1m。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'
  C_W=$'\e[1m';  C_D=$'\e[2m';  C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_W=""; C_D=""; C_0=""
fi

# 统一用 %s 而非 %b：颜色已是真实 ESC，无需再解析转义，
# 这样值里出现的反斜杠不会被当成转义序列吃掉。
#
# 标记一律用 ASCII 三字符 + 一个空格（共 4 列）。✓ × ▸ 这类符号属于
# Unicode 宽度模糊区（East Asian Width = Ambiguous），在中文环境字体里
# 常被渲染成 2 列，会让 [✓] 行比 [*] 行多缩进一格，整屏行首参差不齐。
info() { printf '%s[*]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s[x]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
hr()   { printf '%s%s%s\n' "$C_D" "------------------------------------------------------------" "$C_0"; }
step() { printf '\n%s[>] %s%s\n' "$C_W" "$*" "$C_0"; }
hint() { printf '    %s%s%s\n' "$C_D" "$*" "$C_0"; }

# 键值两栏输出。标签预先按「中文占 2 列、ASCII 占 1 列」补齐到 14 列，
# 不用 %-14s —— printf 按字节数补空格，"版本"是 6 字节、"SNI"是 3 字节，
# 混排必然错位。
kv() { printf ' %s%s\n' "$1" "$2"; }

trap 'die "第 ${LINENO} 行执行失败，已中止"' ERR

# ------------------------------ 基础工具 ------------------------------
need_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo -i"; }
has() { command -v "$1" >/dev/null 2>&1; }
is_ip() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$1" == *:* ]]; }

pkg_mgr() {
  if has apk; then echo apk
  elif has apt-get; then echo apt
  elif has dnf; then echo dnf
  elif has yum; then echo yum
  elif has zypper; then echo zypper
  else echo none; fi
}

pkg_install() {
  [ $# -eq 0 ] && return 0
  local missing=() p
  for p in "$@"; do has "$p" || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0

  info "安装依赖：${missing[*]}"
  case "$(pkg_mgr)" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 || true ;;
    dnf) dnf install -y -q "${missing[@]}" >/dev/null 2>&1 || true ;;
    yum) yum install -y -q "${missing[@]}" >/dev/null 2>&1 || true ;;
    zypper) zypper -q install -y "${missing[@]}" >/dev/null 2>&1 || true ;;
    apk)
      # Alpine：先试 --no-cache（快），失败再 update 后重试
      if ! apk add --no-cache "${missing[@]}" >/dev/null 2>&1; then
        apk update >/dev/null 2>&1 || true
        apk add "${missing[@]}" >/dev/null 2>&1 || true
      fi ;;
    *) warn "未识别的包管理器，请手动安装：${missing[*]}" ;;
  esac

  local still=()
  for p in "${missing[@]}"; do has "$p" || still+=("$p"); done
  if [ ${#still[@]} -eq 0 ]; then
    ok "依赖已就绪"
  else
    warn "未能安装：${still[*]}"
  fi
}

# 二维码工具的安装命令按包管理器给，写死 apt 在 Alpine 上会误导
qr_hint() {
  case "$(pkg_mgr)" in
    apk)    echo "apk add qrencode" ;;
    apt)    echo "apt install -y qrencode" ;;
    dnf)    echo "dnf install -y qrencode" ;;
    yum)    echo "yum install -y qrencode" ;;
    zypper) echo "zypper install -y qrencode" ;;
    *)      echo "安装 qrencode" ;;
  esac
}

# iptables 规则的持久化方式各发行版不同
ipt_hint() {
  case "$(pkg_mgr)" in
    apk)    echo "apk add iptables-openrc && rc-update add iptables" ;;
    apt)    echo "apt install -y iptables-persistent && netfilter-persistent save" ;;
    dnf)    echo "dnf install -y iptables-services && systemctl enable iptables" ;;
    yum)    echo "yum install -y iptables-services && systemctl enable iptables" ;;
    zypper) echo "zypper install -y iptables && systemctl enable iptables" ;;
    *)      echo "按发行版提供的机制保存规则" ;;
  esac
}

# ------------------------------ 交互组件 ------------------------------
# 默认值只在方括号里出现一次。之前把「回车使用 X」写进提示语，
# ask 又追加 [X]，同一串 IP 会在一行里显示两遍。
ask() { # ask "提示" 变量名 [默认值] [secret]
  local prompt="$1" var="$2" def="${3:-}" secret="${4:-}" ans="" tail=""
  if [ "$ASSUME_YES" -eq 1 ]; then printf -v "$var" '%s' "$def"; return 0; fi
  if [ -n "$def" ] && [ -z "$secret" ]; then
    tail=" [${def}]"
  elif [ -n "$def" ]; then
    tail="（回车自动生成）"
  fi
  read -r -p "${C_B}?${C_0} ${prompt}${tail}: " ans || true
  [ -z "$ans" ] && ans="$def"
  printf -v "$var" '%s' "$ans"
}

confirm() { # confirm "提示" 默认值(y/n)
  local prompt="$1" def="${2:-y}" ans=""
  [ "$ASSUME_YES" -eq 1 ] && { [ "$def" = "y" ]; return; }
  read -r -p "${C_Y}?${C_0} ${prompt} [${def}]: " ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

choose() { # choose "提示" 变量名 选项1 选项2 ...
  local prompt="$1" var="$2"; shift 2
  local -a opts=("$@")
  local i ans
  [ "$ASSUME_YES" -eq 1 ] && { printf -v "$var" '%s' "1"; return 0; }
  for i in "${!opts[@]}"; do
    printf '   %s%d%s) %s\n' "$C_B" "$((i + 1))" "$C_0" "${opts[$i]}"
  done
  while :; do
    read -r -p "${C_B}?${C_0} ${prompt} [1]: " ans || true
    ans="${ans:-1}"
    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#opts[@]}" ]; then
      printf -v "$var" '%s' "$ans"; return 0
    fi
    warn "请输入 1 - ${#opts[@]}"
  done
}

# ------------------------------ 参数解析 ------------------------------
set_masq() { # 解析 --masquerade 的取值
  MASQ_MODE_SET=1
  case "${1:-}" in
    auto)            MASQ_MODE="auto";   MASQ_URL="" ;;
    random)          MASQ_MODE="random"; MASQ_URL="" ;;
    none|off|no|"")  MASQ_MODE="none";   MASQ_URL="" ;;
    *)               MASQ_MODE="manual"; MASQ_URL="$1" ;;
  esac
}

usage() {
  cat <<'EOF'
Hysteria2 一键部署脚本（systemd / OpenRC）

命令（默认 install）：
  install        安装 / 重装
  menu           管理菜单（装好后直接敲 hy 即可进入）
  info           打印节点信息与分享链接
  masq [值]      只换伪装站点：auto / random / none / <URL>，不动密码与证书
  relay ...      中转转发（落地机不动，中转机只做 UDP 转发）
      add --link <落地机链接> [--listen 端口] [--name 名字] [--note 备注]
      list [--links]          规则列表 / 连链接一起打印
      link <名字>             只打印这条中转链接
      edit <名字>             改监听端口 / 备注 / 启停
      del <名字>              删除（只删本机规则，不动落地机）
      enable|disable <名字>   启停
      apply | clear           重新下发 / 清空全部规则
      diag                    链路自检（规则命中计数）
  status         查看服务状态
  log            查看实时日志
  restart        重启服务
  upgrade        升级到最新版本
  uninstall      卸载（含服务与配置）

支持的系统：
  Debian / Ubuntu / Rocky / CentOS Stream / Fedora   systemd
  Alpine / Gentoo                                     OpenRC
  OpenWrt（procd）与纯容器                            请改用 Docker
  Alpine 需先执行 apk add bash

选项：
  --domain <域名>        域名 + ACME 自动证书（需解析到本机）
  --email <邮箱>         ACME 注册邮箱
  --ip                   强制使用自签证书
  --host <地址>          客户端连接地址，默认自动探测公网 IP
  --port <端口>          UDP 监听端口，默认 443
  --password <密码>      认证密码，默认随机
  --obfs-password <密码> 混淆密码，默认随机
  --no-obfs              关闭 salamander 混淆
  --masquerade <值>      伪装站点：auto 自动探测(默认) / random 随机 / none 关闭 / <URL> 手动
  --sni <域名>           分享链接里填的 SNI，默认服务器 IP（自签模式用域名做伪装）
  --bw-up <带宽>         服务端上行带宽，如 "100 mbps"
  --bw-down <带宽>       服务端下行带宽
  --no-tune              不写入内核调优
  --version <vX.Y.Z>     指定 Hysteria 版本，默认最新
  --yes, -y              零交互
  --force                已安装时直接覆盖
  -h, --help             帮助

中转是纯 iptables 的 UDP DNAT + MASQUERADE：不装 Hysteria、不起额外进程，
规则写进自定义链 HY2R_PRE / HY2R_POST，并生成开机自启服务。落地机全程不用改。
Hysteria2 走的 QUIC 是 UDP，所以中转机只需放行 UDP 端口，TCP 不用管。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    install|info|status|log|restart|upgrade|uninstall) ACTION="$1"; shift ;;
    masq)            ACTION="masq"; shift ;;
    menu|m)          ACTION="menu"; shift ;;
    relay)           ACTION="relay"; shift ;;
    --link)          RELAY_LINK="${2:-}"; shift 2 ;;
    --listen)        RELAY_LISTEN_ARG="${2:-}"; shift 2 ;;
    --name)          RELAY_NAME="${2:-}"; shift 2 ;;
    --note)          RELAY_NOTE="${2:-}"; shift 2 ;;
    --domain)        DOMAIN="${2:-}"; MODE="acme"; MODE_SET=1; shift 2 ;;
    --email)         EMAIL="${2:-}"; shift 2 ;;
    --ip|--selfsigned) MODE="selfsigned"; MODE_SET=1; shift ;;
    --host)          HOST="${2:-}"; shift 2 ;;
    --port)          PORT="${2:-}"; shift 2 ;;
    --password)      PASSWORD="${2:-}"; shift 2 ;;
    --obfs-password) OBFS_PASSWORD="${2:-}"; shift 2 ;;
    --no-obfs)       USE_OBFS=0; shift ;;
    --sni)           SNI_OVERRIDE="${2:-}"; shift 2 ;;
    --masquerade)
      if [ $# -lt 2 ] || [[ "${2:-}" == --* ]]; then
        die "--masquerade 需要一个值：auto | random | none | <URL>"
      fi
      set_masq "$2"; shift 2 ;;
    --bw-up)         BW_UP="${2:-}"; shift 2 ;;
    --bw-down)       BW_DOWN="${2:-}"; shift 2 ;;
    --no-tune)       TUNE=0; shift ;;
    --version)       PINNED_VERSION="${2:-}"; shift 2 ;;
    --yes|-y)        ASSUME_YES=1; shift ;;
    --force)         FORCE=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    -*) die "未知参数：$1（--help 查看帮助）" ;;
    *)  # masq 后面可以直接跟值：masq auto / masq none / masq https://...
      if [ "$ACTION" = "masq" ]; then set_masq "$1"; shift
      elif [ "$ACTION" = "relay" ]; then
        case "$1" in -*) die "未知参数：$1（--help 查看帮助）" ;; esac
        SUB+=("$1"); shift
      elif [ "$ACTION" = "menu" ]; then
        # hy relay list 这类：菜单命令后面带子命令，直接转交给 relay
        ACTION="relay"; SUB+=("$1"); shift
      else die "未知参数：$1（--help 查看帮助）"; fi ;;
  esac
done

# 通过 curl | bash 执行时，stdin 是脚本内容，交互输入需改走终端
# 用真实打开测试而非 [ -e ]：容器里 /dev/tty 可能存在但打不开
case "$ACTION" in install|menu|relay|masq) INTERACTIVE=1 ;; *) INTERACTIVE=0 ;; esac
if [ "$ASSUME_YES" -eq 0 ] && [ "$INTERACTIVE" -eq 1 ] && [ ! -t 0 ] && { : </dev/tty; } 2>/dev/null; then
  exec </dev/tty
fi

# ------------------------------ 系统探测 ------------------------------
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7)  echo "arm" ;;
    armv6l|armv5*) echo "armv5" ;;
    i386|i686)     echo "386" ;;
    riscv64)       echo "riscv64" ;;
    loongarch64)   echo "loong64" ;;
    s390x)         echo "s390x" ;;
    *) die "不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

detect_pubip() {
  local ip="" url
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
    ip="$(curl -fsS --max-time 6 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    [ -n "$ip" ] && { echo "$ip"; return 0; }
  done
  if has ip; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  echo "$ip"
}

rand_hex() { openssl rand -hex "${1:-16}" 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32; }

# ------------------------------ init 系统适配 ------------------------------
# 支持 systemd 与 OpenRC（Alpine / Gentoo）。OpenWrt 的 procd 不在支持范围内。
detect_init() {
  if has systemctl && [ -d /run/systemd/system ]; then
    INIT_SYS="systemd"; UNIT="/etc/systemd/system/${SVC}.service"
  elif has rc-service && has rc-update && [ -d /etc/init.d ]; then
    INIT_SYS="openrc";  UNIT="/etc/init.d/${SVC}"
  else
    INIT_SYS="none";    UNIT=""
  fi
}

svc_enable() {
  case "$INIT_SYS" in
    systemd) systemctl enable "$SVC" >/dev/null 2>&1 || true ;;
    openrc)  rc-update add "$SVC" default >/dev/null 2>&1 || true ;;
  esac
}
svc_start() {
  case "$INIT_SYS" in
    systemd) systemctl start "$SVC" ;;
    openrc)  rc-service "$SVC" start ;;
  esac
}
svc_stop() {
  case "$INIT_SYS" in
    systemd) systemctl stop "$SVC" 2>/dev/null || true ;;
    openrc)  rc-service "$SVC" stop 2>/dev/null || true ;;
  esac
}
svc_restart() {
  case "$INIT_SYS" in
    systemd) systemctl restart "$SVC" ;;
    openrc)  rc-service "$SVC" restart ;;
  esac
}
svc_active() {
  case "$INIT_SYS" in
    systemd) systemctl is-active --quiet "$SVC" ;;
    openrc)  rc-service "$SVC" status >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
svc_status() {
  case "$INIT_SYS" in
    systemd) systemctl status "$SVC" --no-pager -l ;;
    openrc)  rc-service "$SVC" status ;;
  esac
}
svc_logs() {
  local n="${1:-25}"
  case "$INIT_SYS" in
    systemd) journalctl --no-pager -n "$n" -u "$SVC" ;;
    openrc)  tail -n "$n" "$LOG_FILE" 2>/dev/null || echo "（暂无日志文件 ${LOG_FILE}）" ;;
  esac
}
svc_log_follow() {
  case "$INIT_SYS" in
    systemd) journalctl -u "$SVC" -f --no-pager ;;
    openrc)  tail -f "$LOG_FILE" ;;
  esac
}
svc_log_hint() {
  case "$INIT_SYS" in
    systemd) echo "journalctl -u ${SVC} -f" ;;
    openrc)  echo "tail -f ${LOG_FILE}" ;;
  esac
}
svc_restart_hint() {
  case "$INIT_SYS" in
    openrc) echo "rc-service ${SVC} restart" ;;
    *) echo "systemctl restart ${SVC}" ;;
  esac
}
svc_status_hint() {
  case "$INIT_SYS" in
    openrc) echo "rc-service ${SVC} status" ;;
    *) echo "systemctl status ${SVC}" ;;
  esac
}

# ------------------------------ 伪装站点 ------------------------------
# 候选池筛选标准：全球有 CDN、无反爬挑战、首页体积可控、内容中性（不涉及敏感题材）
MASQ_POOL=(
  "https://www.bing.com/"
  "https://www.apple.com/"
  "https://www.microsoft.com/"
  "https://www.cloudflare.com/"
  "https://www.baidu.com/"
  "https://www.qq.com/"
  "https://www.163.com/"
)
MASQ_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

# 从 URL 取 host，顺便去掉尾部 :端口（伪装站和节点同端口，用户常把端口也写进去）
url_host() {
  local h="${1#*://}"
  h="${h%%/*}"
  [ -n "${2:-}" ] && h="${h%:$2}"
  printf '%s' "$h"
}

# 探测单个站点：可达且内容正常时输出「耗时秒 字节数」，否则返回非 0
probe_masq() {
  local url="$1" out code secs size
  out="$(curl -sS -o /dev/null -L --max-time 6 --connect-timeout 4 \
           -A "$MASQ_UA" -H 'Accept-Language: en-US,en;q=0.9' \
           -w '%{http_code} %{time_total} %{size_download}' \
           "$url" 2>/dev/null)" || return 1
  read -r code secs size <<<"$out"
  case "$code" in 2*|3*) ;; *) return 1 ;; esac
  [ "${size:-0}" -ge 800 ] 2>/dev/null || return 1   # 过滤跳转页/空白页/挑战页
  printf '%s %s\n' "$secs" "$size"
}

# 并行探测整个候选池，输出「耗时<TAB>URL」，只含成功项
probe_masq_all() {
  local dir url i=0
  dir="$(mktemp -d)"
  for url in "${MASQ_POOL[@]}"; do
    i=$((i + 1))
    ( r="$(probe_masq "$url")" && printf '%s\t%s\n' "${r%% *}" "$url" > "${dir}/${i}" ) &
  done
  wait || true
  cat "${dir}"/* 2>/dev/null || true
  rm -rf "$dir" 2>/dev/null || true
}

# 自动模式：选反代耗时最短的那个
pick_masq_auto() {
  probe_masq_all | awk -F'\t' 'BEGIN{b=-1} {if (b < 0 || $1+0 < b) {b=$1+0; u=$2}} END{if (b >= 0) print u}'
}

# 随机模式：不探测，直接抽一个
pick_masq_random() {
  printf '%s' "${MASQ_POOL[$((RANDOM % ${#MASQ_POOL[@]}))]}"
}


# ------------------------------ 安装二进制 ------------------------------
# `hysteria version` 打印的是 appAboutLong：appLogo 常量以换行开头，
# 所以第一行是空行，版本号实际在第九行（Version:\tapp/v2.13.0）。
# 原来用 sed -n '1p' 取首行，永远拿到空串，于是显示成 unknown。
# 这里从整段输出里用正则抠版本号，顺带兼容 stderr 输出的构建。
get_version() {
  local v=""
  v="$("$HY2_BIN" version 2>&1 | tr -d '\r' \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.+-]*' | head -n1 || true)"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  printf '%s' "${DL_VERSION:-${PINNED_VERSION:-unknown}}"
}

install_binary() {
  local arch ver url tmp
  arch="$(detect_arch)"
  tmp="$(mktemp -d)"
  ver="${PINNED_VERSION:-latest}"

  if [ "$ver" = "latest" ]; then
    url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${arch}"
  else
    url="https://github.com/apernet/hysteria/releases/download/app/${ver}/hysteria-linux-${arch}"
  fi

  step "下载 Hysteria 二进制（linux-${arch} / ${ver}）"
  if ! curl -fL --retry 3 --connect-timeout 15 -o "${tmp}/hysteria" "$url" 2>/dev/null; then
    warn "GitHub 直连失败，切换官方加速域名重试"
    if [ "$ver" = "latest" ]; then
      url="https://download.hysteria.network/app/latest/hysteria-linux-${arch}"
    else
      url="https://download.hysteria.network/app/${ver}/hysteria-linux-${arch}"
    fi
    curl -fL --retry 3 --connect-timeout 15 -o "${tmp}/hysteria" "$url" \
      || die "下载失败：请检查 VPS 出网，或手动下载后用 --version 指定版本"
  fi

  [ -s "${tmp}/hysteria" ] || die "下载到的文件为空"
  install -m 0755 "${tmp}/hysteria" "$HY2_BIN"
  rm -rf "$tmp"

  "$HY2_BIN" version >/dev/null 2>&1 || die "二进制无法执行（架构不匹配？）"
  ok "已安装：$(get_version)"
}

# ------------------------------ 证书 ------------------------------
# 证书 SHA256 指纹：hex 小写、无冒号。Hysteria 的 pinSHA256 要的就是这个格式，
# base64 的 SPKI pin 会握手失败。info 时旧版 meta 里没有 M_PIN，用磁盘证书现算。
cert_pin_of() {
  [ -f "$1" ] || return 0
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null \
    | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f'
}

gen_selfsigned() {
  local san="$1" san_entry
  if is_ip "$san"; then san_entry="IP:${san}"; else san_entry="DNS:${san}"; fi

  step "生成自签证书（SAN ${san_entry}，有效期 10 年）"
  openssl ecparam -genkey -name prime256v1 -out "${HY2_DIR}/key.pem" 2>/dev/null
  openssl req -new -x509 -days 3650 \
    -key "${HY2_DIR}/key.pem" -out "${HY2_DIR}/cert.pem" \
    -subj "/CN=${san}" -addext "subjectAltName=${san_entry}" 2>/dev/null \
    || die "证书生成失败（openssl 版本过低，需 1.1.1+）"
  chmod 600 "${HY2_DIR}/key.pem" "${HY2_DIR}/cert.pem"

  CERT_PIN="$(cert_pin_of "${HY2_DIR}/cert.pem")"
  ok "证书已生成（有效期 10 年），pinSHA256: ${CERT_PIN}"
}

# ------------------------------ 配置 / 服务 ------------------------------
write_config() {
  local tmpc; tmpc="$(mktemp)"

  {
    echo "# ============================================================"
    echo "# Hysteria2 服务端配置"
    echo "# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')   脚本版本：${SCRIPT_VERSION}"
    echo "# 文档：https://v2.hysteria.network/zh/docs/"
    echo "# 改完执行：$(svc_restart_hint)"
    echo "# ============================================================"
    echo
    echo "listen: :${PORT}"
    echo

    if [ "$MODE" = "acme" ]; then
      echo "# 自动签发证书：域名必须已解析到本机，且 TCP 80/443 空闲"
      echo "acme:"
      echo "  domains:"
      echo "    - ${DOMAIN}"
      echo "  email: ${EMAIL}"
    else
      echo "# 自签证书：客户端需 insecure: true 或填写 pinSHA256"
      echo "tls:"
      echo "  cert: ${HY2_DIR}/cert.pem"
      echo "  key: ${HY2_DIR}/key.pem"
      echo "  sniGuard: disable   # 自签 + IP 直连必须关闭，否则客户端无 SNI 会被拒"
    fi
    echo

    echo "auth:"
    echo "  type: password"
    echo "  password: \"${PASSWORD}\""
    echo

    if [ "$USE_OBFS" -eq 1 ]; then
      echo "# 混淆：客户端必须填相同密码；老客户端不支持时删掉本段"
      echo "obfs:"
      echo "  type: salamander"
      echo "  salamander:"
      echo "    password: \"${OBFS_PASSWORD}\""
      echo
    fi

    if [ "$MASQ_MODE" != "none" ] && [ -n "$MASQ_URL" ]; then
      echo "# 伪装站点：浏览器直接访问端口会看到这个站"
      echo "masquerade:"
      echo "  type: proxy"
      echo "  proxy:"
      echo "    # rewriteHost 必须为 true，否则转发的是客户端 Host，目标站会返回 400/404"
      echo "    rewriteHost: true"
      echo "    url: ${MASQ_URL}"
      echo
    else
      echo "# 未配置 masquerade：直接访问端口返回 404，不暴露任何指纹"
      echo
    fi

    echo "# QUIC 参数（默认值，大带宽机器可等比放大）"
    echo "quic:"
    echo "  initStreamReceiveWindow: 8388608"
    echo "  maxStreamReceiveWindow: 8388608"
    echo "  initConnReceiveWindow: 20971520"
    echo "  maxConnReceiveWindow: 20971520"
    echo "  maxIdleTimeout: 30s"
    echo "  maxIncomingStreams: 1024"
    echo

    echo "udpIdleTimeout: 60s"
    echo "disableUDP: false"

    if [ -n "$BW_UP" ] || [ -n "$BW_DOWN" ]; then
      echo
      echo "# 服务端带宽，仅在客户端使用 brutal 拥塞控制时生效"
      echo "bandwidth:"
      [ -n "$BW_UP" ]   && echo "  up: ${BW_UP}"
      [ -n "$BW_DOWN" ] && echo "  down: ${BW_DOWN}"
    fi
  } > "$tmpc"

  install -m 600 "$tmpc" "$HY2_CONF"
  rm -f "$tmpc" 2>/dev/null || true
  ok "配置已写入 ${HY2_CONF}"
}

write_service() {
  case "$INIT_SYS" in
    systemd) write_systemd_unit ;;
    openrc)  write_openrc_service ;;
    *) die "未知的 init 系统，无法写入服务文件" ;;
  esac
}

write_systemd_unit() {
  cat > "$UNIT" <<EOF
[Unit]
Description=Hysteria2 Server
Documentation=https://v2.hysteria.network/
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
WorkingDirectory=${HY2_DIR}
ExecStart=${HY2_BIN} server -c ${HY2_CONF}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
LimitNPROC=512
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
Environment=HYSTERIA_LOG_LEVEL=info

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  ok "systemd 服务已写入 ${UNIT}"
}

write_openrc_service() {
  # supervise-daemon 由 OpenRC 0.42+ 提供，负责拉起与崩溃重启
  cat > "$UNIT" <<EOF
#!/sbin/openrc-run

name="Hysteria2 Server"
description="Hysteria2 proxy server"

supervisor="supervise-daemon"
command="${HY2_BIN}"
command_args="server -c ${HY2_CONF}"
command_user="root:root"
directory="${HY2_DIR}"
pidfile="/run/\${RC_SVCNAME}.pid"

output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
respawn_delay=5
respawn_max=0
rc_ulimit="-n 1048576"

depend() {
    need net
    after firewall
}
EOF
  chmod +x "$UNIT"
  : > "$LOG_FILE" 2>/dev/null || true
  ok "OpenRC 服务已写入 ${UNIT}"
}

tune_sysctl() {
  mkdir -p "$(dirname "$SYSCTL_FILE")" 2>/dev/null || true

  if [ -f "$SYSCTL_FILE" ]; then
    info "内核参数文件已存在，跳过写入：${SYSCTL_FILE}"
  else
    cat > "$SYSCTL_FILE" <<'EOF'
# Hysteria2 / QUIC 调优
# hy2 走 QUIC 自带拥塞控制，tcp_congestion_control 只影响 TCP（ACME、伪装回源）
# 真正对 QUIC 有用的是 fq 与放大的 UDP 缓冲区
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
EOF
    ok "内核参数已写入 ${SYSCTL_FILE}"
  fi

  # 立即生效：有 sysctl 命令就用它；Alpine 未装 procps 时直接写 /proc
  if has sysctl; then
    sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
  else
    local k v kp
    grep -E '^[[:space:]]*net\.' "$SYSCTL_FILE" 2>/dev/null | while IFS='=' read -r k v; do
      k="$(printf '%s' "$k" | tr -d '[:space:]')"
      v="$(printf '%s' "$v" | tr -d '[:space:]')"
      [ -n "$k" ] || continue
      kp="/proc/sys/$(printf '%s' "$k" | tr '.' '/')"
      [ -w "$kp" ] && printf '%s' "$v" > "$kp" 2>/dev/null
    done || true
  fi

  # OpenRC 的 sysctl 服务不一定读 sysctl.d，追加一份到 sysctl.conf 保证重启后生效
  if [ "$INIT_SYS" = "openrc" ] && [ -f /etc/sysctl.conf ] && ! grep -q '99-hysteria' /etc/sysctl.conf 2>/dev/null; then
    { echo; echo "# --- hysteria2-deploy ---"; grep -E '^[[:space:]]*net\.' "$SYSCTL_FILE" 2>/dev/null; } >> /etc/sysctl.conf 2>/dev/null || true
  fi

  ok "内核调优已生效（fq + BBR + UDP 缓冲 16MB）"
}

open_firewall() {
  local ports=("${PORT}/udp") handled=0 p
  [ "$MODE" = "acme" ] && ports+=("443/tcp" "80/tcp")

  if has ufw && ufw status 2>/dev/null | grep -qi active; then
    for p in "${ports[@]}"; do ufw allow "$p" >/dev/null 2>&1 || true; done
    ok "ufw 已放行：${ports[*]}"; handled=1
  elif has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    for p in "${ports[@]}"; do firewall-cmd --add-port="$p" --permanent >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld 已放行：${ports[*]}"; handled=1
  fi

  if [ "$handled" -eq 0 ]; then
    for p in "${ports[@]}"; do
      if iptables -C INPUT -p "${p#*/}" --dport "${p%/*}" -j ACCEPT 2>/dev/null; then
        :
      else
        iptables -I INPUT -p "${p#*/}" --dport "${p%/*}" -j ACCEPT 2>/dev/null || true
      fi
    done
    ok "iptables 已放行：${ports[*]}"
    hint "规则重启后不保留，持久化方式：$(ipt_hint)"
  fi

  local extra=""
  [ "$MODE" = "acme" ] && extra=" 及 TCP 443/80"
  warn "云厂商安全组需另行放行 UDP ${PORT}${extra}"
}

# ------------------------------ 元信息 ------------------------------
save_meta() {
  {
    printf 'M_HOST=%q\n'     "${M_HOST:-}"
    printf 'M_PORT=%q\n'     "${M_PORT:-443}"
    printf 'M_DOMAIN=%q\n'   "${M_DOMAIN:-}"
    printf 'M_MODE=%q\n'     "${M_MODE:-selfsigned}"
    printf 'M_PASSWORD=%q\n' "${M_PASSWORD:-}"
    printf 'M_OBFS=%q\n'     "${M_OBFS:-}"
    printf 'M_PIN=%q\n'      "${M_PIN:-}"
    printf 'M_SNI=%q\n'      "${M_SNI:-}"
    printf 'M_VER=%q\n'      "${M_VER:-unknown}"
    printf 'M_MASQ=%q\n'     "${M_MASQ:-}"
  } > "$META"
  chmod 600 "$META"
}

load_meta() {
  [ -f "$META" ] || die "未找到安装信息 ${META}，请先执行 install"
  # shellcheck disable=SC1090
  . "$META"
}

# 读 config.yaml 里 masquerade.proxy.url —— 这是伪装站点唯一的真实来源
config_masq_url() {
  [ -f "$HY2_CONF" ] || return 0
  local u=""
  u="$(awk '
    /^masquerade:[[:space:]]*$/ { inb = 1; next }
    inb && /^[[:space:]]+url:/ {
      sub(/^[[:space:]]+url:[[:space:]]*/, "")
      print
      exit
    }
    inb && /^[^[:space:]]/ { inb = 0 }
  ' "$HY2_CONF")"
  u="${u%\"}"; u="${u#\"}"
  printf '%s' "$u"
}

# 替换 config.yaml 的 masquerade 段（$1 为空 = 删掉，端口直接返回 404）
rewrite_masq() {
  local url="$1" tmp
  tmp="$(mktemp)"
  awk '
    /^masquerade:[[:space:]]*$/ { skip = 1; next }
    skip && /^[[:space:]]/      { next }
    skip                        { skip = 0 }
    { print }
  ' "$HY2_CONF" > "$tmp"
  if [ -n "$url" ]; then
    {
      printf '\nmasquerade:\n'
      printf '  type: proxy\n'
      printf '  proxy:\n'
      printf '    rewriteHost: true\n'
      printf '    url: %s\n' "$url"
    } >> "$tmp"
  fi
  # 用 cat 回写而不是 mv：保留原文件的权限与 inode
  cat "$tmp" > "$HY2_CONF"
  rm -f "$tmp" 2>/dev/null || true
}

# ------------------------------ 分享链接 ------------------------------
uri_enc() {
  local s="$1" out="" c i
  for (( i=0; i<${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) out+="$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

build_uri() {
  local host="$1" port="$2" pwd="$3" obfs="$4" sni="$5" insecure="$6" pin="$7" name="$8"
  local q="" out_host="$host"
  [[ "$host" == *:* ]] && [[ "$host" != \[*\] ]] && out_host="[${host}]"
  [ -n "$sni" ] && q="${q}&sni=$(uri_enc "$sni")"
  [ "$insecure" = "1" ] && q="${q}&insecure=1"
  # 自签模式把指纹一起写进链接：insecure=1 只表示"不校验链"，
  # 有 pinSHA256 才能挡住中间人；缺了它新链接看起来就和别的脚本不一样。
  [ -n "$pin" ] && q="${q}&pinSHA256=${pin}"
  [ -n "$obfs" ] && q="${q}&obfs=salamander&obfs-password=$(uri_enc "$obfs")"
  q="${q#&}"
  [ -z "$q" ] && q="sni=$(uri_enc "$host")"
  printf 'hysteria2://%s@%s:%s/?%s#%s' "$(uri_enc "$pwd")" "$out_host" "$port" "$q" "$(uri_enc "$name")"
}

print_info() {
  load_meta
  local host="${M_HOST:-${M_DOMAIN:-}}" sni="" insecure=0 pin="" uri="" masq=""
  if [ "${M_MODE:-}" = "acme" ]; then
    sni="${M_DOMAIN}"; insecure=0
  else
    # 默认 SNI 仍是服务器 IP（sniGuard 已关，随便填都能握手）；
    # --sni 可以把链接里的 SNI 换成任意域名，让 ClientHello 更像正常访问。
    sni="${SNI_OVERRIDE:-${M_SNI:-$host}}"; insecure=1
    pin="${M_PIN:-}"
    [ -z "$pin" ] && pin="$(cert_pin_of "${HY2_DIR}/cert.pem")"
  fi

  uri="$(build_uri "$host" "$M_PORT" "$M_PASSWORD" "$M_OBFS" "$sni" "$insecure" "$pin" "HY2-${host}")"

  # 旧版脚本写入的 M_VER 是 unknown（取首行的 bug），这时现场问一次二进制，
  # 免得用户为了看版本号去重装、把密码和证书一起换掉
  local ver="${M_VER:-}"
  if [ -z "$ver" ] || [ "$ver" = "unknown" ]; then
    ver="$(get_version 2>/dev/null || true)"
  fi

  echo
  hr
  printf ' %sHysteria2 节点信息%s\n' "$C_W" "$C_0"
  hr
  kv "版本          " "${ver:-unknown}"
  kv "地址          " "${host}"
  kv "端口          " "${M_PORT} (UDP)"
  kv "密码          " "${M_PASSWORD}"
  kv "SNI           " "${sni}"
  if [ "$insecure" = "1" ]; then
    kv "跳过验证      " "是（自签证书）"
  else
    kv "跳过验证      " "否（正式证书）"
  fi
  [ -n "${M_OBFS:-}" ] && kv "混淆          " "salamander / ${M_OBFS}"
  [ -n "$pin" ] && kv "pinSHA256     " "${pin}"
  # 伪装站点以 config.yaml 为准：meta 可能滞后（用户手改过配置或旧的 --masquerade）
  masq="$(config_masq_url)"
  [ -z "$masq" ] && masq="${M_MASQ:-}"
  if [ -n "$masq" ]; then
    kv "伪装站点      " "${masq}"
  else
    kv "伪装站点      " "未配置（直接访问端口返回 404）"
  fi
  hr
  hint "伪装站点只在服务端生效，分享链接里没有这个字段；sni 是 TLS 服务器名，不是伪装网址"
  if [ -n "$masq" ] && [ "$(url_host "$masq" "${M_PORT:-}")" = "${M_HOST:-}" ]; then
    warn "伪装站点指向本机，反代会回环 502；执行 bash install.sh masq auto 修复"
  fi
  echo
  printf '%s分享链接%s\n' "$C_B" "$C_0"
  printf '%s\n' "$uri"
  echo

  if has qrencode; then
    qrencode -t ANSIUTF8 -m 1 "$uri" 2>/dev/null || true
  else
    info "未安装 qrencode，需要二维码请执行：$(qr_hint)"
  fi

  echo
  hr
  printf '%sClash Meta / mihomo%s\n' "$C_B" "$C_0"
  printf 'proxies:\n'
  printf '  - name: "HY2-%s"\n' "$host"
  printf '    type: hysteria2\n'
  printf '    server: %s\n' "$host"
  printf '    port: %s\n' "$M_PORT"
  printf '    password: "%s"\n' "$M_PASSWORD"
  printf '    sni: %s\n' "$sni"
  if [ "$insecure" = "1" ]; then
    printf '    skip-cert-verify: true\n'
  else
    printf '    skip-cert-verify: false\n'
  fi
  [ -n "$pin" ] && printf '    fingerprint: "%s"\n' "$pin"
  if [ -n "${M_OBFS:-}" ]; then
    printf '    obfs: salamander\n'
    printf '    obfs-password: "%s"\n' "$M_OBFS"
  fi
  printf '    up: "50 Mbps"\n'
  printf '    down: "200 Mbps"\n'
  echo
  printf '%ssing-box（outbound）%s\n' "$C_B" "$C_0"
  printf '{\n'
  printf '  "type": "hysteria2",\n'
  printf '  "tag": "hy2",\n'
  printf '  "server": "%s",\n' "$host"
  printf '  "server_port": %s,\n' "$M_PORT"
  printf '  "password": "%s",\n' "$M_PASSWORD"
  printf '  "tls": { "enabled": true, "server_name": "%s", "insecure": %s, "alpn": ["h3"] },\n' \
         "$sni" "$([ "$insecure" = "1" ] && echo true || echo false)"
  if [ -n "${M_OBFS:-}" ]; then
    printf '  "obfs": { "type": "salamander", "password": "%s" },\n' "$M_OBFS"
  fi
  printf '  "up_mbps": 50,\n'
  printf '  "down_mbps": 200\n'
  printf '}\n'
  hr
  kv "配置文件      " "${HY2_CONF}"
  kv "服务状态      " "$(svc_status_hint)"
  echo
}

# ------------------------------ 安装向导 ------------------------------
collect_config() {
  local pubip=""
  pubip="$(detect_pubip)"
  if [ -n "$pubip" ]; then
    info "检测到公网 IP：${C_W}${pubip}${C_0}"
  else
    warn "未能自动获取公网 IP，请手动输入"
  fi

  # --- 1. 连接地址 ---
  step "1/6  客户端连接地址"
  # 走 ACME 且已给域名时，连接地址默认用域名
  if [ "$MODE" = "acme" ] && [ -n "$DOMAIN" ] && { [ -z "$HOST" ] || is_ip "$HOST"; }; then
    HOST="$DOMAIN"
  fi
  if [ -z "$HOST" ]; then
    ask "域名或 IP" HOST "$pubip"
  else
    ask "域名或 IP" HOST "$HOST"
  fi
  [ -n "$HOST" ] || die "连接地址不能为空"

  # --- 2. 端口 ---
  step "2/6  监听端口"
  hint "Hysteria2 走 UDP。部分机房对 443 有 QoS，可改 8443 / 2096 等"
  ask "UDP 端口" PORT "$PORT"
  [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "端口非法：$PORT"

  # --- 3. 证书方式 ---
  step "3/6  证书方式"
  if [ "$MODE_SET" -eq 0 ]; then
    if is_ip "$HOST"; then
      info "地址是 IP，只能使用自签证书"
      MODE="selfsigned"
    else
      choose "选择" MODE_CHOICE \
        "域名 + ACME 自动证书（推荐，需已解析到本机）" \
        "自签证书（跳验证，配置最简单）"
      [ "$MODE_CHOICE" = "1" ] && MODE="acme" || MODE="selfsigned"
    fi
  fi

  if [ "$MODE" = "acme" ]; then
    is_ip "$HOST" && die "ACME 需要域名，当前填的是 IP。请改用 --ip 走自签"
    DOMAIN="${DOMAIN:-$HOST}"
    ask "域名" DOMAIN "$DOMAIN"
    ask "ACME 邮箱" EMAIL "$EMAIL"
    [ -n "$EMAIL" ] || die "邮箱不能为空（Let's Encrypt 需要）"

    local resolved=""
    if has getent; then
      # musl（Alpine）的 getent 不一定支持 ahosts，回落到 hosts
      resolved="$(getent ahosts "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
      [ -z "$resolved" ] && resolved="$(getent hosts "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
      if [ -z "$resolved" ]; then
        warn "域名 ${DOMAIN} 当前解析不到，ACME 会失败"
      elif [ -n "$pubip" ] && [ "$resolved" != "$pubip" ]; then
        warn "域名解析到 ${resolved}，本机是 ${pubip}，可能签不下来"
      else
        ok "域名解析正常：${resolved}"
      fi
    fi
    if ss -ltn 2>/dev/null | grep -qE ':(80|443)([[:space:]]|$)'; then
      warn "TCP 80/443 已被占用（nginx/caddy？），ACME 申请可能失败"
    fi
  fi

  # --- 4. 认证密码 ---
  step "4/6  认证密码"
  [ -z "$PASSWORD" ] && PASSWORD="$(rand_hex 16)"
  ask "认证密码" PASSWORD "$PASSWORD" secret

  # --- 5. 混淆 ---
  step "5/6  流量混淆"
  hint "salamander 给 QUIC 包加一层异或混淆，抗主动探测，建议开启"
  if confirm "启用 salamander 混淆？" "y"; then
    USE_OBFS=1
    [ -z "$OBFS_PASSWORD" ] && OBFS_PASSWORD="$(rand_hex 16)"
    ask "混淆密码" OBFS_PASSWORD "$OBFS_PASSWORD" secret
  else
    USE_OBFS=0
  fi

  # --- 6. 伪装 / 调优 ---
  step "6/6  伪装与调优"
  hint "伪装站点决定别人扫到你端口时看到什么页面，与上面的连接地址无关"

  if [ "$MASQ_MODE_SET" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
    choose "伪装站点" MASQ_CHOICE \
      "自动探测（并行测候选站，选最快的）" \
      "随机选一个（不探测，装得更快）" \
      "手动指定 URL" \
      "关闭（直接访问端口返回 404）"
    case "$MASQ_CHOICE" in
      1) MASQ_MODE="auto" ;;
      2) MASQ_MODE="random" ;;
      3) MASQ_MODE="manual" ;;
      4) MASQ_MODE="none" ;;
    esac
  fi

  local picked=""
  case "$MASQ_MODE" in
    manual)
      ask "伪装站点 URL" MASQ_URL "${MASQ_URL:-https://www.bing.com/}"
      case "$MASQ_URL" in
        http://*|https://*) ;;
        *) die "伪装 URL 需以 http:// 或 https:// 开头" ;;
      esac
      # 指向本机 = 反向代理的请求又回到自己，稳定 502，比不配伪装还假
      local mhost
      mhost="$(url_host "$MASQ_URL" "$PORT")"
      if [ "$mhost" = "$HOST" ] || { [ -n "$pubip" ] && [ "$mhost" = "$pubip" ]; }; then
        die "伪装站点不能填服务器自己的地址（反代会回环成 502），换成正常网站；不在乎伪装就选 4"
      fi ;;
    auto)
      info "探测候选站点可用性（并行，最多约 6 秒）"
      picked="$(pick_masq_auto)"
      if [ -n "$picked" ]; then
        MASQ_URL="$picked"
        ok "自动选定：${MASQ_URL}"
      else
        MASQ_URL="https://www.bing.com/"
        warn "候选站点全部不可达（VPS 出网受限？），回落到 ${MASQ_URL}"
      fi ;;
    random)
      MASQ_URL="$(pick_masq_random)"
      ok "随机选定：${MASQ_URL}" ;;
    none)
      info "已关闭伪装，直接访问端口会返回 404" ;;
  esac

  confirm "写入内核调优（fq + BBR + UDP 缓冲）？" "y" && TUNE=1 || TUNE=0

  # --- 校验 ---
  case "$PASSWORD" in *'"'*|*'\'*|*' '*|'') die "认证密码不能为空，且不能含双引号/反斜杠/空格" ;; esac
  if [ "$USE_OBFS" -eq 1 ]; then
    case "$OBFS_PASSWORD" in *'"'*|*'\'*|*' '*|'') die "混淆密码不能为空，且不能含双引号/反斜杠/空格" ;; esac
  fi
}

show_summary() {
  echo
  hr
  printf ' %s即将执行%s\n' "$C_W" "$C_0"
  hr
  kv "连接地址      " "${HOST}"
  kv "端口          " "${PORT}/udp"
  kv "证书          " "$([ "$MODE" = "acme" ] && echo "ACME 自动签发（${DOMAIN}）" || echo "自签（pinSHA256）")"
  kv "密码          " "${PASSWORD}"
  kv "混淆          " "$([ "$USE_OBFS" -eq 1 ] && echo "salamander / ${OBFS_PASSWORD}" || echo "关闭")"
  kv "伪装站点      " "$([ "$MASQ_MODE" = "none" ] && echo "关闭（返回 404）" || echo "${MASQ_URL}")"
  kv "内核调优      " "$([ "$TUNE" -eq 1 ] && echo "是" || echo "否")"
  hr
  echo
}

# ------------------------------ 安装主流程 ------------------------------
do_install() {
  need_root
  detect_init
  if [ "$INIT_SYS" = "none" ]; then
    die "未检测到 systemd 或 OpenRC。OpenWrt（procd）与纯容器请改用 Docker 部署"
  fi

  echo
  hr
  printf ' %sHysteria2 一键部署%s   %sv%s%s\n' "$C_W" "$C_0" "$C_D" "$SCRIPT_VERSION" "$C_0"
  hr

  if [ -f "$HY2_CONF" ] && [ "$FORCE" -eq 0 ]; then
    warn "检测到已安装：${HY2_CONF}"
    if [ "$ASSUME_YES" -eq 1 ]; then
      die "已存在配置，零交互模式不覆盖。需要重装请加 --force（先 bash install.sh info 记下节点信息）"
    fi
    if ! confirm "覆盖现有配置并重装？" "n"; then
      info "已取消。查看节点：bash install.sh info"
      return 0
    fi
    FORCE=1
  fi

  # 依赖
  pkg_install curl openssl ca-certificates iproute2
  has curl    || die "缺少 curl"
  has openssl || die "缺少 openssl"

  # 向导
  collect_config
  show_summary
  if [ "$ASSUME_YES" -eq 0 ]; then
    confirm "确认开始安装？" "y" || { info "已取消"; return 0; }
  fi

  # 安装
  mkdir -p "$HY2_DIR"
  install_binary

  CERT_PIN=""
  if [ "$MODE" = "selfsigned" ]; then
    gen_selfsigned "$HOST"
  else
    step "使用 ACME 自动证书：${DOMAIN}（首次启动约 10~30 秒签发）"
  fi

  write_config
  write_service
  if [ "$TUNE" -eq 1 ]; then tune_sysctl; else info "跳过内核调优"; fi

  step "启动服务"
  svc_enable
  svc_restart
  sleep 3

  if svc_active; then
    ok "服务已运行（${INIT_SYS}）"
  else
    warn "服务未正常运行，最近日志："
    svc_logs 25 || true
    die "启动失败。常见原因：端口被占 / 域名未解析 / 证书路径错误"
  fi

  if ss -lunp 2>/dev/null | grep -qE ":${PORT}([[:space:]]|$)"; then
    ok "UDP ${PORT} 已监听"
  else
    warn "未检测到 UDP ${PORT} 监听"
  fi

  open_firewall

  M_HOST="$HOST"; M_PORT="$PORT"; M_DOMAIN="$DOMAIN"; M_MODE="$MODE"
  M_PASSWORD="$PASSWORD"
  if [ "$USE_OBFS" -eq 1 ]; then M_OBFS="$OBFS_PASSWORD"; else M_OBFS=""; fi
  M_PIN="${CERT_PIN:-}"
  M_SNI="${SNI_OVERRIDE:-}"
  M_VER="$(get_version)"
  M_MASQ="$MASQ_URL"
  save_meta

  print_info
  # 装一份本机副本：以后敲 hy 就能进菜单，不用再 curl
  self_install >/dev/null 2>&1 || true
  ok "部署完成。日志：$(svc_log_hint)"
  if [ -x /usr/local/bin/hy ]; then
    hint "以后直接敲 hy 进管理菜单，加减节点、转发、改伪装都在里面"
  fi
}

do_upgrade() {
  need_root
  detect_init
  [ -f "$META" ] || die "未找到安装信息 ${META}，请先执行 install"
  # shellcheck disable=SC1090
  . "$META"
  PINNED_VERSION="latest"
  install_binary
  svc_restart
  sleep 2
  if svc_active; then
    ok "升级完成：$(get_version)"
  else
    warn "服务未启动，执行 $(svc_log_hint) 查看"
  fi
  M_VER="$(get_version)"
  save_meta
}

# 只改伪装站点：不碰端口/密码/证书，客户端已导入的节点不用换
do_masq() {
  need_root
  detect_init
  [ -f "$HY2_CONF" ] || die "未找到 ${HY2_CONF}，请先执行 install"
  [ "$MASQ_MODE_SET" -eq 1 ] || die "用法：bash install.sh masq auto | random | none | <URL>"
  load_meta

  local url="$MASQ_URL" mhost=""
  case "$MASQ_MODE" in
    auto)
      info "探测候选站点可用性（并行，最多约 6 秒）"
      url="$(pick_masq_auto)"
      if [ -z "$url" ]; then
        url="https://www.bing.com/"
        warn "候选站点全部不可达（VPS 出网受限？），回落到 ${url}"
      fi ;;
    random)
      url="$(pick_masq_random)" ;;
    none)
      url="" ;;
    manual)
      case "$url" in
        http://*|https://*) ;;
        *) die "伪装 URL 需以 http:// 或 https:// 开头" ;;
      esac
      mhost="$(url_host "$url" "${M_PORT:-}")"
      if [ "$mhost" = "${M_HOST:-}" ] || { [ -n "${M_DOMAIN:-}" ] && [ "$mhost" = "$M_DOMAIN" ]; }; then
        die "伪装站点不能填服务器自己的地址（反代会回环成 502）"
      fi ;;
  esac

  rewrite_masq "$url"
  M_MASQ="$url"
  save_meta
  if [ -n "$url" ]; then ok "伪装站点已更新：${url}"; else ok "已关闭伪装，直接访问端口返回 404"; fi

  if svc_restart; then
    sleep 2
    if svc_active; then ok "服务已重启"; else warn "服务未起来，执行 $(svc_log_hint) 查看"; fi
  fi
  print_info
}

do_uninstall() {
  need_root
  detect_init
  warn "将停止并删除：${HY2_BIN}、${HY2_DIR}、${UNIT}"
  confirm "确认卸载？" "n" || { info "已取消"; exit 0; }
  svc_stop
  case "$INIT_SYS" in
    systemd)
      systemctl disable "$SVC" >/dev/null 2>&1 || true
      rm -f "$UNIT"
      systemctl daemon-reload ;;
    openrc)
      rc-update del "$SVC" default >/dev/null 2>&1 || true
      rm -f "$UNIT" ;;
  esac
  rm -rf "$HY2_DIR"
  rm -f "$HY2_BIN"
  rm -f "$SYSCTL_FILE"
  rm -f "$LOG_FILE" 2>/dev/null || true
  ok "已卸载（防火墙规则请按需手动清理）"
}

# ==============================================================================
#  节点转发（中转机）
#
#  场景：VPS1 是落地机（跑 Hysteria2），VPS2 是中转机（线路好但落地差）。
#        让客户端连 VPS2，由 VPS2 把 UDP 包原样转给 VPS1。
#
#  实现选型：内核 iptables DNAT，不用 realm / gost / nginx。
#    - Hysteria2 只有 QUIC(UDP)，内核转发是零额外进程、零用户态拷贝，延迟最低
#    - 不会因为代理进程崩溃、被 OOM 杀掉而断流，规则在 netfilter 里
#    - 不需要在中转机装 Hysteria，转发跟服务端完全解耦
#
#  为什么 DNAT 之后还必须 MASQUERADE：
#    只做 DNAT 时，落地机收到的源地址还是真实客户端 IP，于是回包会绕过中转机
#    直接发给客户端；而客户端的 socket 连的是中转机，源地址对不上就被内核丢掉，
#    表现为「握手成功、一发数据就卡死」。加上 MASQUERADE 后回程才会走回中转机。
#
#  为什么中转链接里 sni / pinSHA256 / obfs 一个字都不用改：
#    TLS 和混淆都是客户端 ↔ 落地机的端到端行为，中转机只看 UDP 五元组，
#    所以只需把链接里的「地址:端口」换成本机，其余原样保留。
# ==============================================================================

relay_dep() {
  if ! has iptables; then
    pkg_install iptables
  fi
  has iptables || die "缺少 iptables，无法做 UDP 转发。Debian/Ubuntu：apt install -y iptables；Alpine：apk add iptables"
}

relay_name_ok() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]; }

port_ok() { [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

# 域名解析成 IPv4，统一在这里做，避免 iptables 命令行里出现域名（重启时解析失败会静默失效）
resolve4() {
  local h="$1" ip=""
  is_ip "$h" && { printf '%s' "$h"; return 0; }
  if has getent; then
    ip="$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  fi
  if [ -z "$ip" ] && has nslookup; then
    ip="$(nslookup "$h" 2>/dev/null | awk '/^Address: /{print $2; exit}' || true)"
  fi
  if [ -z "$ip" ] && has ping; then
    ip="$(ping -4 -c1 -W2 "$h" 2>/dev/null | sed -n 's/^PING.*(\([0-9.]*\)).*/\1/p' | head -n1 || true)"
  fi
  printf '%s' "$ip"
}

# 百分号解码（链接里的密码/名称可能被转义）
uri_dec() {
  local s="${1:-}" out="" hex c
  while [[ "$s" == *%* ]]; do
    out+="${s%%\%*}"
    s="${s#*\%}"
    hex="${s:0:2}"
    s="${s:2}"
    if [[ "$hex" =~ ^[0-9A-Fa-f]{2}$ ]]; then
      printf -v c "\\x${hex}"
      out+="$c"
    else
      out+="%${hex}"
    fi
  done
  printf '%s' "${out}${s}"
}

# 解析 hysteria2:// 链接，结果写进 P_* 全局变量
parse_uri() {
  local u="${1:-}" frag="" q="" userinfo="" hostport="" kvp k v oldifs="$IFS"
  P_PWD=""; P_HOST=""; P_PORT="443"; P_SNI=""; P_INSECURE=""; P_PIN=""
  P_OBFSTYPE=""; P_OBFSPWD=""; P_MPORT=""; P_NAME=""

  case "$u" in
    hysteria2://*|hy2://*) u="${u#*://}" ;;
    *) return 1 ;;
  esac
  case "$u" in *"#"*) frag="${u#*#}"; u="${u%%#*}" ;; esac
  case "$u" in *"?"*) q="${u#*\?}"; u="${u%%\?*}" ;; esac

  if [[ "$u" == *@* ]]; then
    userinfo="${u%@*}"
    hostport="${u##*@}"
  else
    hostport="$u"
  fi
  hostport="${hostport%%/*}"

  P_PWD="$(uri_dec "$userinfo")"
  P_NAME="$(uri_dec "$frag")"

  if [[ "$hostport" == \[* ]]; then
    # [IPv6]:port
    P_HOST="${hostport#\[}"
    P_HOST="${P_HOST%%\]*}"
    local rest="${hostport#*\]}"
    rest="${rest#:}"
    [ -n "$rest" ] && P_PORT="$rest"
  elif [[ "$hostport" == *:*:* ]]; then
    P_HOST="$hostport"            # 裸 IPv6，没写端口
  elif [[ "$hostport" == *:* ]]; then
    P_HOST="${hostport%%:*}"
    P_PORT="${hostport##*:}"
  else
    P_HOST="$hostport"
  fi

  IFS='&'
  for kvp in $q; do
    k="${kvp%%=*}"
    if [ "$k" = "$kvp" ]; then v=""; else v="${kvp#*=}"; fi
    case "$k" in
      sni)           P_SNI="$(uri_dec "$v")" ;;
      insecure)      P_INSECURE="$v" ;;
      pinSHA256|pin|pin-sha256) P_PIN="$(uri_dec "$v")" ;;
      obfs)          P_OBFSTYPE="$v" ;;
      obfs-password) P_OBFSPWD="$(uri_dec "$v")" ;;
      mport|ports)   P_MPORT="$v" ;;
    esac
  done
  IFS="$oldifs"

  [ -n "$P_HOST" ] && port_ok "$P_PORT"
}

# ------------------------------ 节点存取 ------------------------------
# 一条转发一个文件：/etc/hy2-relay/nodes/<名字>.conf，改坏一条不影响其它
relay_load() {
  N_NAME=""; N_LISTEN=""; N_THOST=""; N_TPORT=""; N_PWD=""; N_SNI=""
  N_INSECURE=""; N_PIN=""; N_OBFSTYPE=""; N_OBFSPWD=""; N_NOTE=""
  N_ENABLED="1"; N_URI=""
  # shellcheck disable=SC1090
  . "$1"
}

relay_get() {
  local name="${1:-}" f
  relay_name_ok "$name" || { warn "名字只能用字母数字和 . _ -，长度 1~32"; return 1; }
  f="${RELAY_NODES}/${name}.conf"
  [ -f "$f" ] || { warn "没有这个转发节点：${name}（hy relay list 查看）"; return 1; }
  relay_load "$f"
}

relay_save() {
  local f="${RELAY_NODES}/${N_NAME}.conf"
  mkdir -p "$RELAY_NODES"
  {
    printf 'N_NAME=%q\n'      "$N_NAME"
    printf 'N_LISTEN=%q\n'    "$N_LISTEN"
    printf 'N_THOST=%q\n'     "$N_THOST"
    printf 'N_TPORT=%q\n'     "$N_TPORT"
    printf 'N_PWD=%q\n'       "$N_PWD"
    printf 'N_SNI=%q\n'       "$N_SNI"
    printf 'N_INSECURE=%q\n'  "$N_INSECURE"
    printf 'N_PIN=%q\n'       "$N_PIN"
    printf 'N_OBFSTYPE=%q\n'  "$N_OBFSTYPE"
    printf 'N_OBFSPWD=%q\n'   "$N_OBFSPWD"
    printf 'N_NOTE=%q\n'      "$N_NOTE"
    printf 'N_ENABLED=%q\n'   "$N_ENABLED"
    printf 'N_URI=%q\n'       "$N_URI"
  } > "$f"
  chmod 600 "$f"
}

relay_count() {
  local f n=0
  [ -d "$RELAY_NODES" ] || { printf '0'; return 0; }
  for f in "$RELAY_NODES"/*.conf; do
    [ -e "$f" ] || continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# 中转机自己的公网 IP（客户端要连的地址）。
# 菜单每刷一屏都会调用它，必须带缓存：探测一次要访问三个外部站点，慢的时候能拖十几秒。
relay_listen_ip() {
  local ip="${MENU_IP:-}" f="${RELAY_DIR}/.pubip" ts="0" now="" age=0
  if [ -n "$ip" ]; then printf '%s' "$ip"; return 0; fi
  if [ -f "$f" ]; then
    ip="$(sed -n '1p' "$f" 2>/dev/null || true)"
    ts="$(sed -n '2p' "$f" 2>/dev/null || true)"
    [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
    now="$(date +%s)"
    age=$((now - ts))
    if [ -n "$ip" ] && [ "$age" -ge 0 ] && [ "$age" -lt 86400 ]; then
      printf '%s' "$ip"; return 0
    fi
  fi
  ip="$(detect_pubip)"
  if [ -n "$ip" ]; then
    mkdir -p "$RELAY_DIR" 2>/dev/null || true
    printf '%s\n%s\n' "$ip" "$(date +%s)" > "$f" 2>/dev/null || true
  fi
  printf '%s' "$ip"
}

# ------------------------------ 规则生成与下发 ------------------------------
# 把当前所有节点渲染成两个自带 shebang 的脚本，再执行它。
# 这样做的好处：开机自启只需要一个 sh 脚本，不依赖 /usr/local/bin/hy2 还在不在，
# 规则永远和 nodes/*.conf 一致（每次 apply 都整体重写，不用做增量 diff）。
relay_render() {
  local ipt n=0 seen="|" f ip tgt lines_pre lines_post
  ipt="$(command -v iptables 2>/dev/null || true)"
  [ -n "$ipt" ] || ipt="/sbin/iptables"
  mkdir -p "$RELAY_DIR"

  lines_pre=""
  lines_post=""

  for f in "$RELAY_NODES"/*.conf; do
    [ -e "$f" ] || continue
    relay_load "$f"
    [ "${N_ENABLED:-1}" = "1" ] || continue
    ip="$(resolve4 "$N_THOST")"
    if [ -z "$ip" ]; then
      warn "跳过 ${N_NAME}：解析不到 ${N_THOST} 的 IP"
      continue
    fi
    n=$((n + 1))
    lines_pre="${lines_pre}${ipt} -t nat -A HY2R_PRE -p udp --dport ${N_LISTEN} -j DNAT --to-destination ${ip}:${N_TPORT}
"
    tgt="|${ip}:${N_TPORT}|"
    case "$seen" in
      *"$tgt"*) : ;;   # 多条规则指向同一落地端口，一条 MASQUERADE 就够
      *) seen="${seen}${ip}:${N_TPORT}|"
         lines_post="${lines_post}${ipt} -t nat -A HY2R_POST -p udp -d ${ip} --dport ${N_TPORT} -j MASQUERADE
" ;;
    esac
  done

  RELAY_RULE_COUNT="$n"

  {
    printf '#!/bin/sh\n'
    printf '# 由 hy2 生成，勿手改；改规则请用 hy relay ...，会自动重写本文件\n'
    printf 'IPT=%s\n\n' "$ipt"
    printf '# nat 自定义链：只动自己的链，不碰系统上已有的规则\n'
    printf '$IPT -t nat -N HY2R_PRE 2>/dev/null\n'
    printf '$IPT -t nat -N HY2R_POST 2>/dev/null\n'
    printf '$IPT -t nat -C PREROUTING -j HY2R_PRE 2>/dev/null || $IPT -t nat -I PREROUTING 1 -j HY2R_PRE\n'
    printf '$IPT -t nat -C POSTROUTING -j HY2R_POST 2>/dev/null || $IPT -t nat -I POSTROUTING 1 -j HY2R_POST\n'
    printf '$IPT -t nat -F HY2R_PRE\n'
    printf '$IPT -t nat -F HY2R_POST\n\n'
    if [ "$n" -gt 0 ]; then
      printf '%s' "$lines_pre"
      printf '\n'
      printf '%s' "$lines_post"
    else
      printf '# 没有任何启用的规则：摘掉跳转并删掉自定义链\n'
      printf '$IPT -t nat -D PREROUTING -j HY2R_PRE 2>/dev/null\n'
      printf '$IPT -t nat -D POSTROUTING -j HY2R_POST 2>/dev/null\n'
      printf '$IPT -t nat -F HY2R_PRE 2>/dev/null\n'
      printf '$IPT -t nat -F HY2R_POST 2>/dev/null\n'
      printf '$IPT -t nat -X HY2R_PRE 2>/dev/null\n'
      printf '$IPT -t nat -X HY2R_POST 2>/dev/null\n'
    fi
    printf '\nexit 0\n'
  } > "$RELAY_APPLY"

  {
    printf '#!/bin/sh\n'
    printf '# 由 hy2 生成：移除全部转发规则（不卸载 Hysteria，只清 netfilter）\n'
    printf 'IPT=%s\n\n' "$ipt"
    printf '$IPT -t nat -D PREROUTING -j HY2R_PRE 2>/dev/null\n'
    printf '$IPT -t nat -D POSTROUTING -j HY2R_POST 2>/dev/null\n'
    printf '$IPT -t nat -F HY2R_PRE 2>/dev/null\n'
    printf '$IPT -t nat -F HY2R_POST 2>/dev/null\n'
    printf '$IPT -t nat -X HY2R_PRE 2>/dev/null\n'
    printf '$IPT -t nat -X HY2R_POST 2>/dev/null\n'
    printf 'exit 0\n'
  } > "$RELAY_CLEAR"

  chmod 755 "$RELAY_APPLY" "$RELAY_CLEAR"
}

# 转发必须的内核开关。QUIC 是长连接，conntrack 默认 30/120 秒太久不动就回收，
# 表现是「放着不用一会儿就断」，所以一并放大。
relay_sysctl() {
  local have_ct=0
  if has modprobe; then modprobe nf_conntrack >/dev/null 2>&1 || true; fi
  [ -e /proc/sys/net/netfilter/nf_conntrack_udp_timeout ] && have_ct=1

  {
    printf '# 由 hy2 生成：中转机转发开关\n'
    printf 'net.ipv4.ip_forward = 1\n'
    if [ "$have_ct" -eq 1 ]; then
      printf 'net.netfilter.nf_conntrack_udp_timeout = 300\n'
      printf 'net.netfilter.nf_conntrack_udp_timeout_stream = 1800\n'
    fi
  } > "$RELAY_SYSCTL"

  sysctl -p "$RELAY_SYSCTL" >/dev/null 2>&1 || true
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" != "1" ]; then
    warn "ip_forward 未能打开，转发不会生效（容器或受限内核常见）"
  fi
}

# 开机自启：一个 oneshot 服务，跑的就是上面生成的 apply.sh
relay_service() {
  detect_init
  case "$INIT_SYS" in
    systemd)
      cat > "${SYSTEMD_DIR}/${RELAY_SVC}.service" <<EOF
[Unit]
Description=HY2 relay (UDP DNAT to landing server)
After=network-online.target
Wants=network-online.target
ConditionPathExists=${RELAY_APPLY}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${RELAY_APPLY}
ExecStop=/bin/sh ${RELAY_CLEAR}

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload >/dev/null 2>&1 || true
      systemctl enable "$RELAY_SVC" >/dev/null 2>&1 || true
      systemctl restart "$RELAY_SVC" >/dev/null 2>&1 || true ;;
    openrc)
      cat > "${OPENRC_DIR}/${RELAY_SVC}" <<EOF
#!/sbin/openrc-run
description="HY2 relay (UDP DNAT to landing server)"

depend() { need net; after firewall; }

start() {
  ebegin "Applying HY2 relay rules"
  /bin/sh ${RELAY_APPLY}
  eend \$?
}

stop() {
  ebegin "Clearing HY2 relay rules"
  /bin/sh ${RELAY_CLEAR}
  eend \$?
}
EOF
      chmod 755 "${OPENRC_DIR}/${RELAY_SVC}"
      rc-update add "$RELAY_SVC" default >/dev/null 2>&1 || true
      rc-service "$RELAY_SVC" restart >/dev/null 2>&1 || true ;;
    *)
      warn "未识别 init 系统：规则重启后不会自动恢复，可把 ${RELAY_APPLY} 加进开机脚本" ;;
  esac
}

relay_apply() {
  local quiet="${1:-}" got=0
  relay_dep
  relay_sysctl
  relay_render

  if ! sh "$RELAY_APPLY"; then
    die "应用转发规则失败：容器里可能没有 nat 表，或内核模块被裁掉了"
  fi

  if [ "${RELAY_RULE_COUNT:-0}" -gt 0 ]; then
    got="$(iptables -t nat -S HY2R_PRE 2>/dev/null | grep -c '^-A' || true)"
    if [ "$got" != "$RELAY_RULE_COUNT" ]; then
      die "规则写入不完整（期望 ${RELAY_RULE_COUNT} 条，实际 ${got} 条）"
    fi
    relay_service
    [ "$quiet" = "--quiet" ] || ok "已应用 ${RELAY_RULE_COUNT} 条转发规则（开机自动恢复）"
  else
    [ "$quiet" = "--quiet" ] || info "没有启用的转发规则，已清空 netfilter 规则"
  fi
}

relay_clear() {
  relay_dep
  [ -f "$RELAY_CLEAR" ] || relay_render
  if ! sh "$RELAY_CLEAR"; then
    die "清理规则失败"
  fi
  ok "已清空全部转发规则"
}

# 中转后的分享链接：只换地址和端口，sni / pin / obfs 原样保留
relay_link() {
  local name="${1:-}" ip="${2:-}" q="" frag
  relay_get "$name" || return 1
  [ -z "$ip" ] && ip="$(relay_listen_ip)"
  [ -n "$N_SNI" ] && q="${q}&sni=$(uri_enc "$N_SNI")"
  [ "$N_INSECURE" = "1" ] && q="${q}&insecure=1"
  [ -n "$N_PIN" ] && q="${q}&pinSHA256=$(uri_enc "$N_PIN")"
  if [ -n "$N_OBFSPWD" ]; then
    q="${q}&obfs=${N_OBFSTYPE:-salamander}&obfs-password=$(uri_enc "$N_OBFSPWD")"
  fi
  q="${q#&}"
  [ -z "$q" ] && q="sni=$(uri_enc "$ip")"
  frag="HY2-${name}"
  printf 'hysteria2://%s@%s:%s/?%s#%s' "$(uri_enc "$N_PWD")" "$ip" "$N_LISTEN" "$q" "$(uri_enc "$frag")"
}

relay_list() {
  local with_link="${1:-}" ip="" i=0 f st
  if [ "$(relay_count)" -eq 0 ]; then
    info "还没有转发规则。用 hy relay add 添加，或在菜单里选 3"
    return 0
  fi
  ip="$(relay_listen_ip)"
  echo
  hr
  printf ' %s转发规则%s   共 %s 条\n' "$C_W" "$C_0" "$(relay_count)"
  hr
  for f in "$RELAY_NODES"/*.conf; do
    [ -e "$f" ] || continue
    relay_load "$f"
    i=$((i + 1))
    if [ "${N_ENABLED:-1}" = "1" ]; then st="启用"; else st="停用"; fi
    printf ' %2s) %-14s %-7s %-24s %s\n' "$i" "$N_NAME" ":${N_LISTEN}" "${N_THOST}:${N_TPORT}" "$st"
    [ -n "${N_NOTE:-}" ] && printf '      %s%s%s\n' "$C_D" "$N_NOTE" "$C_0"
  done
  hr
  hint "本机监听 → 落地目标；客户端连的是本机公网 IP + 左侧端口"

  if [ "$with_link" = "--links" ]; then
    for f in "$RELAY_NODES"/*.conf; do
      [ -e "$f" ] || continue
      relay_load "$f"
      [ "${N_ENABLED:-1}" = "1" ] || continue
      echo
      printf ' %s%s%s\n' "$C_B" "$N_NAME" "$C_0"
      printf ' %s\n' "$(relay_link "$N_NAME" "$ip")"
    done
    echo
  else
    echo
    hint "看链接：hy relay link <名字>    全部链接：hy relay list --links"
  fi
}

# 端口占用检查：不能和另一条转发、本机 Hysteria 服务端、其它 UDP 监听撞车。
# 返回 1 时把原因写在 stdout，由调用方决定是报错退出还是重新问一次
# （交互向导里要能重填，所以这里不能直接 die）。
relay_port_conflict() {
  local p="$1" self="${2:-}" f srvport="" who=""
  if [ -d "$RELAY_NODES" ]; then
    for f in "$RELAY_NODES"/*.conf; do
      [ -e "$f" ] || continue
      relay_load "$f"
      [ "$N_NAME" = "$self" ] && continue
      if [ "${N_LISTEN:-}" = "$p" ]; then
        printf 'UDP %s 已被转发规则 %s 占用，换一个端口' "$p" "$N_NAME"
        return 1
      fi
    done
  fi
  if [ -f "$META" ]; then
    srvport="$(awk -F= '/^M_PORT=/{gsub(/["\047]/,"",$2); print $2}' "$META" 2>/dev/null || true)"
    if [ -n "$srvport" ] && [ "$srvport" = "$p" ]; then
      printf 'UDP %s 是本机 Hysteria 服务端的端口，中转要换一个（如 20001）' "$p"
      return 1
    fi
  fi
  if has ss; then
    who="$(ss -lunp 2>/dev/null | awk -v P=":${p}$" 'NR>1 && $4 ~ P {print $NF}' | head -n1 || true)"
    if [ -n "$who" ]; then
      printf 'UDP %s 已被本机进程占用（%s），换一个端口' "$p" "$who"
      return 1
    fi
  fi
  return 0
}

relay_port_guard() {
  local reason=""
  reason="$(relay_port_conflict "${1:-}" "${2:-}")" || die "${reason}"
}

# ------------------------------ 添加 ------------------------------
# 从解析好的 P_* 落地信息生成一条转发
relay_add_commit() {
  local listen="$1" name="$2" note="$3" ip=""
  relay_port_guard "$listen" "$name"

  N_NAME="$name"
  N_LISTEN="$listen"
  N_THOST="$P_HOST"
  N_TPORT="$P_PORT"
  N_PWD="$P_PWD"
  N_SNI="$P_SNI"
  N_INSECURE="$P_INSECURE"
  N_PIN="$P_PIN"
  N_OBFSTYPE="$P_OBFSTYPE"
  N_OBFSPWD="$P_OBFSPWD"
  N_NOTE="$note"
  N_ENABLED="1"
  N_URI="$URI_RAW"
  relay_save

  relay_apply --quiet
  ip="$(relay_listen_ip)"

  ok "已添加：${name}   ${ip}:${listen} → ${P_HOST}:${P_PORT}（UDP）"
  echo
  printf ' %s新链接（把原来那条换成它）%s\n' "$C_W" "$C_0"
  printf ' %s\n' "$(relay_link "$name" "$ip")"
  echo
  hint "落地机上的节点不要删，删了这条转发就没目标了"
  hint "防火墙：中转机要放行 UDP ${listen}，落地机要放行 UDP ${P_PORT}（云厂商安全组也看一遍）"
}

relay_add_interactive() {
  local uri="" listen="" name="" note="" tries=0 defname=""
  step "添加转发节点"
  hint "在落地机上执行 hy → 2，把它给出的一条 hysteria2:// 链接整条粘贴过来"
  hint "落地机不用做任何改动，也不用知道中转机的存在"
  echo
  ask "落地机链接（回车改为手填）" uri ""
  uri="$(printf '%s' "$uri" | tr -d '[:space:]')"

  if [ -n "$uri" ]; then
    if ! parse_uri "$uri"; then
      warn "这不像 hysteria2:// 链接，检查一下有没有复制全"
      return 0
    fi
    URI_RAW="$uri"
  else
    # 手填：至少要有落地 IP、端口、密码
    local h="" p="" pw="" ob="" sni=""
    ask "落地机 IP 或域名" h ""
    is_ip "$h" || { [ -z "$h" ] && { info "已取消"; return 0; }; }
    ask "落地机端口" p "443"
    port_ok "$p" || { warn "端口不合法"; return 0; }
    ask "节点密码" pw ""
    [ -z "$pw" ] && { info "已取消"; return 0; }
    ask "混淆密码（没有就回车）" ob ""
    ask "SNI（没有就回车，默认落地机地址）" sni ""
    P_PWD="$pw"; P_HOST="$h"; P_PORT="$p"; P_SNI="$sni"
    P_OBFSTYPE=""; [ -n "$ob" ] && P_OBFSTYPE="salamander"
    P_OBFSPWD="$ob"; P_PIN=""; P_INSECURE="1"
    P_MPORT=""; P_NAME=""
    URI_RAW=""
  fi

  echo
  kv "落地地址      " "${P_HOST}:${P_PORT} (UDP)"
  kv "密码          " "${P_PWD}"
  [ -n "$P_SNI" ] && kv "SNI           " "${P_SNI}"
  [ -n "$P_PIN" ] && kv "pinSHA256     " "${P_PIN:0:16}…"
  [ -n "$P_OBFSPWD" ] && kv "混淆          " "${P_OBFSTYPE:-salamander} / ${P_OBFSPWD}"
  [ -n "$P_MPORT" ] && warn "原链接带端口跳跃 mport=${P_MPORT}，中转只转发单端口，跳跃会失效"
  echo

  local reason="" cand="" picked=0
  while [ "$tries" -lt 5 ]; do
    tries=$((tries + 1))
    ask "本机监听端口" listen "$P_PORT"
    if ! port_ok "$listen"; then warn "端口要在 1-65535 之间"; continue; fi
    if reason="$(relay_port_conflict "$listen" "")"; then picked=1; break; fi
    warn "${reason}"
    # 撞车后把默认值往前挪到一个空端口，免得每次回车都撞同一个
    cand="$listen"
    while [ "$cand" -lt 65000 ]; do
      cand=$((cand + 1))
      if relay_port_conflict "$cand" "" >/dev/null 2>&1; then P_PORT="$cand"; break; fi
    done
  done
  [ "$picked" -eq 1 ] || { warn "连试 5 次都不行，先退出"; return 0; }

  defname="$(printf '%s' "$P_HOST" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-24)"
  defname="${defname#-}"; defname="${defname%-}"
  [ -z "$defname" ] && defname="node$(relay_count)"
  while :; do
    ask "名字（字母数字，用于区分多条）" name "$defname"
    relay_name_ok "$name" && break
    warn "名字只能用字母数字和 . _ -"
    [ "$ASSUME_YES" -eq 1 ] && return 0
  done
  ask "备注（可空）" note ""

  relay_add_commit "$listen" "$name" "$note"
}

# ------------------------------ 修改 / 删除 ------------------------------
relay_pick() { # relay_pick "提示" -> PICK_NAME
  local prompt="$1" i=0 f idx names=()
  if [ "$(relay_count)" -eq 0 ]; then info "还没有转发规则"; return 1; fi
  for f in "$RELAY_NODES"/*.conf; do
    [ -e "$f" ] || continue
    relay_load "$f"
    i=$((i + 1))
    names+=("$N_NAME")
    printf ' %2s) %-14s %-7s %s\n' "$i" "$N_NAME" ":${N_LISTEN}" "${N_THOST}:${N_TPORT}"
  done
  echo
  read -r -p "${C_B}?${C_0} ${prompt} [1]: " idx || true
  idx="${idx:-1}"
  [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#names[@]}" ] || { warn "序号不对"; return 1; }
  PICK_NAME="${names[$((idx - 1))]}"
}

relay_edit() {
  local name="${1:-}" listen="" note="" en=""
  if [ -z "$name" ]; then
    relay_pick "改哪一条" || return 1
    name="$PICK_NAME"
  fi
  relay_get "$name" || return 1

  step "修改转发：${name}"
  kv "落地          " "${N_THOST}:${N_TPORT} (UDP)"
  kv "本机监听      " "UDP ${N_LISTEN}"
  kv "状态          " "$([ "${N_ENABLED:-1}" = "1" ] && echo 启用 || echo 停用)"
  echo
  hint "落地地址不在这里改：换落地机请删掉重建，免得密码和落地机对不上"
  echo
  ask "本机监听端口" listen "$N_LISTEN"
  port_ok "$listen" || { warn "端口不合法"; return 1; }
  relay_port_guard "$listen" "$name"
  ask "备注" note "${N_NOTE:-}"
  if [ "${N_ENABLED:-1}" = "1" ]; then
    if confirm "保持启用？选 n 则暂时停用（保留配置）" "y"; then en="1"; else en="0"; fi
  else
    if confirm "现在启用？" "y"; then en="1"; else en="0"; fi
  fi

  # 端口变了，旧链接就失效了，提前说清楚
  if [ "$listen" != "$N_LISTEN" ]; then
    warn "监听端口从 ${N_LISTEN} 改成 ${listen}，客户端要换新链接"
  fi

  N_LISTEN="$listen"
  N_NOTE="$note"
  N_ENABLED="$en"
  relay_save
  relay_apply --quiet
  ok "已保存并生效"
  printf ' %s\n' "$(relay_link "$name")"
}

relay_del() {
  local name="${1:-}" sure=""
  if [ -z "$name" ]; then
    relay_pick "删哪一条" || return 1
    name="$PICK_NAME"
  fi
  relay_get "$name" || return 1
  kv "落地          " "${N_THOST}:${N_TPORT}"
  kv "本机监听      " "UDP ${N_LISTEN}"
  if [ "$ASSUME_YES" -eq 0 ]; then
    warn "只删本机转发规则，不动落地机上的 Hysteria"
    ask "输入名字确认删除：${name}" sure ""
    [ "$sure" = "$name" ] || { info "已取消"; return 0; }
  fi
  rm -f "${RELAY_NODES}/${name}.conf" 2>/dev/null || true
  relay_apply --quiet
  ok "已删除 ${name}，规则已重算"
}

relay_toggle() {
  local name="${1:-}" to="${2:-}"
  if [ -z "$name" ]; then
    relay_pick "改哪一条的启停" || return 1
    name="$PICK_NAME"
  fi
  relay_get "$name" || return 1
  [ -z "$to" ] && { if [ "${N_ENABLED:-1}" = "1" ]; then to="0"; else to="1"; fi; }
  N_ENABLED="$to"
  relay_save
  relay_apply --quiet
  if [ "$to" = "1" ]; then ok "${name} 已启用"; else ok "${name} 已停用（配置保留，随时可开）"; fi
}

# ------------------------------ 排障 ------------------------------
relay_diag() {
  local f n=0 ip
  step "转发链路自检"
  relay_dep

  if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" = "1" ]; then
    ok "ip_forward = 1"
  else
    warn "ip_forward != 1，转发不会生效；执行 hy relay apply 重新写入"
  fi

  if iptables -t nat -S HY2R_PRE >/dev/null 2>&1; then
    n="$(iptables -t nat -S HY2R_PRE 2>/dev/null | grep -c '^-A' || true)"
    ok "自定义链 HY2R_PRE 存在，规则 ${n} 条"
  else
    warn "自定义链不存在：还没添加过规则，或者被别的防火墙工具清掉了"
    return 0
  fi

  echo
  printf ' %s命中计数（第一列是包数，为 0 说明客户端根本没打到这里）%s\n' "$C_D" "$C_0"
  iptables -t nat -L HY2R_PRE -vn 2>/dev/null || true
  echo

  for f in "$RELAY_NODES"/*.conf; do
    [ -e "$f" ] || continue
    relay_load "$f"
    ip="$(resolve4 "$N_THOST")"
    if [ -z "$ip" ]; then
      warn "${N_NAME}：解析不到 ${N_THOST}"
    elif [ "$ip" != "$N_THOST" ]; then
      info "${N_NAME}：${N_THOST} → ${ip}"
    fi
  done

  echo
  hint "包数不动：客户端连的地址/端口不对，或中转机安全组没放行"
  hint "包数在涨但连不上：落地机没放行 UDP，或落地机服务没起（落地机上 hy status 看）"
  hint "两边都正常但仍断：落地机把客户端 IP 当成了中转机 IP，多设备限速类功能会失效"
}

# ------------------------------ 命令行入口 ------------------------------
do_relay() {
  need_root
  local sub="${SUB[0]:-list}" name="${SUB[1]:-}" listen="" ip=""

  case "$sub" in
    add|a)
      if [ -n "${RELAY_LINK:-}" ]; then
        parse_uri "$RELAY_LINK" || die "链接解析失败，需要 hysteria2:// 开头"
        URI_RAW="$RELAY_LINK"
      elif [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
        relay_add_interactive
        return 0
      else
        die "非交互添加需要 --link <落地机链接>"
      fi
      listen="${RELAY_LISTEN_ARG:-}"
      [ -z "$listen" ] && listen="$P_PORT"
      port_ok "$listen" || die "监听端口不合法：${listen}"
      name="${RELAY_NAME:-}"
      if [ -z "$name" ]; then
        name="$(printf '%s' "$P_HOST" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-24)"
        name="${name#-}"; name="${name%-}"
      fi
      relay_name_ok "$name" || die "名字只能用字母数字和 . _ -"
      [ -f "${RELAY_NODES}/${name}.conf" ] && { [ "$FORCE" -eq 1 ] || die "已存在 ${name}，加 --force 覆盖，或换个 --name"; }
      relay_add_commit "$listen" "$name" "${RELAY_NOTE:-}"
      ;;
    list|ls)
      relay_list "${SUB[1]:-}"
      ;;
    link)
      [ -n "$name" ] || die "用法：hy relay link <名字>"
      ip="$(relay_listen_ip)"
      local one=""
      one="$(relay_link "$name" "$ip")" || exit 1
      [ -n "$one" ] || exit 1
      printf '%s\n' "$one"
      ;;
    del|rm|delete)
      relay_del "$name"
      ;;
    edit|mod)
      relay_edit "$name"
      ;;
    enable)  relay_toggle "$name" "1" ;;
    disable) relay_toggle "$name" "0" ;;
    apply)   relay_apply ;;
    clear)   relay_clear ;;
    diag|test) relay_diag ;;
    menu)    relay_menu ;;
    *) die "用法：hy relay [add|list|link|edit|del|enable|disable|apply|clear|diag]" ;;
  esac
}

relay_menu() {
  local c=""
  while :; do
    echo
    relay_list
    echo
    printf '   %s1%s) 添加转发\n' "$C_B" "$C_0"
    printf '   %s2%s) 改端口 / 备注 / 启停\n' "$C_B" "$C_0"
    printf '   %s3%s) 删除\n' "$C_B" "$C_0"
    printf '   %s4%s) 全部链接\n' "$C_B" "$C_0"
    printf '   %s5%s) 重新应用规则\n' "$C_B" "$C_0"
    printf '   %s6%s) 排障自检\n' "$C_B" "$C_0"
    printf '   %s0%s) 返回\n' "$C_B" "$C_0"
    read -r -p "${C_B}?${C_0} 选择 [1]: " c || return 0
    case "${c:-1}" in
      1) relay_add_interactive ;;
      2) relay_edit ;;
      3) relay_del ;;
      4) relay_list --links ;;
      5) relay_apply ;;
      6) relay_diag ;;
      0|q|Q) return 0 ;;
      *) warn "输入 0-6" ;;
    esac
  done
}

# ------------------------------ hy 命令 ------------------------------
# 把脚本自身装到本机，之后敲 hy 就能进菜单，不用每次 curl
self_install() {
  local tmp="/usr/local/bin/.hy2.$$" okk=0
  mkdir -p /usr/local/bin 2>/dev/null || true

  if has curl && curl -fsSL --max-time 40 "$SELF_URL" -o "$tmp" 2>/dev/null; then
    if head -n1 "$tmp" 2>/dev/null | grep -q '^#!/usr/bin/env bash'; then
      chmod 755 "$tmp" 2>/dev/null || true
      mv -f "$tmp" "$CLI_BIN" 2>/dev/null && okk=1
    fi
  fi
  [ "$okk" -eq 0 ] && rm -f "$tmp" 2>/dev/null || true

  # 拿不到网络时，如果本来就是从本地文件运行的，直接拷一份
  if [ "$okk" -eq 0 ] && [ -f "$0" ] && [ "$0" != "$CLI_BIN" ]; then
    cp -f "$0" "$CLI_BIN" 2>/dev/null && chmod 755 "$CLI_BIN" 2>/dev/null && okk=1 || true
  fi

  if [ "$okk" -eq 0 ]; then
    warn "没能安装 hy 命令（下载失败），不影响当前操作"
    return 1
  fi

  cat > /usr/local/bin/hy <<'WRAP'
#!/bin/sh
# hy —— Hysteria2 管理台；不带参数进菜单，带参数等同 hy2 <参数>
[ $# -eq 0 ] && exec /usr/local/bin/hy2 menu
exec /usr/local/bin/hy2 "$@"
WRAP
  chmod 755 /usr/local/bin/hy
  ok "已安装命令：hy（菜单） / hy2（子命令）"
}

# ------------------------------ 主菜单 ------------------------------
menu_banner() {
  local srv="未安装" rt="0" ip="${MENU_IP:-}" os=""
  if [ -f "$HY2_CONF" ]; then
    if svc_active; then srv="运行中"; else srv="未运行"; fi
  fi
  rt="$(relay_count)"
  os="$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null | head -n1 || true)"
  [ -z "$os" ] && os="$(uname -s)"

  echo
  hr
  printf ' %sHysteria2 管理台%s   %sv%s%s\n' "$C_W" "$C_0" "$C_D" "$SCRIPT_VERSION" "$C_0"
  hr
  printf ' 本机    %s   %s   %s\n' "${ip:-未知}" "$os" "${INIT_SYS:-none}"
  printf ' 服务端  %s   %s\n' "$srv" "转发 ${rt} 条"
  hr
  # 单列排版：中文与 ASCII 混排时靠空格对齐必然错位（汉字 2 列、字节 3 个），
  # 与其手工补空格，不如一列一个功能，怎么都不会歪。
  printf '  %s1%s) 安装 / 重装服务端\n' "$C_B" "$C_0"
  printf '  %s2%s) 节点信息与分享链接\n' "$C_B" "$C_0"
  printf '  %s3%s) 添加转发（落地机 → 本机）\n' "$C_B" "$C_0"
  printf '  %s4%s) 转发管理（改 / 删 / 启停 / 排障）\n' "$C_B" "$C_0"
  printf '  %s5%s) 服务状态、重启、日志\n' "$C_B" "$C_0"
  printf '  %s6%s) 修改伪装站点\n' "$C_B" "$C_0"
  printf '  %s7%s) 升级 Hysteria / 卸载\n' "$C_B" "$C_0"
  printf '  %s8%s) 更新 hy 命令\n' "$C_B" "$C_0"
  printf '  %s0%s) 退出\n' "$C_B" "$C_0"
  hr
}

menu_service() {
  local c=""
  echo
  detect_init
  svc_status || true
  printf '   %s1%s) 重启   %s2%s) 日志   %s3%s) 状态   %s0%s) 返回\n' "$C_B" "$C_0" "$C_B" "$C_0" "$C_B" "$C_0" "$C_B" "$C_0"
  read -r -p "${C_B}?${C_0} 选择 [0]: " c || return 0
  case "${c:-0}" in
    1) if svc_restart; then sleep 2; svc_active && ok "已重启" || warn "没起来，看日志"; else warn "重启失败"; fi ;;
    2) svc_log_follow ;;
    3) svc_status ;;
  esac
}

menu_misc() {
  local c=""
  echo
  printf '   %s1%s) 升级 Hysteria 二进制\n' "$C_B" "$C_0"
  printf '   %s2%s) 卸载服务端\n' "$C_B" "$C_0"
  printf '   %s0%s) 返回\n' "$C_B" "$C_0"
  read -r -p "${C_B}?${C_0} 选择 [0]: " c || return 0
  case "${c:-0}" in
    1) do_upgrade ;;
    2) do_uninstall ;;
  esac
}

do_menu() {
  need_root
  detect_init
  MENU_IP="$(detect_pubip)"
  local c=""
  while :; do
    menu_banner
    read -r -p "${C_B}?${C_0} 选择 [0]: " c || break
    case "${c:-0}" in
      1) do_install ;;
      2)
        if [ -f "$META" ]; then print_info; else warn "本机未安装 Hysteria2 服务端，只做中转"; fi
        if [ "$(relay_count)" -gt 0 ]; then relay_list --links; fi ;;
      3) relay_add_interactive ;;
      4) relay_menu ;;
      5) menu_service ;;
      6) if [ -f "$META" ]; then do_masq; else warn "本机未安装服务端，没有伪装站点可改"; fi ;;
      7) menu_misc ;;
      8) self_install ;;
      0|q|Q) break ;;
      *) warn "输入 0-8" ;;
    esac
    echo
    [ "$c" = "1" ] || { read -r -p "${C_D}回车返回菜单${C_0}" _ || true; }
  done
  ok "已退出"
}

case "$ACTION" in
  install)   do_install ;;
  menu)      do_menu ;;
  relay)     do_relay ;;
  info)      need_root; detect_init; print_info ;;
  masq)      do_masq ;;
  status)    detect_init; svc_status ;;
  log)       detect_init; svc_log_follow ;;
  restart)   need_root; detect_init; if svc_restart; then ok "已重启"; else die "重启失败"; fi ;;
  upgrade)   do_upgrade ;;
  uninstall) do_uninstall ;;
esac
