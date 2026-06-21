#!/usr/bin/env bash
set -euo pipefail

VERSION="2026-06-21"
APP="ipblock"
BASE_DIR="/etc/ipblock"
BIN="/usr/local/sbin/ipblock"
SCRIPT_URL="https://raw.githubusercontent.com/Xiyueyy/ipblock/main/ipblock.sh"
URL4="https://raw.githubusercontent.com/mayaxcn/china-ip-list/master/chnroute.txt"
URL6="https://raw.githubusercontent.com/mayaxcn/china-ip-list/master/chnroute_v6.txt"
UPDATE_TIME="${UPDATE_TIME:-04:20:00}"
RANDOM_DELAY="${RANDOM_DELAY:-30m}"

ACTION="${1:-menu}"
PORT="${2:-${PORT:-}}"
PROTO="${3:-${PROTO:-both}}"

log() { echo "[$(date '+%F %T')] $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || err "请用 root 运行，或 sudo $0 $*"; }

usage() {
  cat <<USAGE
${APP} v${VERSION}
用 mayaxcn/china-ip-list 屏蔽中国大陆 IP 访问指定端口，支持裸机服务和 Docker 映射端口。

交互模式：
  ${APP}
  ${APP} menu

命令模式：
  ${APP} install <端口> [tcp|udp|both]      安装/更新端口封禁，创建开机自启和每日更新
  ${APP} apply   <端口> [tcp|udp|both]      只应用一次规则
  ${APP} status  <端口>                     查看指定端口状态
  ${APP} list                              列出已安装端口
  ${APP} update-all                        更新所有已安装端口的 IP 库和规则
  ${APP} uninstall <端口>                  删除指定端口规则、ipset、systemd 任务

例子：
  ${APP} install 25084 both
  ${APP} install 22022 tcp
  ${APP} status 25084
  ${APP} uninstall 25084

IP 库：
  IPv4: ${URL4}
  IPv6: ${URL6}
USAGE
}

ask() {
  # ask "提示" "默认值" var_name
  local prompt="$1" default="${2:-}" __var="$3" ans
  if [ -n "$default" ]; then
    prompt="${prompt} [${default}]"
  fi
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "%s: " "$prompt" > /dev/tty
    IFS= read -r ans < /dev/tty || ans=""
  else
    printf "%s: " "$prompt"
    IFS= read -r ans || ans=""
  fi
  ans="${ans:-$default}"
  printf -v "$__var" '%s' "$ans"
}

pause_tty() {
  local _dummy
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "\n按回车继续..." > /dev/tty
    IFS= read -r _dummy < /dev/tty || true
  fi
}

valid_port() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || err "端口必须是数字"
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || err "端口范围必须是 1-65535"
}

valid_proto() {
  case "$PROTO" in tcp|udp|both) ;; *) err "协议只能是 tcp / udp / both";; esac
}

has_proto() { [ "$PROTO" = "both" ] || [ "$PROTO" = "$1" ]; }
set4() { echo "ipblock_${PORT}_v4"; }
set6() { echo "ipblock_${PORT}_v6"; }
comment() { echo "ipblock:${PORT}"; }
service_name() { echo "ipblock-${PORT}.service"; }
timer_name() { echo "ipblock-${PORT}.timer"; }

ipt4() { iptables -w "$@" 2>/dev/null || iptables "$@"; }
ipt6() { ip6tables -w "$@" 2>/dev/null || ip6tables "$@"; }

install_deps() {
  local missing=0
  for c in curl ipset iptables; do command -v "$c" >/dev/null 2>&1 || missing=1; done
  command -v ip6tables >/dev/null 2>&1 || true
  [ "$missing" -eq 0 ] && return 0

  log "安装依赖：curl ipset iptables ca-certificates"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ipset iptables ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ipset iptables iptables-services ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ipset iptables iptables-services ca-certificates
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl ipset iptables ip6tables ca-certificates
  else
    err "找不到支持的包管理器，请手动安装 curl/ipset/iptables 后再运行"
  fi
}

fetch_or_cache() {
  local url="$1" dest="$2" required="${3:-required}" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(mktemp)"
  if curl -fsSL --connect-timeout 10 --max-time 90 "$url" -o "$tmp" && [ -s "$tmp" ]; then
    mv "$tmp" "$dest"
    log "已更新 $(basename "$dest")：$(wc -l < "$dest") 条"
    return 0
  fi

  rm -f "$tmp"
  if [ -s "$dest" ]; then
    log "下载失败，使用本地缓存：$dest"
    return 0
  fi
  if [ "$required" = "required" ]; then
    err "下载失败且没有缓存：$url"
  fi
  log "下载失败且没有缓存，跳过：$url"
  return 1
}

