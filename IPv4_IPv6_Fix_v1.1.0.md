# AnyTLS-Go IPv4/IPv6 优先级修复说明 v1.1.0

## 问题描述
用户反馈：选择"IPv4优先"后，实际使用中仍然是IPv6优先，IPv4优先设置不生效。

## 根本原因分析
经过深入分析，发现问题有以下几个层面：

### 1. 监听地址配置问题
- **原错误逻辑**: IPv4优先使用 `0.0.0.0:端口`
- **问题**: 在双栈系统中，`0.0.0.0` 仍可能被系统解析为双栈监听
- **解决方案**: IPv4优先改为 `127.0.0.1:端口`，强制仅IPv4本地监听

### 2. Go语言网络行为
- **原问题**: 没有设置Go语言特定的网络环境变量
- **解决方案**: 添加 `GODEBUG=netdns=go+4` 强制Go使用IPv4优先的DNS解析

### 3. 系统级网络优先级
- **原问题**: 系统默认可能优先IPv6
- **解决方案**: 配置 `/etc/gai.conf` 设置IPv4地址优先级

### 4. 环境变量缺失
- **原问题**: systemd服务没有设置网络相关环境变量
- **解决方案**: 在systemd服务中添加相应的Environment配置

## 修复内容详解

### 版本更新
- 脚本版本从 `1.0.0` 更新到 `1.1.0`
- 在脚本头部和显示中体现版本变更

### IPv4/IPv6配置逻辑修复

#### IPv4优先 (ipv4_first)
```bash
# 监听地址
listen_addr="127.0.0.1:${USER_PORT}"

# 环境变量
Environment="GODEBUG=netdns=go+4" "PREFER_IPV4=1"

# 系统优化
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
```

#### IPv6优先 (ipv6_first)
```bash
# 监听地址
listen_addr="[::]:${USER_PORT}"

# 环境变量
Environment="GODEBUG=netdns=go+6"
```

#### 仅IPv4 (ipv4_only)
```bash
# 监听地址
listen_addr="0.0.0.0:${USER_PORT}"

# 环境变量
Environment="GODEBUG=netdns=go+4" "PREFER_IPV4=1"
```

#### 仅IPv6 (ipv6_only)
```bash
# 监听地址
listen_addr="[::]:${USER_PORT}"

# 环境变量
Environment="GODEBUG=netdns=go+6" "DISABLE_IPV4=1"
```

### 新增功能

1. **系统网络优化函数** (`optimize_network_for_ip_version`)
   - 自动配置系统级IPv4/IPv6优先级
   - 修改 `/etc/gai.conf` 实现地址选择优化
   - 根据用户选择进行相应优化

2. **动态监听地址显示**
   - 用户界面根据IP版本选择显示正确的监听地址
   - 不再固定显示 `0.0.0.0:端口`

3. **增强环境变量配置**
   - 在systemd服务中添加 `${env_vars}` 占位符
   - 根据IP版本自动设置相应环境变量

## 技术实现要点

### Go语言网络控制
```bash
# IPv4强制
GODEBUG=netdns=go+4

# IPv6强制
GODEBUG=netdns=go+6

# 自定义环境变量
PREFER_IPV4=1
DISABLE_IPV4=1
```

### systemd服务配置
```ini
[Service]
Type=simple
User=anytls
Group=anytls
Environment="GODEBUG=netdns=go+4" "PREFER_IPV4=1"
ExecStart=/opt/anytls/anytls-server -l 127.0.0.1:8443 -p "password"
```

### 系统优化配置
```bash
# IPv4优先配置
echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
```

## 验证方法

### 1. 配置验证
```bash
# 检查systemd服务
systemctl cat anytls

# 检查监听地址
netstat -tlnp | grep :8443

# 检查系统配置
cat /etc/gai.conf
```

### 2. 连接测试
```bash
# IPv4连接测试
telnet 127.0.0.1 8443

# IPv6连接测试 (应该失败，如果是IPv4优先配置)
telnet ::1 8443
```

## 预期效果

### IPv4优先模式
- ✅ 服务监听在 `127.0.0.1:端口`
- ✅ 强制使用IPv4进行DNS解析
- ✅ 系统优先选择IPv4地址
- ✅ 拒绝IPv6连接

### 其他模式
- IPv6优先：双栈监听，优先IPv6
- 仅IPv4：强制IPv4，拒绝IPv6
- 仅IPv6：仅监听IPv6

## 注意事项

1. **兼容性**: 修复后的配置需要重新运行安装脚本生效
2. **系统影响**: `/etc/gai.conf` 的修改会影响全系统的地址选择
3. **端口访问**: IPv4优先模式只能通过127.0.0.1访问，外部需要配置端口转发
4. **测试验证**: 安装后建议进行连接测试确认配置正确

## 更新日志

### v1.1.0 (当前版本)
- 🔧 修复IPv4优先配置不生效的问题
- ➕ 添加系统网络优化功能
- ➕ 增强Go语言环境变量配置
- ➕ 动态监听地址显示
- 📝 更新版本号标识

### v1.0.0 (旧版本)
- ❌ IPv4优先配置存在问题
- ❌ 缺少系统级优化
- ❌ 环境变量配置不完整