#!/usr/bin/env bash
# Shadowsocks 交互安装（跨发行版）
#
# wget -O shadowsocks.sh https://raw.githubusercontent.com/lichen930122-lang/ss-install/main/shadowsocks.sh
# chmod +x shadowsocks.sh
# ./shadowsocks.sh 2>&1 | tee shadowsocks.log
#
# 卸载: ./shadowsocks.sh uninstall
# 改密码: ./shadowsocks.sh set-pass [端口] [密码]
# 看链接: ./shadowsocks.sh airlink [端口]
#
# 安装时可选：单端口单用户（原版），或多端口多人（一端口一密码）

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

CONF_DIR="/etc/shadowsocks"
CONF_FILE="${CONF_DIR}/config.json"
SERVICE_NAME="shadowsocks"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
OPENRC_FILE="/etc/init.d/${SERVICE_NAME}"
BIN_LIBEV=""
BIN_RUST="/usr/local/bin/ssserver"
SS_IMPL=""
SS_IMPL_MODE="auto"
SS_BIN=""
SS_RUST_VERSION="${SS_RUST_VERSION:-1.25.0}"
SS_PROFILE="single"
SS_USER_COUNT=1
SS_PORT_END=""
USERS_FILE="/root/shadowsocks-users.txt"
SS_PORTS=()
SS_PWDS=()
SS_IP_LIMIT=0
LIMIT_BIN="/usr/local/sbin/shadowsocks-ip-limit.py"
LIMIT_PORTS_FILE="${CONF_DIR}/ip-limit.ports"
LIMIT_STATE_DIR="/var/lib/shadowsocks/ip-limit"
LIMIT_UNIT="/etc/systemd/system/shadowsocks-ip-limit.service"
REGISTER_PORT_FILE="${CONF_DIR}/register.port"
REGISTER_CERT="${CONF_DIR}/register.crt"
REGISTER_KEY="${CONF_DIR}/register.key"
REGISTER_SPKI_FILE="${CONF_DIR}/register.spki"
REGISTER_SPKI=""
TOKEN_PORT="${TOKEN_PORT:-443}"

modes=(tcp_and_udp tcp_only udp_only)
mode_hints=("TCP + UDP（推荐）" "仅 TCP" "仅 UDP")

ciphers=(
  chacha20-ietf-poly1305
  aes-256-gcm
  aes-128-gcm
  xchacha20-ietf-poly1305
  aes-192-gcm
  aes-256-cfb
  aes-128-cfb
  chacha20-ietf
)
cipher_hints=(
  "推荐，速度快"
  "推荐，兼容性最好"
  "更省 CPU"
  "AEAD，部分旧服务端不支持"
  "AEAD"
  "旧客户端"
  "旧客户端"
  "旧流密码，不推荐"
)

error() { echo -e "[${red}Error${plain}] $*" >&2; exit 1; }
info() { echo -e "[${green}Info${plain}] $*"; }
warn() { echo -e "[${yellow}Warn${plain}] $*"; }
step() { echo -e "[${green}进行中${plain}] $*"; }

ask() {
  local prompt="$1" var="$2"
  local value=""
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt" value < /dev/tty
  else
    read -r -p "$prompt" value
  fi
  printf -v "$var" '%s' "$value"
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || error "请用 root 运行: sudo bash $0"
    exec sudo -E bash "$0" "$@"
  fi
}

detect_os() {
  OS_ID=""
  OS_LIKE=""
  PKG=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  fi
  if command -v apt-get >/dev/null 2>&1; then
    PKG=apt
  elif command -v dnf >/dev/null 2>&1; then
    PKG=dnf
  elif command -v yum >/dev/null 2>&1; then
    PKG=yum
  elif command -v apk >/dev/null 2>&1; then
    PKG=apk
  elif command -v pacman >/dev/null 2>&1; then
    PKG=pacman
  elif command -v zypper >/dev/null 2>&1; then
    PKG=zypper
  else
    PKG=""
  fi
}

pkg_install() {
  [[ $# -eq 0 ]] && return 0
  case "$PKG" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      if [[ "${APT_UPDATED:-0}" != 1 ]]; then
        step "正在更新软件源，可能需要一两分钟..."
        apt-get update -qq
        APT_UPDATED=1
      fi
      step "正在安装: $*"
      apt-get install -y -qq "$@"
      ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    apk) apk add --no-cache "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    zypper) zypper --non-interactive install -y "$@" ;;
    *) return 1 ;;
  esac
}

try_pkg() {
  local p
  for p in "$@"; do
    pkg_install "$p" >/dev/null 2>&1 && return 0
  done
  return 1
}

install_base_tools() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || try_pkg curl wget || true
  command -v tar >/dev/null 2>&1 || try_pkg tar || true
  command -v xz >/dev/null 2>&1 || command -v xzcat >/dev/null 2>&1 || try_pkg xz xz-utils || true
  command -v openssl >/dev/null 2>&1 || try_pkg openssl || true
  command -v ip >/dev/null 2>&1 || try_pkg iproute2 iproute || true
  command -v ss >/dev/null 2>&1 || try_pkg iproute2 iproute procps-ng || true
  command -v qrencode >/dev/null 2>&1 || try_pkg qrencode || true
}

download() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 15 -o "$dest" "$url" && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=15 --no-check-certificate -O "$dest" "$url" && return 0
  fi
  return 1
}

download_github() {
  local rel="$1" dest="$2"
  local mirrors=(
    "https://github.com/${rel}"
    "https://ghproxy.net/https://github.com/${rel}"
    "https://gitclone.com/github.com/${rel}"
    "https://mirror.ghproxy.com/https://github.com/${rel}"
  )
  local u
  for u in "${mirrors[@]}"; do
    info "下载: $u"
    download "$u" "$dest" && return 0
  done
  return 1
}

is_musl() {
  ldd /bin/sh 2>/dev/null | grep -q musl
}

rust_target() {
  local arch libc=gnu
  arch="$(uname -m)"
  is_musl && libc=musl
  case "$arch" in
    x86_64|amd64)
      [[ "$libc" == musl ]] && echo "x86_64-unknown-linux-musl" || echo "x86_64-unknown-linux-gnu"
      ;;
    aarch64|arm64)
      [[ "$libc" == musl ]] && echo "aarch64-unknown-linux-musl" || echo "aarch64-unknown-linux-gnu"
      ;;
    armv7l|armv7)
      echo "armv7-unknown-linux-gnueabihf"
      ;;
    armv6l)
      echo "arm-unknown-linux-gnueabihf"
      ;;
    i386|i686)
      echo "i686-unknown-linux-musl"
      ;;
    *)
      echo ""
      ;;
  esac
}

find_libev() {
  local p
  for p in /usr/bin/ss-server /usr/local/bin/ss-server /usr/sbin/ss-server; do
    [[ -x "$p" ]] && { BIN_LIBEV="$p"; return 0; }
  done
  command -v ss-server >/dev/null 2>&1 && { BIN_LIBEV="$(command -v ss-server)"; return 0; }
  return 1
}

find_rust() {
  local p
  for p in "$BIN_RUST" /usr/bin/ssserver /usr/local/bin/ssserver; do
    [[ -x "$p" ]] && { BIN_RUST="$p"; return 0; }
  done
  command -v ssserver >/dev/null 2>&1 && { BIN_RUST="$(command -v ssserver)"; return 0; }
  return 1
}

install_libev_pkg() {
  case "$PKG" in
    apt) pkg_install shadowsocks-libev ;;
    dnf)
      dnf install -y epel-release >/dev/null 2>&1 || true
      pkg_install shadowsocks-libev || pkg_install shadowsocks-libev.x86_64 || return 1
      ;;
    yum)
      yum install -y epel-release >/dev/null 2>&1 || true
      pkg_install shadowsocks-libev || return 1
      ;;
    apk) pkg_install shadowsocks-libev ;;
    pacman) pkg_install shadowsocks-libev || pkg_install shadowsocks || return 1 ;;
    zypper) pkg_install shadowsocks-libev || return 1 ;;
    *) return 1 ;;
  esac
  find_libev
}

install_rust_binary() {
  local target archive tmp
  target="$(rust_target)"
  [[ -n "$target" ]] || return 1
  command -v tar >/dev/null 2>&1 || return 1
  tmp="$(mktemp -d)"
  archive="${tmp}/ss.tar.xz"
  if ! download_github "shadowsocks/shadowsocks-rust/releases/download/v${SS_RUST_VERSION}/shadowsocks-v${SS_RUST_VERSION}.${target}.tar.xz" "$archive"; then
    rm -rf "$tmp"
    return 1
  fi
  tar -xJf "$archive" -C "$tmp" || tar --xz -xf "$archive" -C "$tmp" || { rm -rf "$tmp"; return 1; }
  local bin
  bin="$(find "$tmp" -type f -name ssserver | head -n1)"
  [[ -n "$bin" && -f "$bin" ]] || { rm -rf "$tmp"; return 1; }
  install -m 755 "$bin" "$BIN_RUST"
  rm -rf "$tmp"
  find_rust
}

