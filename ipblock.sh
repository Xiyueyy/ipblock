#!/usr/bin/env bash
# ipblock —— 按端口控制入站来源（nftables）：
#   大陆屏蔽：指定端口丢弃中国大陆 IP 主动发起的连接，可放行大陆中转机等例外 IP
#   端口白名单：指定端口只接受名单内 IP（或整个省份、域名）的连接，每个端口一份名单
# 只看"连进来"的新连接（conntrack 方向），本机访问外部的回包、其他端口都不受影响。
# 在 prerouting 阶段（DNAT 之前）匹配，裸机监听和 Docker 映射端口都能拦。
set -Eeuo pipefail

VERSION="2026-10-28"
APP="ipblock"
BIN="/usr/local/sbin/${APP}"
SCRIPT_URL="https://raw.githubusercontent.com/Xiyueyy/ipblock/main/ipblock.sh"
BASE_DIR="/etc/${APP}"
CN_PORTS="${BASE_DIR}/cn.ports"
CN_ALLOW="${BASE_DIR}/cn.allow"
CN4_FILE="${BASE_DIR}/cn4.txt"
CN6_FILE="${BASE_DIR}/cn6.txt"
WL_PORTS="${BASE_DIR}/wl.ports"
WL_DIR="${BASE_DIR}/wl"
PROV_DIR="${BASE_DIR}/prov"
DNS_DIR="${BASE_DIR}/dns"
NFT_TABLE="ipblock"
UNIT_DIR="/etc/systemd/system"

# 主来源：GeoLite2 按实际地理位置划分的国家库（"起,止,国家" CSV，每日更新）；备用：APNIC 官方分配表。
# 不用按运营商归属整理的库（chnroute 之类）：会把阿里云美国/新加坡/香港等海外机房（47.88.x、8.209.x…）也算成大陆。
CN4_URL="${IPBLOCK_CN4_URL:-https://raw.githubusercontent.com/sapics/ip-location-db/main/geolite2-country/geolite2-country-ipv4.csv}"
CN6_URL="${IPBLOCK_CN6_URL:-https://raw.githubusercontent.com/sapics/ip-location-db/main/geolite2-country/geolite2-country-ipv6.csv}"
APNIC_URL="${IPBLOCK_APNIC_URL:-https://ftp.apnic.net/stats/apnic/delegated-apnic-latest}"
# 省份/城市 IPv4 段（metowolf/iplist 的 cncity，按行政区划代码分文件，%s 替换成代码）；依次尝试，任一成功即可
PROV_URLS="${IPBLOCK_PROV_URL:-https://metowolf.github.io/iplist/data/cncity/%s.txt https://testingcf.jsdelivr.net/gh/metowolf/iplist@master/data/cncity/%s.txt https://raw.githubusercontent.com/metowolf/iplist/master/data/cncity/%s.txt}"
MIN_PROV_LINES=10
MIN_CN4_LINES=1000
MIN_CN6_LINES=200

if [ -t 1 ]; then RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'; else RED=""; GREEN=""; YELLOW=""; NC=""; fi
info() { printf '%s[信息]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die() { printf '%s[错误]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${APP} ${VERSION} —— 按端口屏蔽大陆来源 / 只放行白名单 IP（nftables）

交互菜单：
  ${APP}

大陆屏蔽：
  ${APP} cn add <端口>...          屏蔽大陆 IP 连这些端口
  ${APP} cn del <端口>...          取消屏蔽
  ${APP} cn allow <IP>...          例外放行（如大陆中转机），只对大陆屏蔽生效
  ${APP} cn disallow <IP>...       移除例外

端口白名单：
  ${APP} wl add <端口> <IP|省份|域名>...  该端口只放行这些来源（可多次执行追加）
  ${APP} wl rm  <端口> <IP|省份|域名>...  从该端口名单里移除
  ${APP} wl del <端口>...          取消该端口的白名单

其他：
  ${APP} status                    查看配置、IP 库和拦截计数
  ${APP} update                    重新下载大陆 / 省份 IP 库并生效（已设每周自动更新）
  ${APP} dns                       重新解析白名单里的域名，IP 变了就更新规则（有域名时每 5 分钟自动执行）
  ${APP} off / on                  临时关闭 / 按配置恢复（重启后自动恢复）
  ${APP} import                    导入并替换旧的 cn-port-block / port-allowlist
  ${APP} uninstall                 删除全部规则、定时任务和配置

端口写法：443、443/tcp、20000-20010/udp（不写协议 = TCP+UDP）
IP 写法：1.2.3.4、1.2.3.0/24、2001:db8::/32
省份写法：江西、广东省、内蒙古，或 6 位行政区划代码（如 360000 江西、360100 南昌），只含 IPv4
域名写法：ddns.example.com（适合动态 IP，解析出的 IPv4 / IPv6 都放行）
EOF
}

need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || die "请用 root 运行"; }

take_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"/run/${APP}.lock"
  flock -w 120 9 || die "另一个 ${APP} 正在运行"
}

