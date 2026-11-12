#!/usr/bin/env bash
# ==============================================================================
#  Hysteria2 一键部署脚本（裸机 / systemd，非 Docker）
#
#  适用系统：Debian 11+ / Ubuntu 20.04+ / Rocky 8+ / CentOS Stream 8+ / Fedora 37+
#  协议版本：Hysteria v2.13.x（自动拉取 GitHub 最新 release）
#  脚本版本：1.0.0
#
#  用法：
#    bash install.sh                          # 交互式向导（推荐）
#    bash install.sh --yes                    # 全默认，零交互
#    bash install.sh --domain a.com --email me@a.com --yes
#    bash install.sh info | status | log | restart | upgrade | uninstall
#
#  在线执行：
#    bash <(curl -fsSL https://raw.githubusercontent.com/<你>/<仓库>/main/install.sh)
#
#  脚本只会改动这些路径：
#    /usr/local/bin/hysteria
#    /etc/hysteria/{config.yaml,cert.pem,key.pem,.install.meta}
#    /etc/systemd/system/hysteria-server.service
#    /etc/sysctl.d/99-hysteria.conf
# ==============================================================================

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"

# ------------------------------ 常量与默认值 ------------------------------
HY2_BIN="/usr/local/bin/hysteria"
HY2_DIR="/etc/hysteria"
HY2_CONF="${HY2_DIR}/config.yaml"
META="${HY2_DIR}/.install.meta"
UNIT="/etc/systemd/system/hysteria-server.service"
SYSCTL_FILE="/etc/sysctl.d/99-hysteria.conf"
SVC="hysteria-server"

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
TUNE=1
ASSUME_YES=0
FORCE=0
ACTION="install"

# ------------------------------ 输出样式 ------------------------------
if [ -t 1 ]; then
  C_R="\033[31m"; C_G="\033[32m"; C_Y="\033[33m"; C_B="\033[36m"; C_W="\033[1m"; C_D="\033[2m"; C_0="\033[0m"
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_W=""; C_D=""; C_0=""
fi
info() { printf "${C_B}[*]${C_0} %s\n" "$*"; }
ok()   { printf "${C_G}[✓]${C_0} %s\n" "$*"; }
warn() { printf "${C_Y}[!]${C_0} %s\n" "$*"; }
die()  { printf "${C_R}[×]${C_0} %s\n" "$*" >&2; exit 1; }
hr()   { printf "${C_D}%s${C_0}\n" "------------------------------------------------------------"; }
step() { printf "\n${C_W}▸ %s${C_0}\n" "$*"; }

trap 'die "第 ${LINENO} 行执行失败，已中止"' ERR

# ------------------------------ 基础工具 ------------------------------
need_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo -i"; }
has() { command -v "$1" >/dev/null 2>&1; }
is_ip() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$1" == *:* ]]; }

pkg_mgr() {
  if has apt-get; then echo apt
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
    *) warn "未识别的包管理器，请手动安装：${missing[*]}" ;;
  esac
}

# ------------------------------ 交互组件 ------------------------------
ask() { # ask "提示" 变量名 默认值
  local prompt="$1" var="$2" def="${3:-}" ans=""
  if [ "$ASSUME_YES" -eq 1 ]; then printf -v "$var" '%s' "$def"; return 0; fi
  if [ -n "$def" ]; then
    read -r -p "$(printf "${C_B}?${C_0} %s [%s]: " "$prompt" "$def")" ans || true
    ans="${ans:-$def}"
  else
    read -r -p "$(printf "${C_B}?${C_0} %s: " "$prompt")" ans || true
  fi
  printf -v "$var" '%s' "$ans"
}

confirm() { # confirm "提示" 默认值(y/n)
  local prompt="$1" def="${2:-y}" ans=""
  [ "$ASSUME_YES" -eq 1 ] && { [ "$def" = "y" ]; return; }
  read -r -p "$(printf "${C_Y}?${C_0} %s [%s]: " "$prompt" "$def")" ans || true
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy] ]]
}

