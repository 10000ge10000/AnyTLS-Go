#!/bin/bash

# AnyTLS-Go 快速部署脚本
# 用于测试和演示安装过程

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo "请使用root权限运行此脚本"
    exit 1
fi

echo "=== AnyTLS-Go 快速部署测试 ==="
echo

# 设置执行权限
chmod +x install.sh

echo "1. 服务端模式测试部署"
echo "2. 客户端模式测试部署" 
echo "3. 交互式安装"
echo -n "请选择部署模式 [1-3]: "
read -r choice

case $choice in
    1)
        echo ">>> 开始服务端模式部署测试"
        # 这里可以添加自动化的服务端配置
        ./install.sh
        ;;
    2)
        echo ">>> 开始客户端模式部署测试"
        # 这里可以添加自动化的客户端配置
        ./install.sh
        ;;
    3)
        echo ">>> 开始交互式安装"
        ./install.sh
        ;;
    *)
        echo "无效选择"
        exit 1
        ;;
esac

echo
echo "=== 部署完成 ==="
echo "使用 'anytls-manage' 命令管理服务"
echo "查看安装指南: cat INSTALL_GUIDE.md"