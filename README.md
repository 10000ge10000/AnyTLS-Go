
# 自用高性能代理脚本合集 (OpenClash 优化版)

欢迎使用！本项目收录了一系列针对 **OpenClash (Meta 内核)** 进行深度优化的服务端一键管理脚本。

✨ **项目亮点：**
* 🛠️ **一键部署**：全自动安装依赖、配置内核、申请证书。
* ⚙️ **专属优化**：针对 Meta 内核生成专属配置代码和填空指引。
* 📊 **便捷管理**：提供功能强大的管理面板，支持查看日志、修改端口、IP 优先级设置等。
* ⚡ **协议丰富**：涵盖了目前主流的高性能及高隐匿性协议。

---

## 1️⃣ AnyTLS (隐匿传输) 🛡️
> 基于 `anytls-go` 核心，主打极致隐匿。通过模拟正常的 HTTPS 流量来绕过防火墙检测，适合高封锁环境。

* **特点**：高度隐匿、抗探测、需配合客户端使用
* **管理命令**: `anytls`

```bash
bash <(curl -fsSL [https://raw.githubusercontent.com/10000ge10000/AnyTLS-Go/main/anytls.sh](https://raw.githubusercontent.com/10000ge10000/AnyTLS-Go/main/anytls.sh))

```

---

## 2️⃣ Tuic v5 (QUIC 高速协议) ⚡

> 基于 QUIC 协议构建的高性能代理。支持 0-RTT 连接，在拥塞网络环境中表现优异，延迟更低。

* **特点**：QUIC 协议、BBR 拥塞控制、低延迟、Meta 内核原生支持
* **管理命令**: `tuic`

```bash
bash <(curl -fsSL [https://raw.githubusercontent.com/10000ge10000/AnyTLS-Go/main/tuic.sh](https://raw.githubusercontent.com/10000ge10000/AnyTLS-Go/main/tuic.sh))

```

---

## 3️⃣ Shadowsocks 2022 (Rust 极致性能) 🦀

> 使用 Rust 语言编写的最新版 Shadowsocks。支持最新的 AEAD-2022 加密规范，拥有极低的资源占用和超高的稳定性。

* **特点**：内存占用低、超稳定、最新加密规范、防止重放攻击
* **管理命令**: `ss`

```bash
bash <(curl -fsSL [https://raw.githubusercontent.com/10000ge10000/AnyTLS-Go/main/ss2022.sh](https://raw.githubusercontent.com/10000ge10000/AnyTLS-Go/main/ss2022.sh))

```

---

## 4️⃣ Hysteria 2 (暴力加速) 🌊

> 下一代 Hysteria 协议。在弱网环境下拥有强悍的抢占能力，能够有效提升网络吞吐量，同时提供伪装功能。

* **特点**：弱网救星、端口跳跃、高吞吐量、Meta 内核完美兼容
* **管理命令**: `hy`

```bash
bash <(curl -fsSL [https://raw.githubusercontent.com/10000ge10000/AnyTLS-Go/main/hy2.sh](https://raw.githubusercontent.com/10000ge10000/AnyTLS-Go/main/hy2.sh))

```
