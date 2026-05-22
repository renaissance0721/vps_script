# VPS 一键管理脚本

适配 Alpine、Debian、Ubuntu 等主流 Linux 发行版。当前已完成「系统信息查询」，「节点管理」「Docker管理」「系统工具」先保留菜单入口。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/renaissance0721/vps_script/main/install.sh | bash
```

这条命令会从 GitHub 拉取最新脚本并安装到 `/usr/local/bin/vps`，同时创建快捷命令 `r`。

如果系统没有 `curl`，可以使用：

```bash
wget -qO- https://raw.githubusercontent.com/renaissance0721/vps_script/main/install.sh | bash
```

Alpine 最小系统如果没有 `bash`，先执行：

```bash
apk add --no-cache bash curl
```

## 使用

```bash
vps
```

或直接输入：

```bash
r
```

脚本菜单内也可以选择 `5. 一键更新`，从 GitHub 拉取最新版本。

也可以不安装，直接运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/renaissance0721/vps_script/main/vps.sh)
```

## 已实现功能

- 主机名、系统版本、Linux 内核版本
- CPU 架构、型号、核心数、频率、占用
- 系统负载、TCP/UDP 连接数
- 物理内存、虚拟内存、硬盘占用
- 网卡累计接收/发送流量
- TCP 拥塞控制算法和默认队列算法
- 运营商、公网 IPv4、DNS、地理位置
- 系统时间、运行时长
- 系统工具：修改 SSH 端口、切换 IPv4/IPv6 优先级、SSH 密钥登录模式、端口管理、虚拟内存大小、BBR3/BBR 加速