ensure_deps() {
  if ! command -v nft >/dev/null 2>&1; then
    info "未检测到 nftables，正在安装..."
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y -q nftables
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q nftables
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache nftables >/dev/null
    else
      die "无法自动安装 nftables，请手动安装后重试"
    fi
  fi
  command -v nft >/dev/null 2>&1 || die "nftables 安装失败"
  nft list tables >/dev/null 2>&1 || die "当前环境无法使用 nftables（常见于 LXC/OpenVZ 容器，宿主机未授权），请在宿主机或 KVM 机器上使用"
}

# ---------- 配置文件 ----------

read_list() { [ -f "$1" ] && awk '!/^[[:space:]]*(#|$)/' "$1" || true; }

add_unique() {
  mkdir -p "$(dirname "$1")"; touch "$1"
  grep -qxF "$2" "$1" || printf '%s\n' "$2" >>"$1"
}

remove_line() {
  [ -f "$1" ] || return 0
  awk -v v="$2" '$0 != v' "$1" >"$1.tmp"
  mv "$1.tmp" "$1"
}

# 端口规格 → 每行 "端口 协议"（不写协议展开成 tcp、udp 两行）
parse_port() {
  local spec="$1" port proto a b
  port="${spec%%/*}"; proto="both"
  [[ "$spec" == */* ]] && proto="${spec#*/}"
  if [[ "$port" =~ ^[0-9]+$ ]]; then
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "端口超出范围：$spec"
  elif [[ "$port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"
    [ "$a" -ge 1 ] && [ "$b" -le 65535 ] && [ "$a" -lt "$b" ] || die "端口区间不对：$spec"
  else
    die "端口格式不对：$spec"
  fi
  case "$proto" in
    tcp|udp) echo "$port $proto" ;;
    both|"") echo "$port tcp"; echo "$port udp" ;;
    *) die "协议只能是 tcp / udp：$spec" ;;
  esac
}

valid_ip() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || [[ "$1" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ && "$1" == *:* ]]
}

port_overlaps() {
  local p="$1" x="$2"
  if [[ "$p" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    [ "$x" -ge "${BASH_REMATCH[1]}" ] && [ "$x" -le "${BASH_REMATCH[2]}" ]
  else
    [ "$p" -eq "$x" ]
  fi
}

ssh_ports() {
  local ports=""
  command -v sshd >/dev/null 2>&1 && ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' || true)"
  if [ -z "$ports" ] && command -v ss >/dev/null 2>&1; then
    ports="$(ss -Hltnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}' | sort -u || true)"
  fi
  printf '%s\n' "${ports:-22}"
}

refuse_ssh() {
  local port="$1" s
  for s in $(ssh_ports); do
    port_overlaps "$port" "$s" && die "端口 $port 包含 SSH 端口 $s，拒绝操作，防止把自己锁在外面"
  done
  return 0
}

# "端口 协议" 列表 → "443 25084/tcp" 这样的展示
fmt_ports() {
  awk '{ if (!($1 in p)) o[++n] = $1; p[$1] = p[$1] " " $2 }
       END { for (i = 1; i <= n; i++) { k = o[i]; s = (p[k] ~ /tcp/ && p[k] ~ /udp/) ? k : k "/" substr(p[k], 2); printf "%s%s", (i > 1 ? " " : ""), s } }'
}

wl_file() { echo "${WL_DIR}/$1"; }
wl_id() { echo "${1//-/_}"; }
wl_port_list() { read_list "$WL_PORTS" | awk '!seen[$1]++ { print $1 }'; }
wl_has_port() { read_list "$WL_PORTS" | awk -v p="$1" '$1 == p { f = 1 } END { exit !f }'; }
v4_only() { awk '/^[0-9.\/]+$/'; }
v6_only() { awk '/:/'; }
prov_only() { awk '!/[.:]/'; }
dom_only() { awk '/[A-Za-z]/ && /\./ && !/:/'; }

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9]$ ]]
}

# 省份名 → 去掉"省/市/自治区"等后缀的简称；6 位代码原样返回；不认识返回失败
prov_norm() {
  local n="$1"
  if [[ "$n" =~ ^[1-6][0-9]{5}$ ]]; then echo "$n"; return 0; fi
  n="${n%省}"; n="${n%市}"; n="${n%自治区}"; n="${n%壮族}"; n="${n%回族}"; n="${n%维吾尔}"
  prov_code "$n" >/dev/null && echo "$n"
}

