#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="VPS一键管理脚本"
REPO="${REPO:-renaissance0721/vps_script}"
BRANCH="${BRANCH:-main}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin/vps}"
SHORTCUT_PATH="${SHORTCUT_PATH:-/usr/local/bin/r}"
SOURCE_URL="${SOURCE_URL:-https://raw.githubusercontent.com/${REPO}/${BRANCH}/vps.sh}"

if [ -t 1 ]; then
  RED='\033[31m'
  GREEN='\033[32m'
  YELLOW='\033[33m'
  BLUE='\033[34m'
  CYAN='\033[36m'
  RESET='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  CYAN=''
  RESET=''
fi

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

unknown_if_empty() {
  local value="${1:-}"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '未知\n'
  fi
}

format_bytes() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", unit, " ")
    i = 1
    while (b >= 1024 && i < 6) {
      b = b / 1024
      i++
    }
    if (i == 1) {
      printf "%.0f %s", b, unit[i]
    } else {
      printf "%.2f %s", b, unit[i]
    }
  }'
}

format_percent() {
  local used="${1:-0}"
  local total="${2:-0}"
  awk -v u="$used" -v t="$total" 'BEGIN {
    if (t > 0) {
      printf "%.1f%%", u * 100 / t
    } else {
      printf "0.0%%"
    }
  }'
}

http_get() {
  local url="$1"

  if command_exists curl; then
    curl -4fsSL --connect-timeout 4 --max-time 8 "$url"
  elif command_exists wget; then
    wget -qO- -T 8 -t 1 "$url"
  else
    return 1
  fi
}

download_file() {
  local url="$1"
  local output="$2"

  if command_exists curl; then
    curl -fsSL --connect-timeout 8 --max-time 30 "$url" -o "$output"
  else
    return 1
  fi
}

get_hostname() {
  hostname 2>/dev/null || printf '未知\n'
}

get_os_version() {
  if [ -r /etc/os-release ]; then
    (
      # shellcheck disable=SC1091
      . /etc/os-release
      if [ -n "${PRETTY_NAME:-}" ]; then
        printf '%s\n' "$PRETTY_NAME"
      elif [ -n "${NAME:-}" ]; then
        printf '%s %s\n' "$NAME" "${VERSION_ID:-}"
      else
        printf '未知\n'
      fi
    )
  elif command_exists lsb_release; then
    lsb_release -ds 2>/dev/null | tr -d '"' || printf '未知\n'
  else
    printf '未知\n'
  fi
}

get_linux_version() {
  uname -sr 2>/dev/null || printf '未知\n'
}

get_cpu_arch() {
  uname -m 2>/dev/null || printf '未知\n'
}

get_cpu_model() {
  if [ -r /proc/cpuinfo ]; then
    awk -F ':' '
      /model name|Hardware|Processor/ {
        value = $2
        gsub(/^[ \t]+|[ \t]+$/, "", value)
        if (value != "") {
          print value
          exit
        }
      }
    ' /proc/cpuinfo
  else
    printf '未知\n'
  fi
}

get_cpu_cores() {
  local cores=""

  if command_exists nproc; then
    cores="$(nproc 2>/dev/null || true)"
  fi

  if [ -z "$cores" ] && command_exists getconf; then
    cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi

  if [ -z "$cores" ] && [ -r /proc/cpuinfo ]; then
    cores="$(awk '/^processor[ \t]*:/ { count++ } END { print count ? count : 1 }' /proc/cpuinfo)"
  fi

  unknown_if_empty "$cores"
}

get_cpu_freq() {
  local mhz=""
  local khz=""

  if [ -r /proc/cpuinfo ]; then
    mhz="$(awk -F ':' '/cpu MHz/ {
      value = $2
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      if (value != "") {
        printf "%.0f", value
        exit
      }
    }' /proc/cpuinfo)"
  fi

  if [ -z "$mhz" ]; then
    for path in /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq; do
      if [ -r "$path" ]; then
        khz="$(cat "$path" 2>/dev/null || true)"
        if [ -n "$khz" ]; then
          mhz="$(awk -v k="$khz" 'BEGIN { printf "%.0f", k / 1000 }')"
          break
        fi
      fi
    done
  fi

  if [ -n "$mhz" ]; then
    printf '%s MHz\n' "$mhz"
  else
    printf '未知\n'
  fi
}

read_cpu_stat() {
  awk '/^cpu / {
    print $2, $3, $4, $5, $6, $7, $8, $9
    exit
  }' /proc/stat
}

get_cpu_usage() {
  if [ ! -r /proc/stat ]; then
    printf '未知\n'
    return
  fi

  local user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1
  local user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2

  read -r user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 < <(read_cpu_stat)
  sleep 1
  read -r user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 < <(read_cpu_stat)

  local idle_all1=$((idle1 + iowait1))
  local idle_all2=$((idle2 + iowait2))
  local total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1 + steal1))
  local total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2))
  local total_delta=$((total2 - total1))
  local idle_delta=$((idle_all2 - idle_all1))

  awk -v total="$total_delta" -v idle="$idle_delta" 'BEGIN {
    if (total > 0) {
      printf "%.1f%%", (total - idle) * 100 / total
    } else {
      printf "未知"
    }
  }'
}

get_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{ printf "%s %s %s", $1, $2, $3 }' /proc/loadavg
  else
    printf '未知\n'
  fi
}

get_tcp_udp_connections() {
  local tcp="0"
  local udp="0"

  tcp="$(count_socket_files /proc/net/tcp /proc/net/tcp6)"
  udp="$(count_socket_files /proc/net/udp /proc/net/udp6)"

  printf 'TCP: %s | UDP: %s\n' "$tcp" "$udp"
}

