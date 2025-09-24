# AnyTLS-Go 一键安装脚本指南

## 概述

AnyTLS-Go 一键安装脚本提供了简单、快速、安全的方式在Linux服务器上安装和配置AnyTLS代理服务。脚本支持服务端和客户端两种模式，具有完整的系统检测、依赖安装、防火墙配置、证书管理等功能。

## 主要特性

- ✅ **全面系统支持**: Ubuntu、Debian、CentOS、RHEL、Rocky、AlmaLinux、Fedora、Arch
- ✅ **自动环境配置**: 自动安装Go语言环境和必要依赖
- ✅ **智能防火墙配置**: 支持UFW、firewalld、iptables
- ✅ **Let's Encrypt集成**: 自动申请和续期TLS证书
- ✅ **交互式配置向导**: 友好的用户界面，支持自定义配置
- ✅ **systemd服务集成**: 完整的系统服务管理
- ✅ **在线版本管理**: 自动检查更新和升级
- ✅ **完整管理面板**: 图形化服务管理界面

## 快速开始

### 方法一：直接运行（推荐）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/anytls/anytls-go/main/install.sh)
```

### 方法二：下载后运行

```bash
wget https://raw.githubusercontent.com/anytls/anytls-go/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

### 方法三：从Git仓库安装

```bash
git clone https://github.com/anytls/anytls-go.git
cd anytls-go
sudo bash install.sh
```

## 系统要求

### 操作系统
- Ubuntu 18.04+
- Debian 9+
- CentOS 7+
- RHEL 7+
- Rocky Linux 8+
- AlmaLinux 8+
- Fedora 30+
- Arch Linux

### 系统架构
- x86_64 (amd64)
- ARM64 (aarch64)
- ARMv7
- ARMv6

### 最低配置
- CPU: 1核心
- 内存: 512MB
- 磁盘: 100MB可用空间
- 网络: 稳定的互联网连接

### 权限要求
- Root用户权限（使用sudo运行）

## 安装过程详解

### 1. 系统检测阶段

脚本会自动检测以下信息：
- 操作系统类型和版本
- 系统架构（x86_64、ARM64等）
- 包管理器类型（apt、yum、dnf、pacman）
- 防火墙类型（UFW、firewalld、iptables）
- 网络连接状态
- 本地和公网IP地址

### 2. 环境准备阶段

- 更新系统软件包
- 安装编译工具链和基础依赖
- 检查并安装Go语言环境（版本1.24.0+）
- 创建必要的系统目录

### 3. 程序安装阶段

- 从GitHub克隆最新源代码
- 编译服务端和客户端程序
- 安装二进制文件到系统目录
- 创建符号链接便于命令行使用

### 4. 配置向导阶段

#### 服务端模式配置
- 选择监听端口（默认8443）
- 设置连接密码
- 配置域名（可选，用于TLS证书）
- 选择是否自动申请Let's Encrypt证书
- 配置开机自启和防火墙

#### 客户端模式配置
- 设置服务器地址和端口
- 配置连接密码
- 选择本地SOCKS5端口（默认1080）
- 设置SNI（可选）
- 配置开机自启

### 5. 系统集成阶段

- 生成配置文件
- 配置系统防火墙规则
- 申请和安装TLS证书（如果选择）
- 创建systemd服务文件
- 安装管理脚本

## 配置参数详解

### 服务端配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| 监听端口 | 8443 | 服务端监听的TCP端口 |
| 连接密码 | 用户设置 | 客户端连接认证密码 |
| 域名 | 可选 | 用于申请TLS证书的域名 |
| 自动证书 | 否 | 是否自动申请Let's Encrypt证书 |
| 日志级别 | info | 日志输出级别（debug/info/warn/error） |

### 客户端配置参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| 服务器地址 | 用户设置 | AnyTLS服务器的地址和端口 |
| 连接密码 | 用户设置 | 服务端配置的连接密码 |
| 本地端口 | 1080 | 本地SOCKS5代理监听端口 |
| SNI | 可选 | TLS连接的Server Name Indication |
| 不安全连接 | 是 | 允许不安全的TLS连接 |

## 防火墙配置

脚本会自动检测并配置以下防火墙：

### UFW (Ubuntu/Debian)
```bash
# 启用UFW
ufw --force enable
# 允许SSH
ufw allow 22/tcp
# 允许AnyTLS端口（服务端模式）
ufw allow 8443/tcp
# 重新加载规则
ufw reload
```

### firewalld (CentOS/RHEL/Fedora)
```bash
# 启动firewalld
systemctl enable firewalld
systemctl start firewalld
# 允许AnyTLS端口（服务端模式）
firewall-cmd --permanent --add-port=8443/tcp
# 重新加载规则
firewall-cmd --reload
```

### iptables (通用)
```bash
# 允许AnyTLS端口（服务端模式）
iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
# 保存规则（如果支持）
iptables-save > /etc/iptables/rules.v4
```

## Let's Encrypt证书

### 自动申请流程

1. 安装acme.sh工具
2. 使用standalone模式申请证书
3. 自动安装证书到指定目录
4. 配置自动续期

