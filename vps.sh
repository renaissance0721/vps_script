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
  elif command_exists wget; then
    wget -qO "$output" "$url"
  else
    printf '%b\n' "${RED}未找到 curl 或 wget，无法下载脚本。${RESET}" >&2
    return 1
  fi
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    printf '%b\n' "${RED}需要 root 权限，请使用 root 用户执行或安装 sudo。${RESET}" >&2
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

update_script() {
  local tmp_file

  clear_screen
  print_header
  printf '%b\n' "${YELLOW}正在从 GitHub 拉取最新脚本...${RESET}"

  tmp_file="$(mktemp)"

  if ! download_file "$SOURCE_URL" "$tmp_file"; then
    rm -f "$tmp_file"
    printf '%b\n' "${RED}下载失败，请检查网络或稍后重试。${RESET}"
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
    printf '%b\n' "${GREEN}更新完成。输入 vps 或 r 可打开菜单。${RESET}"
  else
    printf '%b\n' "${YELLOW}脚本已更新，但快捷命令 r 创建失败。${RESET}"
  fi

  print_footer
  pause
}

show_menu() {
  clear_screen
  print_header
  printf '%s\n' '1. 系统信息查询'
  printf '%s\n' '2. 节点管理'
  printf '%s\n' '3. Docker管理'
  printf '%s\n' '4. 系统工具'
  printf '%s\n' '5. 一键更新'
  printf '%s\n' 'r. 打开菜单'
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
        placeholder '系统工具'
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