prov_code() {
  case "$1" in
    北京) echo 110000 ;; 天津) echo 120000 ;; 河北) echo 130000 ;; 山西) echo 140000 ;; 内蒙古) echo 150000 ;;
    辽宁) echo 210000 ;; 吉林) echo 220000 ;; 黑龙江) echo 230000 ;;
    上海) echo 310000 ;; 江苏) echo 320000 ;; 浙江) echo 330000 ;; 安徽) echo 340000 ;; 福建) echo 350000 ;; 江西) echo 360000 ;; 山东) echo 370000 ;;
    河南) echo 410000 ;; 湖北) echo 420000 ;; 湖南) echo 430000 ;; 广东) echo 440000 ;; 广西) echo 450000 ;; 海南) echo 460000 ;;
    重庆) echo 500000 ;; 四川) echo 510000 ;; 贵州) echo 520000 ;; 云南) echo 530000 ;; 西藏) echo 540000 ;;
    陕西) echo 610000 ;; 甘肃) echo 620000 ;; 青海) echo 630000 ;; 宁夏) echo 640000 ;; 新疆) echo 650000 ;;
    *) [[ "$1" =~ ^[1-6][0-9]{5}$ ]] && echo "$1" || return 1 ;;
  esac
}

prov_file() { echo "${PROV_DIR}/$(prov_code "$1").txt"; }

# 所有端口名单里用到的省份（去重）
used_provs() {
  local port
  for port in $(wl_port_list); do read_list "$(wl_file "$port")" | prov_only; done | awk '!seen[$0]++'
}

used_doms() {
  local port
  for port in $(wl_port_list); do read_list "$(wl_file "$port")" | dom_only; done | awk '!seen[$0]++'
}

dns_file() { echo "${DNS_DIR}/$1"; }

# 解析全部域名写入缓存；解析失败沿用上次结果。有缓存变化时返回 0
resolve_doms() {
  local d f tmp changed=1
  mkdir -p "$DNS_DIR"
  for d in $(used_doms); do
    f="$(dns_file "$d")"; tmp="$(mktemp)"
    { timeout 10 getent ahostsv4 "$d" || true; timeout 10 getent ahostsv6 "$d" || true; } \
      | awk '{ print $1 }' | grep -vE '^::ffff:' | sort -u >"$tmp"
    if [ ! -s "$tmp" ]; then
      [ -s "$f" ] && warn "域名 $d 解析失败，沿用上次结果：$(paste -sd' ' "$f")" || warn "域名 $d 解析失败，暂时没有可放行的 IP"
      rm -f "$tmp"; continue
    fi
    if ! cmp -s "$tmp" "$f"; then
      [ -s "$f" ] && info "域名 $d：$(paste -sd' ' "$f") → $(paste -sd' ' "$tmp")"
      install -m 600 "$tmp" "$f"; changed=0
    fi
    rm -f "$tmp"
  done
  return "$changed"
}

# 端口名单展开成具体地址：IP 原样，域名换成缓存里的解析结果
wl_addrs() {
  local e
  read_list "$(wl_file "$1")" | while read -r e; do
    if valid_ip "$e"; then echo "$e"; elif valid_domain "$e"; then read_list "$(dns_file "$e")"; fi
  done
}

# ---------- 大陆 IP 库 ----------

fetch_cn_lists() {
  command -v curl >/dev/null 2>&1 || die "需要 curl"
  mkdir -p "$BASE_DIR"
  local tmp4 tmp6 apnic
  tmp4="$(mktemp)"; tmp6="$(mktemp)"; apnic="$(mktemp)"

  info "下载大陆 IP 库..."
  if curl -fsSL --retry 3 --connect-timeout 15 -m 300 "$CN4_URL" -o "$tmp4" \
    && curl -fsSL --retry 3 --connect-timeout 15 -m 300 "$CN6_URL" -o "$tmp6" \
    && { awk -F, '$3=="CN" { print ($1==$2 ? $1 : $1 "-" $2) }' "$tmp4" | grep -E '^[0-9]+(\.[0-9]+){3}(-[0-9]+(\.[0-9]+){3})?$' >"${tmp4}.ok" || true; } \
    && { awk -F, '$3=="CN" { print ($1==$2 ? $1 : $1 "-" $2) }' "$tmp6" | grep -E '^[0-9a-fA-F:]+(-[0-9a-fA-F:]+)?$' >"${tmp6}.ok" || true; } \
    && [ "$(wc -l <"${tmp4}.ok")" -ge "$MIN_CN4_LINES" ] \
    && [ "$(wc -l <"${tmp6}.ok")" -ge "$MIN_CN6_LINES" ]; then
    mv "${tmp4}.ok" "$tmp4"; mv "${tmp6}.ok" "$tmp6"
  else
    rm -f "${tmp4}.ok" "${tmp6}.ok"
    warn "主来源不可用，改用 APNIC 官方分配表"
    if ! curl -fsSL --retry 3 --connect-timeout 15 -m 300 "$APNIC_URL" -o "$apnic"; then
      rm -f "$tmp4" "$tmp6" "$apnic"
      [ -s "$CN4_FILE" ] && { warn "下载失败，继续使用本地缓存的 IP 库"; return 0; }
      die "下载 IP 库失败，请检查网络后重试"
    fi
    # APNIC 的 IPv4 记录是"起始地址 + 数量"，数量不一定是 2 的幂，直接转成 nft 区间写法。
    awk -F'|' '$2=="CN" && $3=="ipv4" {
      split($4, o, "."); s = ((o[1]*256 + o[2])*256 + o[3])*256 + o[4]; e = s + $5 - 1;
      printf "%s-%d.%d.%d.%d\n", $4, int(e/16777216)%256, int(e/65536)%256, int(e/256)%256, e%256
    }' "$apnic" >"$tmp4"
    awk -F'|' '$2=="CN" && $3=="ipv6" { print $4 "/" $5 }' "$apnic" >"$tmp6"
    if [ "$(wc -l <"$tmp4")" -lt "$MIN_CN4_LINES" ]; then
      rm -f "$tmp4" "$tmp6" "$apnic"
      [ -s "$CN4_FILE" ] && { warn "APNIC 数据异常，继续使用本地缓存的 IP 库"; return 0; }
      die "APNIC 数据异常，已放弃更新"
    fi
  fi

  install -m 600 "$tmp4" "$CN4_FILE"
  install -m 600 "$tmp6" "$CN6_FILE"
  rm -f "$tmp4" "$tmp6" "$apnic"
  info "IP 库已更新：IPv4 $(wc -l <"$CN4_FILE") 段，IPv6 $(wc -l <"$CN6_FILE") 段"
}

