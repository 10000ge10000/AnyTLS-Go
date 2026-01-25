#!/bin/bash

# ==============================================================
# Debian Systemd-Resolved 终极配置脚本
# 功能：国内外分流 + 缓存加速 + DNSSEC 开关 (默认关)
# ==============================================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 权限运行此脚本。${NC}"
  exit 1
fi

clear
echo -e "${SKYBLUE}===============================================${NC}"
echo -e "${SKYBLUE}   Debian DNS 终极配置工具 (Stub 模式/缓存版)   ${NC}"
echo -e "${SKYBLUE}===============================================${NC}"

# ===========================
# 第一步：用户交互 (确定环境)
# ===========================
echo -e "${YELLOW}[1/7] 请选择服务器所在区域：${NC}"
echo "1. 国内服务器 (China) - 使用阿里云/腾讯云 DNS"
echo "2. 海外服务器 (Global) - 使用 Cloudflare/Google DNS"
read -p "请输入数字 [1-2]: " REGION_CHOICE

# 初始化变量
TEST_DOMAIN=""
TEMP_DNS=""
CONF_DNS=""
CONF_FALLBACK=""

case $REGION_CHOICE in
    1)
        echo -e "\n已选择: ${GREEN}国内模式${NC}"
        TEMP_DNS="223.5.5.5"
        CONF_DNS="223.5.5.5 119.29.29.29"
        CONF_FALLBACK="114.114.114.114"
        TEST_DOMAIN="www.baidu.com"
        ;;
    2)
        echo -e "\n已选择: ${GREEN}海外模式${NC}"
        echo -e "${RED}注意：海外模式将严格禁止使用国内 DNS。${NC}"
        
        echo -e "请选择具体 DNS 方案："
        echo "1. 默认推荐 (1.1.1.1 + 8.8.8.8)"
        echo "2. 自定义输入"
        read -p "请输入选项 [1-2]: " DNS_MODE
        
        if [ "$DNS_MODE" == "2" ]; then
            read -p "请输入主 DNS IP: " CUST_DNS1
            read -p "请输入备 DNS IP: " CUST_DNS2
            CONF_DNS="$CUST_DNS1 $CUST_DNS2"
            TEMP_DNS="$CUST_DNS1"
        else
            CONF_DNS="1.1.1.1 8.8.8.8"
            TEMP_DNS="1.1.1.1"
        fi
        
        CONF_FALLBACK="8.8.4.4 1.0.0.1"
        TEST_DOMAIN="www.google.com"
        ;;
    *)
        echo -e "${RED}输入错误，脚本退出。${NC}"
        exit 1
        ;;
esac

# ===========================
# 第二步：DNSSEC 开关 (新增交互)
# ===========================
echo -e "\n${YELLOW}[2/7] DNSSEC 安全验证设置：${NC}"
echo "DNSSEC 可以防止 DNS 投毒，但如果域名配置错误会导致无法解析。"
echo "对于个人 VPS，建议关闭以提高连通性。"
read -p "是否开启 DNSSEC? (y/N, 默认 N 不开启): " DNSSEC_INPUT

CONF_DNSSEC="no" # 默认值
case "$DNSSEC_INPUT" in
    [yY][eE][sS]|[yY])
        CONF_DNSSEC="allow-downgrade"
        echo -e "已选择: ${GREEN}开启 (智能降级模式)${NC}"
        ;;
    *)
        CONF_DNSSEC="no"
        echo -e "已选择: ${GREEN}关闭 (推荐)${NC}"
        ;;
esac

# ===========================
# 第三步：紧急网络修复
# ===========================
echo -e "\n${YELLOW}[3/7] 正在修复基础网络连接...${NC}"

# 强制删除可能损坏的软连接
if [ -L "/etc/resolv.conf" ] || [ -f "/etc/resolv.conf" ]; then
    rm -f /etc/resolv.conf
fi

# 写入临时 DNS
echo "nameserver $TEMP_DNS" > /etc/resolv.conf
echo "nameserver $TEMP_DNS" >> /etc/resolv.conf

if ping -c 1 -W 2 $TEST_DOMAIN > /dev/null 2>&1; then
    echo -e "${GREEN}临时网络已连通。${NC}"
else
    echo -e "${RED}警告：临时 DNS 无法连通，尝试继续安装...${NC}"
fi

# ===========================
# 第四步：安装组件
# ===========================
echo -e "${YELLOW}[4/7] 安装 Systemd-Resolved 组件...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y systemd-resolved -qq

# ===========================
# 第五步：生成配置文件
# ===========================
echo -e "${YELLOW}[5/7] 写入 /etc/systemd/resolved.conf ...${NC}"

[ -f /etc/systemd/resolved.conf ] && cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak

# 写入配置 (代入 DNSSEC 变量)
cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=$CONF_DNS
FallbackDNS=$CONF_FALLBACK
Domains=~.
DNSSEC=$CONF_DNSSEC
DNSOverTLS=opportunistic
EOF

echo -e "配置详情: DNS=${GREEN}$CONF_DNS${NC} | DNSSEC=${GREEN}$CONF_DNSSEC${NC}"

# ===========================
# 第六步：建立 Stub 模式链接
# ===========================
echo -e "${YELLOW}[6/7] 建立标准 Stub 链接...${NC}"

rm -f /etc/resolv.conf
# 指向 stub-resolv.conf (开启 127.0.0.53 本地代理)
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# 重启服务
systemctl enable systemd-resolved --now > /dev/null 2>&1
systemctl restart systemd-resolved

if systemctl list-unit-files | grep -q systemd-networkd; then
    systemctl restart systemd-networkd
fi

# 清除缓存
systemd-resolve --flush-caches 2>/dev/null || resolvectl flush-caches

# ===========================
# 第七步：最终验证
# ===========================
echo -e "\n${YELLOW}[7/7] 最终状态验证...${NC}"

# 1. 验证文件内容
echo -e "1. 查看 /etc/resolv.conf (应显示 127.0.0.53):"
grep "nameserver" /etc/resolv.conf | head -n 1

# 2. 验证实际配置
echo -e "\n2. Systemd 实际配置状态:"
# 获取 DNSSEC 状态和 DNS 服务器
if command -v resolvectl &> /dev/null; then
    resolvectl status | grep -E "DNS Servers|DNSSEC" -A 2 | head -n 5
else
    systemd-resolve --status | grep -E "DNS Servers|DNSSEC" -A 2 | head -n 5
fi

# 3. 网络测试
echo -e "\n3. 网络连通性测试 (Target: $TEST_DOMAIN):"
if ping -c 3 $TEST_DOMAIN; then
    echo -e "\n${GREEN}===========================================${NC}"
    echo -e "${GREEN}  配置成功！  ${NC}"
    echo -e "${GREEN}  DNSSEC 状态: $CONF_DNSSEC ${NC}"
    echo -e "${GREEN}===========================================${NC}"
else
    echo -e "\n${RED}======================================${NC}"
    echo -e "${RED}      警告：配置完成但无法联网！      ${NC}"
    echo -e "${RED}======================================${NC}"
fi