load_ipset() {
  local family="$1" set_name="$2" file="$3"
  local tmp_set="${set_name}_tmp"
  [ -s "$file" ] || err "IP 列表为空：$file"

  ipset create "$set_name" hash:net family "$family" hashsize 16384 maxelem 300000 -exist
  ipset create "$tmp_set" hash:net family "$family" hashsize 16384 maxelem 300000 -exist
  ipset flush "$tmp_set"

  local cidr count=0
  while IFS= read -r cidr; do
    cidr="${cidr%%#*}"
    cidr="$(echo "$cidr" | tr -d ' \t\r')"
    [ -z "$cidr" ] && continue
    ipset add "$tmp_set" "$cidr" -exist || true
    count=$((count + 1))
  done < "$file"

  ipset swap "$tmp_set" "$set_name"
  ipset destroy "$tmp_set" 2>/dev/null || true
  log "已加载 $set_name：$count 条"
}

add_one_rule() {
  local bin="$1" chain="$2" proto="$3" set="$4" mode="$5"
  local cmt; cmt="$(comment)"
  if [ "$mode" = "input" ]; then
    if ! "$bin" -C "$chain" -p "$proto" --dport "$PORT" -m set --match-set "$set" src -m comment --comment "$cmt" -j DROP >/dev/null 2>&1; then
      "$bin" -I "$chain" 1 -p "$proto" --dport "$PORT" -m set --match-set "$set" src -m comment --comment "$cmt" -j DROP
    fi
  else
    if ! "$bin" -C "$chain" -p "$proto" -m conntrack --ctorigdstport "$PORT" -m set --match-set "$set" src -m comment --comment "$cmt" -j DROP >/dev/null 2>&1; then
      "$bin" -I "$chain" 1 -p "$proto" -m conntrack --ctorigdstport "$PORT" -m set --match-set "$set" src -m comment --comment "$cmt" -j DROP
    fi
  fi
}

del_one_rule() {
  local bin="$1" chain="$2" proto="$3" set="$4" mode="$5"
  local cmt; cmt="$(comment)"
  if [ "$mode" = "input" ]; then
    while "$bin" -C "$chain" -p "$proto" --dport "$PORT" -m set --match-set "$set" src -m comment --comment "$cmt" -j DROP >/dev/null 2>&1; do
      "$bin" -D "$chain" -p "$proto" --dport "$PORT" -m set --match-set "$set" src -m comment --comment "$cmt" -j DROP || break
    done
  else
    while "$bin" -C "$chain" -p "$proto" -m conntrack --ctorigdstport "$PORT" -m set --match-set "$set" src -m comment --comment "$cmt" -j DROP >/dev/null 2>&1; do
      "$bin" -D "$chain" -p "$proto" -m conntrack --ctorigdstport "$PORT" -m set --match-set "$set" src -m comment --comment "$cmt" -j DROP || break
    done
  fi
}

apply_rules() {
  mkdir -p "$BASE_DIR"
  fetch_or_cache "$URL4" "$BASE_DIR/chnroute.txt"
  load_ipset inet "$(set4)" "$BASE_DIR/chnroute.txt"

  if command -v ip6tables >/dev/null 2>&1 && fetch_or_cache "$URL6" "$BASE_DIR/chnroute_v6.txt" optional; then
    load_ipset inet6 "$(set6)" "$BASE_DIR/chnroute_v6.txt" || log "IPv6 ipset 加载失败，已跳过 IPv6"
  fi

  local p
  for p in tcp udp; do
    has_proto "$p" || continue
    add_one_rule ipt4 INPUT "$p" "$(set4)" input
    if ipset list "$(set6)" >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1; then
      add_one_rule ipt6 INPUT "$p" "$(set6)" input || true
    fi

    if ipt4 -S DOCKER-USER >/dev/null 2>&1; then
      add_one_rule ipt4 DOCKER-USER "$p" "$(set4)" docker
    fi
    if command -v ip6tables >/dev/null 2>&1 && ipt6 -S DOCKER-USER >/dev/null 2>&1 && ipset list "$(set6)" >/dev/null 2>&1; then
      add_one_rule ipt6 DOCKER-USER "$p" "$(set6)" docker || true
    fi
  done
  log "完成：已屏蔽中国大陆 IP 访问 ${PORT}/${PROTO}"
}

install_self_if_needed() {
  mkdir -p "$(dirname "$BIN")"
  if [ "${0:-}" != "$BIN" ] && [ -r "${0:-}" ] && [ -f "${0:-}" ]; then
    install -m 0755 "$0" "$BIN"
  elif [ ! -x "$BIN" ]; then
    curl -fsSL --connect-timeout 10 --max-time 60 "$SCRIPT_URL" -o "$BIN"
    chmod +x "$BIN"
  fi
}

write_units() {
  command -v systemctl >/dev/null 2>&1 || { log "非 systemd 系统，已应用规则，但未创建开机自启"; return 0; }
  cat > "/etc/systemd/system/$(service_name)" <<UNIT
[Unit]
Description=Block Mainland China inbound traffic to port ${PORT}
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN} apply ${PORT} ${PROTO}

[Install]
WantedBy=multi-user.target
UNIT

  cat > "/etc/systemd/system/$(timer_name)" <<UNIT