fetch_prov() {
  # $1 省份简称或代码；$2=keep 时下载失败沿用缓存
  local name="$1" code dst tmp tpl
  command -v curl >/dev/null 2>&1 || die "需要 curl"
  code="$(prov_code "$name")"; dst="$(prov_file "$name")"
  mkdir -p "$PROV_DIR"; tmp="$(mktemp)"
  for tpl in $PROV_URLS; do
    # shellcheck disable=SC2059
    if curl -fsSL --retry 2 --connect-timeout 10 -m 60 "$(printf "$tpl" "$code")" 2>/dev/null \
      | grep -E '^[0-9]+(\.[0-9]+){3}/[0-9]+$' >"$tmp" && [ "$(wc -l <"$tmp")" -ge "$MIN_PROV_LINES" ]; then
      install -m 600 "$tmp" "$dst"; rm -f "$tmp"
      info "${name} IP 库已更新：IPv4 $(wc -l <"$dst") 段"
      return 0
    fi
  done
  rm -f "$tmp"
  if [ "${2:-}" = keep ] && [ -s "$dst" ]; then warn "${name} IP 库下载失败，继续使用本地缓存"; return 0; fi
  die "${name} IP 库下载失败，请检查网络后重试"
}

# ---------- 规则 ----------

set_block() {
  # $1 名称 $2 类型，元素从标准输入读
  local elements
  elements="$(paste -sd, - | sed 's/,/, /g')"
  printf '  set %s {\n    type %s\n    flags interval\n    auto-merge\n' "$1" "$2"
  [ -n "$elements" ] && printf '    elements = { %s }\n' "$elements"
  printf '  }\n'
}

build_ruleset() {
  local port proto id p
  # 先建再删再建：整份文件原子生效，不会出现规则空窗。
  printf 'table inet %s {}\ndelete table inet %s\ntable inet %s {\n' "$NFT_TABLE" "$NFT_TABLE" "$NFT_TABLE"

  set_block cn4 ipv4_addr <"$CN4_FILE"
  set_block cn6 ipv6_addr <"$CN6_FILE"
  read_list "$CN_ALLOW" | v4_only | set_block cn_allow4 ipv4_addr
  read_list "$CN_ALLOW" | v6_only | set_block cn_allow6 ipv6_addr
  read_list "$CN_PORTS" | awk '$2=="tcp" { print $1 }' | set_block cn_tcp inet_service
  read_list "$CN_PORTS" | awk '$2=="udp" { print $1 }' | set_block cn_udp inet_service
  for port in $(wl_port_list); do
    id="$(wl_id "$port")"
    wl_addrs "$port" | v4_only | awk '!seen[$0]++' | set_block "wl_${id}_4" ipv4_addr
    wl_addrs "$port" | v6_only | awk '!seen[$0]++' | set_block "wl_${id}_6" ipv6_addr
  done
  for p in $(used_provs); do
    set_block "prov_$(prov_code "$p")" ipv4_addr <"$(prov_file "$p")"
  done

  printf '  chain prerouting {\n    type filter hook prerouting priority -160; policy accept;\n'
  printf '    tcp dport @cn_tcp ct direction original jump cn\n'
  printf '    udp dport @cn_udp ct direction original jump cn\n'
  read_list "$WL_PORTS" | while read -r port proto; do
    printf '    %s dport %s ct direction original jump wl_%s\n' "$proto" "$port" "$(wl_id "$port")"
  done
  printf '  }\n'

  cat <<'EOF'
  chain cn {
    ip saddr @cn_allow4 return
    ip6 saddr @cn_allow6 return
    ip saddr @cn4 counter drop
    ip6 saddr @cn6 counter drop
  }
EOF
  for port in $(wl_port_list); do
    id="$(wl_id "$port")"
    printf '  chain wl_%s {\n    ip saddr @wl_%s_4 return\n    ip6 saddr @wl_%s_6 return\n' "$id" "$id" "$id"
    for p in $(read_list "$(wl_file "$port")" | prov_only); do
      printf '    ip saddr @prov_%s return\n' "$(prov_code "$p")"
    done
    printf '    counter drop\n  }\n'
  done
  printf '}\n'
}