choose_impl_auto() {
  if find_libev; then
    SS_IMPL=libev
    SS_BIN="$BIN_LIBEV"
    return 0
  fi
  if find_rust; then
    SS_IMPL=rust
    SS_BIN="$BIN_RUST"
    return 0
  fi
  info "尝试从系统软件源安装 shadowsocks-libev..."
  if install_libev_pkg && find_libev; then
    SS_IMPL=libev
    SS_BIN="$BIN_LIBEV"
    return 0
  fi
  warn "软件源没有可用的 shadowsocks-libev，改用官方 shadowsocks-rust 二进制"
  if install_rust_binary && find_rust; then
    SS_IMPL=rust
    SS_BIN="$BIN_RUST"
    return 0
  fi
  error "无法安装 Shadowsocks（系统包和官方二进制都失败）。请检查网络能否访问 GitHub。"
}

choose_impl_rust() {
  if find_rust; then
    SS_IMPL=rust
    SS_BIN="$BIN_RUST"
    return 0
  fi
  info "下载官方 shadowsocks-rust..."
  if install_rust_binary && find_rust; then
    SS_IMPL=rust
    SS_BIN="$BIN_RUST"
    return 0
  fi
  error "shadowsocks-rust 安装失败。请检查网络能否访问 GitHub。"
}

choose_impl_libev() {
  if find_libev; then
    SS_IMPL=libev
    SS_BIN="$BIN_LIBEV"
    return 0
  fi
  info "尝试从系统软件源安装 shadowsocks-libev..."
  if install_libev_pkg && find_libev; then
    SS_IMPL=libev
    SS_BIN="$BIN_LIBEV"
    return 0
  fi
  error "系统源没有可用的 shadowsocks-libev。可改选 rust 或「根据系统自动选择」。"
}

choose_impl() {
  case "$SS_IMPL_MODE" in
    rust) choose_impl_rust ;;
    libev) choose_impl_libev ;;
    *) choose_impl_auto ;;
  esac
}

