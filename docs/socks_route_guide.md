# 🏠 Alice 家宽分流 — 使用指南

## 目录

- [概述](#概述)
- [工作原理](#工作原理)
- [快速开始](#快速开始)
- [菜单功能详解](#菜单功能详解)
  - [1. 安装/配置 SOCKS5 入站](#1-安装配置-socks5-入站)
  - [2. 查看服务状态](#2-查看服务状态)
  - [3. 添加节点 (分享链接)](#3-添加节点-分享链接)
  - [4. 一键导入 Alice 家宽](#4-一键导入-alice-家宽)
  - [5. 查看节点](#5-查看节点)
  - [6. 删除节点](#6-删除节点)
  - [7. 配置分流规则](#7-配置分流规则)
  - [8. 测试分流效果](#8-测试分流效果)
  - [9/10. 启动/停止/重启服务](#910-启动停止重启服务)
  - [11. 完全卸载](#11-完全卸载)
- [典型使用场景](#典型使用场景)
- [分流规则预设列表](#分流规则预设列表)
- [支持的协议](#支持的协议)
- [文件说明](#文件说明)
- [故障排查](#故障排查)
- [注意事项](#注意事项)

---

## 概述

`socks_route.sh` 是一个 **SOCKS5 入站 + 链式代理出站 + 分流规则管理** 的一体化脚本。

**核心用途**：在 VPS 上搭建 SOCKS5 代理服务，将特定流量（如 Netflix、ChatGPT）通过家宽 IP 出口转发，实现流媒体解锁和 IP 归属地伪装。

---

## 工作原理

```
┌──────────────────────────────────────────────────────────────┐
│                         VPS 服务器                            │
│                                                              │
│  客户端 ──→ [SOCKS5 入站:10800] ──→ [Xray 路由引擎]         │
│                                         │                    │
│                           ┌─────────────┼─────────────┐      │
│                           ▼             ▼             ▼      │
│                      [直连出口]   [链式代理]    [负载均衡]    │
│                       direct      chain:节点   balancer:组   │
│                           │             │             │      │
│                           ▼             ▼             ▼      │
│                       VPS 公网IP   家宽节点IP   多节点轮询    │
└──────────────────────────────────────────────────────────────┘
```

**流量路径示例**：

| 访问目标 | 路由规则 | 出口 IP |
|----------|----------|---------|
| `google.com` | 直连 | VPS 公网 IP |
| `chatgpt.com` | → Alice 负载均衡 | 台湾家宽 IP (轮询) |
| `netflix.com` | → Alice-TW-01 | 台湾家宽 IP (固定) |
| `mysite.com` | → 自定义节点 | 自定义出口 IP |

---

## 快速开始

### 方式一：通过管理面板（推荐）

```bash
# 运行聚合管理脚本
x

# 选择 11. Alice分流
```

### 方式二：直接运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/socks_route.sh)
```

### 30 秒快速上手

```
1. 选择 [1] → 配置 SOCKS5 入站（设定端口、用户名、密码）
2. 选择 [4] → 一键导入 Alice 8 个家宽节点 + 创建负载均衡组
3. 选择 [7] → 添加分流规则:
   - OpenAI → Alice 负载均衡
   - Netflix → Alice 负载均衡
4. 选择 [8] → 测试分流效果
5. 在客户端配置 SOCKS5 代理即可使用
```

---

## 菜单功能详解

### 1. 安装/配置 SOCKS5 入站

配置 Xray 的 SOCKS5 入站协议。这是客户端连接你 VPS 的入口。

**配置项**：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| 端口 | SOCKS5 监听端口 | 随机生成 (10000-60000) |
| 认证模式 | `密码认证` 或 `无认证` | 密码认证 |
| 用户名 | 连接用户名 | 随机生成 |
| 密码 | 连接密码 | 随机生成 |
| 监听地址 | 仅无认证模式可改 | `0.0.0.0`（密码）/ `127.0.0.1`（无认证） |

**操作流程**：

```
选择 [1] → 设置端口 → 选择认证模式 → 设置用户名密码
         → 自动安装 Xray → 生成配置 → 启动服务 → 显示连接信息
```

安装完成后会显示完整的连接链接：

```
socks5://用户名:密码@你的IP:端口#SOCKS5
```

> ⚠️ **安全建议**：强烈推荐使用密码认证模式。如果使用无认证模式，监听地址应改为 `127.0.0.1`，仅允许本机访问。

---

### 2. 查看服务状态

显示当前服务的运行概况：

- SOCKS5 入站状态（运行中/已停止/未配置）
- 已配置的代理节点数量
- 分流规则数量
- 连接信息（链接）

---

### 3. 添加节点 (分享链接)

通过粘贴分享链接来添加链式代理出站节点。

**支持的链接格式**：

```
socks5://user:pass@host:port#名称
ss://base64@host:port#名称
vmess://base64编码
vless://uuid@host:port?security=reality&...#名称
trojan://password@host:port#名称
```

**IPv6 示例**：

```
socks5://alice:password@[2a14:67c0:116::1]:10001#Alice-TW-01
```

添加节点后会自动重新生成 Xray 配置并重启服务。

---

### 4. 一键导入 Alice 家宽

一键导入 8 个预置的 Alice 台湾家宽 SOCKS5 出口节点。

| 节点名称 | 服务器 | 端口 |
|----------|--------|------|
| Alice-TW-SOCKS5-01 | `2a14:67c0:116::1` | 10001 |
| Alice-TW-SOCKS5-02 | `2a14:67c0:116::1` | 10002 |
| Alice-TW-SOCKS5-03 | `2a14:67c0:116::1` | 10003 |
| Alice-TW-SOCKS5-04 | `2a14:67c0:116::1` | 10004 |
| Alice-TW-SOCKS5-05 | `2a14:67c0:116::1` | 10005 |
| Alice-TW-SOCKS5-06 | `2a14:67c0:116::1` | 10006 |
| Alice-TW-SOCKS5-07 | `2a14:67c0:116::1` | 10007 |
| Alice-TW-SOCKS5-08 | `2a14:67c0:116::1` | 10008 |

导入后会询问是否创建 **负载均衡组** `Alice-TW-LB`（随机策略，8 节点轮询）。

> 💡 **推荐**：创建负载均衡组后，分流规则选择 `Alice-TW-LB` 作为出口，可以在 8 个家宽 IP 之间随机轮换，降低单 IP 被封风险。

---

### 5. 查看节点

显示所有已添加的链式代理节点列表和负载均衡组。

```
📋 链式代理节点
─────────────────────────────
  1. Alice-TW-SOCKS5-01 (socks @ 2a14:67c0:116::1:10001)
  2. Alice-TW-SOCKS5-02 (socks @ 2a14:67c0:116::1:10002)
  ...

  负载均衡组
  ⚖ Alice-TW-LB (random, 8节点)
```

---

### 6. 删除节点

选择要删除的节点编号，或输入 `all` 删除全部节点。删除节点时会同时清理引用该节点的分流规则。

---

### 7. 配置分流规则

**这是核心功能**——决定哪些流量走家宽出口，哪些流量走直连。

#### 添加规则流程

```
选择规则类型 → 选择出口（直连/链式代理/负载均衡）→ 自动生效
```

#### 规则类型

| 序号 | 类型 | 匹配目标 |
|------|------|----------|
| 1 | OpenAI/ChatGPT | openai.com, chatgpt.com 等 8 个域名 |
| 2 | Netflix | netflix.com, nflxvideo.net 等 7 个域名 |
| 3 | Disney+ | disney.com, disneyplus.com 等 6 个域名 |
| 4 | YouTube | youtube.com, googlevideo.com 等 5 个域名 |
| 5 | Spotify | spotify.com, spotifycdn.com 等 4 个域名 |
| 6 | TikTok | tiktok.com, tiktokcdn.com 等 6 个域名 |
| 7 | Telegram | telegram.org, t.me 等 5 个域名 |
| 8 | Google | google.com, googleapis.com 等 6 个域名 |
| 9 | MyTVSuper | mytvsuper.com, tvb.com |
| c | 自定义域名 | 手动输入域名列表（逗号分隔） |
| a | 所有流量 | 全局代理（catch-all 规则） |

#### 出口选择

添加规则时需要选择出口：

- **DIRECT (直连)**：流量直接从 VPS 公网 IP 出去
- **chain:节点名**：流量通过指定的链式代理节点出去
- **balancer:组名**：流量通过负载均衡组（多节点轮询）

#### 自定义域名示例

```
# 普通域名
example.com,mysite.org,another.io

# geosite 规则 (使用 Xray 内置的地理站点数据库)
geosite:netflix,geosite:openai

# 混合使用
example.com,geosite:netflix,geoip:jp
```

---

### 8. 测试分流效果

通过 SOCKS5 代理测试以下目标的可达性：

| 测试项 | 地址 |
|--------|------|
| 出口 IP | `https://api.ipify.org` |
| ChatGPT | `https://chatgpt.com` |
| Netflix | `https://www.netflix.com` |
| YouTube | `https://www.youtube.com` |
| Google | `https://www.google.com` |

输出示例：

```
  ✓ 出口IP: 123.45.67.89    ← 如果走了家宽，这里显示家宽IP
  ✓ ChatGPT: 可访问
  ✓ Netflix: 可访问
  ✗ YouTube: 不可访问        ← 未配置分流规则或节点离线
  ✓ Google: 可访问
```

---

### 9/10. 启动/停止/重启服务

- 服务运行中时，显示 **重启** 和 **停止**
- 服务未运行时，显示 **启动**

服务由 systemd 管理，服务名为 `xray-socks`。

手动管理命令：

```bash
systemctl status xray-socks    # 查看状态
systemctl restart xray-socks   # 重启
systemctl stop xray-socks      # 停止
journalctl -u xray-socks -n 50 # 查看日志
```

---

### 11. 完全卸载

删除以下内容：

- systemd 服务 `xray-socks`
- Xray 配置文件 `/etc/xray/config.json`
- 分流数据库 `/etc/xray/socks_route.json`

> ⚠️ 不会卸载 Xray 二进制本身（可能被其他服务使用，如 VLESS）。

---

## 典型使用场景

### 场景一：解锁 Netflix + ChatGPT

> VPS 在日本，但 IP 被 Netflix 封了。通过台湾家宽出口解锁。

```
1. [1] 配置入站 → 端口 10800, 用户 myuser, 密码 mypass
2. [4] 导入 Alice 家宽 → 创建负载均衡组
3. [7] 添加规则:
   - Netflix → Alice-TW-LB (负载均衡)
   - OpenAI  → Alice-TW-LB (负载均衡)
4. 客户端配置 socks5://myuser:mypass@VPS-IP:10800
```

**效果**：
- 访问 Netflix/ChatGPT → 通过台湾家宽 IP（8 个 IP 随机轮换）
- 其他流量 → VPS 直连出口

### 场景二：全局家宽代理

> 所有流量都通过家宽出口。

```
1. [1] 配置入站
2. [4] 导入 Alice 家宽 + 负载均衡
3. [7] 添加规则:
   - 所有流量 (选 a) → Alice-TW-LB
```

### 场景三：多出口精细分流

> 不同服务走不同出口。

```
1. [1] 配置入站
2. [3] 添加节点 — 粘贴日本 SOCKS5 链接
3. [3] 添加节点 — 粘贴美国 VLESS 链接
4. [4] 导入 Alice 家宽
5. [7] 分流规则:
   - Netflix → 日本 SOCKS5 节点 (解锁日区)
   - ChatGPT → 美国 VLESS 节点
   - YouTube → Alice 负载均衡 (台湾家宽)
   - 其他流量 → 直连
```

### 场景四：配合其他代理协议使用

> 在 VLESS 客户端中配置 outbound chain，将 VLESS 的出站链到本机 SOCKS5 分流服务。

```
客户端 → [VLESS-Reality 入站] → [SOCKS5 出站 → 127.0.0.1:10800]
                                        ↓
                            [socks_route 分流引擎]
                                   ↓         ↓
                              直连出口     家宽出口
```

---

## 分流规则预设列表

| 预设 | 匹配域名 |
|------|----------|
| OpenAI/ChatGPT | `openai.com`, `chatgpt.com`, `oaiusercontent.com`, `oaistatic.com`, `auth0.com`, `intercom.io`, `sentry.io`, `challenges.cloudflare.com` |
| Netflix | `netflix.com`, `netflix.net`, `nflximg.com`, `nflximg.net`, `nflxvideo.net`, `nflxso.net`, `nflxext.com` |
| Disney+ | `disney.com`, `disneyplus.com`, `dssott.com`, `bamgrid.com`, `disney-plus.net`, `disneystreaming.com` |
| YouTube | `youtube.com`, `googlevideo.com`, `ytimg.com`, `yt.be`, `youtube-nocookie.com`, `youtu.be` |
| Spotify | `spotify.com`, `spotifycdn.com`, `scdn.co`, `spotify.design` |
| TikTok | `tiktok.com`, `tiktokv.com`, `tiktokcdn.com`, `musical.ly`, `byteoversea.com`, `ibytedtos.com` |
| Telegram | `telegram.org`, `t.me`, `telegram.me`, `telesco.pe`, `tdesktop.com`, `telegra.ph` |
| Google | `google.com`, `googleapis.com`, `gstatic.com`, `google.co`, `google.com.hk`, `google.co.jp` |
| MyTVSuper | `mytvsuper.com`, `tvb.com` |

---

## 支持的协议

链式代理出站支持以下协议的分享链接导入：

| 协议 | 链接格式 | 说明 |
|------|----------|------|
| SOCKS5 | `socks5://user:pass@host:port#名称` | 家宽出口常用 |
| Shadowsocks | `ss://base64@host:port#名称` | 支持 AEAD |
| VMess | `vmess://base64` | V2Ray 标准格式 |
| VLESS | `vless://uuid@host:port?params#名称` | 支持 Reality/TLS |
| Trojan | `trojan://password@host:port#名称` | 支持 TLS |

---

## 文件说明

| 文件路径 | 说明 |
|----------|------|
| `/etc/xray/socks_route_xray.json` | Xray 运行配置（自动生成，勿手动编辑） |
| `/etc/xray/socks_route.json` | 分流数据库（节点、规则、入站配置） |
| `/etc/systemd/system/xray-socks.service` | systemd 服务文件 |
| `/usr/local/bin/xray` | Xray 二进制文件 |

### 数据库结构 (`socks_route.json`)

```json
{
  "socks_inbound": {
    "port": 10800,
    "username": "user",
    "password": "pass",
    "auth_mode": "password",
    "listen": "0.0.0.0"
  },
  "chain_nodes": [
    {
      "name": "Alice-TW-SOCKS5-01",
      "type": "socks",
      "server": "2a14:67c0:116::1",
      "port": 10001,
      "username": "alice",
      "password": "alicefofo123..OVO"
    }
  ],
  "routing_rules": [
    {
      "id": "1234567890",
      "type": "netflix",
      "outbound": "balancer:Alice-TW-LB",
      "domains": "",
      "ip_version": "as_is"
    }
  ],
  "balancer_groups": [
    {
      "name": "Alice-TW-LB",
      "strategy": "random",
      "nodes": ["Alice-TW-SOCKS5-01", "..."]
    }
  ],
  "direct_ip_version": "as_is"
}
```

---

## 故障排查

### 服务无法启动

```bash
# 查看详细日志
journalctl -u xray-socks -n 50 --no-pager

# 手动验证配置
xray run -test -c /etc/xray/config.json

# 常见原因: 端口被占用
ss -tunlp | grep :你的端口
```

### 代理无法连接

```bash
# 确认服务运行
systemctl status xray-socks

# 确认端口监听
ss -tunlp | grep :你的端口

# 确认防火墙放行
iptables -L INPUT -n | grep 你的端口

# 如果使用 ufw
ufw allow 你的端口/tcp
ufw allow 你的端口/udp
```

### 分流不生效（所有流量都直连）

```bash
# 检查是否有分流规则
jq '.routing_rules' /etc/xray/socks_route.json

# 检查 Xray 配置中的路由规则
jq '.routing.rules' /etc/xray/socks_route_xray.json

# 确认节点在线 (手动测试)
curl -x socks5://alice:alicefofo123..OVO@[2a14:67c0:116::1]:10001 https://api.ipify.org
```

### 节点超时/不可达

- 确认家宽 SOCKS5 节点在线
- 确认 VPS 能访问节点 IP（IPv6 需要 VPS 支持）
- 测试连通性：`curl -6 -x socks5://user:pass@[IPv6]:port https://api.ipify.org`

### 与 VLESS 服务冲突

本脚本使用独立的 systemd 服务 `xray-socks` 和独立的配置文件 `socks_route_xray.json`，与 `xray` 服务（VLESS 使用的 `config.json`）完全隔离，互不影响。两个 Xray 实例可以同时运行。

---

## 注意事项

1. **IPv6 支持**：Alice 节点使用 IPv6 地址，确保你的 VPS 支持 IPv6
2. **端口安全**：使用密码认证或限制监听地址，避免 SOCKS5 被滥用
3. **节点可用性**：Alice 家宽节点可能因维护而临时下线，建议使用负载均衡分散风险
4. **规则优先级**：分流规则按添加顺序匹配，优先匹配的规则先生效
5. **`all` 规则**：添加 "所有流量" 规则会使后续规则失效（catch-all），请放在最后
6. **防火墙**：脚本会自动添加 iptables 规则，如果使用 ufw/firewalld 需手动放行端口
