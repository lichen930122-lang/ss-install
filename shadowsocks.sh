#!/usr/bin/env bash
# Shadowsocks-libev 交互安装（在任意 Ubuntu / Debian VPS 上运行）
#
# wget -O shadowsocks.sh https://raw.githubusercontent.com/lichen930122-lang/ss-install/main/shadowsocks.sh
# chmod +x shadowsocks.sh
# ./shadowsocks.sh 2>&1 | tee shadowsocks.log
#
# 卸载: ./shadowsocks.sh uninstall

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

red='\033[0;31m'
green='\033[0;32m'
plain='\033[0m'

modes=(
  tcp_and_udp
  tcp_only
  udp_only
)
mode_hints=(
  "TCP + UDP（推荐）"
  "仅 TCP"
  "仅 UDP"
)

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
  "推荐，兼容性好"
  "更省 CPU"
  "AEAD"
  "AEAD"
  "旧客户端"
  "旧客户端"
  "旧流密码，不推荐"
)

[[ -t 0 ]] || {
  echo -e "[${red}Error${plain}] 请先下载再运行，不要用 wget ... | bash"
  exit 1
}

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

error() {
  echo -e "[${red}Error${plain}] $*" >&2
  exit 1
}

info() {
  echo -e "[${green}Info${plain}] $*"
}

require_debian() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian|linuxmint|pop) return 0 ;;
    esac
  fi
  command -v apt-get >/dev/null 2>&1 || error "仅支持 Ubuntu / Debian（需要 apt）"
}

random_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 24 | tr -d '/+=' | head -c 24
    echo
    return
  fi
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
  echo
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
  ss -lntuH 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
}