[Unit]
Description=Daily update Mainland China IP ranges for port ${PORT} block

[Timer]
OnCalendar=*-*-* ${UPDATE_TIME}
RandomizedDelaySec=${RANDOM_DELAY}
Persistent=true
Unit=$(service_name)

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now "$(service_name)" >/dev/null 2>&1 || true
  systemctl enable --now "$(timer_name)" >/dev/null 2>&1 || true
  log "已创建 systemd：$(service_name) / $(timer_name)"
}

install_port() {
  need_root; valid_port; valid_proto
  install_deps
  install_self_if_needed
  apply_rules
  write_units
}

status_port() {
  valid_port
  echo "== ipset =="
  ipset list "$(set4)" 2>/dev/null | sed -n '1,12p' || true
  ipset list "$(set6)" 2>/dev/null | sed -n '1,12p' || true
  echo
  echo "== iptables rules =="
  iptables-save 2>/dev/null | grep -F "$(comment)" || true
  ip6tables-save 2>/dev/null | grep -F "$(comment)" || true
  echo
  echo "== systemd =="
  systemctl status "$(service_name)" --no-pager -l 2>/dev/null | sed -n '1,12p' || true
  systemctl list-timers "$(timer_name)" --no-pager 2>/dev/null || true
}

list_ports() {
  echo "== installed ports =="
  local found=0 f p
  if command -v systemctl >/dev/null 2>&1; then
    for f in /etc/systemd/system/ipblock-*.service; do
      [ -e "$f" ] || continue
      p="${f##*/ipblock-}"
      p="${p%.service}"
      echo "- $p"
      found=1
    done
  fi
  iptables-save 2>/dev/null | grep -oE 'ipblock:[0-9]+' | cut -d: -f2 | sort -n -u | while read -r p; do
    [ -n "$p" ] && echo "- $p (iptables)"
  done
  [ "$found" -eq 1 ] || true
}

update_all() {
  need_root
  command -v systemctl >/dev/null 2>&1 || err "update-all 需要 systemd；非 systemd 请逐个执行 apply"
  local f svc count=0
  for f in /etc/systemd/system/ipblock-*.service; do
    [ -e "$f" ] || continue
    svc="${f##*/}"
    log "更新 $svc"
    systemctl start "$svc"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || log "没有找到已安装的 ipblock service"
}

uninstall_port() {
  need_root; valid_port
  local p
  for p in tcp udp; do
    del_one_rule ipt4 INPUT "$p" "$(set4)" input || true
    del_one_rule ipt4 DOCKER-USER "$p" "$(set4)" docker || true
    if command -v ip6tables >/dev/null 2>&1; then
      del_one_rule ipt6 INPUT "$p" "$(set6)" input || true
      del_one_rule ipt6 DOCKER-USER "$p" "$(set6)" docker || true
    fi
  done
  ipset destroy "$(set4)" 2>/dev/null || true
  ipset destroy "$(set6)" 2>/dev/null || true

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$(timer_name)" >/dev/null 2>&1 || true
    systemctl disable --now "$(service_name)" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$(service_name)" "/etc/systemd/system/$(timer_name)"
    systemctl daemon-reload || true
  fi
  log "已删除端口 ${PORT} 的大陆封禁规则"
}

prompt_port_proto() {
  ask "请输入端口" "${PORT:-25084}" PORT
  valid_port
  ask "请输入协议 tcp/udp/both" "${PROTO:-both}" PROTO
  valid_proto
}

menu() {
  need_root
  install_self_if_needed || true
  while true; do
    cat <<MENU

========== ipblock 大陆端口封禁 ==========
IP 库：mayaxcn/china-ip-list
当前脚本：${BIN}

1) 安装/更新端口封禁，含开机自启和每日更新
2) 只应用一次规则
3) 查看端口状态
4) 列出已安装端口
5) 更新所有已安装端口
6) 删除端口封禁
0) 退出
MENU
    local choice
    ask "请选择" "1" choice
    case "$choice" in
      1) prompt_port_proto; install_port; pause_tty ;;
      2) prompt_port_proto; install_deps; apply_rules; pause_tty ;;
      3) ask "请输入端口" "${PORT:-25084}" PORT; status_port; pause_tty ;;
      4) list_ports; pause_tty ;;
      5) update_all; pause_tty ;;
      6) ask "请输入要删除的端口" "${PORT:-25084}" PORT; uninstall_port; pause_tty ;;
      0|q|Q|exit) exit 0 ;;
      *) echo "无效选择"; pause_tty ;;
    esac
  done
}

main() {
  case "$ACTION" in
    menu|interactive) menu ;;
    install) install_port ;;
    apply|update) need_root; valid_port; valid_proto; install_deps; apply_rules ;;
    status) status_port ;;
    list) list_ports ;;
    update-all) update_all ;;
    uninstall|remove) uninstall_port ;;
    -h|--help|help) usage ;;
    *) usage; err "未知命令：$ACTION" ;;
  esac
}

main "$@"