random_password() {
  local s=""
  if command -v openssl >/dev/null 2>&1; then
    s="$(openssl rand -base64 32 2>/dev/null | tr -d '/+=\n' | head -c 24)"
  fi
  if [[ ${#s} -lt 16 && -r /dev/urandom ]]; then
    s="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  fi
  [[ ${#s} -ge 16 ]] || error "无法生成随机密码"
  printf '%s\n' "$s"
}

random_port() {
  if command -v shuf >/dev/null 2>&1; then
    shuf -i 20000-49999 -n 1
    return
  fi
  echo $((20000 + RANDOM % 30000))
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntuH 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$" && return 0
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lntu 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$" && return 0
  fi
  return 1
}

range_in_use() {
  local start="$1" count="$2" i p
  for ((i = 0; i < count; i++)); do
    p=$((start + i))
    port_in_use "$p" && return 0
  done
  return 1
}

fill_user_accounts() {
  local start="$1" i p
  SS_PORTS=()
  SS_PWDS=()
  for ((i = 0; i < SS_USER_COUNT; i++)); do
    p=$((start + i))
    SS_PORTS+=("$p")
    SS_PWDS+=("$(random_password)")
  done
  ss_port="${SS_PORTS[0]}"
  SS_PORT_END="${SS_PORTS[$((SS_USER_COUNT - 1))]}"
  ss_pwd="${SS_PWDS[0]}"
}

get_ip() {
  local ip=""
  local urls=(https://ifconfig.me https://icanhazip.com https://api.ipify.org https://ipv4.icanhazip.com)
  local u
  for u in "${urls[@]}"; do
    if command -v curl >/dev/null 2>&1; then
      ip="$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null || true)"
    elif command -v wget >/dev/null 2>&1; then
      ip="$(wget -qO- -T5 "$u" 2>/dev/null || true)"
    fi
    ip="${ip//$'\r'/}"
    ip="${ip//$'\n'/}"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return; }
  done
  ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  [[ -n "$ip" ]] && { echo "$ip"; return; }
  hostname -I 2>/dev/null | awk '{print $1}'
}

has_ipv6() {
  ip -6 addr show scope global 2>/dev/null | grep -q inet6
}

b64_nopad() {
  if command -v openssl >/dev/null 2>&1; then
    openssl base64 -A | tr -d '='
    return
  fi
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w0 | tr -d '='
    return
  fi
  base64 | tr -d '\n='
}

make_ss_uri() {
  local method="$1" password="$2" host="$3" port="$4"
  local userinfo
  userinfo="$(printf '%s' "${method}:${password}" | b64_nopad)"
  printf 'ss://%s@%s:%s' "$userinfo" "$host" "$port"
}

urlencode_rfc3986() {
  python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

make_airlink_uri() {
  local method="$1" password="$2" host="$3" port="$4" base enc
  [[ -n "$REGISTER_SPKI" ]] || return 1
  base="$(make_ss_uri "$method" "$password" "$host" "$port")"
  enc="$(urlencode_rfc3986 "$REGISTER_SPKI")"
  printf '%s?spki=%s' "$base" "$enc"
}

rewrite_users_airlink_links() {
  local py
  [[ -n "$REGISTER_SPKI" && -f "$USERS_FILE" ]] || return 0
  py="$(python3_bin)"
  [[ -n "$py" ]] || py=python3
  "$py" - "$USERS_FILE" "$REGISTER_SPKI" <<'PY'
import pathlib
import re
import sys
import urllib.parse

path = pathlib.Path(sys.argv[1])
spki = sys.argv[2]
enc = urllib.parse.quote(spki, safe="")
lines = path.read_text(encoding="utf-8").splitlines()
out = []
for line in lines:
    if re.match(r"^\s+Airlink\s+", line):
        continue
    out.append(line)
    m = re.match(r"^(\s+链接\s+)(ss://[^\s?#]+)", line)
    if m:
        out.append(f"  Airlink  {m.group(2)}?spki={enc}")
text = "\n".join(out) + "\n"
path.write_text(text, encoding="utf-8")
PY
  chmod 600 "$USERS_FILE"
}

publish_config() {
  chmod 644 "$CONF_FILE"
  chown root:root "$CONF_FILE" 2>/dev/null || true
  mkdir -p /etc/shadowsocks-libev
  cp -f "$CONF_FILE" /etc/shadowsocks-libev/config.json 2>/dev/null || true
  chmod 644 /etc/shadowsocks-libev/config.json 2>/dev/null || true
}

write_config() {
  local port="$1" password="$2" method="$3" mode="$4" server_json="$5"
  mkdir -p "$CONF_DIR"
  cat > "$CONF_FILE" <<EOF
{
    "server": ${server_json},
    "server_port": ${port},
    "password": "${password}",
    "timeout": 300,
    "method": "${method}",
    "mode": "${mode}",
    "fast_open": false
}
EOF
  publish_config
}

write_config_multi() {
  local server_json="$1"
  local i last comma
  mkdir -p "$CONF_DIR"
  last=$((SS_USER_COUNT - 1))
  if [[ "$SS_IMPL" == rust ]]; then
    {
      echo '{'
      echo '    "servers": ['
      for i in "${!SS_PORTS[@]}"; do
        comma=","
        [[ "$i" -eq "$last" ]] && comma=""
        cat <<EOF
        {
            "server": "0.0.0.0",
            "server_port": ${SS_PORTS[$i]},
            "password": "${SS_PWDS[$i]}",
            "method": "${ss_cipher}",
            "mode": "${ss_mode}",
            "timeout": 300
        }${comma}
EOF
      done
      echo '    ]'
      echo '}'
    } > "$CONF_FILE"
  else
    {
      echo '{'
      echo '    "server": "0.0.0.0",'
      echo '    "port_password": {'
      for i in "${!SS_PORTS[@]}"; do
        comma=","
        [[ "$i" -eq "$last" ]] && comma=""
        printf '        "%s": "%s"%s\n' "${SS_PORTS[$i]}" "${SS_PWDS[$i]}" "$comma"
      done
      echo '    },'
      echo '    "timeout": 300,'
      echo "    \"method\": \"${ss_cipher}\""
      echo '}'
    } > "$CONF_FILE"
  fi
  publish_config
}

libev_args() {
  local mode="$1"
  case "$mode" in
    tcp_only) echo "" ;;
    udp_only) echo "-U" ;;
    *) echo "-u" ;;
  esac
}

write_systemd_unit() {
  local extra=""
  if [[ "$SS_IMPL" == libev ]]; then
    extra="$(libev_args "$ss_mode")"
  fi
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Shadowsocks Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
ExecStart=${SS_BIN} ${extra} -c ${CONF_FILE}

[Install]
WantedBy=multi-user.target
EOF
}

write_openrc() {
  local exec_line
  if [[ "$SS_IMPL" == libev ]]; then
    exec_line="${SS_BIN} $(libev_args "$ss_mode") -c ${CONF_FILE}"
  else
    exec_line="${SS_BIN} -c ${CONF_FILE}"
  fi
  cat > "$OPENRC_FILE" <<EOF
#!/sbin/openrc-run
name="shadowsocks"
command="${exec_line%% *}"
command_args="${exec_line#* }"
command_background=yes
pidfile="/run/shadowsocks.pid"
EOF
  chmod +x "$OPENRC_FILE"
}

stop_conflicts() {
  local svc
  for svc in shadowsocks-libev shadowsocks-libev-server@config shadowsocks ss-server; do
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop "$svc" 2>/dev/null || true
      systemctl disable "$svc" 2>/dev/null || true
    fi
    command -v service >/dev/null 2>&1 && service "$svc" stop 2>/dev/null || true
  done
  pkill -x ss-server >/dev/null 2>&1 || true
  pkill -x ssserver >/dev/null 2>&1 || true
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

start_via_systemd() {
  has_systemd || return 1
  write_systemd_unit
  systemctl daemon-reload >/dev/null
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME" || true
  sleep 1.2
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    return 0
  fi
  return 2
}

start_via_openrc() {
  command -v rc-update >/dev/null 2>&1 || return 1
  write_openrc
  rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
  rc-service "$SERVICE_NAME" restart || rc-service "$SERVICE_NAME" start
}

start_via_nuhup() {
  local log=/var/log/shadowsocks.log
  mkdir -p /var/log
  if [[ "$SS_IMPL" == libev ]]; then
    nohup "$SS_BIN" $(libev_args "$ss_mode") -c "$CONF_FILE" >>"$log" 2>&1 &
  else
    nohup "$SS_BIN" -c "$CONF_FILE" >>"$log" 2>&1 &
  fi
  echo $! >/var/run/shadowsocks.pid
  sleep 0.6
  kill -0 "$(cat /var/run/shadowsocks.pid)" 2>/dev/null
}

service_logs() {
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$SERVICE_NAME" -n 40 --no-pager 2>/dev/null || true
  fi
  [[ -f /var/log/shadowsocks.log ]] && tail -n 40 /var/log/shadowsocks.log
}

try_start() {
  local rc
  step "停止旧进程，避免端口冲突"
  stop_conflicts
  if has_systemd; then
    step "用 systemd 启动服务"
    start_via_systemd
    rc=$?
    [[ $rc -eq 0 ]] && return 0
    warn "systemd 在运行，但服务进程退出了（配置不被当前 ss-server 接受）"
    return 2
  fi
  step "本机没有 systemd，尝试 OpenRC"
  if start_via_openrc; then
    return 0
  fi
  step "改用后台进程启动"
  start_via_nuhup
}

open_firewall() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${port}/tcp" >/dev/null
    ufw allow "${port}/udp" >/dev/null
    info "已在 ufw 放行 ${port}"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "已在 firewalld 放行 ${port}"
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
  fi
}

open_firewall_range() {
  local start="$1" end="$2" p
  if [[ "$start" == "$end" ]]; then
    open_firewall "$start"
    return
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "${start}:${end}/tcp" >/dev/null
    ufw allow "${start}:${end}/udp" >/dev/null
    info "已在 ufw 放行 ${start}-${end}"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -qi running; then
    firewall-cmd --permanent --add-port="${start}-${end}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${start}-${end}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "已在 firewalld 放行 ${start}-${end}"
  fi
  if command -v iptables >/dev/null 2>&1; then
    for p in $(seq "$start" "$end"); do
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
      iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
  fi
}

relax_selinux() {
  if [[ -s /etc/selinux/config ]] && grep -q 'SELINUX=enforcing' /etc/selinux/config; then
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    command -v setenforce >/dev/null 2>&1 && setenforce 0 || true
    warn "已关闭 SELinux 强制模式，避免端口/二进制被拦"
  fi
}

pre_install() {
  [[ -t 1 ]] && command -v clear >/dev/null 2>&1 && clear || true
  echo
  echo "#############################################################"
  echo "#            Shadowsocks 交互安装 / 重新部署               #"
  echo "#############################################################"
  echo
  echo "系统: ${OS_ID:-unknown}  包管理: ${PKG:-none}"
  echo

  echo "0) 服务端程序"
  echo -e "  ${green}1${plain}) 根据系统自动选择    推荐。不区分 Rust 或 libev，单端口用系统里的，多端口自动换成 rust"
  echo -e "  ${green}2${plain}) shadowsocks-rust     官方在维护，单/多端口都推荐，和常见客户端兼容"
  echo -e "  ${green}3${plain}) shadowsocks-libev    上游已停更，单端口够用；多端口经常装不上"
  local i pick start n
  ask "输入数字，回车默认 1: " pick
  pick="${pick:-1}"
  case "$pick" in
    1) SS_IMPL_MODE=auto ;;
    2) SS_IMPL_MODE=rust ;;
    3) SS_IMPL_MODE=libev ;;
    *) error "请输入 1、2 或 3" ;;
  esac
  echo

  echo "0) 部署方式"
  echo -e "  ${green}1${plain}) 单端口单用户（原版）"
  echo -e "  ${green}2${plain}) 多端口多人（一个端口一把密码）"
  ask "输入数字，回车默认 1: " pick
  pick="${pick:-1}"
  case "$pick" in
    1) SS_PROFILE=single ;;
    2) SS_PROFILE=multi ;;
    *) error "请输入 1 或 2" ;;
  esac
  echo "---------------------------"
  echo "profile = ${SS_PROFILE}"
  echo "---------------------------"
  echo

  echo "1) 转发模式"
  for i in "${!modes[@]}"; do
    echo -e "  ${green}$((i + 1))${plain}) ${modes[$i]}    ${mode_hints[$i]}"
  done
  ask "输入数字，回车默认 1: " pick
  pick="${pick:-1}"
  [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#modes[@]})) || error "请输入 1-${#modes[@]} 的数字"
  ss_mode="${modes[$((pick - 1))]}"
  echo "---------------------------"
  echo "mode = ${ss_mode}"
  echo "---------------------------"
  echo

  if [[ "$SS_PROFILE" == multi ]]; then
    echo "2) 用户数量（每个用户独立端口和密码）"
    ask "输入人数，回车默认 5，最多 50: " SS_USER_COUNT
    SS_USER_COUNT="${SS_USER_COUNT:-5}"
    [[ "$SS_USER_COUNT" =~ ^[0-9]+$ ]] && ((SS_USER_COUNT >= 1 && SS_USER_COUNT <= 50)) || error "人数需在 1-50"
    echo "---------------------------"
    echo "users = ${SS_USER_COUNT}"
    echo "---------------------------"
    echo

    echo "3) 起始端口（会占用连续 ${SS_USER_COUNT} 个端口，密码全部随机）"
    ask "输入起始端口，回车则随机: " start
    if [[ -z "${start:-}" ]]; then
      for n in 1 2 3 4 5 6 7 8 9 10; do
        start="$(random_port)"
        ((start + SS_USER_COUNT - 1 <= 65535)) || continue
        range_in_use "$start" "$SS_USER_COUNT" || break
      done
      range_in_use "$start" "$SS_USER_COUNT" && error "找不到一段空闲端口，请手动指定起始端口"
      info "随机起始端口 ${start}"
    else
      [[ "$start" =~ ^[0-9]+$ ]] || error "端口必须是数字"
      ((start >= 1 && start + SS_USER_COUNT - 1 <= 65535)) || error "端口段超出 1-65535"
      range_in_use "$start" "$SS_USER_COUNT" && error "端口段 ${start}-$((start + SS_USER_COUNT - 1)) 有端口被占用"
    fi
    fill_user_accounts "$start"
    echo "---------------------------"
    echo "ports = ${ss_port}-${SS_PORT_END}"
    echo "---------------------------"
    echo
  else
    echo "2) 端口"
    ask "输入端口，回车则随机: " ss_port
    if [[ -z "${ss_port:-}" ]]; then
      for n in 1 2 3 4 5 6 7 8; do
        ss_port="$(random_port)"
        port_in_use "$ss_port" || break
      done
      info "随机端口 ${ss_port}"
    else
      [[ "$ss_port" =~ ^[0-9]+$ ]] || error "端口必须是数字"
      ((ss_port >= 1 && ss_port <= 65535)) || error "端口需在 1-65535"
      port_in_use "$ss_port" && error "端口 ${ss_port} 已被占用"
    fi
    echo "---------------------------"
    echo "port = ${ss_port}"
    echo "---------------------------"
    echo

    echo "3) 密码"
    ask "输入密码，回车则随机: " ss_pwd
    if [[ -z "${ss_pwd:-}" ]]; then
      ss_pwd="$(random_password)"
      info "已生成随机密码"
    fi
    [[ "$ss_pwd" != *'"'* && "$ss_pwd" != *$'\n'* && "$ss_pwd" != *$'\r'* ]] || error "密码不能包含双引号或换行"
    echo "---------------------------"
    echo "password = ${ss_pwd}"
    echo "---------------------------"
    echo
    SS_USER_COUNT=1
    SS_PORTS=("$ss_port")
    SS_PWDS=("$ss_pwd")
    SS_PORT_END="$ss_port"
  fi

  echo "4) 加密方式"
  for i in "${!ciphers[@]}"; do
    echo -e "  ${green}$((i + 1))${plain}) ${ciphers[$i]}    ${cipher_hints[$i]}"
  done
  ask "输入数字，回车默认 1: " pick
  pick="${pick:-1}"
  [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#ciphers[@]})) || error "请输入 1-${#ciphers[@]} 的数字"
  ss_cipher="${ciphers[$((pick - 1))]}"
  echo "---------------------------"
  echo "cipher = ${ss_cipher}"
  echo "---------------------------"
  echo

  if [[ "$SS_PROFILE" == multi ]]; then
    echo "5) 每端口同时在线限制"
    echo -e "  ${green}1${plain}) 同时只允许 1 个公网 IP（防止把密码发给别人一起用，推荐）"
    echo -e "  ${green}2${plain}) 不限制（同一密码可多人同时连）"
    ask "输入数字，回车默认 1: " pick
    pick="${pick:-1}"
    case "$pick" in
      1) SS_IP_LIMIT=1 ;;
      2) SS_IP_LIMIT=0 ;;
      *) error "请输入 1 或 2" ;;
    esac
    echo "---------------------------"
    echo "ip_limit = ${SS_IP_LIMIT}"
    echo "---------------------------"
    echo
    if [[ "$SS_IP_LIMIT" -eq 1 ]]; then
      TOKEN_PORT=443
      echo "---------------------------"
      echo "登记口 = HTTPS ${TOKEN_PORT}（令牌客户端写死这个口，自签+钉指纹，不进 ss://）"
      echo "---------------------------"
      echo
    fi
  else
    SS_IP_LIMIT=0
  fi

  ss_ip="$(get_ip)"
  echo "即将部署:"
  echo "  IP     ${ss_ip}"
  if [[ "$SS_PROFILE" == multi ]]; then
    echo "  方式   多用户 ${SS_USER_COUNT} 人"
    echo "  端口   ${ss_port}-${SS_PORT_END}（一人一端口，密码随机）"
    if [[ "$SS_IP_LIMIT" -eq 1 ]]; then
      echo "  登记口 HTTPS ${TOKEN_PORT}（自签证书，指纹见账号表）"
      echo "  限制   每端口同时只允许 1 个公网 IP"
    else
      echo "  限制   不限制同时在线人数"
    fi
  else
    echo "  方式   单用户"
    echo "  端口   ${ss_port}"
    echo "  密码   ${ss_pwd}"
  fi
  echo "  加密   ${ss_cipher}"
  echo "  模式   ${ss_mode}"
  echo
  ask "确认执行？y 部署 / n 取消: " confirm
  case "${confirm:-}" in
    y|Y|yes|YES)
      echo
      echo "已确认，开始部署。"
      echo "接下来可能要装软件或下载程序，请等状态提示，不要按 Ctrl+C。"
      echo
      ;;
    *) echo "已取消"; exit 0 ;;
  esac
}