count_socket_files() {
  local count=0
  local file
  local file_count

  for file in "$@"; do
    if [ -r "$file" ]; then
      file_count="$(awk 'FNR > 1 { count++ } END { print count + 0 }' "$file")"
      count=$((count + file_count))
    fi
  done

  printf '%s\n' "$count"
}

get_memory_usage() {
  if [ ! -r /proc/meminfo ]; then
    printf '未知\n'
    return
  fi

  local total_kb
  local available_kb
  local free_kb
  local used_kb
  local total_bytes
  local used_bytes

  total_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
  available_kb="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
  free_kb="$(awk '/^MemFree:/ { print $2 }' /proc/meminfo)"

  if [ -z "$available_kb" ]; then
    available_kb="$free_kb"
  fi

  if [ -z "$total_kb" ] || [ -z "$available_kb" ]; then
    printf '未知\n'
    return
  fi

  used_kb=$((total_kb - available_kb))
  total_bytes=$((total_kb * 1024))
  used_bytes=$((used_kb * 1024))

  printf '%s / %s (%s)\n' "$(format_bytes "$used_bytes")" "$(format_bytes "$total_bytes")" "$(format_percent "$used_bytes" "$total_bytes")"
}

get_swap_usage() {
  if [ ! -r /proc/meminfo ]; then
    printf '未知\n'
    return
  fi

  local total_kb
  local free_kb
  local used_kb
  local total_bytes
  local used_bytes

  total_kb="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"
  free_kb="$(awk '/^SwapFree:/ { print $2 }' /proc/meminfo)"

  if [ -z "$total_kb" ] || [ -z "$free_kb" ]; then
    printf '未知\n'
    return
  fi

  used_kb=$((total_kb - free_kb))
  total_bytes=$((total_kb * 1024))
  used_bytes=$((used_kb * 1024))

  printf '%s / %s (%s)\n' "$(format_bytes "$used_bytes")" "$(format_bytes "$total_bytes")" "$(format_percent "$used_bytes" "$total_bytes")"
}

get_disk_usage() {
  local line
  local total_kb
  local used_kb
  local percent
  local total_bytes
  local used_bytes

  line="$(df -Pk / 2>/dev/null | awk 'NR == 2 { print $2, $3, $5 }' || true)"
  if [ -z "$line" ]; then
    printf '未知\n'
    return
  fi

  read -r total_kb used_kb percent <<< "$line"

  if ! [[ "$total_kb" =~ ^[0-9]+$ && "$used_kb" =~ ^[0-9]+$ ]]; then
    printf '未知\n'
    return
  fi

  total_bytes=$((total_kb * 1024))
  used_bytes=$((used_kb * 1024))

  printf '%s / %s (%s)\n' "$(format_bytes "$used_bytes")" "$(format_bytes "$total_bytes")" "$percent"
}

get_network_totals() {
  if [ ! -r /proc/net/dev ]; then
    printf '0 0\n'
    return
  fi

  awk -F '[: ]+' '
    NR > 2 {
      iface = $2
      if (iface != "lo") {
        rx += $3
        tx += $11
      }
    }
    END {
      printf "%.0f %.0f", rx, tx
    }
  ' /proc/net/dev
}

get_network_algorithm() {
  local congestion=""
  local qdisc=""

  if [ -r /proc/sys/net/ipv4/tcp_congestion_control ]; then
    congestion="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)"
  elif command_exists sysctl; then
    congestion="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
  fi

  if [ -r /proc/sys/net/core/default_qdisc ]; then
    qdisc="$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || true)"
  elif command_exists sysctl; then
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
  fi

  if [ -n "$congestion" ] && [ -n "$qdisc" ]; then
    printf '%s / %s\n' "$congestion" "$qdisc"
  elif [ -n "$congestion" ]; then
    printf '%s\n' "$congestion"
  else
    printf '未知\n'
  fi
}

get_dns_servers() {
  if [ -r /etc/resolv.conf ]; then
    awk '
      /^nameserver[ \t]+/ {
        if (servers != "") {
          servers = servers ", " $2
        } else {
          servers = $2
        }
      }
      END {
        if (servers != "") {
          print servers
        } else {
          print "未知"
        }
      }
    ' /etc/resolv.conf
  else
    printf '未知\n'
  fi
}

get_public_ipv4_fallback() {
  local ip=""

  ip="$(http_get 'https://api.ipify.org' 2>/dev/null || true)"
  if [ -n "$ip" ]; then
    printf '%s\n' "$ip"
    return
  fi

  if command_exists ip; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) {
        if ($i == "src") {
          print $(i + 1)
          exit
        }
      }
    }' || true)"
  fi

  unknown_if_empty "$ip"
}

get_ip_geo_info() {
  local info
  local ipv4=""
  local isp=""
  local country=""
  local region=""
  local city=""

  info="$(http_get 'http://ip-api.com/line/?fields=country,regionName,city,isp,query' 2>/dev/null || true)"

  if [ -n "$info" ]; then
    country="$(printf '%s\n' "$info" | sed -n '1p')"
    region="$(printf '%s\n' "$info" | sed -n '2p')"
    city="$(printf '%s\n' "$info" | sed -n '3p')"
    isp="$(printf '%s\n' "$info" | sed -n '4p')"
    ipv4="$(printf '%s\n' "$info" | sed -n '5p')"
  fi

  if [ -z "$ipv4" ]; then
    ipv4="$(get_public_ipv4_fallback)"
  fi

  if [ -z "$isp" ]; then
    isp="未知"
  fi

  local location
  location="$(printf '%s %s %s' "$country" "$region" "$city" | awk '{$1=$1; print}')"
  if [ -z "$location" ]; then
    location="未知"
  fi

  printf '%s\n%s\n%s\n' "$isp" "$ipv4" "$location"
}

