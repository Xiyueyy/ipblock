#!/usr/bin/env bash
set -euo pipefail
BIN="/usr/local/sbin/ipblock"
SCRIPT_URL="https://raw.githubusercontent.com/Xiyueyy/ipblock/main/ipblock.sh"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "ERROR: 请用 root 运行" >&2
  exit 1
fi

mkdir -p "$(dirname "$BIN")"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --connect-timeout 10 --max-time 60 "$SCRIPT_URL" -o "$BIN"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$BIN" "$SCRIPT_URL"
else
  echo "ERROR: 需要 curl 或 wget" >&2
  exit 1
fi
chmod +x "$BIN"
echo "已安装到 $BIN"
exec "$BIN" "${@:-menu}"