apply_rules() {
  if [ -z "$(read_list "$CN_PORTS")" ] && [ -z "$(read_list "$WL_PORTS")" ]; then
    nft delete table inet "$NFT_TABLE" 2>/dev/null || true
    info "没有配置任何端口，规则已清空"
    return 0
  fi
  mkdir -p "$BASE_DIR"
  if [ -n "$(read_list "$CN_PORTS")" ] && [ ! -s "$CN4_FILE" ]; then
    fetch_cn_lists
  fi
  local p
  for p in $(used_provs); do [ -s "$(prov_file "$p")" ] || fetch_prov "$p"; done
  [ -n "${DNS_RESOLVED:-}" ] || [ -z "$(used_doms)" ] || resolve_doms || true
  [ -e "$CN4_FILE" ] || : >"$CN4_FILE"
  [ -e "$CN6_FILE" ] || : >"$CN6_FILE"

  local ruleset
  ruleset="$(mktemp)"
  build_ruleset >"$ruleset"
  if ! nft -c -f "$ruleset"; then
    rm -f "$ruleset"
    die "规则校验失败，未做任何改动"
  fi
  nft -f "$ruleset"
  rm -f "$ruleset"
  info "规则已生效"
}

install_self() {
  if [ "${0:-}" != "$BIN" ] && [ -f "${0:-}" ]; then
    install -m 755 "$0" "$BIN"
  elif [ ! -x "$BIN" ]; then
    curl -fsSL --connect-timeout 10 --max-time 60 "$SCRIPT_URL" -o "$BIN" && chmod +x "$BIN" \
      || warn "无法安装到 ${BIN}，开机自启需要脚本在该路径"
  fi
}

install_units() {
  install_self
  command -v systemctl >/dev/null 2>&1 || { warn "没有 systemd：重启后需要手动执行 ${APP} on"; return 0; }
  cat >"${UNIT_DIR}/${APP}.service" <<EOF
[Unit]
Description=ipblock: per-port mainland China block and source allowlist
Wants=network-pre.target
Before=network-pre.target
After=nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${BIN} on
ExecStop=${BIN} off

[Install]
WantedBy=multi-user.target
EOF
  cat >"${UNIT_DIR}/${APP}-update.service" <<EOF
[Unit]
Description=ipblock: refresh mainland China / province IP lists
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN} update
EOF
  cat >"${UNIT_DIR}/${APP}-update.timer" <<EOF
[Unit]
Description=ipblock: weekly refresh of mainland China / province IP lists

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  cat >"${UNIT_DIR}/${APP}-dns.service" <<EOF
[Unit]
Description=ipblock: re-resolve allowlist domains
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN} dns
EOF
  cat >"${UNIT_DIR}/${APP}-dns.timer" <<EOF
[Unit]
Description=ipblock: re-resolve allowlist domains every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable "${APP}.service" >/dev/null 2>&1 || true
  systemctl enable --now "${APP}-update.timer" >/dev/null 2>&1 || true
  dns_timer_sync
}

# 名单里有域名才开每 5 分钟的重新解析
dns_timer_sync() {
  command -v systemctl >/dev/null 2>&1 && [ -f "${UNIT_DIR}/${APP}-dns.timer" ] || return 0
  if [ -n "$(used_doms)" ]; then
    systemctl enable --now "${APP}-dns.timer" >/dev/null 2>&1 || true
  else
    systemctl disable --now "${APP}-dns.timer" >/dev/null 2>&1 || true
  fi
}

# ---------- 旧版迁移 ----------

# 旧版 ipblock（iptables + ipset，每个端口一组 ipblock-<端口>.service/.timer）
legacy_ipblock_entries() {
  local f
  for f in "${UNIT_DIR}"/${APP}-[0-9]*.service; do
    [ -e "$f" ] || continue
    awk '/^ExecStart=/ { print $3, ($4 == "" ? "both" : $4) }' "$f"
  done
  if command -v iptables-save >/dev/null 2>&1; then
    iptables-save -t filter 2>/dev/null | awk '/ipblock:[0-9]+/ {
      for (i = 1; i <= NF; i++) { if ($i == "-p") pr = $(i+1); if ($i ~ /ipblock:[0-9]+/) { pt = $i; gsub(/[^0-9]/, "", pt) } }
      print pt, pr }'
  fi
}