get_system_time() {
  date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '未知\n'
}

get_uptime() {
  if [ -r /proc/uptime ]; then
    awk '{
      seconds = int($1)
      days = int(seconds / 86400)
      seconds %= 86400
      hours = int(seconds / 3600)
      seconds %= 3600
      minutes = int(seconds / 60)

      if (days > 0) {
        printf "%d天 %d小时 %d分钟", days, hours, minutes
      } else if (hours > 0) {
        printf "%d小时 %d分钟", hours, minutes
      } else {
        printf "%d分钟", minutes
      }
    }' /proc/uptime
  else
    uptime -p 2>/dev/null || printf '未知\n'
  fi
}

print_separator() {
  printf '%s\n' '-------------'
}

print_header() {
  printf '%b\n' "${CYAN}--------${SCRIPT_NAME}----------${RESET}"
}

print_footer() {
  printf '%s\n' '-------------------------------------'
}

print_line() {
  local label="$1"
  local value="$2"
  printf '%-18s %s\n' "${label}:" "$value"
}

show_system_info() {
  local net_totals
  local rx_bytes
  local tx_bytes
  local geo_info
  local isp
  local ipv4
  local location

  net_totals="$(get_network_totals)"
  read -r rx_bytes tx_bytes <<< "$net_totals"

  geo_info="$(get_ip_geo_info)"
  isp="$(printf '%s\n' "$geo_info" | sed -n '1p')"
  ipv4="$(printf '%s\n' "$geo_info" | sed -n '2p')"
  location="$(printf '%s\n' "$geo_info" | sed -n '3p')"

  clear_screen
  print_header
  print_line '主机名' "$(get_hostname)"
  print_line '系统版本' "$(get_os_version)"
  print_line 'Linux版本' "$(get_linux_version)"
  print_separator
  print_line 'CPU架构' "$(get_cpu_arch)"
  print_line 'CPU型号' "$(unknown_if_empty "$(get_cpu_model)")"
  print_line 'CPU核心数' "$(get_cpu_cores)"
  print_line 'CPU频率' "$(get_cpu_freq)"
  print_separator
  print_line 'CPU占用' "$(get_cpu_usage)"
  print_line '系统负载' "$(get_load_average)"
  print_line 'TCP|UDP连接数' "$(get_tcp_udp_connections)"
  print_line '物理内存' "$(get_memory_usage)"
  print_line '虚拟内存' "$(get_swap_usage)"
  print_line '硬盘占用' "$(get_disk_usage)"
  print_separator
  print_line '总接收' "$(format_bytes "$rx_bytes")"
  print_line '总发送' "$(format_bytes "$tx_bytes")"
  print_separator
  print_line '网络算法' "$(get_network_algorithm)"
  print_separator
  print_line '运营商' "$(unknown_if_empty "$isp")"
  print_line 'IPv4地址' "$(unknown_if_empty "$ipv4")"
  print_line 'DNS地址' "$(get_dns_servers)"
  print_line '地理位置' "$(unknown_if_empty "$location")"
  print_line '系统时间' "$(get_system_time)"
  print_separator
  print_line '运行时长' "$(get_uptime)"
  print_footer
  pause
}

clear_screen() {
  if [ -t 1 ] && command_exists clear; then
    clear
  fi
}

pause() {
  if [ -t 0 ]; then
    printf '\n'
    read -r -p '按回车键返回菜单...' _
  fi
}

placeholder() {
  local title="$1"

  clear_screen
  print_header
  printf '%b\n' "${YELLOW}${title} 功能暂未开放。${RESET}"
  print_footer
  pause
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    printf '%b\n' "${RED}此功能需要 root 权限，请使用 root 用户执行脚本。${RESET}"
    return 1
  fi
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif "$@" 2>/dev/null; then
    return 0
  elif command_exists sudo; then
    sudo "$@"
  else
    printf '%b\n' "${RED}此操作需要 root 权限，请使用 root 用户执行或安装 sudo。${RESET}"
    return 1
  fi
}

is_number() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

valid_port() {
  local port="${1:-}"

  is_number "$port" && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

backup_file() {
  local file="$1"
  local backup=""

  if [ -e "$file" ]; then
    backup="${file}.bak.$(date '+%Y%m%d%H%M%S')"
    cp -a "$file" "$backup"
  fi

  printf '%s\n' "$backup"
}

confirm_action() {
  local message="$1"
  local answer=""

  if [ ! -t 0 ]; then
    return 1
  fi

  read -r -p "${message} [y/N]: " answer
  case "$answer" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

find_sshd_config() {
  if [ -f /etc/ssh/sshd_config ]; then
    printf '%s\n' '/etc/ssh/sshd_config'
  else
    printf '%s\n' ''
  fi
}

find_sshd_bin() {
  local bin

  for bin in /usr/sbin/sshd /usr/local/sbin/sshd sshd; do
    if command_exists "$bin" || [ -x "$bin" ]; then
      printf '%s\n' "$bin"
      return
    fi
  done

  printf '%s\n' ''
}

get_ssh_option() {
  local key="$1"
  local file="$2"

  awk -v key="$key" '
    $1 !~ /^#/ && $1 == key {
      print $2
      exit
    }
  ' "$file" 2>/dev/null
}

set_ssh_option() {
  local key="$1"
  local value="$2"
  local file="$3"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]+" {
      if (!done) {
        print key " " value
        done = 1
      }
      next
    }
    { print }
    END {
      if (!done) {
        print key " " value
      }
    }
  ' "$file" > "$tmp_file"
  cat "$tmp_file" > "$file"
  rm -f "$tmp_file"
}

