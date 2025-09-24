#!/bin/bash

# AnyTLS-Go 一行安装命令生成器

echo "=== AnyTLS-Go 一键安装命令 ==="
echo
echo "复制以下命令在你的Linux服务器上运行："
echo
echo -e "\033[1;32mbash <(curl -fsSL https://raw.githubusercontent.com/anytls/anytls-go/main/install.sh)\033[0m"
echo
echo "或者使用wget："
echo
echo -e "\033[1;32mwget -O- https://raw.githubusercontent.com/anytls/anytls-go/main/install.sh | bash\033[0m"
echo
echo "支持的系统："
echo "- Ubuntu 18.04+"
echo "- Debian 9+"
echo "- CentOS 7+"
echo "- RHEL 7+"
echo "- Rocky Linux 8+"
echo "- AlmaLinux 8+"
echo "- Fedora 30+"
echo "- Arch Linux"
echo
echo "支持的架构："
echo "- x86_64 (amd64)"
echo "- ARM64 (aarch64)"
echo "- ARMv7"
echo "- ARMv6"
echo
echo "安装后使用 'anytls-manage' 命令管理服务"