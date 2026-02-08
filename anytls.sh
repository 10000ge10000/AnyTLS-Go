#!/bin/bash

# ====================================================
# AnyTLS-Go OpenClash 优化版
# ====================================================

# --- 视觉与颜色 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 全局变量 ---
REPO="anytls/anytls-go"
SCRIPT_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main/anytls.sh"

INSTALL_DIR="/opt/anytls"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/anytls.service"
SHORTCUT_BIN="/usr/bin/anytls"
GAI_CONF="/etc/gai.conf"

# --- 辅助函数 ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
print_info() { echo -e "${CYAN}➜${PLAIN} $1"; }
print_ok()   { echo -e "${GREEN}✔${PLAIN} $1"; }
print_err()  { echo -e "${RED}✖${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}⚡${PLAIN} $1"; }
print_line() { echo -e "${CYAN}──────────────────────────────────────────────${PLAIN}"; }

# --- 1. 系统检查 ---
check_sys() {
    [[ $EUID -ne 0 ]] && print_err "请使用 root 运行" && exit 1
    if [ -f /etc/alpine-release ]; then
        RELEASE="alpine"
    elif [ -f /etc/redhat-release ]; then
        RELEASE="centos"
    else
        RELEASE="debian"
    fi
}

# --- 2. 依赖安装 ---
install_deps() {
    CMD_INSTALL=""
    if command -v apt-get &>/dev/null; then
        CMD_INSTALL="apt-get install -y"
        apt-get update >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        CMD_INSTALL="yum install -y"
    else
        print_err "未识别的系统"
        exit 1
    fi
    $CMD_INSTALL curl unzip jq net-tools iptables >/dev/null 2>&1
}

# --- 3. 快捷指令 ---
create_shortcut() {
    if [[ -f "$0" ]]; then
        cp -f "$0" "$SHORTCUT_BIN"
    else
        wget -qO "$SHORTCUT_BIN" "$SCRIPT_URL"
    fi
    chmod +x "$SHORTCUT_BIN"
    cp -f "$SHORTCUT_BIN" "/usr/local/bin/anytls" >/dev/null 2>&1
    chmod +x "/usr/local/bin/anytls"
}

# --- 4. 核心安装 (记录版本号) ---
install_core() {
    clear
    print_line
    echo -e " ${BOLD}AnyTLS-Go 安装向导${PLAIN}"
    print_line
    
    print_info "获取最新版本..."
    LATEST_JSON=$(curl -sL -H "User-Agent: Mozilla/5.0" "https://api.github.com/repos/$REPO/releases/latest")
    
    if [[ -z "$LATEST_JSON" ]] || echo "$LATEST_JSON" | grep -q "API rate limit"; then
         print_err "GitHub API 受限。"
         exit 1
    fi
    
    TARGET_VERSION=$(echo "$LATEST_JSON" | jq -r .tag_name)
    print_info "最新版本: ${GREEN}${TARGET_VERSION}${PLAIN}"

    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) KW_ARCH="amd64" ;;
        aarch64|arm64) KW_ARCH="arm64" ;;
        *) print_err "不支持架构: $ARCH"; exit 1 ;;
    esac

    print_info "下载中..."
    ALL_URLS=$(echo "$LATEST_JSON" | jq -r '.assets[].browser_download_url')
    DOWNLOAD_URL=$(echo "$ALL_URLS" | grep -i "linux" | grep -i "$KW_ARCH" | grep -i ".zip" | head -n 1)

    if [[ -z "$DOWNLOAD_URL" ]]; then
        print_err "未找到适配的下载包！"
        exit 1
    fi

    wget -q --show-progress -O "/tmp/anytls.zip" "$DOWNLOAD_URL"
    if [[ ! -s "/tmp/anytls.zip" ]]; then print_err "下载失败"; exit 1; fi

    print_info "解压安装..."
    rm -rf /tmp/anytls_extract
    mkdir -p /tmp/anytls_extract
    unzip -q /tmp/anytls.zip -d /tmp/anytls_extract
    
    FOUND_BIN=$(find /tmp/anytls_extract -type f -name "anytls-server" | head -n 1)
    
    if [[ -z "$FOUND_BIN" ]]; then
        print_err "安装包异常，未找到文件！"
        exit 1
    fi

    systemctl stop anytls 2>/dev/null
    mkdir -p "$INSTALL_DIR"
    cp -f "$FOUND_BIN" "$INSTALL_DIR/anytls-server"
    chmod +x "$INSTALL_DIR/anytls-server"
    
    # 记录安装的版本号到本地文件
    echo "$TARGET_VERSION" > "$VERSION_FILE"
    
    rm -rf /tmp/anytls.zip /tmp/anytls_extract

    mkdir -p "$CONFIG_DIR"
    print_ok "核心安装完成 ($TARGET_VERSION)"
}