test_sshd_config() {
  local file="$1"
  local sshd_bin

  sshd_bin="$(find_sshd_bin)"
  if [ -n "$sshd_bin" ]; then
    "$sshd_bin" -t -f "$file"
  else
    return 0
  fi
}

restart_service_by_names() {
  local service_name

  for service_name in "$@"; do
    if command_exists systemctl && systemctl restart "$service_name" >/dev/null 2>&1; then
      return 0
    fi

    if command_exists rc-service && rc-service "$service_name" restart >/dev/null 2>&1; then
      return 0
    fi

    if command_exists service && service "$service_name" restart >/dev/null 2>&1; then
      return 0
    fi

    if [ -x "/etc/init.d/${service_name}" ] && "/etc/init.d/${service_name}" restart >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

restart_ssh_service() {
  restart_service_by_names sshd ssh
}

modify_ssh_port() {
  local config_file
  local current_port
  local new_port
  local backup

  clear_screen
  print_header

  if ! require_root; then
    pause
    return
  fi

  config_file="$(find_sshd_config)"
  if [ -z "$config_file" ]; then
    printf '%b\n' "${RED}未找到 /etc/ssh/sshd_config。${RESET}"
    pause
    return
  fi

  current_port="$(get_ssh_option Port "$config_file")"
  current_port="${current_port:-22}"
  printf '当前 SSH 端口: %s\n' "$current_port"

  read -r -p '请输入新的 SSH 端口(1-65535): ' new_port
  if ! valid_port "$new_port"; then
    printf '%b\n' "${RED}端口无效。${RESET}"
    pause
    return
  fi

  if ! confirm_action "确认将 SSH 端口修改为 ${new_port} 吗"; then
    printf '%b\n' "${YELLOW}已取消。${RESET}"
    pause
    return
  fi

  backup="$(backup_file "$config_file")"
  set_ssh_option Port "$new_port" "$config_file"

  if ! test_sshd_config "$config_file"; then
    [ -n "$backup" ] && cp -a "$backup" "$config_file"
    printf '%b\n' "${RED}SSH 配置检查失败，已恢复备份。${RESET}"
    pause
    return
  fi

  open_firewall_port "$new_port" tcp silent || true

  if restart_ssh_service; then
    printf '%b\n' "${GREEN}SSH 端口已修改为 ${new_port}，请确认新端口可连接后再关闭当前 SSH 会话。${RESET}"
  else
    printf '%b\n' "${YELLOW}配置已写入，但 SSH 服务重启失败，请手动检查服务状态。${RESET}"
  fi

  [ -n "$backup" ] && printf '配置备份: %s\n' "$backup"
  print_footer
  pause
}

set_gai_priority() {
  local mode="$1"
  local file="/etc/gai.conf"
  local tmp_file
  local backup

  if ! require_root; then
    return 1
  fi

  [ -f "$file" ] || touch "$file"
  backup="$(backup_file "$file")"
  tmp_file="$(mktemp)"

  awk '
    /^[[:space:]]*# VPS script network priority/ { next }
    /^[[:space:]]*#?[[:space:]]*precedence[[:space:]]+::ffff:0:0\/96[[:space:]]+/ { next }
    /^[[:space:]]*#?[[:space:]]*precedence[[:space:]]+::\/0[[:space:]]+/ { next }
    { print }
  ' "$file" > "$tmp_file"

  cat "$tmp_file" > "$file"
  rm -f "$tmp_file"

  {
    if [ "$mode" = "ipv4" ]; then
      printf '\n'
      printf '# VPS script network priority\n'
      printf 'precedence ::ffff:0:0/96  100\n'
    elif [ "$mode" = "ipv6" ]; then
      printf '\n'
      printf '# VPS script network priority\n'
      printf 'precedence ::/0  100\n'
      printf 'precedence ::ffff:0:0/96  10\n'
    fi
  } >> "$file"

  if [ "$mode" = "ipv4" ]; then
    printf '%b\n' "${GREEN}已设置为优先 IPv4。${RESET}"
  elif [ "$mode" = "ipv6" ]; then
    printf '%b\n' "${GREEN}已设置为优先 IPv6。${RESET}"
  else
    printf '%b\n' "${GREEN}已恢复为系统默认 IPv4/IPv6 优先级配置。${RESET}"
  fi

  [ -n "$backup" ] && printf '配置备份: %s\n' "$backup"
}

get_current_ip_priority() {
  local file="/etc/gai.conf"

  if [ ! -r "$file" ]; then
    printf '%s\n' '默认配置'
    return
  fi

  awk '
    /^[[:space:]]*#/ { next }
    $1 == "precedence" && $2 == "::ffff:0:0/96" {
      ipv4 = $3 + 0
      seen4 = 1
    }
    $1 == "precedence" && $2 == "::/0" {
      ipv6 = $3 + 0
      seen6 = 1
    }
    END {
      if (seen4 && (!seen6 || ipv4 > ipv6)) {
        print "优先 IPv4"
      } else if (seen6 && (!seen4 || ipv6 > ipv4)) {
        print "优先 IPv6"
      } else {
        print "默认配置"
      }
    }
  ' "$file"
}

has_ipv4() {
  if command_exists ip && ip -4 addr show scope global 2>/dev/null | awk '/inet / { found = 1 } END { exit found ? 0 : 1 }'; then
    return 0
  fi

  if command_exists ifconfig && ifconfig 2>/dev/null | awk '/inet / && $2 !~ /^127\./ { found = 1 } END { exit found ? 0 : 1 }'; then
    return 0
  fi

  return 1
}

has_ipv6() {
  if command_exists ip && ip -6 addr show scope global 2>/dev/null | awk '/inet6 / { found = 1 } END { exit found ? 0 : 1 }'; then
    return 0
  fi

  if [ -r /proc/net/if_inet6 ] && awk '$4 == "00" { found = 1 } END { exit found ? 0 : 1 }' /proc/net/if_inet6; then
    return 0
  fi

  return 1
}

print_ip_stack_status() {
  if has_ipv4; then
    printf '%b\n' "${GREEN}IPv4状态: 已检测到${RESET}"
  else
    printf '%b\n' "${RED}IPv4状态: 未检测到${RESET}"
  fi

  if has_ipv6; then
    printf '%b\n' "${GREEN}IPv6状态: 已检测到${RESET}"
  else
    printf '%b\n' "${RED}IPv6状态: 未检测到${RESET}"
  fi
}

switch_ip_priority() {
  local choice=""

  clear_screen
  print_header
  printf '当前优先: %s\n' "$(get_current_ip_priority)"
  print_ip_stack_status
  print_separator
  printf '%s\n' '1. 优先 IPv4'
  printf '%s\n' '2. 优先 IPv6'
  printf '%s\n' '3. 默认配置'
  printf '%s\n' '0. 返回'
  printf '%s\n' '00. 退出脚本'
  print_footer

  read -r -p '请输入选项: ' choice
  case "$choice" in
    1)
      if ! has_ipv4; then
        printf '%b\n' "${RED}未检测到可用 IPv4 地址，无法切换为优先 IPv4。${RESET}"
        pause
        return
      fi
      set_gai_priority ipv4
      ;;
    2)
      if ! has_ipv6; then
        printf '%b\n' "${RED}未检测到可用 IPv6 地址，无法切换为优先 IPv6。${RESET}"
        pause
        return
      fi
      set_gai_priority ipv6
      ;;
    3)
      set_gai_priority default
      ;;
    0)
      return 0
      ;;
    00)
      printf '%b\n' "${GREEN}已退出。${RESET}"
      exit 0
      ;;
    *)
      printf '%b\n' "${RED}无效选项。${RESET}"
      ;;
  esac

  pause
}

