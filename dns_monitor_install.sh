#!/bin/bash

# ================= 配置区域 =================
# 【重要】请修改为你的 GitHub 用户名
GITHUB_USER_NAME="10000ge10000"
GITHUB_REPO_NAME="own-rules"
GITHUB_BRANCH="main"
# ===========================================

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

# 核心文件路径
CORE_SCRIPT="/usr/local/bin/dns_monitor.sh"
CONFIG_DIR="/etc/autodns"
CONFIG_FILE="${CONFIG_DIR}/config.env"
LOCK_FILE="/tmp/dns_monitor_backoff"

# 检查 Root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}错误: 请使用 sudo 或 root 权限运行此脚本${NC}"
        exit 1
    fi
}

# --- 功能函数：安装 ---
install_monitor() {
    echo -e "${GREEN}>>> 开始安装/更新 DNS 自动切换监控...${NC}"

    # 1. 安装依赖
    if ! command -v curl &> /dev/null; then
        echo "正在安装 curl..."
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y curl
        elif [ -f /etc/redhat-release ]; then
            yum install -y curl
        fi
    fi

    # 2. 获取 IP
    echo "正在获取本机公网 IP..."
    SERVER_IP=$(curl -s ifconfig.me)
    [ -z "$SERVER_IP" ] && SERVER_IP="未知IP"
    echo -e "检测到 IP: ${YELLOW}$SERVER_IP${NC}"

    # 3. 交互配置
    echo "------------------------------------------------"
    echo -e "${YELLOW}请配置参数：${NC}"
    
    read -p "1. 服务器备注 (例如 HK-Node-1): " SERVER_REMARK
    SERVER_REMARK=${SERVER_REMARK:-"未命名服务器"}

    read -p "2. 目标域名 (回车默认 www.google.com): " TARGET_DOMAIN
    TARGET_DOMAIN=${TARGET_DOMAIN:-"www.google.com"}

    read -p "3. 延迟阈值 ms (回车默认 10): " LATENCY_THRESHOLD
    LATENCY_THRESHOLD=${LATENCY_THRESHOLD:-10}

    echo -e "\n--- Telegram 配置 ---"
    read -p "4. Bot Token: " TG_BOT_TOKEN
    read -p "5. Chat ID: " TG_CHAT_ID

    echo -e "\n--- DNS 配置 ---"
    echo "默认备选池: 8.8.4.4, 1.0.0.1, 8.8.8.8, 1.1.1.1"
    read -p "6. 额外 DNS (空格分隔，回车跳过): " EXTRA_DNS_LIST

    # 4. 写入配置
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
SERVER_REMARK="$SERVER_REMARK"
SERVER_IP="$SERVER_IP"
TARGET_DOMAIN="$TARGET_DOMAIN"
LATENCY_THRESHOLD=$LATENCY_THRESHOLD
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EXTRA_DNS_LIST="$EXTRA_DNS_LIST"
EOF
    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}>>> 配置已保存。${NC}"

    # 5. 下载核心脚本
    echo "正在下载核心脚本..."
    DOWNLOAD_URL="https://raw.githubusercontent.com/${GITHUB_USER_NAME}/${GITHUB_REPO_NAME}/${GITHUB_BRANCH}/dns_monitor.sh"
    curl -sL "$DOWNLOAD_URL" -o "$CORE_SCRIPT"

    if [ ! -s "$CORE_SCRIPT" ]; then
        echo -e "${RED}下载失败！请检查 GITHUB_USER_NAME 是否正确。${NC}"
        exit 1
    fi
    chmod +x "$CORE_SCRIPT"

    # 6. 设置 Crontab
    CRON_JOB="* * * * * $CORE_SCRIPT >/dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "$CORE_SCRIPT"; echo "$CRON_JOB") | crontab -

    # 7. 清理可能存在的冷却锁，确保立即生效
    rm -f "$LOCK_FILE"

    echo -e "${GREEN}✅ 安装完成！脚本已开始在后台运行。${NC}"
}

# --- 功能函数：卸载 ---
uninstall_monitor() {
    echo -e "${YELLOW}>>> 正在卸载...${NC}"

    # 1. 移除定时任务
    (crontab -l 2>/dev/null | grep -v "$CORE_SCRIPT") | crontab -
    echo "√ 定时任务已移除"

    # 2. 删除文件
    rm -f "$CORE_SCRIPT"
    rm -rf "$CONFIG_DIR"
    rm -f "$LOCK_FILE"
    
    echo "√ 文件已清理"
    echo -e "${GREEN}✅ 卸载成功。${NC}"
}

# --- 主菜单 ---
show_menu() {
    clear
    echo -e "${SKYBLUE}========================================${NC}"
    echo -e "${SKYBLUE}    Auto DNS Monitor 管理脚本${NC}"
    echo -e "${SKYBLUE}========================================${NC}"
    echo -e "1. 安装 / 更新 / 修改配置"
    echo -e "2. 卸载脚本"
    echo -e "0. 退出"
    echo "----------------------------------------"
    read -p "请输入选项 [0-2]: " choice

    case "$choice" in
        1)
            check_root
            install_monitor
            ;;
        2)
            check_root
            uninstall_monitor
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项${NC}"
            exit 1
            ;;
    esac
}

# 运行菜单
show_menu