choose() { # choose "提示" 变量名 选项1 选项2 ...
  local prompt="$1" var="$2"; shift 2
  local -a opts=("$@")
  local i ans
  [ "$ASSUME_YES" -eq 1 ] && { printf -v "$var" '%s' "1"; return 0; }
  for i in "${!opts[@]}"; do
    printf "   ${C_B}%d${C_0}) %s\n" "$((i + 1))" "${opts[$i]}"
  done
  while :; do
    read -r -p "$(printf "${C_B}?${C_0} %s [1]: " "$prompt")" ans || true
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
Hysteria2 一键部署脚本

命令（默认 install）：
  install        安装 / 重装
  info           打印节点信息与分享链接
  status         查看服务状态
  log            查看实时日志
  restart        重启服务
  upgrade        升级到最新版本
  uninstall      卸载（含服务与配置）

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
  --bw-up <带宽>         服务端上行带宽，如 "100 mbps"
  --bw-down <带宽>       服务端下行带宽
  --no-tune              不写入内核调优
  --version <vX.Y.Z>     指定 Hysteria 版本，默认最新
  --yes, -y              零交互
  --force                已安装时直接覆盖
  -h, --help             帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    install|info|status|log|restart|upgrade|uninstall) ACTION="$1"; shift ;;
    --domain)        DOMAIN="${2:-}"; MODE="acme"; MODE_SET=1; shift 2 ;;
    --email)         EMAIL="${2:-}"; shift 2 ;;
    --ip|--selfsigned) MODE="selfsigned"; MODE_SET=1; shift ;;
    --host)          HOST="${2:-}"; shift 2 ;;
    --port)          PORT="${2:-}"; shift 2 ;;
    --password)      PASSWORD="${2:-}"; shift 2 ;;
    --obfs-password) OBFS_PASSWORD="${2:-}"; shift 2 ;;
    --no-obfs)       USE_OBFS=0; shift ;;
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
    *) die "未知参数：$1（--help 查看帮助）" ;;
  esac
done

# 通过 curl | bash 执行时，stdin 是脚本内容，交互输入需改走终端
# 用真实打开测试而非 [ -e ]：容器里 /dev/tty 可能存在但打不开
if [ "$ASSUME_YES" -eq 0 ] && [ "$ACTION" = "install" ] && [ ! -t 0 ] && { : </dev/tty; } 2>/dev/null; then
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
get_version() {
  local v
  v="$("$HY2_BIN" version 2>/dev/null | sed -n '1p' | tr -d '\r' || true)"
  printf '%s' "${v:-unknown}"
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

  CERT_PIN="$(openssl x509 -in "${HY2_DIR}/cert.pem" -noout -fingerprint -sha256 \
              | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f')"
  ok "证书已生成，pinSHA256 = ${CERT_PIN}"
}