show_ssh_login_status() {
  local config_file
  local pubkey
  local password

  config_file="$(find_sshd_config)"
  if [ -z "$config_file" ]; then
    printf '%b\n' "${RED}未找到 /etc/ssh/sshd_config。${RESET}"
    return
  fi

  pubkey="$(get_ssh_option PubkeyAuthentication "$config_file")"
  password="$(get_ssh_option PasswordAuthentication "$config_file")"

  printf 'PubkeyAuthentication: %s\n' "${pubkey:-默认}"
  printf 'PasswordAuthentication: %s\n' "${password:-默认}"
}

set_ssh_login_mode() {
  local mode="$1"
  local config_file
  local backup

  if ! require_root; then
    pause
    return
  fi

  config_file="$(find_sshd_config)"
  if [ -z "$config_file" ]; then
    printf '%b\n' "${RED}未找到 /etc/ssh/sshd_config。${RESET}"
    pause
    return
  fi

  if [ "$mode" = "key" ]; then
    printf '%b\n' "${YELLOW}开启密钥登录并关闭密码登录前，请确认当前用户已配置可用公钥。${RESET}\n"
    if ! confirm_action '确认继续'; then
      printf '%b\n' "${YELLOW}已取消。${RESET}"
      pause
      return
    fi
  fi

  backup="$(backup_file "$config_file")"

  if [ "$mode" = "key" ]; then
    set_ssh_option PubkeyAuthentication yes "$config_file"
    set_ssh_option PasswordAuthentication no "$config_file"
    set_ssh_option KbdInteractiveAuthentication no "$config_file"
    set_ssh_option ChallengeResponseAuthentication no "$config_file"
  else
    set_ssh_option PubkeyAuthentication yes "$config_file"
    set_ssh_option PasswordAuthentication yes "$config_file"
    set_ssh_option KbdInteractiveAuthentication yes "$config_file"
    set_ssh_option ChallengeResponseAuthentication yes "$config_file"
  fi

  if ! test_sshd_config "$config_file"; then
    [ -n "$backup" ] && cp -a "$backup" "$config_file"
    printf '%b\n' "${RED}SSH 配置检查失败，已恢复备份。${RESET}"
    pause
    return
  fi

  if restart_ssh_service; then
    printf '%b\n' "${GREEN}SSH 登录模式已更新。${RESET}"
  else
    printf '%b\n' "${YELLOW}配置已写入，但 SSH 服务重启失败，请手动检查服务状态。${RESET}"
  fi

  [ -n "$backup" ] && printf '配置备份: %s\n' "$backup"
  pause
}

ssh_key_login_menu() {
  local choice=""

  while true; do
    clear_screen
    print_header
    show_ssh_login_status
    print_separator
    printf '%s\n' '1. 开启密钥登录并关闭密码登录'
    printf '%s\n' '2. 开启密码登录'
    printf '%s\n' '0. 返回'
    printf '%s\n' '00. 退出脚本'
    print_footer

    read -r -p '请输入选项: ' choice
    case "$choice" in
      1)
        set_ssh_login_mode key
        ;;
      2)
        set_ssh_login_mode password
        ;;
      0|r|R)
        return 0
        ;;
      00)
        printf '%b\n' "${GREEN}已退出。${RESET}"
        exit 0
        ;;
      *)
        printf '%b\n' "${RED}无效选项。${RESET}"
        sleep 1
        ;;
    esac
  done
}

