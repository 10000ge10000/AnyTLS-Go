# AnyTLS-Go 一键安装脚本

[![GitHub release](https://img.shields.io/github/release/anytls/anytls-go.svg)](https://github.com/anytls/anytls-go/releases)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Linux-green.svg)](#系统支持)

一个功能完整的AnyTLS-Go自动化安装脚本，支持服务端和客户端模式，具备完整的系统集成功能。

## ✨ 主要特性

- 🔧 **全自动安装**: 一条命令完成所有配置
- 🖥️ **全系统支持**: Ubuntu、Debian、CentOS、RHEL、Rocky、AlmaLinux、Fedora、Arch
- 🏗️ **多架构支持**: x86_64、ARM64、ARMv7、ARMv6
- 🛡️ **智能防火墙**: 自动配置UFW、firewalld、iptables
- 🔒 **Let's Encrypt**: 自动申请和续期TLS证书
- 🎛️ **交互配置**: 友好的配置向导界面
- 📊 **管理面板**: 完整的服务管理功能
- 🔄 **版本管理**: 在线检查更新和一键升级
- 🚀 **systemd集成**: 完整的系统服务支持

## 🚀 快速开始

### 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/anytls/anytls-go/main/install.sh)
```

### 备用方法

```bash
wget -O- https://raw.githubusercontent.com/anytls/anytls-go/main/install.sh | bash
```

### 本地安装

```bash
git clone https://github.com/anytls/anytls-go.git
cd anytls-go
sudo bash install.sh
```

## 📋 系统支持

### 操作系统
- ✅ Ubuntu 18.04+
- ✅ Debian 9+
- ✅ CentOS 7+
- ✅ RHEL 7+
- ✅ Rocky Linux 8+
- ✅ AlmaLinux 8+
- ✅ Fedora 30+
- ✅ Arch Linux

### 系统架构
- ✅ x86_64 (amd64)
- ✅ ARM64 (aarch64)
- ✅ ARMv7
- ✅ ARMv6

### 最低配置
- **CPU**: 1核心
- **内存**: 512MB
- **存储**: 100MB可用空间
- **网络**: 稳定的互联网连接
- **权限**: Root用户权限

## 🔧 安装过程

安装脚本将按以下步骤执行：

1. **系统检测**: 自动检测操作系统、架构、包管理器
2. **环境准备**: 更新系统、安装依赖、配置Go环境
3. **程序编译**: 下载源码、编译服务端和客户端
4. **交互配置**: 用户友好的配置向导
5. **系统集成**: 创建服务、配置防火墙、申请证书

## ⚙️ 配置选项

### 服务端模式
- 监听端口选择
- 连接密码设置
- 域名配置（可选）
- 自动TLS证书申请
- 防火墙自动配置
- 开机自启设置

### 客户端模式
- 服务器地址配置
- 连接密码设置
- 本地SOCKS5端口
- SNI设置（可选）
- 开机自启设置

## 🎛️ 管理命令

安装完成后，可使用以下命令管理服务：

```bash
# 打开管理面板
anytls-manage

# 快速操作
anytls-manage start      # 启动服务
anytls-manage stop       # 停止服务
anytls-manage restart    # 重启服务
anytls-manage status     # 查看状态
anytls-manage logs       # 查看日志
anytls-manage update     # 检查更新
anytls-manage uninstall  # 卸载程序
```

## 📁 文件结构

```
/opt/anytls/                 # 主安装目录
├── anytls-server           # 服务端程序
└── anytls-client           # 客户端程序

/etc/anytls/                # 配置目录
├── server.conf             # 服务端配置
├── client.conf             # 客户端配置
└── certs/                  # TLS证书目录

/var/log/anytls/            # 日志目录
├── server.log              # 服务端日志
└── client.log              # 客户端日志

/usr/local/bin/             # 系统命令
├── anytls-server           # 服务端命令
├── anytls-client           # 客户端命令
└── anytls-manage           # 管理脚本
```

## 🔥 使用示例

### 服务端部署

```bash
# 运行安装脚本
bash <(curl -fsSL https://raw.githubusercontent.com/anytls/anytls-go/main/install.sh)

# 选择服务端模式，配置：
# - 端口: 8443
# - 密码: your_secure_password
# - 域名: your-domain.com (可选)
# - 自动证书: 是 (如果有域名)
# - 防火墙: 是
# - 开机自启: 是
```

### 客户端部署

```bash
# 运行安装脚本
bash <(curl -fsSL https://raw.githubusercontent.com/anytls/anytls-go/main/install.sh)

# 选择客户端模式，配置：
# - 服务器: your-server-ip:8443
# - 密码: your_secure_password
# - 本地端口: 1080
# - SNI: your-domain.com (可选)
# - 开机自启: 是
```

### 连接测试

```bash
# 测试代理连接（客户端）
curl --proxy socks5://127.0.0.1:1080 https://www.google.com

# 检查服务状态
anytls-manage status
```

## 🛡️ 安全配置

### 防火墙规则

脚本会自动配置防火墙规则，支持：

- **UFW** (Ubuntu/Debian)
- **firewalld** (CentOS/RHEL/Fedora)
- **iptables** (通用)

### TLS证书

支持Let's Encrypt自动证书申请和续期：

- 使用acme.sh工具
- 支持多种验证方式
- 自动续期配置
- 证书安全存储

## 🔍 故障排除

### 常见问题

1. **权限不足**
   ```bash
   sudo bash install.sh
   ```

2. **网络连接问题**
   ```bash
   # 检查网络
   ping -c 4 8.8.8.8
   
   # 检查DNS
   nslookup github.com
   ```

3. **服务启动失败**
   ```bash
   # 查看详细日志
   journalctl -u anytls -l
   
   # 检查配置
   cat /etc/anytls/server.conf
   ```

4. **端口冲突**
   ```bash
   # 检查端口占用
   netstat -tlnp | grep :8443
   
   # 修改配置端口
   nano /etc/anytls/server.conf
   systemctl restart anytls
   ```

### 获取帮助

- 📖 查看详细指南: [INSTALL_GUIDE.md](INSTALL_GUIDE.md)
- 🐛 提交问题: [GitHub Issues](https://github.com/anytls/anytls-go/issues)
- 📚 查看文档: [项目文档](https://github.com/anytls/anytls-go/tree/main/docs)

## 🔄 更新和维护

### 自动更新

```bash
# 检查并更新到最新版本
anytls-manage update
```

### 配置备份

```bash
# 备份配置
tar -czf anytls-backup-$(date +%Y%m%d).tar.gz /etc/anytls

# 恢复配置
tar -xzf anytls-backup-20240101.tar.gz -C /
```

## 🗑️ 卸载

```bash
# 使用管理脚本卸载（推荐）
anytls-manage uninstall

# 手动卸载
sudo systemctl stop anytls
sudo systemctl disable anytls
sudo rm -rf /opt/anytls /etc/anytls /var/log/anytls
sudo rm -f /usr/local/bin/anytls-* /etc/systemd/system/anytls.service
sudo systemctl daemon-reload
```

## 📄 许可证

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情。

## 🤝 贡献

欢迎提交 Pull Request 来改进安装脚本！

1. Fork 本仓库
2. 创建功能分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 打开 Pull Request

## ⭐ 支持项目

如果这个安装脚本对您有帮助，请给项目点个星标 ⭐

## 📞 联系我们

- 项目主页: https://github.com/anytls/anytls-go
- 问题反馈: https://github.com/anytls/anytls-go/issues

---

**注意**: 使用前请确保遵守当地法律法规。本工具仅供学习和合法用途使用。