# ------------------------------ 配置 / 服务 ------------------------------
write_config() {
  local tmpc; tmpc="$(mktemp)"

  {
    echo "# ============================================================"
    echo "# Hysteria2 服务端配置"
    echo "# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')   脚本版本：${SCRIPT_VERSION}"
    echo "# 文档：https://v2.hysteria.network/zh/docs/"
    echo "# 改完执行：systemctl restart ${SVC}"
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

tune_sysctl() {
  if [ -f "$SYSCTL_FILE" ]; then
    info "内核参数已存在，跳过：${SYSCTL_FILE}"
    return 0
  fi
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
  sysctl --system >/dev/null 2>&1 || true
  ok "内核调优已写入（fq + BBR + UDP 缓冲 16MB）"
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
    ok "iptables 已放行：${ports[*]}（重启后不保留，如需持久化请装 iptables-persistent）"
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
  local host="$1" port="$2" pwd="$3" obfs="$4" sni="$5" insecure="$6" name="$7"
  local q="" out_host="$host"
  [[ "$host" == *:* ]] && [[ "$host" != \[*\] ]] && out_host="[${host}]"
  [ -n "$sni" ] && q="${q}&sni=$(uri_enc "$sni")"
  [ "$insecure" = "1" ] && q="${q}&insecure=1"
  [ -n "$obfs" ] && q="${q}&obfs=salamander&obfs-password=$(uri_enc "$obfs")"
  q="${q#&}"
  [ -z "$q" ] && q="sni=$(uri_enc "$host")"
  printf 'hysteria2://%s@%s:%s/?%s#%s' "$(uri_enc "$pwd")" "$out_host" "$port" "$q" "$(uri_enc "$name")"
}

print_info() {
  load_meta
  local host="${M_HOST:-${M_DOMAIN:-}}" sni="" insecure=0 pin="" uri=""
  if [ "${M_MODE:-}" = "acme" ]; then
    sni="${M_DOMAIN}"; insecure=0
  else
    sni="$host"; insecure=1; pin="${M_PIN:-}"
  fi

  uri="$(build_uri "$host" "$M_PORT" "$M_PASSWORD" "$M_OBFS" "$sni" "$insecure" "HY2-${host}")"

  echo
  hr
  printf " ${C_G}${C_W}Hysteria2 节点信息${C_0}\n"
  hr
  printf " %-12s %s\n" "版本"     "${M_VER:-unknown}"
  printf " %-12s %s\n" "地址"     "${host}"
  printf " %-12s %s\n" "端口"     "${M_PORT} (UDP)"
  printf " %-12s %s\n" "密码"     "${M_PASSWORD}"
  printf " %-12s %s\n" "SNI"      "${sni}"
  if [ "$insecure" = "1" ]; then
    printf " %-12s %s\n" "跳过验证" "是（自签证书）"
  else
    printf " %-12s %s\n" "跳过验证" "否（正式证书）"
  fi
  [ -n "${M_OBFS:-}" ] && printf " %-12s %s\n" "混淆" "salamander / ${M_OBFS}"
  [ -n "$pin" ] && printf " %-12s %s\n" "pinSHA256" "${pin}"
  [ -n "${M_MASQ:-}" ] && printf " %-12s %s\n" "伪装站点" "${M_MASQ}"
  hr
  echo
  printf "${C_B}分享链接${C_0}\n"
  printf '%s\n' "$uri"
  echo

  if has qrencode; then
    qrencode -t ANSIUTF8 -m 1 "$uri" 2>/dev/null || true
  else
    info "需要二维码：apt install -y qrencode"
  fi

  hr
  printf "${C_B}Clash Meta / mihomo${C_0}\n"
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
  printf "${C_B}sing-box（outbound）${C_0}\n"
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
  echo
  info "配置文件：${HY2_CONF}    服务：systemctl status ${SVC}"
}

# ------------------------------ 安装向导 ------------------------------
collect_config() {
  local pubip=""
  pubip="$(detect_pubip)"
  [ -n "$pubip" ] && info "检测到公网 IP：${C_W}${pubip}${C_0}" || warn "未能自动获取公网 IP，请手动输入"

  # --- 1. 连接地址 ---
  step "1/6  客户端连接地址"
  # 走 ACME 且已给域名时，连接地址默认用域名
  if [ "$MODE" = "acme" ] && [ -n "$DOMAIN" ] && { [ -z "$HOST" ] || is_ip "$HOST"; }; then
    HOST="$DOMAIN"
  fi
  if [ -z "$HOST" ]; then
    ask "域名或 IP（回车使用 ${pubip:-检测值}）" HOST "$pubip"
  else
    ask "域名或 IP" HOST "$HOST"
  fi
  [ -n "$HOST" ] || die "连接地址不能为空"

  # --- 2. 端口 ---
  step "2/6  监听端口"
  echo "   ${C_D}Hysteria2 走 UDP。部分机房对 443 有 QoS，可改 8443 / 2096 等${C_0}"
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
      resolved="$(getent ahosts "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
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
  ask "密码（回车使用随机值）" PASSWORD "$PASSWORD"

  # --- 5. 混淆 ---
  step "5/6  流量混淆"
  echo "   ${C_D}salamander 会给 QUIC 包加一层异或混淆，抗主动探测，建议开启${C_0}"
  if confirm "启用 salamander 混淆？" "y"; then
    USE_OBFS=1
    [ -z "$OBFS_PASSWORD" ] && OBFS_PASSWORD="$(rand_hex 16)"
    ask "混淆密码（回车使用随机值）" OBFS_PASSWORD "$OBFS_PASSWORD"
  else
    USE_OBFS=0
  fi

  # --- 6. 伪装 / 调优 ---
  step "6/6  伪装与调优"
  echo "   ${C_D}伪装站点决定别人扫到你端口时看到什么页面${C_0}"

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
      esac ;;
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
  printf " ${C_W}即将执行${C_0}\n"
  hr
  printf " %-12s %s\n" "连接地址" "${HOST}"
  printf " %-12s %s\n" "端口"     "${PORT}/udp"
  printf " %-12s %s\n" "证书"     "$([ "$MODE" = "acme" ] && echo "ACME 自动签发（${DOMAIN}）" || echo "自签（pinSHA256）")"
  printf " %-12s %s\n" "密码"     "${PASSWORD}"
  printf " %-12s %s\n" "混淆"     "$([ "$USE_OBFS" -eq 1 ] && echo "salamander / ${OBFS_PASSWORD}" || echo "关闭")"
  printf " %-12s %s\n" "伪装站点" "$([ "$MASQ_MODE" = "none" ] && echo "关闭（返回 404）" || echo "${MASQ_URL}")"
  printf " %-12s %s\n" "内核调优" "$([ "$TUNE" -eq 1 ] && echo "是" || echo "否")"
  hr
  echo
}

# ------------------------------ 安装主流程 ------------------------------
do_install() {
  need_root
  has systemctl || die "未检测到 systemd，本脚本不支持 OpenWrt / Alpine"

  echo
  hr
  printf " ${C_W}Hysteria2 一键部署${C_0}   ${C_D}v${SCRIPT_VERSION}${C_0}\n"
  hr

  if [ -f "$HY2_CONF" ] && [ "$FORCE" -eq 0 ]; then
    warn "检测到已安装：${HY2_CONF}"
    if [ "$ASSUME_YES" -eq 1 ]; then
      die "已存在配置，零交互模式不覆盖。需要重装请加 --force（先 bash install.sh info 记下节点信息）"
    fi
    if ! confirm "覆盖现有配置并重装？" "n"; then
      info "已取消。查看节点：bash install.sh info"
      exit 0
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
  [ "$ASSUME_YES" -eq 0 ] && { confirm "确认开始安装？" "y" || { info "已取消"; exit 0; }; }

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
  [ "$TUNE" -eq 1 ] && tune_sysctl || info "跳过内核调优"

  step "启动服务"
  systemctl enable "$SVC" >/dev/null 2>&1 || true
  systemctl restart "$SVC"
  sleep 3

  if systemctl is-active --quiet "$SVC"; then
    ok "服务已运行"
  else
    warn "服务未正常运行，最近日志："
    journalctl --no-pager -n 25 -u "$SVC" || true
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
  M_VER="$(get_version)"
  M_MASQ="$MASQ_URL"
  save_meta

  print_info
  ok "部署完成。日志：journalctl -u ${SVC} -f"
}

do_upgrade() {
  need_root
  [ -f "$META" ] || die "未找到安装信息 ${META}，请先执行 install"
  # shellcheck disable=SC1090
  . "$META"
  PINNED_VERSION="latest"
  install_binary
  systemctl restart "$SVC"
  sleep 2
  if systemctl is-active --quiet "$SVC"; then
    ok "升级完成：$(get_version)"
  else
    warn "服务未启动，执行 journalctl -u ${SVC} -n 30 查看"
  fi
  M_VER="$(get_version)"
  save_meta
}

do_uninstall() {
  need_root
  warn "将停止并删除：${HY2_BIN}、${HY2_DIR}、${UNIT}"
  confirm "确认卸载？" "n" || { info "已取消"; exit 0; }
  systemctl stop "$SVC" 2>/dev/null || true
  systemctl disable "$SVC" 2>/dev/null || true
  rm -f "$UNIT"
  systemctl daemon-reload
  rm -rf "$HY2_DIR"
  rm -f "$HY2_BIN"
  rm -f "$SYSCTL_FILE"
  ok "已卸载（防火墙规则请按需手动清理）"
}

case "$ACTION" in
  install)   do_install ;;
  info)      need_root; print_info ;;
  status)    systemctl status "$SVC" --no-pager -l ;;
  log)       journalctl -u "$SVC" -f --no-pager ;;
  restart)   need_root; systemctl restart "$SVC" && ok "已重启" ;;
  upgrade)   do_upgrade ;;
  uninstall) do_uninstall ;;
esac