detect_firewall_backend() {
  if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    printf '%s\n' 'firewalld'
  elif command_exists ufw; then
    printf '%s\n' 'ufw'
  elif command_exists iptables; then
    printf '%s\n' 'iptables'
  else
    printf '%s\n' 'none'
  fi
}

persist_iptables_rules() {
  if command_exists netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1 && return 0
  fi

  if command_exists rc-service && rc-service iptables save >/dev/null 2>&1; then
    return 0
  fi

  if command_exists service && service iptables save >/dev/null 2>&1; then
    return 0
  fi

  if command_exists iptables-save && [ -d /etc/iptables ]; then
    iptables-save > /etc/iptables/rules.v4
    if command_exists ip6tables-save; then
      ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
    return 0
  fi

  return 1
}

iptables_port_rule() {
  local action="$1"
  local port="$2"
  local proto="$3"
  local cmd

  for cmd in iptables ip6tables; do
    if ! command_exists "$cmd"; then
      continue
    fi

    if [ "$action" = "open" ]; then
      "$cmd" -C INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1 || \
        "$cmd" -I INPUT -p "$proto" --dport "$port" -j ACCEPT
    else
      while "$cmd" -D INPUT -p "$proto" --dport "$port" -j ACCEPT >/dev/null 2>&1; do
        :
      done
    fi
  done
}

firewall_apply_port() {
  local action="$1"
  local port="$2"
  local proto="$3"
  local backend
  local result=0

  if [ "$proto" = "all" ]; then
    firewall_apply_port "$action" "$port" tcp || result=1
    firewall_apply_port "$action" "$port" udp || result=1
    return "$result"
  fi

  backend="$(detect_firewall_backend)"
  case "$backend" in
    firewalld)
      if [ "$action" = "open" ]; then
        firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null
      else
        firewall-cmd --permanent --remove-port="${port}/${proto}" >/dev/null
      fi
      firewall-cmd --reload >/dev/null
      ;;
    ufw)
      if [ "$action" = "open" ]; then
        ufw --force allow "${port}/${proto}"
      else
        ufw --force delete allow "${port}/${proto}"
      fi
      ;;
    iptables)
      iptables_port_rule "$action" "$port" "$proto"
      persist_iptables_rules || printf '%b\n' "${YELLOW}iptables 规则已写入运行时，重启后是否保留取决于系统防火墙服务。${RESET}"
      ;;
    *)
      printf '%b\n' "${RED}未检测到 firewalld、ufw 或 iptables。${RESET}"
      return 1
      ;;
  esac
}

normalize_protocol() {
  local proto="${1:-tcp}"

  case "$proto" in
    tcp|TCP)
      printf '%s\n' 'tcp'
      ;;
    udp|UDP)
      printf '%s\n' 'udp'
      ;;
    all|ALL|'')
      printf '%s\n' 'all'
      ;;
    *)
      printf '%s\n' ''
      ;;
  esac
}

open_firewall_port() {
  local port="$1"
  local proto="${2:-tcp}"
  local quiet="${3:-}"

  if ! valid_port "$port"; then
    [ "$quiet" = "silent" ] || printf '%b\n' "${RED}端口无效。${RESET}"
    return 1
  fi

  proto="$(normalize_protocol "$proto")"
  if [ -z "$proto" ]; then
    [ "$quiet" = "silent" ] || printf '%b\n' "${RED}协议无效。${RESET}"
    return 1
  fi

  firewall_apply_port open "$port" "$proto"
}

manage_firewall_port() {
  local action="$1"
  local port=""
  local proto=""

  if ! require_root; then
    pause
    return
  fi

  read -r -p '请输入端口号: ' port
  if ! valid_port "$port"; then
    printf '%b\n' "${RED}端口无效。${RESET}"
    pause
    return
  fi

  read -r -p '请输入协议(tcp/udp/all，默认 all): ' proto
  proto="$(normalize_protocol "$proto")"
  if [ -z "$proto" ]; then
    printf '%b\n' "${RED}协议无效。${RESET}"
    pause
    return
  fi

  if firewall_apply_port "$action" "$port" "$proto"; then
    if [ "$action" = "open" ]; then
      printf '%b\n' "${GREEN}端口已开放: ${port}/${proto}${RESET}"
    else
      printf '%b\n' "${GREEN}端口规则已移除: ${port}/${proto}${RESET}"
    fi
  fi

  pause
}

show_firewall_rules() {
  local backend

  clear_screen
  print_header
  backend="$(detect_firewall_backend)"
  printf '当前防火墙后端: %s\n' "$backend"
  print_separator

  case "$backend" in
    firewalld)
      firewall-cmd --list-ports
      ;;
    ufw)
      ufw status numbered
      ;;
    iptables)
      iptables -S INPUT 2>/dev/null | awk '/--dport/ { print }'
      if command_exists ip6tables; then
        ip6tables -S INPUT 2>/dev/null | awk '/--dport/ { print }'
      fi
      ;;
    *)
      printf '%s\n' '未检测到可管理的防火墙工具。'
      ;;
  esac

  print_footer
  pause
}