migrate_legacy_ipblock() {
  local entries bin line s
  entries="$(legacy_ipblock_entries | sort -u)"
  [ -n "$entries" ] || return 0
  info "检测到旧版 ipblock（iptables 版），迁移到新规则..."
  while read -r port proto; do
    [ -n "$port" ] || continue
    parse_port "${port}/${proto}" | while read -r line; do add_unique "$CN_PORTS" "$line"; done
  done <<<"$entries"

  for bin in iptables ip6tables; do
    command -v "${bin}-save" >/dev/null 2>&1 || continue
    "${bin}-save" -t filter 2>/dev/null | awk '/^-A / && /ipblock:[0-9]+/' | while IFS= read -r line; do
      eval "$bin -w -t filter -D ${line#-A }" 2>/dev/null || true
    done
  done
  if command -v ipset >/dev/null 2>&1; then
    for s in $(ipset list -n 2>/dev/null | awk '/^ipblock_[0-9]+_v[46]$/'); do ipset destroy "$s" 2>/dev/null || true; done
  fi
  for line in "${UNIT_DIR}"/${APP}-[0-9]*.timer "${UNIT_DIR}"/${APP}-[0-9]*.service; do
    [ -e "$line" ] || continue
    s="${line##*/}"
    if command -v systemctl >/dev/null 2>&1; then
      # 不对 .service 用 --now：这次运行可能就是旧的 ipblock-<端口>.service 拉起来的
      if [[ "$s" == *.timer ]]; then systemctl disable --now "$s" >/dev/null 2>&1 || true; else systemctl disable "$s" >/dev/null 2>&1 || true; fi
    fi
    rm -f "$line"
  done
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload || true
  rm -f "${BASE_DIR}/chnroute.txt" "${BASE_DIR}/chnroute_v6.txt"
  info "旧版端口已并入大陆屏蔽：$(read_list "$CN_PORTS" | fmt_ports)"
  apply_rules
  install_units
}

import_old() {
  local found=0 p ip
  if [ -d /etc/cn-port-block ]; then
    found=1
    info "导入 cn-port-block..."
    for p in $(read_list /etc/cn-port-block/ports); do
      parse_port "$p" | while read -r line; do add_unique "$CN_PORTS" "$line"; done
    done
    for ip in $(read_list /etc/cn-port-block/allow); do add_unique "$CN_ALLOW" "$ip"; done
    if [ -s /etc/cn-port-block/cn4.txt ] && [ ! -s "$CN4_FILE" ]; then
      install -m 600 /etc/cn-port-block/cn4.txt "$CN4_FILE"
      install -m 600 /etc/cn-port-block/cn6.txt "$CN6_FILE"
    fi
  fi
  if [ -d /etc/port-allowlist ]; then
    found=1
    info "导入 port-allowlist..."
    for p in $(read_list /etc/port-allowlist/ports); do
      parse_port "$p" | while read -r line; do add_unique "$WL_PORTS" "$line"; done
      for ip in $(read_list /etc/port-allowlist/allow); do add_unique "$(wl_file "${p%%/*}")" "$ip"; done
    done
  fi
  [ "$found" -eq 1 ] || { info "没有找到 cn-port-block / port-allowlist 的配置"; return 0; }

  apply_rules
  install_units
  # 新规则生效后再拆旧的，中间不留空窗
  nft delete table inet cn_port_block 2>/dev/null || true
  nft delete table inet port_allowlist 2>/dev/null || true
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now cn-port-block-update.timer >/dev/null 2>&1 || true
    systemctl disable cn-port-block.service port-allowlist.service >/dev/null 2>&1 || true
    rm -f "${UNIT_DIR}"/cn-port-block.service "${UNIT_DIR}"/cn-port-block-update.service "${UNIT_DIR}"/cn-port-block-update.timer "${UNIT_DIR}"/port-allowlist.service
    systemctl daemon-reload || true
  fi
  rm -rf /etc/cn-port-block /etc/port-allowlist
  rm -f /usr/local/sbin/cn-port-block /usr/local/sbin/port-allowlist
  info "导入完成，旧脚本已移除"
  show_status
}

# ---------- 命令 ----------

cn_cmd() {
  local sub="${1:-}" p line
  shift || true
  case "$sub" in
    add)
      [ $# -gt 0 ] || die "请指定端口，例如：${APP} cn add 443"
      for p in "$@"; do parse_port "$p" >/dev/null; refuse_ssh "${p%%/*}"; done
      for p in "$@"; do parse_port "$p" | while read -r line; do add_unique "$CN_PORTS" "$line"; done; done
      apply_rules; install_units ;;
    del)
      [ $# -gt 0 ] || die "请指定端口"
      for p in "$@"; do parse_port "$p" | while read -r line; do remove_line "$CN_PORTS" "$line"; done; done
      apply_rules ;;
    allow)
      [ $# -gt 0 ] || die "请指定 IP"
      for p in "$@"; do valid_ip "$p" || die "IP 格式不对：$p"; done
      for p in "$@"; do add_unique "$CN_ALLOW" "$p"; done
      apply_rules ;;
    disallow)
      [ $# -gt 0 ] || die "请指定 IP"
      for p in "$@"; do remove_line "$CN_ALLOW" "$p"; done
      apply_rules ;;
    *) usage; exit 1 ;;
  esac
  show_status
}

# IP、域名原样返回，省份返回简称；都不是则报错
wl_entry() {
  valid_ip "$1" && { echo "$1"; return 0; }
  valid_domain "$1" && { echo "$1" | tr 'A-Z' 'a-z'; return 0; }
  prov_norm "$1" || die "不是 IP、域名或省份：$1"
}

wl_cmd() {
  local sub="${1:-}" spec port p line entries=()
  shift || true
  case "$sub" in
    add)
      [ $# -ge 2 ] || die "用法：${APP} wl add <端口> <IP|省份>..."
      spec="$1"; shift; port="${spec%%/*}"
      parse_port "$spec" >/dev/null; refuse_ssh "$port"
      for p in "$@"; do entries+=("$(wl_entry "$p")"); done
      for p in "${entries[@]}"; do
        if ! valid_ip "$p" && ! valid_domain "$p" && [ ! -s "$(prov_file "$p")" ]; then fetch_prov "$p"; fi
      done
      if wl_has_port "$port" && [[ "$spec" == */* ]]; then
        warn "端口 $port 已有白名单，协议以首次添加为准；要改协议请先 ${APP} wl del $port"
      else
        parse_port "$spec" | while read -r line; do add_unique "$WL_PORTS" "$line"; done
      fi
      for p in "${entries[@]}"; do add_unique "$(wl_file "$port")" "$p"; done
      apply_rules; install_units ;;
    rm)
      [ $# -ge 2 ] || die "用法：${APP} wl rm <端口> <IP|省份>..."
      port="${1%%/*}"; shift
      wl_has_port "$port" || die "端口 $port 没有白名单"
      for p in "$@"; do remove_line "$(wl_file "$port")" "$(wl_entry "$p")"; done
      [ -n "$(read_list "$(wl_file "$port")")" ] || warn "端口 $port 的名单已空，所有来源都会被拦截；不需要了请用 ${APP} wl del $port"
      apply_rules; dns_timer_sync ;;
    del)
      [ $# -gt 0 ] || die "请指定端口"
      for spec in "$@"; do
        port="${spec%%/*}"
        parse_port "$spec" | while read -r line; do remove_line "$WL_PORTS" "$line"; done
        wl_has_port "$port" || rm -f "$(wl_file "$port")"
      done
      apply_rules; dns_timer_sync ;;
    *) usage; exit 1 ;;
  esac
  show_status
}