write_active_config() {
  local server_json="$1"
  if [[ "$SS_PROFILE" == multi ]]; then
    write_config_multi "$server_json"
  else
    write_config "$ss_port" "$ss_pwd" "$ss_cipher" "$ss_mode" "$server_json"
  fi
}

start_with_fallback() {
  local server_json='"0.0.0.0"'
  if [[ "$SS_PROFILE" != multi ]] && has_ipv6; then
    server_json='["0.0.0.0", "::"]'
  fi

  step "写入配置文件 ${CONF_FILE}"
  write_active_config "$server_json"
  if try_start; then
    return 0
  fi

  if [[ "$SS_IMPL_MODE" == auto && "$SS_PROFILE" == multi && "$SS_IMPL" == libev ]]; then
    step "当前 libev 不支持这份多端口配置，改下官方 shadowsocks-rust（可能要下载 1～2 分钟）"
    if install_rust_binary && find_rust; then
      SS_IMPL=rust
      SS_BIN="$BIN_RUST"
      info "已切换到 rust: ${SS_BIN}"
      write_active_config '"0.0.0.0"'
      try_start && return 0
    else
      warn "shadowsocks-rust 下载失败"
    fi
  fi

  step "改为仅 IPv4 + chacha20-ietf-poly1305 再试一次"
  ss_cipher="chacha20-ietf-poly1305"
  write_active_config '"0.0.0.0"'
  try_start || {
    service_logs
    error "服务启动失败"
  }
}