port_management_menu() {
  local choice=""

  while true; do
    clear_screen
    print_header
    printf '%s\n' '1. 开放端口'
    printf '%s\n' '2. 关闭端口'
    printf '%s\n' '3. 查看端口规则'
    printf '%s\n' '0. 返回'
    printf '%s\n' '00. 退出脚本'
    print_footer

    read -r -p '请输入选项: ' choice
    case "$choice" in
      1)
        manage_firewall_port open
        ;;
      2)
        manage_firewall_port close
        ;;
      3)
        show_firewall_rules
        ;;
      0|r|R)
        return 0
        ;;
      00)
        printf '%b\n' "${GREEN}已退出。${RESET}"
        exit 0
        ;;
      *)
        printf '%b\n' "${RED}无效选项。${RESET}"
        sleep 1
        ;;
    esac
  done
}

swapfile_active() {
  awk '$1 == "/swapfile" { found = 1 } END { exit found ? 0 : 1 }' /proc/swaps 2>/dev/null
}

remove_swapfile_from_fstab() {
  local file="/etc/fstab"
  local tmp_file

  [ -f "$file" ] || touch "$file"
  tmp_file="$(mktemp)"
  awk '$1 != "/swapfile" { print }' "$file" > "$tmp_file"
  cat "$tmp_file" > "$file"
  rm -f "$tmp_file"
}

show_swap_status() {
  if [ -r /proc/swaps ]; then
    cat /proc/swaps
  else
    printf '%s\n' '无法读取 /proc/swaps'
  fi
}

modify_swap_size() {
  local size_gb=""
  local count_mb
  local backup

  clear_screen
  print_header
  show_swap_status
  print_separator

  if ! require_root; then
    pause
    return
  fi

  read -r -p '请输入新的虚拟内存大小(GB，输入 0 删除 /swapfile): ' size_gb
  if ! is_number "$size_gb"; then
    printf '%b\n' "${RED}请输入数字。${RESET}"
    pause
    return
  fi

  backup="$(backup_file /etc/fstab)"

  if swapfile_active; then
    if ! swapoff /swapfile; then
      printf '%b\n' "${RED}关闭现有 /swapfile 失败，请检查是否被占用。${RESET}"
      pause
      return
    fi
  fi

  remove_swapfile_from_fstab
  rm -f /swapfile

  if [ "$size_gb" -eq 0 ]; then
    printf '%b\n' "${GREEN}已删除 /swapfile 虚拟内存配置。${RESET}"
    [ -n "$backup" ] && printf 'fstab 备份: %s\n' "$backup"
    pause
    return
  fi

  count_mb=$((size_gb * 1024))
  printf '正在创建 %sGB swapfile...\n' "$size_gb"

  if ! {
    if command_exists fallocate; then
      fallocate -l "${size_gb}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$count_mb"
    else
      dd if=/dev/zero of=/swapfile bs=1M count="$count_mb"
    fi
  }; then
    rm -f /swapfile
    printf '%b\n' "${RED}创建 swapfile 失败，请检查磁盘空间。${RESET}"
    pause
    return
  fi

  chmod 600 /swapfile
  if ! mkswap /swapfile >/dev/null; then
    rm -f /swapfile
    printf '%b\n' "${RED}格式化 swapfile 失败。${RESET}"
    pause
    return
  fi

  if ! swapon /swapfile; then
    rm -f /swapfile
    printf '%b\n' "${RED}启用 swapfile 失败。${RESET}"
    pause
    return
  fi

  printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab

  printf '%b\n' "${GREEN}虚拟内存已设置为 ${size_gb}GB。${RESET}"
  [ -n "$backup" ] && printf 'fstab 备份: %s\n' "$backup"
  pause
}

sysctl_get() {
  sysctl -n "$1" 2>/dev/null || true
}

sysctl_key_exists() {
  [ -n "$(sysctl_get "$1")" ]
}

choose_bbr_algorithm() {
  local available

  available="$(sysctl_get net.ipv4.tcp_available_congestion_control)"
  if ! printf ' %s ' "$available" | grep -q ' bbr'; then
    command_exists modprobe && modprobe tcp_bbr >/dev/null 2>&1 || true
    available="$(sysctl_get net.ipv4.tcp_available_congestion_control)"
  fi

  if printf ' %s ' "$available" | grep -q ' bbr3 '; then
    printf '%s\n' 'bbr3'
  elif printf ' %s ' "$available" | grep -q ' bbr '; then
    printf '%s\n' 'bbr'
  else
    printf '%s\n' ''
  fi
}

enable_bbr3() {
  local algorithm
  local config_file="/etc/sysctl.d/99-vps-bbr.conf"
  local backup=""

  clear_screen
  print_header

  if ! require_root; then
    pause
    return
  fi

  algorithm="$(choose_bbr_algorithm)"
  if [ -z "$algorithm" ]; then
    printf '%b\n' "${RED}当前内核未检测到 bbr/bbr3 拥塞控制算法，无法直接启用。${RESET}"
    printf '%s\n' '请先更换支持 BBR3 或 BBR 的内核后再执行。'
    pause
    return
  fi

  mkdir -p /etc/sysctl.d
  backup="$(backup_file "$config_file")"

  {
    printf '# VPS script BBR acceleration\n'
    if sysctl_key_exists net.core.default_qdisc; then
      printf 'net.core.default_qdisc = fq\n'
    fi
    printf 'net.ipv4.tcp_congestion_control = %s\n' "$algorithm"
  } > "$config_file"

  if ! sysctl -p "$config_file"; then
    if [ -n "$backup" ]; then
      cp -a "$backup" "$config_file"
    else
      rm -f "$config_file"
    fi
    printf '%b\n' "${RED}sysctl 配置应用失败，已恢复备份。${RESET}"
    pause
    return
  fi

  printf '%b\n' "${GREEN}已启用 ${algorithm} 加速。${RESET}"
  printf '当前拥塞控制: %s\n' "$(sysctl_get net.ipv4.tcp_congestion_control)"
  printf '当前队列算法: %s\n' "$(sysctl_get net.core.default_qdisc)"
  if [ "$algorithm" = "bbr" ]; then
    printf '%b\n' "${YELLOW}提示: 当前内核暴露的算法名为 bbr；如果内核实现是 BBR3，会通过该算法名生效。${RESET}"
  fi
  [ -n "$backup" ] && printf '配置备份: %s\n' "$backup"
  print_footer
  pause
}