chain_drops() {
  nft list chain inet "$NFT_TABLE" "$1" 2>/dev/null \
    | awk '/counter/ && /drop/ { for (i = 1; i <= NF; i++) if ($i == "packets") s += $(i+1) } END { print s + 0 }'
}

show_status() {
  local active=0 port ips allow p
  nft list table inet "$NFT_TABLE" >/dev/null 2>&1 && active=1
  echo
  printf '%s %s  状态：%s\n' "$APP" "$VERSION" "$([ "$active" -eq 1 ] && echo "${GREEN}生效中${NC}" || echo "${YELLOW}未生效${NC}")"

  echo "[大陆屏蔽]"
  if [ -n "$(read_list "$CN_PORTS")" ]; then
    allow="$(read_list "$CN_ALLOW" | paste -sd' ' -)"
    echo "  端口：  $(read_list "$CN_PORTS" | fmt_ports)"
    echo "  例外：  ${allow:-（无）}"
    if [ -s "$CN4_FILE" ]; then
      echo "  IP 库： IPv4 $(wc -l <"$CN4_FILE") 段 / IPv6 $(wc -l <"$CN6_FILE") 段，更新于 $(date -r "$CN4_FILE" '+%F %T')"
    else
      echo "  IP 库： 未下载"
    fi
    [ "$active" -eq 1 ] && echo "  已拦截：$(chain_drops cn) 个包"
  else
    echo "  （未配置）"
  fi

  echo "[端口白名单]"
  if [ -n "$(read_list "$WL_PORTS")" ]; then
    for port in $(wl_port_list); do
      ips="$(read_list "$(wl_file "$port")" | while read -r p; do
        if valid_ip "$p"; then echo "$p"
        elif valid_domain "$p"; then echo "${p}($(read_list "$(dns_file "$p")" | paste -sd, - | sed 's/^$/未解析/'))"
        else echo "${p}($(wc -l 2>/dev/null <"$(prov_file "$p")" || echo 0)段)"; fi
      done | paste -sd' ' -)"
      printf '  %-12s 放行：%s' "$(read_list "$WL_PORTS" | awk -v p="$port" '$1 == p' | fmt_ports)" "${ips:-（无，全部拦截）}"
      [ "$active" -eq 1 ] && printf '  已拦截：%s 个包' "$(chain_drops "wl_$(wl_id "$port")")"
      echo
    done
  else
    echo "  （未配置）"
  fi
  return 0
}