### 证书文件位置
- 私钥: `/etc/anytls/certs/[域名].key`
- 证书: `/etc/anytls/certs/[域名].crt`

### 手动续期
```bash
~/.acme.sh/acme.sh --renew -d [域名]
```

## systemd服务管理

### 服务文件位置
- `/etc/systemd/system/anytls.service`

### 基本管理命令
```bash
# 启动服务
systemctl start anytls

# 停止服务
systemctl stop anytls

# 重启服务
systemctl restart anytls

# 查看状态
systemctl status anytls

# 开机自启
systemctl enable anytls

# 取消自启
systemctl disable anytls

# 查看日志
journalctl -u anytls -f
```

## 管理面板使用

### 启动管理面板
```bash
anytls-manage
```

### 命令行操作
```bash
# 查看状态
anytls-manage status

# 启动服务
anytls-manage start

# 停止服务
anytls-manage stop

# 重启服务
anytls-manage restart

# 查看日志
anytls-manage logs

# 检查更新
anytls-manage update

# 卸载程序
anytls-manage uninstall
```

### 管理面板功能

1. **查看状态**: 显示服务运行状态、网络监听、最近日志
2. **启动服务**: 启动AnyTLS服务
3. **停止服务**: 停止AnyTLS服务
4. **重启服务**: 重启AnyTLS服务
5. **查看日志**: 实时查看或历史日志
6. **检查更新**: 检查并更新到最新版本
7. **卸载程序**: 完全卸载AnyTLS及配置文件

## 目录结构

安装完成后，AnyTLS会在以下位置创建文件：

```
/opt/anytls/                 # 主安装目录
├── anytls-server           # 服务端程序
└── anytls-client           # 客户端程序

/etc/anytls/                # 配置目录
├── server.conf             # 服务端配置（如果是服务端模式）
├── client.conf             # 客户端配置（如果是客户端模式）
└── certs/                  # TLS证书目录
    ├── [域名].key          # 私钥文件
    └── [域名].crt          # 证书文件

/var/log/anytls/            # 日志目录
├── server.log              # 服务端日志
└── client.log              # 客户端日志

/usr/local/bin/             # 系统命令目录
├── anytls-server           # 服务端命令（符号链接）
├── anytls-client           # 客户端命令（符号链接）
└── anytls-manage           # 管理脚本

/etc/systemd/system/        # systemd服务目录
└── anytls.service          # 服务配置文件
```

## 使用示例

### 服务端部署示例

1. **基础服务端设置**
   ```bash
   # 运行安装脚本
   bash <(curl -fsSL https://raw.githubusercontent.com/anytls/anytls-go/main/install.sh)
   
   # 选择服务端模式
   # 设置端口：8443
   # 设置密码：your_password
   # 开启防火墙配置
   # 开启开机自启
   ```

2. **带域名和证书的服务端**
   ```bash
   # 安装时配置域名：example.com
   # 选择自动申请Let's Encrypt证书
   ```

3. **查看服务状态**
   ```bash
   anytls-manage status
   ```

### 客户端部署示例

1. **基础客户端设置**
   ```bash
   # 运行安装脚本
   bash <(curl -fsSL https://raw.githubusercontent.com/anytls/anytls-go/main/install.sh)
   
   # 选择客户端模式
   # 服务器地址：your_server_ip:8443
   # 设置密码：your_password
   # 本地端口：1080
   ```

2. **使用代理**
   ```bash
   # 配置系统代理为 127.0.0.1:1080
   # 或使用特定应用程序的代理设置
   
   # 测试连接
   curl --proxy socks5://127.0.0.1:1080 https://www.google.com
   ```

## 故障排除

### 常见问题

#### 1. 安装失败：权限不足
```bash
# 解决方案：使用root权限运行
sudo bash install.sh
```

#### 2. 网络连接问题
```bash
# 检查网络连接
ping -c 4 8.8.8.8

# 检查DNS解析
nslookup github.com

# 检查防火墙设置
systemctl status ufw
systemctl status firewalld
```

#### 3. Go语言安装失败
```bash
# 手动安装Go（以1.24.0为例）
wget https://go.dev/dl/go1.24.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.24.0.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
source ~/.bashrc
```

#### 4. 编译失败
```bash
# 检查Go版本
go version

# 清理缓存重新编译
go clean -cache
go clean -modcache

# 手动编译
cd /tmp
git clone https://github.com/anytls/anytls-go.git
cd anytls-go
go build -o anytls-server ./cmd/server
go build -o anytls-client ./cmd/client
```

#### 5. 服务启动失败
```bash
# 查看详细错误信息
systemctl status anytls -l
journalctl -u anytls --no-pager

# 检查配置文件
cat /etc/anytls/server.conf
cat /etc/anytls/client.conf

# 手动测试启动
/opt/anytls/anytls-server -l 0.0.0.0:8443 -p your_password
```

#### 6. 端口冲突
```bash
# 检查端口占用
netstat -tlnp | grep :8443
ss -tlnp | grep :8443

# 修改配置端口
sudo nano /etc/anytls/server.conf
sudo systemctl restart anytls
```

