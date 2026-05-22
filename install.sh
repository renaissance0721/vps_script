#!/usr/bin/env bash

set -Eeuo pipefail

REPO="${REPO:-renaissance0721/vps_script}"
BRANCH="${BRANCH:-main}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/vps}"
SOURCE_URL="${SOURCE_URL:-https://raw.githubusercontent.com/${REPO}/${BRANCH}/vps.sh}"

if [ -t 1 ]; then
  GREEN='\033[32m'
  YELLOW='\033[33m'
  RED='\033[31m'
  RESET='\033[0m'
else
  GREEN=''
  YELLOW=''
  RED=''
  RESET=''
fi

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    printf '%b\n' "${RED}需要 root 权限写入 ${INSTALL_PATH}，请使用 root 用户执行或安装 sudo。${RESET}" >&2
    exit 1
  fi
}

download() {
  local url="$1"
  local output="$2"

  if command_exists curl; then
    curl -fsSL --connect-timeout 8 --max-time 30 "$url" -o "$output"
  elif command_exists wget; then
    wget -qO "$output" "$url"
  else
    printf '%b\n' "${RED}未找到 curl 或 wget，无法下载安装脚本。${RESET}" >&2
    printf '%s\n' 'Debian/Ubuntu: apt update && apt install -y curl'
    printf '%s\n' 'Alpine: apk add --no-cache curl bash'
    exit 1
  fi
}

main() {
  if ! command_exists bash; then
    printf '%b\n' "${RED}未找到 bash，请先安装 bash。${RESET}" >&2
    printf '%s\n' 'Debian/Ubuntu: apt update && apt install -y bash'
    printf '%s\n' 'Alpine: apk add --no-cache bash'
    exit 1
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' EXIT

  printf '%b\n' "${YELLOW}正在下载 VPS 管理脚本...${RESET}"
  download "$SOURCE_URL" "$tmp_file"

  if ! bash -n "$tmp_file"; then
    printf '%b\n' "${RED}脚本语法检查失败，已停止安装。${RESET}" >&2
    exit 1
  fi

  run_as_root mkdir -p "$(dirname "$INSTALL_PATH")"
  run_as_root cp "$tmp_file" "$INSTALL_PATH"
  run_as_root chmod 0755 "$INSTALL_PATH"

  printf '%b\n' "${GREEN}安装完成。${RESET}"
  printf '运行命令: %s\n' "$INSTALL_PATH"
  printf '快捷命令: %s\n' "$(basename "$INSTALL_PATH")"
}

main "$@"