system_tools_menu() {
  local choice=""

  while true; do
    clear_screen
    printf '%b\n' "${CYAN}--------系统工具 | 输入 r 返回主菜单----------${RESET}"
    printf '%s\n' '1. 修改SSH连接端口'
    printf '%s\n' '2. 切换优先IPv4/IPv6'
    printf '%s\n' '3. 用户密钥登录模式'
    printf '%s\n' '4. 开放端口管理'
    printf '%s\n' '5. 修改虚拟内存大小'
    printf '%s\n' '6. 设置BBR3加速'
    printf '%s\n' '0. 返回'
    printf '%s\n' '00. 退出脚本'
    print_footer

    if [ -t 0 ]; then
      read -r -p '请输入选项: ' choice
    else
      return 0
    fi

    case "$choice" in
      1)
        modify_ssh_port
        ;;
      2)
        switch_ip_priority
        ;;
      3)
        ssh_key_login_menu
        ;;
      4)
        port_management_menu
        ;;
      5)
        modify_swap_size
        ;;
      6)
        enable_bbr3
        ;;
      0|r|R)
        return 0
        ;;
      00)
        printf '%b\n' "${GREEN}已退出。${RESET}"
        exit 0
        ;;
      *)
        printf '%b\n' "${RED}无效选项，请重新输入。${RESET}"
        sleep 1
        ;;
    esac
  done
}

update_script() {
  local tmp_file

  clear_screen
  print_header

  if ! command_exists curl; then
    printf '%b\n' "${RED}未找到 curl，无法拉取最新脚本。${RESET}"
    printf '%s\n' 'Debian/Ubuntu: apt update && apt install -y curl'
    printf '%s\n' 'Alpine: apk add --no-cache curl'
    pause
    return
  fi

  printf '%b\n' "${YELLOW}正在从 GitHub 下载最新脚本...${RESET}"
  printf '来源: %s\n' "$SOURCE_URL"

  tmp_file="$(mktemp)"
  if ! download_file "$SOURCE_URL" "$tmp_file"; then
    rm -f "$tmp_file"
    printf '%b\n' "${RED}下载失败，请检查网络或 GitHub 地址。${RESET}"
    pause
    return
  fi

  if ! bash -n "$tmp_file"; then
    rm -f "$tmp_file"
    printf '%b\n' "${RED}最新脚本语法检查失败，已停止更新。${RESET}"
    pause
    return
  fi

  if ! run_as_root mkdir -p "$(dirname "$INSTALL_PATH")"; then
    rm -f "$tmp_file"
    pause
    return
  fi

  if ! run_as_root cp "$tmp_file" "$INSTALL_PATH"; then
    rm -f "$tmp_file"
    printf '%b\n' "${RED}写入 ${INSTALL_PATH} 失败。${RESET}"
    pause
    return
  fi

  rm -f "$tmp_file"

  if ! run_as_root chmod 0755 "$INSTALL_PATH"; then
    printf '%b\n' "${RED}设置执行权限失败。${RESET}"
    pause
    return
  fi

  if run_as_root ln -sf "$INSTALL_PATH" "$SHORTCUT_PATH"; then
    printf '%b\n' "${GREEN}更新完成。输入 vps 或 r 可打开脚本。${RESET}"
  else
    printf '%b\n' "${YELLOW}脚本已更新，但快捷命令 r 创建失败。${RESET}"
  fi

  print_footer
  printf '%b\n' "${GREEN}正在启动最新脚本...${RESET}"
  exec bash "$INSTALL_PATH"
}

show_menu() {
  clear_screen
  printf '%b\n' "${CYAN}--------${SCRIPT_NAME} | 输入 r 一键打开脚本----------${RESET}"
  printf '%s\n' '1. 系统信息查询'
  printf '%s\n' '2. 节点管理'
  printf '%s\n' '3. Docker管理'
  printf '%s\n' '4. 系统工具'
  printf '%s\n' '5. 一键更新'
  printf '%s\n' '0. 退出'
  print_footer
}

main() {
  local choice=""

  while true; do
    show_menu
    if [ -t 0 ]; then
      read -r -p '请输入选项: ' choice
    else
      choice="${1:-1}"
    fi

    case "$choice" in
      1)
        show_system_info
        ;;
      2)
        placeholder '节点管理'
        ;;
      3)
        placeholder 'Docker管理'
        ;;
      4)
        system_tools_menu
        ;;
      5|u|U|update)
        update_script
        ;;
      r|R)
        ;;
      0|q|Q|exit|quit)
        printf '%b\n' "${GREEN}已退出。${RESET}"
        exit 0
        ;;
      *)
        printf '%b\n' "${RED}无效选项，请重新输入。${RESET}"
        sleep 1
        ;;
    esac

    if [ ! -t 0 ]; then
      break
    fi
  done
}

main "$@"
