# 自用代理脚本合集 (OpenClash 优化版)

---

## 🚀 一键聚合脚本 (推荐)

> 统一入口，管理所有代理服务。支持实时状态检测、一键查看配置、自动更新。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/onekey.sh)
```

安装后使用快捷命令 `x` 即可呼出管理面板。

---

## 📊 协议横向对比表

> 无法决定使用哪个？参考下表选择最适合您网络环境的协议。

| 协议 | 核心机制 | 传输层 | 抗封锁能力 | 推荐场景 |
| :--- | :--- | :--- | :--- | :--- |
| **VLESS (Reality)** | TLS 偷取/伪装 | TCP/XTLS | ⭐⭐⭐⭐⭐ | **首选主力**，长期稳定，通用性极佳 |
| **Hysteria 2** | UDP 拥塞控制 | UDP | ⭐⭐⭐ | **垃圾线路提速**，4K/8K 视频，晚高峰 |
| **Tuic v5** | QUIC 0-RTT | UDP (QUIC) | ⭐⭐⭐ | **游戏/低延迟**，移动网络优选 |
| **AnyTLS** | 全拟态 HTTPS | TCP | ⭐⭐⭐⭐⭐ | **极高封锁区**，IP被重点关照时救急 |
| **Sudoku** | ASCII 隐写术 | TCP | ⭐⭐⭐⭐⭐ | **对抗 DPI/白名单**，特殊防火墙环境 |
| **Mieru** | 强混淆/抗重放 | TCP/UDP | ⭐⭐⭐⭐ | **非常规端口**，对抗主动探测 |
| **SS-2022** | Rust/AEAD | TCP/UDP | ⭐⭐ | **中转/内网**，低性能路由，资源敏感 |

---

## 1️⃣ AnyTLS (隐匿传输) 🛡️
> 基于 `anytls-go` 核心，主打极致隐匿。通过模拟正常的 HTTPS 流量来绕过防火墙检测，适合高封锁环境。

* **管理命令**: `anytls`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/anytls.sh)
```

---

## 2️⃣ Tuic v5 (QUIC 高速协议) ⚡

> 基于 QUIC 协议构建的高性能代理。支持 0-RTT 连接，在拥塞网络环境中表现优异，延迟更低。

* **管理命令**: `tuic`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/tuic.sh)
```

---

## 3️⃣ Shadowsocks 2022 (Rust 极致性能) 🦀

> 使用 Rust 语言编写的最新版 Shadowsocks。支持最新的 AEAD-2022 加密规范，拥有极低的资源占用和超高的稳定性。

* **管理命令**: `ss`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/ss2022.sh)
```

---

## 4️⃣ Hysteria 2 (暴力加速) 🌊

> 下一代 Hysteria 协议。在弱网环境下拥有强悍的抢占能力，能够有效提升网络吞吐量，同时提供伪装功能。

* **管理命令**: `hy`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/hy2.sh)
```

---

## 5️⃣ Mieru (新型代理协议) 📡

> Mieru 是一种新型代理协议，专注于流量混淆和抗检测。支持 TCP/UDP 双栈传输，端口范围监听。

* **管理命令**: `mieru`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/mieru.sh)
```

---

## 6️⃣ VLESS (全能协议) 🌌

> 基于 Xray-core 的 VLESS 协议。支持 REALITY、TCP-Vision、XHTTP 等多种流控模式，兼容性极佳，支持各大客户端。

* **管理命令**: `vless`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/vless.sh)
```

---

## 7️⃣ Sudoku (数独隐写) 🧩

> 基于数独隐写的流量混淆代理协议。使用 ChaCha20-Poly1305 加密，支持 HTTP 伪装，流量表现为低熵 ASCII 字符，有效规避 DPI 检测。

* **管理命令**: `sudoku`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/sudoku.sh)
```

---

## 8️⃣ Auto DNS Monitor (智能 DNS 优选) 🔄

> 这是一个"部署即忘"的自动化运维工具。脚本每分钟监控 Google 连通性，当延迟过高时自动寻找并切换最快 DNS。

* **配置文件**: `/etc/autodns/config.env`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/dns_monitor_install.sh)
```

---

## 9️⃣ Systemd DNS Fixer (DNS 永久修复) 🚑

> 专治 Debian/Ubuntu 系统重启后 `/etc/resolv.conf` 被重置、文件丢失或出现 "No such file" 错误的疑难杂症。

* **管理命令**: `fixdns`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/setup_dns.sh)
```

---

## 🔟 IPF (Iptables 端口转发) 🔀

> 极简端口转发工具。基于原生 `iptables` 内核级转发，资源占用几乎为 0。

* **管理命令**: `ipf`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/ipf.sh)
```

---

## 📋 项目文件说明

| 文件 | 说明 |
|------|------|
| `onekey.sh` | 🚀 聚合管理脚本 (推荐入口) |
| `common.sh` | 公共函数库 |
| `anytls.sh` | AnyTLS 部署脚本 |
| `tuic.sh` | TUIC v4/v5 部署脚本 |
| `ss2022.sh` | Shadowsocks 2022 部署脚本 |
| `hy2.sh` | Hysteria 2 部署脚本 |
| `mieru.sh` | Mieru 部署脚本 |
| `vless.sh` | VLESS + REALITY 部署脚本 |
| `sudoku.sh` | Sudoku 部署脚本 |
| `ipf.sh` | IPTables 端口转发工具 |
| `dns_monitor_install.sh` | DNS 监控安装脚本 |
| `dns_monitor.sh` | DNS 监控核心脚本 |
| `setup_dns.sh` | DNS 修复脚本 |

---

## ⚠️ 免责声明

本项目仅供学习和研究使用，请遵守当地法律法规。使用本项目产生的任何后果由使用者自行承担。