fetch_and_apply() {
  local p provs
  provs="$(used_provs)"
  if [ -z "$(read_list "$CN_PORTS")" ] && [ -z "$provs" ]; then
    info "没有配置大陆屏蔽端口或省份白名单，跳过 IP 库更新"
    return 0
  fi
  [ -n "$(read_list "$CN_PORTS")" ] && fetch_cn_lists
  for p in $provs; do fetch_prov "$p" keep; done
  apply_rules
}

refresh_dns() {
  [ -n "$(used_doms)" ] || { info "白名单里没有域名"; return 0; }
  if resolve_doms; then DNS_RESOLVED=1 apply_rules; else info "域名解析结果没有变化"; fi
}

uninstall_all() {
  nft delete table inet "$NFT_TABLE" 2>/dev/null || true
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "${APP}-update.timer" "${APP}-dns.timer" "${APP}.service" >/dev/null 2>&1 || true
    rm -f "${UNIT_DIR}/${APP}.service" "${UNIT_DIR}/${APP}-update.service" "${UNIT_DIR}/${APP}-update.timer" "${UNIT_DIR}/${APP}-dns.service" "${UNIT_DIR}/${APP}-dns.timer"
    systemctl daemon-reload || true
  fi
  rm -rf "$BASE_DIR"
  rm -f "$BIN"
  info "已卸载"
}

# ---------- 交互菜单 ----------

ask() {
  local prompt="$1" default="${2:-}" __var="$3" ans
  [ -n "$default" ] && prompt="${prompt} [${default}]"
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s: ' "$prompt" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
  else
    printf '%s: ' "$prompt"
    IFS= read -r ans || ans=""
  fi
  printf -v "$__var" '%s' "${ans:-$default}"
}

pause_tty() {
  local _dummy
  [ -r /dev/tty ] && [ -w /dev/tty ] && { printf '\n按回车继续...' >/dev/tty; IFS= read -r _dummy </dev/tty || true; }
  return 0
}

# 菜单里每个操作放进子 shell，出错只回到菜单
run() { ( "$@" ) || true; pause_tty; }

menu() {
  local choice a b
  install_self
  while true; do
    cat <<MENU

========== ${APP} ${VERSION} ==========
 大陆屏蔽
  1) 添加端口            2) 删除端口
  3) 添加例外 IP         4) 移除例外 IP
 端口白名单（只放行指定 IP / 省份 / 域名）
  5) 添加端口 / IP       6) 移除 IP
  7) 取消某端口白名单
 其他
  8) 查看状态            9) 立即更新 IP 库
 10) 导入旧版 cn-port-block / port-allowlist
 11) 全部卸载            0) 退出
MENU
    ask "请选择" "8" choice
    case "$choice" in
      1) ask "端口（空格分隔，如 443 25084/tcp 20000-20010）" "" a; run cn_cmd add $a ;;
      2) ask "要取消屏蔽的端口" "" a; run cn_cmd del $a ;;
      3) ask "例外 IP（空格分隔）" "" a; run cn_cmd allow $a ;;
      4) ask "要移除的例外 IP" "" a; run cn_cmd disallow $a ;;
      5) ask "端口" "" a; ask "放行的 IP、省份或域名（空格分隔，如 1.2.3.4 江西 ddns.example.com）" "" b; run wl_cmd add "$a" $b ;;
      6) ask "端口" "" a; ask "要移除的 IP、省份或域名" "" b; run wl_cmd rm "$a" $b ;;
      7) ask "要取消白名单的端口" "" a; run wl_cmd del $a ;;
      8) run show_status ;;
      9) run fetch_and_apply ;;
      10) run import_old ;;
      11) ask "确认删除全部规则和配置？输入 yes" "" a; if [ "$a" = "yes" ]; then uninstall_all; exit 0; fi ;;
      0|q|Q|exit) exit 0 ;;
      *) echo "无效选择" ;;
    esac
  done
}

main() {
  local cmd="${1:-menu}"
  shift || true
  case "$cmd" in
    -h|--help|help) usage; exit 0 ;;
    -v|--version|version) echo "$VERSION"; exit 0 ;;
  esac
  need_root
  ensure_deps
  take_lock
  migrate_legacy_ipblock
  case "$cmd" in
    menu|interactive) menu ;;
    cn) cn_cmd "$@" ;;
    wl|allowlist) wl_cmd "$@" ;;
    status|list) show_status ;;
    update|update-all) fetch_and_apply ;;
    dns) refresh_dns ;;
    on|apply) apply_rules ;;
    off) nft delete table inet "$NFT_TABLE" 2>/dev/null || true; info "已临时关闭（配置保留，执行 ${APP} on 恢复）" ;;
    import) import_old ;;
    uninstall) uninstall_all ;;
    # 旧版写法：ipblock install <端口> [tcp|udp|both]
    install) [ $# -gt 0 ] || die "请指定端口"; cn_cmd add "$1${2:+/$2}" ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