write_ip_limit_script() {
  mkdir -p "$(dirname "$LIMIT_BIN")" "$LIMIT_STATE_DIR"
  cat > "$LIMIT_BIN" <<'EOF'
#!/usr/bin/env python3
"""独享：客户端令牌认设备，ipset 只放行该令牌当前公网 IP。"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import subprocess
import threading
import time
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORTS_FILE = Path("/etc/shadowsocks/ip-limit.ports")
LOG_FILE = Path("/var/log/shadowsocks-ip-limit.log")
TOKEN_FILE = Path("/var/lib/shadowsocks/ip-limit/tokens.json")
CHAIN = "SS_IP_LIMIT"
IDLE_RELEASE = 45
HMAC_WINDOW = 180
TOKEN_GRACE = 90
NONCE_RE = re.compile(r"^[0-9a-f]{32}$")
REGISTER_PORT_FILE = Path("/etc/shadowsocks/register.port")
REGISTER_CERT = Path("/etc/shadowsocks/register.crt")
REGISTER_KEY = Path("/etc/shadowsocks/register.key")


def read_register_port() -> int:
    if REGISTER_PORT_FILE.exists():
        try:
            n = int(REGISTER_PORT_FILE.read_text(encoding="utf-8").strip())
            if 1 <= n <= 65535:
                return n
        except (OSError, ValueError):
            pass
    env = os.environ.get("SS_TOKEN_PORT", "").strip()
    if env.isdigit():
        return int(env)
    return 443


TOKEN_PORT = read_register_port()
CONF_FILES = (
    "/etc/shadowsocks/config.json",
    "/etc/shadowsocks-libev/config.json",
    "/etc/shadowsocks.json",
)
token_lock = threading.Lock()
nonce_seen: dict[tuple[str, str], float] = {}


def log(msg: str) -> None:
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + msg
    try:
        with LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def read_ports():
    if not PORTS_FILE.exists():
        return []
    ports = []
    for raw in PORTS_FILE.read_text(encoding="utf-8").split():
        if raw.isdigit():
            ports.append(int(raw))
    return ports


def load_passwords() -> dict[int, str]:
    out: dict[int, str] = {}
    for path in CONF_FILES:
        p = Path(path)
        if not p.exists():
            continue
        try:
            cfg = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(cfg.get("port_password"), dict):
            for port, pwd in cfg["port_password"].items():
                if str(port).isdigit() and pwd:
                    out[int(port)] = str(pwd)
        for item in cfg.get("servers") or []:
            if not isinstance(item, dict):
                continue
            port = item.get("server_port")
            pwd = item.get("password")
            if port and pwd:
                out[int(port)] = str(pwd)
        if cfg.get("server_port") and cfg.get("password"):
            out[int(cfg["server_port"])] = str(cfg["password"])
        if out:
            break
    return out


def load_tokens() -> dict:
    if not TOKEN_FILE.exists():
        return {}
    try:
        data = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def save_tokens(data: dict) -> None:
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = TOKEN_FILE.with_name(TOKEN_FILE.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.chmod(0o600)
    os.replace(tmp, TOKEN_FILE)


def endpoint_host(ep: str) -> str:
    if ep.startswith("["):
        return ep[1:].split("]", 1)[0]
    if ep.startswith("::ffff:"):
        ep = ep[7:]
    if ep.count(":") == 1 and "." in ep:
        return ep.rsplit(":", 1)[0]
    if "." in ep:
        return ep.rsplit(":", 1)[0]
    return ep.rsplit(":", 1)[0]


def peer_ips(port: int) -> set[str]:
    result = run(["ss", "-tn"])
    suffix = f":{port}"
    ips: set[str] = set()
    for line in result.stdout.splitlines():
        parts = line.split()
        for idx, token in enumerate(parts[:-1]):
            if token.endswith(suffix):
                host = endpoint_host(parts[idx + 1])
                if host and host not in {"127.0.0.1", "::1", "0.0.0.0", "*", "State"}:
                    ips.add(host)
                break
    return ips


def set_name(port: int, ipv6: bool = False) -> str:
    return f"ssip{port}v6" if ipv6 else f"ssip{port}"


def ensure_ipset(port: int) -> None:
    for ipv6 in (False, True):
        name = set_name(port, ipv6)
        family = "inet6" if ipv6 else "inet"
        listed = run(["ipset", "list", name])
        if listed.returncode != 0:
            created = run(["ipset", "create", name, "hash:ip", "family", family, "maxelem", "1"])
            if created.returncode != 0:
                log(f"ipset 创建失败 {name}: {created.stderr.strip()}")


def ipset_members(port: int) -> list[str]:
    members = []
    for ipv6 in (False, True):
        result = run(["ipset", "list", set_name(port, ipv6)])
        grab = False
        for line in result.stdout.splitlines():
            if line.startswith("Members"):
                grab = True
                continue
            if grab and line.strip():
                members.append(line.strip())
    return members


def ipset_flush(port: int) -> None:
    run(["ipset", "flush", set_name(port)])
    run(["ipset", "flush", set_name(port, True)])


def is_ipv6(ip: str) -> bool:
    return ":" in ip and "." not in ip


def bind_ip(port: int, ip: str) -> None:
    ensure_ipset(port)
    ipset_flush(port)
    name = set_name(port, is_ipv6(ip))
    run(["ipset", "add", name, ip])
    last_seen[port] = time.time()
    drop_extra_conntrack(port, ip)


def ensure_chain(ports: list[int]) -> None:
    run(["iptables", "-N", CHAIN])
    if run(["iptables", "-C", "INPUT", "-j", CHAIN]).returncode != 0:
        run(["iptables", "-I", "INPUT", "1", "-j", CHAIN])
    run(["iptables", "-F", CHAIN])
    for port in ports:
        name = set_name(port)
        port_s = str(port)
        run(["iptables", "-A", CHAIN, "-p", "tcp", "--dport", port_s, "-m", "set", "--match-set", name, "src", "-j", "RETURN"])
        run(["iptables", "-A", CHAIN, "-p", "udp", "--dport", port_s, "-m", "set", "--match-set", name, "src", "-j", "RETURN"])
        run(["iptables", "-A", CHAIN, "-p", "tcp", "--dport", port_s, "-m", "conntrack", "--ctstate", "NEW", "-j", "SET", "--add-set", name, "src"])
        run(["iptables", "-A", CHAIN, "-p", "tcp", "--dport", port_s, "-m", "set", "--match-set", name, "src", "-j", "RETURN"])
        run(["iptables", "-A", CHAIN, "-p", "udp", "--dport", port_s, "-m", "set", "--match-set", name, "src", "-j", "RETURN"])
        run(["iptables", "-A", CHAIN, "-p", "tcp", "--dport", port_s, "-j", "REJECT", "--reject-with", "tcp-reset"])
        run(["iptables", "-A", CHAIN, "-p", "udp", "--dport", port_s, "-j", "DROP"])
        log(f"已为端口 {port} 写入防火墙（无令牌时先连先占；有令牌则认设备）")


def drop_extra_conntrack(port: int, owner: str) -> None:
    if not owner or not shutil_which("conntrack"):
        return
    for ip in peer_ips(port):
        if ip != owner:
            run(["conntrack", "-D", "-p", "tcp", "--dport", str(port), "-s", ip])
            run(["conntrack", "-D", "-p", "udp", "--dport", str(port), "-s", ip])
            log(f"端口 {port} 踢掉 {ip}")


def shutil_which(name: str) -> bool:
    from shutil import which
    return which(name) is not None


last_seen: dict[int, float] = {}
rules_signature = ""


def sign(password: str, port: int, token: str, ts: int, nonce: str = "") -> str:
    if nonce:
        msg = f"{port}|{token}|{ts}|{nonce}".encode()
    else:
        msg = f"{port}|{token}|{ts}".encode()
    return hmac.new(password.encode(), msg, hashlib.sha256).hexdigest()


def prune_nonces(now: float) -> None:
    dead = [k for k, exp in nonce_seen.items() if exp <= now]
    for k in dead:
        nonce_seen.pop(k, None)


def register_token(port: int, token: str, src_ip: str) -> tuple[int, str]:
    if not token or len(token) < 16:
        return 400, "令牌无效"
    with token_lock:
        data = load_tokens()
        key = str(port)
        cur = data.get(key) if isinstance(data.get(key), dict) else None
        if cur and cur.get("token") and cur["token"] != token:
            return 409, "该端口已绑定其他设备"
        data[key] = {"token": token, "ip": src_ip, "ts": int(time.time())}
        save_tokens(data)
        bind_ip(port, src_ip)
        log(f"端口 {port} 令牌登记 {src_ip}")
        return 200, src_ip


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        return

    def _json(self, code: int, obj: dict) -> None:
        payload = {"ss_limit": True, "ok": bool(obj.get("ok"))}
        payload.update(obj)
        payload["ss_limit"] = True
        if payload["ok"] is False and "error" not in payload:
            payload["error"] = "未找到"
        raw = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        if self.path.startswith("/health"):
            self._json(200, {"ok": True})
            return
        self._json(404, {"ok": False, "error": "未找到"})

    def do_POST(self) -> None:
        if not self.path.startswith("/register"):
            self._json(404, {"ok": False, "error": "未找到"})
            return
        length = int(self.headers.get("Content-Length") or "0")
        if length <= 0 or length > 4096:
            self._json(400, {"ok": False, "error": "请求过大"})
            return
        try:
            body = json.loads(self.rfile.read(length).decode("utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError):
            self._json(400, {"ok": False, "error": "JSON 无效"})
            return
        try:
            port = int(body.get("port"))
            token = str(body.get("token") or "")
            ts = int(body.get("ts"))
            digest = str(body.get("hmac") or "")
            nonce = str(body.get("nonce") or "").strip().lower()
        except (TypeError, ValueError):
            self._json(400, {"ok": False, "error": "字段无效"})
            return
        now = time.time()
        if abs(int(now) - ts) > HMAC_WINDOW:
            self._json(400, {"ok": False, "error": "时间戳过期"})
            return
        if port not in read_ports():
            self._json(404, {"ok": False, "error": "端口未开启独享"})
            return
        passwords = load_passwords()
        password = passwords.get(port)
        if not password:
            self._json(500, {"ok": False, "error": "读不到密码"})
            return
        if nonce:
            if not NONCE_RE.fullmatch(nonce):
                self._json(400, {"ok": False, "error": "字段无效"})
                return
            with token_lock:
                prune_nonces(now)
                if nonce_seen.get((token, nonce), 0) > now:
                    self._json(403, {"ok": False, "error": "重放被拒"})
                    return
            expect = sign(password, port, token, ts, nonce)
        else:
            expect = sign(password, port, token, ts)
        if not hmac.compare_digest(expect, digest):
            self._json(403, {"ok": False, "error": "校验失败"})
            return
        if nonce:
            with token_lock:
                nonce_seen[(token, nonce)] = now + HMAC_WINDOW
        src = (self.client_address[0] or "").replace("::ffff:", "")
        code, detail = register_token(port, token, src)
        if code == 200:
            self._json(200, {"ok": True, "ip": detail})
        else:
            self._json(code, {"ok": False, "error": detail})


def enforce_once() -> None:
    global rules_signature
    ports = read_ports()
    if not ports:
        return
    sig = ",".join(str(p) for p in ports)
    if sig != rules_signature:
        for port in ports:
            ensure_ipset(port)
        ensure_chain(ports)
        rules_signature = sig
    now = time.time()
    with token_lock:
        prune_nonces(now)
        data = load_tokens()
    for port in ports:
        rec = data.get(str(port)) if isinstance(data.get(str(port)), dict) else None
        owner = (rec or {}).get("ip") or ""
        members = ipset_members(port)
        online = peer_ips(port)
        if owner:
            if members != [owner]:
                bind_ip(port, owner)
            token_fresh = now - float(rec.get("ts") or 0) < TOKEN_GRACE
            if owner in online or token_fresh:
                last_seen[port] = now
            drop_extra_conntrack(port, owner)
            if owner not in online and not token_fresh and now - last_seen.get(port, now) >= IDLE_RELEASE:
                ipset_flush(port)
                last_seen.pop(port, None)
                with token_lock:
                    data2 = load_tokens()
                    if str(port) in data2 and isinstance(data2[str(port)], dict):
                        data2[str(port)]["ip"] = ""
                        save_tokens(data2)
                log(f"端口 {port} 原 IP {owner} 已离线，保留令牌")
        elif rec and rec.get("token"):
            if members:
                ipset_flush(port)
        elif members:
            cur = members[0]
            if cur in online or online:
                last_seen[port] = now
            drop_extra_conntrack(port, cur)
            if cur not in online and now - last_seen.get(port, now) >= IDLE_RELEASE:
                ipset_flush(port)
                last_seen.pop(port, None)
                log(f"端口 {port} 原 IP {cur} 已离线，释放名额")
        elif online:
            first = sorted(online)[0]
            bind_ip(port, first)
            log(f"端口 {port} 锁定 {first}（普通客户端）")


def serve_tokens() -> None:
    if not REGISTER_CERT.exists() or not REGISTER_KEY.exists():
        log("缺少 /etc/shadowsocks/register.crt 或 register.key，HTTPS 登记口未启动")
        return
    httpd = ThreadingHTTPServer(("0.0.0.0", TOKEN_PORT), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(str(REGISTER_CERT), str(REGISTER_KEY))
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    log(f"令牌登记端口 {TOKEN_PORT} HTTPS")
    httpd.serve_forever()


def main() -> None:
    log("单 IP 限制已启动（令牌认设备）")
    threading.Thread(target=serve_tokens, daemon=True).start()
    while True:
        try:
            enforce_once()
        except Exception as exc:
            log(f"循环异常: {exc}")
        time.sleep(5)


if __name__ == "__main__":
    main()
EOF
  chmod 755 "$LIMIT_BIN"
}

python3_bin() {
  command -v python3 || command -v python || true
}

find_ss_config() {
  local f
  for f in "$CONF_FILE" /etc/shadowsocks-libev/config.json /etc/shadowsocks.json; do
    [[ -s "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

resolve_conf_file() {
  local file
  file="$(find_ss_config || true)"
  [[ -n "$file" ]] || error "找不到配置文件（试过 /etc/shadowsocks/config.json 和 /etc/shadowsocks-libev/config.json）"
  CONF_FILE="$file"
}

parse_ports_from_text() {
  local file="$1"
  grep -oE '"[0-9]{2,5}":' "$file" 2>/dev/null | tr -d '":'
  grep -oE '"server_port"[[:space:]]*:[[:space:]]*[0-9]+' "$file" 2>/dev/null | grep -oE '[0-9]+$'
}

load_ports_from_config() {
  local py file
  SS_PORTS=()
  file="$(find_ss_config || true)"
  if [[ -z "$file" ]]; then
    warn "找不到配置文件（试过 ${CONF_FILE} 和 /etc/shadowsocks-libev/config.json）"
    return 1
  fi
  CONF_FILE="$file"
  py="$(python3_bin)"
  if [[ -n "$py" ]]; then
    mapfile -t SS_PORTS < <("$py" - "$file" <<'PY' 2>/dev/null
import json, sys
try:
    cfg = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
ports = []
if isinstance(cfg.get("port_password"), dict):
    ports = list(cfg["port_password"])
elif isinstance(cfg.get("servers"), list):
    ports = [str(x.get("server_port")) for x in cfg["servers"] if isinstance(x, dict) and x.get("server_port")]
elif cfg.get("server_port"):
    ports = [str(cfg["server_port"])]
for p in ports:
    if str(p).isdigit():
        print(p)
PY
)
  fi
  if [[ ${#SS_PORTS[@]} -eq 0 ]]; then
    mapfile -t SS_PORTS < <(parse_ports_from_text "$file" | awk 'NF && !seen[$0]++')
  fi
  if [[ ${#SS_PORTS[@]} -eq 0 && -f "$USERS_FILE" ]]; then
    mapfile -t SS_PORTS < <(awk '/^  端口/{print $2}' "$USERS_FILE" | grep -E '^[0-9]+$')
  fi
  [[ ${#SS_PORTS[@]} -gt 0 ]]
}

ensure_register_cert() {
  local crt="$REGISTER_CERT" key="$REGISTER_KEY" spki="$REGISTER_SPKI_FILE"
  command -v openssl >/dev/null 2>&1 || pkg_install openssl || true
  command -v openssl >/dev/null 2>&1 || error "需要 openssl 才能生成登记口证书"
  mkdir -p "$CONF_DIR"
  if [[ ! -s "$crt" || ! -s "$key" ]]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
      -keyout "$key" -out "$crt" -subj "/CN=ss-register" >/dev/null 2>&1 \
      || error "生成登记口自签证书失败"
  fi
  chmod 600 "$key"
  chmod 644 "$crt"
  openssl x509 -in "$crt" -pubkey -noout \
    | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary \
    | openssl base64 -A > "$spki" \
    || error "计算登记口证书指纹失败"
  chmod 644 "$spki"
  REGISTER_SPKI="$(tr -d ' \r\n' < "$spki")"
  [[ -n "$REGISTER_SPKI" ]] || error "登记口指纹为空"
}

resolve_register_port() {
  if [[ -n "${SS_TOKEN_PORT:-}" ]]; then
    TOKEN_PORT="$SS_TOKEN_PORT"
  else
    TOKEN_PORT=443
  fi
  [[ "$TOKEN_PORT" =~ ^[0-9]+$ ]] && ((TOKEN_PORT >= 1 && TOKEN_PORT <= 65535)) || error "登记口端口无效"
}

enable_ip_limit() {
  local p py
  command -v iptables >/dev/null 2>&1 || pkg_install iptables || true
  command -v ipset >/dev/null 2>&1 || pkg_install ipset || true
  command -v python3 >/dev/null 2>&1 || pkg_install python3 || true
  command -v conntrack >/dev/null 2>&1 || pkg_install conntrack || pkg_install conntrack-tools || true
  command -v iptables >/dev/null 2>&1 || error "没有 iptables。请先执行: apt-get install -y iptables ipset python3"
  command -v ipset >/dev/null 2>&1 || error "ipset 安装失败。请先执行: apt-get install -y ipset"
  py="$(python3_bin)"
  [[ -n "$py" ]] || error "需要 python3"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop shadowsocks-ip-limit 2>/dev/null || true
  fi
  pkill -f "$LIMIT_BIN" >/dev/null 2>&1 || true
  sleep 0.3
  resolve_register_port
  if port_in_use "$TOKEN_PORT"; then
    error "登记口 TCP ${TOKEN_PORT} 已被占用。独享用 443，请先停掉占用该口的程序（nginx/caddy 等）"
  fi
  ensure_register_cert
  write_ip_limit_script
  mkdir -p "$CONF_DIR"
  printf '%s\n' "$TOKEN_PORT" > "$REGISTER_PORT_FILE"
  chmod 600 "$REGISTER_PORT_FILE"
  open_firewall "$TOKEN_PORT"
  mkdir -p "$LIMIT_STATE_DIR"
  : > "$LIMIT_PORTS_FILE"
  for p in "${SS_PORTS[@]}"; do
    printf '%s\n' "$p" >> "$LIMIT_PORTS_FILE"
  done
  chmod 600 "$LIMIT_PORTS_FILE"
  if has_systemd; then
    cat > "$LIMIT_UNIT" <<EOF
[Unit]
Description=Shadowsocks per-port single IP limiter
After=network.target ${SERVICE_NAME}.service

[Service]
Type=simple
ExecStart=${py} ${LIMIT_BIN}
Environment=SS_TOKEN_PORT=${TOKEN_PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null
    systemctl enable shadowsocks-ip-limit >/dev/null 2>&1 || true
    systemctl restart shadowsocks-ip-limit
    sleep 0.8
    if ! systemctl is-active --quiet shadowsocks-ip-limit; then
      journalctl -u shadowsocks-ip-limit -n 30 --no-pager 2>/dev/null || true
      error "单 IP 限制服务启动失败，看上面日志"
    fi
  else
    nohup "$py" "$LIMIT_BIN" >>/var/log/shadowsocks-ip-limit.log 2>&1 &
    echo $! >/var/run/shadowsocks-ip-limit.pid
  fi
  info "已开启独享：普通 SS 可先连先占；带令牌客户端换网络可顶替。请放行 TCP ${TOKEN_PORT}（HTTPS）"
}

ss_conf_py() {
  command -v python3 >/dev/null 2>&1 || error "改密码需要 python3"
  [[ -f "$CONF_FILE" ]] || error "还没安装，找不到 ${CONF_FILE}"
  python3 - "$CONF_FILE" "$@" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
cmd = sys.argv[2]
cfg = json.loads(path.read_text(encoding="utf-8"))


def ports_of(cfg):
    out = []
    if isinstance(cfg.get("servers"), list):
        for item in cfg["servers"]:
            if isinstance(item, dict) and item.get("server_port") is not None:
                out.append(int(item["server_port"]))
        return out
    if isinstance(cfg.get("port_password"), dict):
        return sorted(int(k) for k in cfg["port_password"])
    if cfg.get("server_port") is not None:
        return [int(cfg["server_port"])]
    return []


def method_of(cfg, port):
    if isinstance(cfg.get("servers"), list):
        for item in cfg["servers"]:
            if isinstance(item, dict) and int(item.get("server_port") or -1) == port:
                return str(item.get("method") or cfg.get("method") or "")
    return str(cfg.get("method") or "")


def password_of(cfg, port):
    if isinstance(cfg.get("servers"), list):
        for item in cfg["servers"]:
            if isinstance(item, dict) and int(item.get("server_port") or -1) == port:
                return str(item.get("password") or "")
    if isinstance(cfg.get("port_password"), dict):
        for k, v in cfg["port_password"].items():
            if int(k) == port:
                return str(v)
    if int(cfg.get("server_port") or -1) == port:
        return str(cfg.get("password") or "")
    return ""


if cmd == "ports":
    print(" ".join(str(p) for p in ports_of(cfg)))
    sys.exit(0)

if cmd == "method":
    print(method_of(cfg, int(sys.argv[3])))
    sys.exit(0)

if cmd == "password":
    print(password_of(cfg, int(sys.argv[3])))
    sys.exit(0)

if cmd != "set":
    sys.exit(1)

port = int(sys.argv[3])
new = sys.argv[4]
found = False
if isinstance(cfg.get("servers"), list):
    for item in cfg["servers"]:
        if isinstance(item, dict) and int(item.get("server_port") or -1) == port:
            item["password"] = new
            found = True
            break
elif isinstance(cfg.get("port_password"), dict):
    key = None
    for k in cfg["port_password"]:
        if int(k) == port:
            key = k
            break
    if key is not None:
        cfg["port_password"][key] = new
        found = True
elif int(cfg.get("server_port") or -1) == port:
    cfg["password"] = new
    found = True

if not found:
    sys.exit(2)
path.write_text(json.dumps(cfg, ensure_ascii=False, indent=4) + "\n", encoding="utf-8")
print(method_of(cfg, port))
PY
}

restart_running_ss() {
  if has_systemd && systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    systemctl restart "$SERVICE_NAME" || error "重启 shadowsocks 失败"
    sleep 0.8
    systemctl is-active --quiet "$SERVICE_NAME" || error "重启后服务没起来，看 journalctl -u ${SERVICE_NAME}"
    return
  fi
  if command -v rc-service >/dev/null 2>&1 && [[ -f "$OPENRC_FILE" ]]; then
    rc-service "$SERVICE_NAME" restart || error "重启 shadowsocks 失败"
    return
  fi
  error "找不到已安装的 shadowsocks 服务"
}

update_users_password_line() {
  local port="$1" pwd="$2" uri="$3" airlink="${4:-}"
  [[ -f "$USERS_FILE" ]] || return 0
  python3 - "$USERS_FILE" "$port" "$pwd" "$uri" "$airlink" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
port = sys.argv[2]
pwd = sys.argv[3]
uri = sys.argv[4]
airlink = sys.argv[5] if len(sys.argv) > 5 else ""
lines = path.read_text(encoding="utf-8").splitlines()
out = []
i = 0
while i < len(lines):
    line = lines[i]
    m = re.match(r"^(\s+端口\s+)" + re.escape(port) + r"\s*$", line)
    if not m:
        out.append(line)
        i += 1
        continue
    out.append(line)
    i += 1
    while i < len(lines):
        nxt = lines[i]
        if re.match(r"^\s+密码\s+", nxt):
            indent = re.match(r"^(\s+密码\s+)", nxt).group(1)
            out.append(indent + pwd)
        elif re.match(r"^\s+链接\s+", nxt):
            indent = re.match(r"^(\s+链接\s+)", nxt).group(1)
            out.append(indent + uri)
            if airlink:
                out.append("  Airlink  " + airlink)
        elif re.match(r"^\s+Airlink\s+", nxt):
            i += 1
            continue
        else:
            break
        i += 1
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
  chmod 600 "$USERS_FILE"
}

cmd_set_pass() {
  local ports_str port_arg pass_arg target_port new_pass method uri ss_ip airlink=""
  local -a ports=()
  resolve_conf_file
  ports_str="$(ss_conf_py ports)"
  read -r -a ports <<< "$ports_str"
  [[ ${#ports[@]} -gt 0 ]] || error "配置里没有端口"
  port_arg="${1:-}"
  pass_arg="${2:-}"

  if [[ -z "$port_arg" ]]; then
    [[ ${#ports[@]} -eq 1 ]] || error "多端口请写明要改哪一个，例如: $0 set-pass ${ports[0]}"
    target_port="${ports[0]}"
    new_pass="$(random_password)"
  elif [[ -n "$pass_arg" ]]; then
    target_port="$port_arg"
    new_pass="$pass_arg"
  else
    local p
    for p in "${ports[@]}"; do
      if [[ "$p" == "$port_arg" ]]; then
        target_port="$p"
        new_pass="$(random_password)"
        break
      fi
    done
    if [[ -z "$target_port" ]]; then
      [[ ${#ports[@]} -eq 1 ]] || error "端口 ${port_arg} 不在配置里。现有端口: ${ports_str}"
      target_port="${ports[0]}"
      new_pass="$port_arg"
    fi
  fi

  [[ "$target_port" =~ ^[0-9]+$ ]] && ((target_port >= 1 && target_port <= 65535)) || error "端口无效"
  local found=0 p
  for p in "${ports[@]}"; do
    [[ "$p" == "$target_port" ]] && found=1 && break
  done
  [[ "$found" -eq 1 ]] || error "端口 ${target_port} 不在配置里。现有端口: ${ports_str}"
  [[ -n "$new_pass" ]] || error "密码不能为空"
  [[ ${#new_pass} -le 128 ]] || error "密码太长"
  [[ "$new_pass" != *$'\n'* ]] || error "密码不能换行"

  method="$(ss_conf_py set "$target_port" "$new_pass")" || error "写入配置失败"
  [[ -n "$method" ]] || error "配置里没有加密方式"
  publish_config
  restart_running_ss
  if command -v ipset >/dev/null 2>&1; then
    ipset flush "ssip${target_port}" 2>/dev/null || true
    ipset flush "ssip${target_port}v6" 2>/dev/null || true
  fi
  if command -v conntrack >/dev/null 2>&1; then
    conntrack -D -p tcp --dport "$target_port" >/dev/null 2>&1 || true
    conntrack -D -p udp --dport "$target_port" >/dev/null 2>&1 || true
  fi

  if [[ -z "$REGISTER_SPKI" && -f "$REGISTER_SPKI_FILE" ]]; then
    REGISTER_SPKI="$(tr -d ' \r\n' < "$REGISTER_SPKI_FILE")"
  fi
  ss_ip="$(get_ip)"
  uri="$(make_ss_uri "$method" "$new_pass" "$ss_ip" "$target_port")"
  if [[ -n "$REGISTER_SPKI" ]]; then
    airlink="$(make_airlink_uri "$method" "$new_pass" "$ss_ip" "$target_port")"
  fi
  update_users_password_line "$target_port" "$new_pass" "$uri" "$airlink"
  echo
  echo "已改端口 ${target_port} 的密码（旧链接立刻失效）"
  echo -e " 端口      \033[41;37m ${target_port} \033[0m"
  echo -e " 密码      \033[41;37m ${new_pass} \033[0m"
  echo -e " 链接      ${green}${uri}${plain}"
  if [[ -n "$airlink" ]]; then
    echo -e " Airlink   ${green}${airlink}${plain}"
  fi
  [[ -f "$USERS_FILE" ]] && echo "已写入 ${USERS_FILE}"
}

cmd_show() {
  local ports_str method pwd uri airlink ss_ip target idx p found
  local -a ports=() want=()
  shift
  resolve_conf_file
  ports_str="$(ss_conf_py ports)"
  read -r -a ports <<< "$ports_str"
  [[ ${#ports[@]} -gt 0 ]] || error "配置里没有端口"
  if [[ $# -eq 0 || "$1" == all ]]; then
    want=("${ports[@]}")
  else
    want=("$@")
  fi
  if [[ -z "$REGISTER_SPKI" && -f "$REGISTER_SPKI_FILE" ]]; then
    REGISTER_SPKI="$(tr -d ' \r\n' < "$REGISTER_SPKI_FILE")"
  fi
  ss_ip="$(get_ip)"
  for target in "${want[@]}"; do
    found=0
    idx=0
    for p in "${ports[@]}"; do
      if [[ "$p" == "$target" ]]; then
        found=1
        break
      fi
      idx=$((idx + 1))
    done
    [[ "$found" -eq 1 ]] || error "端口 ${target} 不在配置里。现有端口: ${ports_str}"
    method="$(ss_conf_py method "$target")"
    pwd="$(ss_conf_py password "$target")"
    [[ -n "$method" && -n "$pwd" ]] || error "读不到端口 ${target} 的加密或密码"
    uri="$(make_ss_uri "$method" "$pwd" "$ss_ip" "$target")"
    airlink=""
    if [[ -n "$REGISTER_SPKI" ]]; then
      airlink="$(make_airlink_uri "$method" "$pwd" "$ss_ip" "$target")"
    fi
    echo "用户 $((idx + 1))"
    echo "  端口    ${target}"
    echo "  密码    ${pwd}"
    echo "  链接    ${uri}"
    [[ -n "$airlink" ]] && echo "  Airlink  ${airlink}"
    echo
  done
}

cmd_limit_on() {
  detect_os
  try_pkg python3 >/dev/null 2>&1 || true
  if ! load_ports_from_config; then
    echo "当前能看到的配置："
    ls -l "$CONF_FILE" /etc/shadowsocks-libev/config.json /etc/shadowsocks.json "$USERS_FILE" 2>/dev/null || true
    echo "----- config.json 前 40 行 -----"
    head -n 40 "$CONF_FILE" 2>/dev/null || echo "(没有 ${CONF_FILE})"
    error "读不到端口。若还没部署成功，先运行: ./shadowsocks.sh （选多端口）。若已经在用，把上面打印的配置发回来。"
  fi
  enable_ip_limit
  echo "已对现有端口启用独享（普通 SS 与令牌客户端都可用），没有改密码："
  printf '  %s\n' "${SS_PORTS[@]}"
  echo "配置: ${CONF_FILE}"
  echo "令牌登记端口: HTTPS ${TOKEN_PORT}（客户端写死 443，不进 ss://，不再提供明文 HTTP）"
  echo "登记指纹 SPKI SHA-256: ${REGISTER_SPKI}"
  echo "云安全组：业务口 TCP/UDP ${SS_PORTS[0]:-?}–段，另放行 TCP ${TOKEN_PORT}"
  echo "自检: curl -sk https://127.0.0.1:${TOKEN_PORT}/health"
  echo "日志: /var/log/shadowsocks-ip-limit.log"
  rewrite_users_airlink_links
  if [[ -f "$USERS_FILE" ]]; then
    echo "已在 ${USERS_FILE} 为每个用户补上 Airlink 链接（?spki=）。普通「链接」未改。"
  fi
}

cmd_limit_off() {
  detect_os
  disable_ip_limit
  echo "已关闭单 IP 限制"
}

disable_ip_limit() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop shadowsocks-ip-limit 2>/dev/null || true
    systemctl disable shadowsocks-ip-limit 2>/dev/null || true
  fi
  if [[ -f /var/run/shadowsocks-ip-limit.pid ]]; then
    kill "$(cat /var/run/shadowsocks-ip-limit.pid)" 2>/dev/null || true
    rm -f /var/run/shadowsocks-ip-limit.pid
  fi
  pkill -f "$LIMIT_BIN" >/dev/null 2>&1 || true
  if command -v iptables >/dev/null 2>&1; then
    iptables -D INPUT -j SS_IP_LIMIT 2>/dev/null || true
    iptables -F SS_IP_LIMIT 2>/dev/null || true
    iptables -X SS_IP_LIMIT 2>/dev/null || true
  fi
  if command -v ipset >/dev/null 2>&1; then
    ipset list -name 2>/dev/null | grep -E '^ssip[0-9]+' | while read -r n; do
      ipset destroy "$n" 2>/dev/null || true
    done
  fi
  rm -f "$LIMIT_UNIT" "$LIMIT_PORTS_FILE" "$LIMIT_BIN"
  rm -rf "$LIMIT_STATE_DIR"
  # 保留 register.port，再次 limit-on 时沿用同一报名口
}

save_users_file() {
  local i uri
  {
    echo "IP        ${ss_ip}"
    echo "加密      ${ss_cipher}"
    echo "模式      ${ss_mode}"
    if [[ "$SS_IP_LIMIT" -eq 1 ]]; then
      echo "登记口    HTTPS ${TOKEN_PORT}（令牌客户端 POST /register，不进 ss://）"
      echo "登记指纹  ${REGISTER_SPKI}"
    fi
    echo
    for i in "${!SS_PORTS[@]}"; do
      uri="$(make_ss_uri "$ss_cipher" "${SS_PWDS[$i]}" "$ss_ip" "${SS_PORTS[$i]}")"
      echo "用户 $((i + 1))"
      echo "  端口    ${SS_PORTS[$i]}"
      echo "  密码    ${SS_PWDS[$i]}"
      echo "  链接    ${uri}"
      if [[ "$SS_IP_LIMIT" -eq 1 && -n "$REGISTER_SPKI" ]]; then
        echo "  Airlink  $(make_airlink_uri "$ss_cipher" "${SS_PWDS[$i]}" "$ss_ip" "${SS_PORTS[$i]}")"
      fi
      echo
    done
  } > "$USERS_FILE"
  chmod 600 "$USERS_FILE"
}

print_result() {
  local uri i
  echo
  echo "============================================================"
  echo " 部署完成"
  echo "============================================================"
  echo -e " IP        \033[41;37m ${ss_ip} \033[0m"
  echo -e " 加密      \033[41;37m ${ss_cipher} \033[0m"
  echo " 实现      ${SS_IMPL}  (${SS_BIN})"
  echo
  if [[ "$SS_PROFILE" == multi ]]; then
    echo "共 ${SS_USER_COUNT} 个用户，端口 ${ss_port}-${SS_PORT_END}，一人一端口一密码。"
    echo
    for i in "${!SS_PORTS[@]}"; do
      uri="$(make_ss_uri "$ss_cipher" "${SS_PWDS[$i]}" "$ss_ip" "${SS_PORTS[$i]}")"
      echo "---------- 用户 $((i + 1)) ----------"
      echo -e " 端口      \033[41;37m ${SS_PORTS[$i]} \033[0m"
      echo -e " 密码      \033[41;37m ${SS_PWDS[$i]} \033[0m"
      echo -e " 链接      ${green}${uri}${plain}"
      if [[ "$SS_IP_LIMIT" -eq 1 && -n "$REGISTER_SPKI" ]]; then
        echo -e " Airlink   ${green}$(make_airlink_uri "$ss_cipher" "${SS_PWDS[$i]}" "$ss_ip" "${SS_PORTS[$i]}")${plain}"
      fi
      if command -v qrencode >/dev/null 2>&1 && (( SS_USER_COUNT <= 8 )); then
        qrencode -t ANSIUTF8 -m 1 "$uri" 2>/dev/null || qrencode -t ANSI -m 1 "$uri" 2>/dev/null || true
      fi
      echo
    done
    save_users_file
    echo "账号表已保存: ${USERS_FILE}（仅 root 可读）"
    if [[ "$SS_IP_LIMIT" -eq 1 ]]; then
      echo "已限制：每个端口同时只允许 1 个公网 IP。后连上的会被踢掉。"
      echo "同一 Wi-Fi/公司 NAT 下多台设备仍算同一个 IP，可以一起用。"
      echo -e " 登记口    \033[41;37m HTTPS ${TOKEN_PORT} \033[0m  （令牌客户端写死，不进 ss://）"
      echo -e " 登记指纹  \033[41;37m ${REGISTER_SPKI} \033[0m"
      echo "普通客户端用「链接」；Airlink 用带 ?spki= 的那一行（导入即带指纹）"
      echo "请在云厂商安全组放行 TCP/UDP ${ss_port}-${SS_PORT_END}，以及 TCP ${TOKEN_PORT}"
    else
      echo "请在云厂商安全组放行 TCP/UDP ${ss_port}-${SS_PORT_END}"
    fi
  else
    uri="$(make_ss_uri "$ss_cipher" "$ss_pwd" "$ss_ip" "$ss_port")"
    echo -e " 端口      \033[41;37m ${ss_port} \033[0m"
    echo -e " 密码      \033[41;37m ${ss_pwd} \033[0m"
    echo
    echo "导入链接（直接粘贴到 Shadowsocks）:"
    echo -e "${green}${uri}${plain}"
    echo
    if command -v qrencode >/dev/null 2>&1; then
      echo "二维码:"
      qrencode -t ANSIUTF8 -m 1 "$uri" || qrencode -t ANSI -m 1 "$uri" || true
    fi
    echo
    echo "配置文件: ${CONF_FILE}"
    echo "请在云厂商安全组放行 TCP/UDP ${ss_port}"
  fi
  echo
}

uninstall_shadowsocks() {
  ask "确认卸载 Shadowsocks？(y/n，默认 n): " answer
  answer="${answer:-n}"
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "已取消"
    return
  fi
  disable_ip_limit
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    systemctl stop shadowsocks-libev 2>/dev/null || true
    systemctl disable shadowsocks-libev 2>/dev/null || true
  fi
  command -v rc-service >/dev/null 2>&1 && rc-service "$SERVICE_NAME" stop 2>/dev/null || true
  if [[ -f /var/run/shadowsocks.pid ]]; then
    kill "$(cat /var/run/shadowsocks.pid)" 2>/dev/null || true
    rm -f /var/run/shadowsocks.pid
  fi
  pkill -x ss-server >/dev/null 2>&1 || true
  pkill -x ssserver >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE" "$OPENRC_FILE"
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true
  rm -f "$CONF_FILE" /etc/shadowsocks-libev/config.json "$USERS_FILE" "$REGISTER_PORT_FILE"
  echo "已停止服务并删除配置。系统软件包未卸载。"
}

install_shadowsocks() {
  detect_os
  relax_selinux
  step "检查并安装基础工具（curl/openssl 等）"
  install_base_tools
  pre_install
  step "选择 Shadowsocks 实现（系统包或官方二进制）"
  choose_impl
  info "使用 ${SS_IMPL}: ${SS_BIN}"
  start_with_fallback
  step "检查本机防火墙"
  if [[ "$SS_PROFILE" == multi ]]; then
    open_firewall_range "$ss_port" "$SS_PORT_END"
    if [[ "$SS_IP_LIMIT" -eq 1 ]]; then
      step "开启每端口单 IP 限制"
      enable_ip_limit
    else
      disable_ip_limit
    fi
  else
    open_firewall "$ss_port"
    disable_ip_limit
  fi
  print_result
}

need_root "$@"
action="${1:-install}"
case "$action" in
  install) install_shadowsocks ;;
  uninstall) detect_os; uninstall_shadowsocks ;;
  limit-on) cmd_limit_on ;;
  limit-off) cmd_limit_off ;;
  set-pass|passwd|set-password)
    shift
    cmd_set_pass "$@"
    ;;
  airlink|show|link)
    shift
    cmd_show "$action" "$@"
    ;;
  *)
    echo "用法: $(basename "$0") [install|uninstall|limit-on|limit-off|set-pass|airlink|show]"
    echo "改密码: $(basename "$0") set-pass [端口] [密码]"
    echo "看账号: $(basename "$0") show 23865"
    echo "  多个端口: $(basename "$0") show 23865 23867"
    echo "  全部端口: $(basename "$0") show"
    exit 1
    ;;
esac