# --- 5. 系统优化 ---
optimize_sysctl() {
    print_info "正在优化 TCP/内核网络参数 (针对多路复用)..."
    
    # 备份
    if [[ ! -f /etc/sysctl.conf.bak ]]; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak
    fi

    # 定义优化参数
    cat > /etc/sysctl.d/99-anytls.conf <<EOF
# --- AnyTLS Optimization ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 16384 8388608
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 4096
# ---------------------------
EOF

    # 移除旧的重复设置 (如果存在于 sysctl.conf)
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf

    # 应用
    sysctl -p /etc/sysctl.d/99-anytls.conf >/dev/null 2>&1
    sysctl --system >/dev/null 2>&1
    print_ok "网络优化已应用"
}

check_port() {
    local port=$1
    # 优先使用 ss 命令，fallback 到 netstat
    if command -v ss &>/dev/null; then
        if ss -tunlp 2>/dev/null | grep -q ":${port} "; then return 1; fi
    elif command -v netstat &>/dev/null; then
        if netstat -tunlp 2>/dev/null | grep -q ":${port} "; then return 1; fi
    fi
    return 0
}

# --- 6. 交互配置 ---
configure() {
    clear
    print_line
    echo -e " ${BOLD}配置向导${PLAIN}"
    print_line

    # 1. 端口
    while true; do
        read -p "$(echo -e "${CYAN}::${PLAIN} 监听端口 [回车默认 9527]: ")" PORT
        [[ -z "${PORT}" ]] && PORT=9527
        if check_port $PORT; then echo -e "   ➜ 使用端口: ${GREEN}$PORT${PLAIN}"; break; else print_err "端口被占用"; fi
    done

    # 2. 密码
    echo ""
    read -p "$(echo -e "${CYAN}::${PLAIN} 连接密码 [回车随机生成]: ")" PASSWORD
    if [[ -z "${PASSWORD}" ]]; then
        PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
        echo -e "   ➜ 随机密码: ${GREEN}$PASSWORD${PLAIN}"
    fi

    # 3. IP 策略交互
    echo ""
    echo -e " ${BOLD}出站 IP 策略 (VPS侧)${PLAIN}"
    echo -e " 1. ${GREEN}IPv4 优先${PLAIN} (推荐，兼容性好)"
    echo -e " 2. ${CYAN}IPv6 优先${PLAIN} (系统默认)"
    read -p " 请选择 [1-2] (默认 1): " IP_CHOICE
    [[ -z "$IP_CHOICE" ]] && IP_CHOICE=1

    apply_ip_preference "$IP_CHOICE"

    # 保存配置 (设置安全权限)
    cat > "$CONFIG_FILE" << EOF
PORT="${PORT}"
PASSWORD="${PASSWORD}"
EOF
    chmod 600 "$CONFIG_FILE"

    # 写入 Systemd
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS-Go Server
After=network.target

[Service]
Type=simple
User=root
# 提高进程优先级 (Nice=-10, 高优)
Nice=-10
# 批量处理调度策略
CPUSchedulingPolicy=batch
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${PORT} -p "${PASSWORD}"
Restart=always
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# --- 7. 防火墙 ---
apply_firewall() {
    source "$CONFIG_FILE" 2>/dev/null
    [[ -z "$PORT" ]] && return
    
    print_info "配置防火墙..."
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --zone=public --add-port=${PORT}/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=${PORT}/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
        iptables -I INPUT -p udp --dport ${PORT} -j ACCEPT
        if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save >/dev/null 2>&1; fi
    fi
}

start_and_check() {
    systemctl enable anytls >/dev/null 2>&1
    systemctl restart anytls
    sleep 2
    if systemctl is-active --quiet anytls; then return 0; else
        echo ""
        print_err "启动失败！日志如下："
        journalctl -u anytls -n 20 --no-pager
        return 1
    fi
}

# --- 8. 结果展示 ---
show_result() {
    if [[ ! -f "$CONFIG_FILE" ]]; then print_err "未找到配置"; return; fi
    source "$CONFIG_FILE"
    
    IPV4=$(curl -s4m8 https://api.ipify.org)
    [[ -z "$IPV4" ]] && IPV4=$(curl -s4m8 https://ifconfig.me)
    [[ -z "$IPV4" ]] && IPV4="无法获取IPv4"
    IPV6=$(curl -s6m8 https://api64.ipify.org)
    
    PARAMS="sni=www.bing.com&insecure=1"
    LINK="anytls://${PASSWORD}@${IPV4}:${PORT}?${PARAMS}#AnyTLS"

    clear
    print_line
    echo -e "       AnyTLS 配置详情"
    print_line
    echo -e " IP: ${GREEN}${IPV4}${PLAIN}"
    echo ""
    
    echo -e "${BOLD} 🔗 导出链接${PLAIN}"
    echo -e "${CYAN}${LINK}${PLAIN}"
    echo ""
    
    echo -e "${BOLD} 📝 OpenClash 填空指引${PLAIN}"
    echo -e "┌─────────────────────┬──────────────────────────────────────┐"
    echo -e "│ 选项                │ 推荐填入值                           │"
    echo -e "├─────────────────────┼──────────────────────────────────────┤"
    printf "│ 服务器地址          │ %-36s │\n" "${IPV4}"
    printf "│ 端口                │ %-36s │\n" "${PORT}"
    printf "│ 密码                │ %-36s │\n" "${PASSWORD}"
    printf "│ UDP 支持            │ %-36s │\n" "true"
    printf "│ 跳过证书验证        │ %-36s │\n" "true"
    printf "│ SNI                 │ %-36s │\n" "www.bing.com"
    printf "│ ALPN                │ %-36s │\n" "h2, http/1.1"
    printf "│ 客户端指纹          │ %-36s │\n" "chrome"
    echo -e "└─────────────────────┴──────────────────────────────────────┘"
    echo ""
    
    echo -e "${BOLD} 📋 OpenClash 配置文件 (YAML)${PLAIN}"
    echo -e "${GREEN}"
    cat << EOF
  - name: "AnyTLS"
    type: anytls
    server: "${IPV4}"
    port: ${PORT}
    password: "${PASSWORD}"
    sni: "www.bing.com"
    skip-cert-verify: true
    udp: true
    alpn:
      - h2
      - http/1.1
    client-fingerprint: chrome
    idle-session-check-interval: 30
    idle-session-timeout: 60
EOF
    echo -e "${PLAIN}"
    print_line
}

# --- 9. IP 策略逻辑 ---
apply_ip_preference() {
    local choice=$1
    if [[ ! -f "$GAI_CONF" ]]; then
        cat > "$GAI_CONF" <<EOF
label  ::1/128       0
label  ::/0          1
label  2002::/16     2
label ::/96          3
label ::ffff:0:0/96  4
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence ::/96          20
precedence ::ffff:0:0/96  10
EOF
    fi

    if [[ "$choice" == "1" ]]; then
        if grep -q "^precedence ::ffff:0:0/96" "$GAI_CONF"; then
            sed -i 's/^precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' "$GAI_CONF"
        else
            echo "precedence ::ffff:0:0/96  100" >> "$GAI_CONF"
        fi
        print_ok "已设置: 优先使用 IPv4"
    else
        if grep -q "^precedence ::ffff:0:0/96" "$GAI_CONF"; then
            sed -i 's/^precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  10/' "$GAI_CONF"
        else
            echo "precedence ::ffff:0:0/96  10" >> "$GAI_CONF"
        fi
        print_ok "已恢复: 系统默认 (IPv6 优先)"
    fi
}

set_ip_menu() {
    clear
    print_line
    echo -e " ${BOLD}出站 IP 优先级设置${PLAIN}"
    print_line
    if grep -q "^precedence ::ffff:0:0/96.*100" "$GAI_CONF" 2>/dev/null; then
        CURRENT_STATUS="${GREEN}IPv4 优先${PLAIN}"
    else
        CURRENT_STATUS="${CYAN}IPv6 优先 (默认)${PLAIN}"
    fi
    echo -e " 当前状态: ${CURRENT_STATUS}"
    echo ""
    echo -e " 1. 强制 ${GREEN}IPv4${PLAIN} 优先"
    echo -e " 2. 恢复 ${CYAN}IPv6${PLAIN} 优先 (默认)"
    print_line
    read -p " 请选择 [1-2]: " choice
    case "$choice" in
        1|2) apply_ip_preference "$choice" ;;
        *) print_err "无效输入" ;;
    esac
    print_warn "即时生效，无需重启服务。"
    read -p "按回车返回..."
}

# --- 10. 内核升级逻辑 ---
update_kernel() {
    print_info "正在检查新版本..."
    
    # 获取本地版本
    if [[ -f "$VERSION_FILE" ]]; then
        LOCAL_VER=$(cat "$VERSION_FILE")
    else
        LOCAL_VER="未知/未安装"
    fi

    # 获取远程版本
    LATEST_JSON=$(curl -sL --max-time 5 "https://api.github.com/repos/$REPO/releases/latest")
    REMOTE_VER=$(echo "$LATEST_JSON" | jq -r .tag_name 2>/dev/null)

    if [[ -z "$REMOTE_VER" || "$REMOTE_VER" == "null" ]]; then
        print_err "无法获取最新版本信息。"
        read -p "按回车返回..."
        return
    fi

    print_line
    echo -e " 当前版本: ${YELLOW}${LOCAL_VER}${PLAIN}"
    echo -e " 最新版本: ${GREEN}${REMOTE_VER}${PLAIN}"
    print_line

    if [[ "$LOCAL_VER" == "$REMOTE_VER" ]]; then
        print_ok "当前已是最新版本。"
        read -p "按回车返回..."
        return
    fi

    read -p " 发现新版本，是否立即升级? [y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        install_core
        # 升级后重启服务
        if systemctl is-active --quiet anytls; then
            systemctl restart anytls
            print_ok "服务已重启"
        fi
        read -p "升级完成，按回车返回..." 
    else
        print_info "已取消"
    fi
}

# --- 11. 菜单系统 ---
show_menu() {
    clear
    # 状态检测
    if systemctl is-active --quiet anytls; then
        STATUS="${GREEN}● 运行中${PLAIN}"
        PID=$(systemctl show -p MainPID anytls | cut -d= -f2)
    else
        STATUS="${RED}● 已停止${PLAIN}"
        PID="N/A"
    fi

    # 预读版本信息 (静默获取，超时跳过)
    if [[ -f "$VERSION_FILE" ]]; then
        LOCAL_V=$(cat "$VERSION_FILE")
    else
        LOCAL_V="未安装"
    fi
    
    # 异步或简单获取远程版本（为了菜单响应速度，这里做简单展示，详情在选项7中）
    # 为了菜单对齐，这里只显示本地，进入选项7再联网检查
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "           ${BOLD}AnyTLS-Go 管理面板${PLAIN}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e " 运行状态 : ${STATUS}"
    echo -e " 进程 PID : ${YELLOW}${PID}${PLAIN}"
    echo -e " 内核版本 : ${YELLOW}${LOCAL_V}${PLAIN}"
    echo -e "${CYAN}────────────────────────────────────────${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN}  安装 / 重置"
    echo -e "  ${GREEN}2.${PLAIN}  查看配置"
    echo -e "  ${GREEN}3.${PLAIN}  查看日志"
    echo -e ""
    echo -e "  ${GREEN}4.${PLAIN}  启动服务"
    echo -e "  ${GREEN}5.${PLAIN}  停止服务"
    echo -e "  ${GREEN}6.${PLAIN}  重启服务"
    echo -e ""
    # 动态版本显示占位，进入选项后详细检查
    echo -e "  ${GREEN}7.${PLAIN}  内核升级 (检测更新)"
    echo -e "  ${YELLOW}9.${PLAIN}  出站 IP 偏好设置"
    echo -e "  ${RED}8.${PLAIN}  卸载程序"
    echo -e "  ${RED}0.${PLAIN}  退出脚本"
    echo -e "${CYAN}────────────────────────────────────────${PLAIN}"
    
    read -p " 请输入选项: " num
    case "$num" in
        1) check_sys; install_deps; optimize_sysctl; install_core; configure; apply_firewall
           create_shortcut
           start_and_check && show_result ;;
        2) [[ ! -f "$CONFIG_FILE" ]] && return; show_result; read -p "按回车返回..." ; show_menu ;;
        3) journalctl -u anytls -f ;;
        4) start_and_check; read -p "按回车继续..."; show_menu ;;
        5) systemctl stop anytls; print_warn "服务已停止"; sleep 1; show_menu ;;
        6) start_and_check; read -p "按回车继续..."; show_menu ;;
        7) update_kernel; show_menu ;;
        9) set_ip_menu; show_menu ;;
        8) uninstall; exit 0 ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

uninstall() {
    echo ""
    read -p " 确定要卸载 AnyTLS 吗? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && show_menu && return
    
    systemctl stop anytls
    systemctl disable anytls
    rm -f "$SERVICE_FILE" "/usr/bin/anytls" "/usr/local/bin/anytls"
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
    systemctl daemon-reload
    print_ok "卸载完成。"
    exit 0
}

run_install() {
    check_sys; install_deps; optimize_sysctl; install_core; create_shortcut; configure; apply_firewall; start_and_check && show_result
}

if [[ -f "$CONFIG_FILE" && "$1" != "install" ]]; then show_menu; else run_install; fi