#### 7. 防火墙阻止连接
```bash
# UFW
sudo ufw status
sudo ufw allow 8443/tcp

# firewalld
sudo firewall-cmd --list-ports
sudo firewall-cmd --permanent --add-port=8443/tcp
sudo firewall-cmd --reload

# iptables
sudo iptables -L -n
sudo iptables -I INPUT -p tcp --dport 8443 -j ACCEPT
```

#### 8. Let's Encrypt证书申请失败
```bash
# 检查域名DNS解析
nslookup your_domain.com

# 检查80端口是否开放
sudo netstat -tlnp | grep :80

# 手动申请证书
~/.acme.sh/acme.sh --issue -d your_domain.com --standalone --httpport 80 --debug
```

### 日志分析

#### 系统服务日志
```bash
# 查看实时日志
journalctl -u anytls -f

# 查看最近的日志
journalctl -u anytls --no-pager -n 50

# 查看指定时间的日志
journalctl -u anytls --since "2024-01-01 00:00:00"
```

#### 应用程序日志
```bash
# 服务端日志
tail -f /var/log/anytls/server.log

# 客户端日志
tail -f /var/log/anytls/client.log
```

### 性能优化

#### 1. 系统参数调优
```bash
# 增加文件描述符限制
echo "* soft nofile 65535" >> /etc/security/limits.conf
echo "* hard nofile 65535" >> /etc/security/limits.conf

# 优化网络参数
echo "net.core.rmem_max = 134217728" >> /etc/sysctl.conf
echo "net.core.wmem_max = 134217728" >> /etc/sysctl.conf
echo "net.ipv4.tcp_rmem = 4096 87380 134217728" >> /etc/sysctl.conf
echo "net.ipv4.tcp_wmem = 4096 65536 134217728" >> /etc/sysctl.conf
sysctl -p
```

#### 2. 服务配置优化
```bash
# 编辑服务配置增加并发连接数
sudo nano /etc/anytls/server.conf
# 添加：MAX_CONNECTIONS="5000"
```

## 安全建议

### 1. 密码安全
- 使用强密码（包含大小写字母、数字、特殊字符）
- 定期更换密码
- 避免使用常见密码

### 2. 系统安全
```bash
# 定期更新系统
sudo apt update && sudo apt upgrade  # Ubuntu/Debian
sudo yum update                       # CentOS/RHEL

# 配置SSH安全
sudo nano /etc/ssh/sshd_config
# PasswordAuthentication no
# PermitRootLogin no
# Port 2222

# 重启SSH服务
sudo systemctl restart sshd
```

### 3. 防火墙安全
- 只开放必要的端口
- 定期检查防火墙规则
- 考虑使用fail2ban防止暴力攻击

### 4. 证书安全
- 使用有效的TLS证书
- 定期检查证书有效期
- 及时续期证书

## 更新和维护

### 自动更新
```bash
# 使用管理面板检查更新
anytls-manage update

# 或者使用命令行
anytls-manage check_update
```

### 手动更新
```bash
# 停止服务
sudo systemctl stop anytls

# 备份配置
sudo cp -r /etc/anytls /etc/anytls.backup

# 重新运行安装脚本
bash <(curl -fsSL https://raw.githubusercontent.com/anytls/anytls-go/main/install.sh)
```

### 配置备份
```bash
# 备份配置文件
sudo tar -czf anytls-backup-$(date +%Y%m%d).tar.gz /etc/anytls /opt/anytls

# 恢复配置文件
sudo tar -xzf anytls-backup-20240101.tar.gz -C /
```

## 卸载指南

### 使用管理脚本卸载（推荐）
```bash
anytls-manage uninstall
```

### 手动卸载
```bash
# 停止并禁用服务
sudo systemctl stop anytls
sudo systemctl disable anytls

# 删除服务文件
sudo rm -f /etc/systemd/system/anytls.service
sudo systemctl daemon-reload

# 删除程序文件
sudo rm -rf /opt/anytls
sudo rm -rf /etc/anytls
sudo rm -rf /var/log/anytls

# 删除命令链接
sudo rm -f /usr/local/bin/anytls-server
sudo rm -f /usr/local/bin/anytls-client
sudo rm -f /usr/local/bin/anytls-manage

# 清理Go环境（可选）
sudo rm -rf /usr/local/go
```

## 技术支持

### 官方资源
- GitHub仓库: https://github.com/anytls/anytls-go
- 协议文档: https://github.com/anytls/anytls-go/blob/main/docs/protocol.md
- 常见问题: https://github.com/anytls/anytls-go/blob/main/docs/faq.md

### 问题报告
如果遇到问题，请在GitHub上提交Issue，包含以下信息：
- 操作系统版本
- 错误日志
- 配置文件内容
- 详细的重现步骤

### 贡献代码
欢迎提交Pull Request来改进安装脚本和文档。

## 许可证

本安装脚本和AnyTLS-Go项目遵循相同的开源许可证。详情请查看项目仓库的LICENSE文件。

---

**注意**: 本指南基于AnyTLS-Go项目的最新版本编写。如果您在使用过程中遇到任何问题，请参考官方文档或提交Issue。