get_ip() {
  local ip
  ip="$(curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -4 -fsS --max-time 5 icanhazip.com 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(wget -qO- -T5 ipv4.icanhazip.com 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  echo "${ip//$'\r'/}"
}

make_ss_uri() {
  local method="$1" password="$2" host="$3" port="$4"
  local userinfo
  userinfo="$(printf '%s' "${method}:${password}" | openssl base64 -A | tr -d '=')"
  printf 'ss://%s@%s:%s\n' "$userinfo" "$host" "$port"
}

write_config() {
  local port="$1" password="$2" method="$3" mode="$4"
  mkdir -p /etc/shadowsocks-libev
  cat > /etc/shadowsocks-libev/config.json <<EOF
{
    "server": ["0.0.0.0", "::"],
    "server_port": ${port},
    "password": "${password}",
    "timeout": 300,
    "method": "${method}",
    "mode": "${mode}",
    "fast_open": false,
    "nameserver": "1.1.1.1"
}
EOF
  chmod 600 /etc/shadowsocks-libev/config.json
}

pre_install() {
  clear
  echo
  echo "#############################################################"
  echo "#          Shadowsocks-libev 交互安装 / 重新部署           #"
  echo "#############################################################"
  echo

  echo "1) 转发模式"
  local i pick
  for i in "${!modes[@]}"; do
    echo -e "  ${green}$((i + 1))${plain}) ${modes[$i]}    ${mode_hints[$i]}"
  done
  read -r -p "输入数字，回车默认 1: " pick
  pick="${pick:-1}"
  [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#modes[@]})) || error "请输入 1-${#modes[@]} 的数字"
  ss_mode="${modes[$((pick - 1))]}"
  echo "---------------------------"
  echo "mode = ${ss_mode}"
  echo "---------------------------"
  echo

  echo "2) 端口"
  read -r -p "输入端口，回车则随机: " ss_port
  if [[ -z "${ss_port:-}" ]]; then
    local n
    for n in 1 2 3 4 5 6 7 8; do
      ss_port="$(random_port)"
      port_in_use "$ss_port" || break
    done
    info "随机端口 ${ss_port}"
  else
    [[ "$ss_port" =~ ^[0-9]+$ ]] || error "端口必须是数字"
    ((ss_port >= 1024 && ss_port <= 65535)) || error "端口需在 1024-65535"
    port_in_use "$ss_port" && error "端口 ${ss_port} 已被占用"
  fi
  echo "---------------------------"
  echo "port = ${ss_port}"
  echo "---------------------------"
  echo

  echo "3) 密码"
  read -r -p "输入密码，回车则随机: " ss_pwd
  if [[ -z "${ss_pwd:-}" ]]; then
    ss_pwd="$(random_password)"
    info "已生成随机密码"
  fi
  [[ "$ss_pwd" != *'"'* && "$ss_pwd" != *$'\n'* ]] || error "密码不能包含双引号或换行"
  echo "---------------------------"
  echo "password = ${ss_pwd}"
  echo "---------------------------"
  echo

  echo "4) 加密方式"
  for i in "${!ciphers[@]}"; do
    echo -e "  ${green}$((i + 1))${plain}) ${ciphers[$i]}    ${cipher_hints[$i]}"
  done
  read -r -p "输入数字，回车默认 1: " pick
  pick="${pick:-1}"
  [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#ciphers[@]})) || error "请输入 1-${#ciphers[@]} 的数字"
  ss_cipher="${ciphers[$((pick - 1))]}"
  echo "---------------------------"
  echo "cipher = ${ss_cipher}"
  echo "---------------------------"
  echo

  ss_ip="$(get_ip)"
  echo "即将部署:"
  echo "  IP     ${ss_ip}"
  echo "  端口   ${ss_port}"
  echo "  密码   ${ss_pwd}"
  echo "  加密   ${ss_cipher}"
  echo "  模式   ${ss_mode}"
  echo
  read -r -p "确认执行？y 部署 / n 取消: " confirm
  case "${confirm:-}" in
    y|Y|yes|YES) ;;
    *)
      echo "已取消"
      exit 0
      ;;
  esac
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq shadowsocks-libev curl openssl
  apt-get install -y -qq qrencode || true
  mkdir -p /etc/shadowsocks-libev
}

start_service() {
  write_config "$ss_port" "$ss_pwd" "$ss_cipher" "$ss_mode"
  systemctl enable shadowsocks-libev >/dev/null
  systemctl restart shadowsocks-libev
  sleep 0.4
  systemctl is-active --quiet shadowsocks-libev || {
    journalctl -u shadowsocks-libev -n 30 --no-pager
    error "服务启动失败"
  }
}

print_result() {
  local uri
  uri="$(make_ss_uri "$ss_cipher" "$ss_pwd" "$ss_ip" "$ss_port")"
  echo
  echo "============================================================"
  echo " 部署完成"
  echo "============================================================"
  echo -e " IP        \033[41;37m ${ss_ip} \033[0m"
  echo -e " 端口      \033[41;37m ${ss_port} \033[0m"
  echo -e " 密码      \033[41;37m ${ss_pwd} \033[0m"
  echo -e " 加密      \033[41;37m ${ss_cipher} \033[0m"
  echo
  echo "导入链接（直接粘贴到 Shadowsocks）:"
  echo -e "${green}${uri}${plain}"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    echo "二维码:"
    qrencode -t ANSIUTF8 -m 1 "$uri"
  fi
  echo
  echo "配置文件: /etc/shadowsocks-libev/config.json"
  echo "请在云厂商安全组放行 TCP/UDP ${ss_port}"
  echo
}

uninstall_shadowsocks() {
  read -r -p "确认卸载 Shadowsocks？(y/n，默认 n): " answer
  answer="${answer:-n}"
  if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    systemctl stop shadowsocks-libev 2>/dev/null || true
    systemctl disable shadowsocks-libev 2>/dev/null || true
    apt-get purge -y shadowsocks-libev
    rm -f /etc/shadowsocks-libev/config.json
    echo "已卸载"
  else
    echo "已取消"
  fi
}

install_shadowsocks() {
  require_debian
  pre_install
  install_packages
  start_service
  print_result
}

action="${1:-install}"
case "$action" in
  install) install_shadowsocks ;;
  uninstall) uninstall_shadowsocks ;;
  *)
    echo "用法: $(basename "$0") [install|uninstall]"
    exit 1
    ;;
esac
