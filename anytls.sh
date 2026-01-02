#!/bin/bash

# ====================================================
# AnyTLS-Go 管理脚本 (V3.5 路径兼容版)
# 修复: 解决 "No such file" 路径缓存报错问题
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
# 1. 核心源 (官方仓库)
REPO="anytls/anytls-go"

# 2. 脚本源 (用于修复快捷指令)
SCRIPT_URL="https://raw.githubusercontent.com/10000ge10000/AnyTLS-Go/main/anytls.sh"

# 目录与文件
INSTALL_DIR="/opt/anytls"
CONFIG_DIR="/etc/anytls"
CONFIG_FILE="${CONFIG_DIR}/server.conf"
SERVICE_FILE="/etc/systemd/system/anytls.service"

# --- 辅助函数 ---
print_info() { echo -e "${CYAN}➜${PLAIN} $1"; }
print_ok()   { echo -e "${GREEN}✔${PLAIN} $1"; }
print_err()  { echo -e "${RED}✖${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}⚡${PLAIN} $1"; }
print_line() { echo -e "${CYAN}──────────────────────────────────────────────────────────${PLAIN}"; }

# --- 1. 系统检查 ---
check_sys() {
    [[ $EUID -ne 0 ]] && print_err "请使用 root 运行" && exit 1
    if [ -f /etc/redhat-release ]; then RELEASE="centos"; else RELEASE="debian"; fi
}

install_deps() {
    if ! command -v curl &> /dev/null || ! command -v unzip &> /dev/null || ! command -v jq &> /dev/null; then
        print_info "安装依赖 (curl, unzip, jq, iptables)..."
        if [[ "${RELEASE}" == "centos" ]]; then
            yum install -y curl unzip jq net-tools iptables-services >/dev/null 2>&1
        else
            apt update >/dev/null 2>&1
            apt install -y curl unzip jq net-tools iptables-persistent >/dev/null 2>&1
        fi
    fi
}

# --- 2. 创建快捷指令 (双路兼容修复) ---
create_shortcut() {
    print_info "正在生成快捷指令 'anytls'..."
    
    # 下载脚本内容
    wget -qO "/usr/bin/anytls" "$SCRIPT_URL"
    
    # 检查下载是否成功
    if [[ ! -s "/usr/bin/anytls" ]]; then
        print_warn "在线获取失败，使用本地文件作为替补..."
        cp -f "$0" "/usr/bin/anytls"
    fi

    # 赋予权限
    chmod +x "/usr/bin/anytls"

    # 【关键修复】同时复制到 /usr/local/bin 以解决路径缓存报错
    cp -f "/usr/bin/anytls" "/usr/local/bin/anytls"
    chmod +x "/usr/local/bin/anytls"

    print_ok "快捷指令创建成功！(兼容 /usr/bin 和 /usr/local/bin)"
}

# --- 3. 核心安装 ---
install_core() {
    print_info "获取最新版本信息 (来自官方)..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) FILE_ARCH="amd64" ;;
        aarch64|arm64) FILE_ARCH="arm64" ;;
        *) print_err "不支持架构: $ARCH"; exit 1 ;;
    esac

    # 自动获取
    LATEST_JSON=$(curl -s "https://api.github.com/repos/$REPO/releases/latest")
    LATEST_VERSION=$(echo "$LATEST_JSON" | jq -r .tag_name 2>/dev/null)
    
    # 兜底逻辑
    if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
        TAGS_JSON=$(curl -s "https://api.github.com/repos/$REPO/tags")
        LATEST_VERSION=$(echo "$TAGS_JSON" | jq -r '.[0].name' 2>/dev/null)
    fi

    if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
        print_warn "无法自动获取版本 (可能网络受限)"
        read -p "   请手动输入版本号 [例如 v0.0.11]: " MANUAL_VERSION
        [[ -z "$MANUAL_VERSION" ]] && print_err "未输入版本，退出" && exit 1
        LATEST_VERSION=$MANUAL_VERSION
    fi

    CLEAN_VER=${LATEST_VERSION#v}
    FILENAME="anytls_${CLEAN_VER}_linux_${FILE_ARCH}.zip"
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/${LATEST_VERSION}/${FILENAME}"

    print_info "正在下载: ${GREEN}$LATEST_VERSION${PLAIN}..."
    
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
    cd /tmp
    curl -L -o "$FILENAME" "$DOWNLOAD_URL"
    
    if [[ $? -ne 0 ]]; then 
        print_err "下载失败！请检查版本号或网络。"
        rm -f "$FILENAME"
        exit 1
    fi

    unzip -o -q "$FILENAME" -d "anytls_tmp"
    if [[ -f "anytls_tmp/anytls-server" ]]; then
        systemctl stop anytls 2>/dev/null
        mv anytls_tmp/anytls-server "$INSTALL_DIR/"
        mv anytls_tmp/anytls-client "$INSTALL_DIR/" 2>/dev/null
        chmod +x "$INSTALL_DIR/anytls-server"
        rm -rf "$FILENAME" "anytls_tmp"
        print_ok "核心安装完成"
    else
        print_err "解压异常，未找到二进制文件"
        rm -rf "$FILENAME" "anytls_tmp"
        exit 1
    fi
}

# --- 4. 系统优化 ---
optimize_sysctl() {
    print_info "优化内核参数 (BBR + TCP)..."
    if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sed -i '/net.ipv4.tcp_window_scaling/d' /etc/sysctl.conf
    echo "net.ipv4.tcp_window_scaling = 1" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
}

check_port() {
    if [[ -n $(ss -tunlp | grep ":${1} " | grep -E "tcp|udp") ]]; then return 1; else return 0; fi
}

# --- 5. 交互配置 ---
configure() {
    clear
    print_line
    echo -e " ${BOLD}AnyTLS-Go 配置向导${PLAIN}"
    print_line

    # 1. 端口
    while true; do
        read -p "$(echo -e "${CYAN}::${PLAIN} 监听端口 [回车默认 8443]: ")" PORT
        [[ -z "${PORT}" ]] && PORT=8443
        if check_port $PORT; then echo -e "   ➜ 使用端口: ${GREEN}$PORT${PLAIN}"; break; else print_err "端口被占用，请更换"; fi
    done

    # 2. 密码
    echo ""
    read -p "$(echo -e "${CYAN}::${PLAIN} 连接密码 [回车随机生成]: ")" PASSWORD
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
        echo -e "   ➜ 随机密码: ${GREEN}$PASSWORD${PLAIN}"
    fi

    # 写入配置 (仅供脚本读取状态用)
    cat > "$CONFIG_FILE" << EOF
LISTEN_ADDR="0.0.0.0:${PORT}"
PASSWORD="${PASSWORD}"
EOF

    # 写入 Systemd
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=AnyTLS-Go Server
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${PORT} -p "${PASSWORD}"
Restart=always
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# --- 6. 防火墙 ---
apply_firewall() {
    source "$CONFIG_FILE" 2>/dev/null
    PORT=${LISTEN_ADDR##*:}
    
    print_info "配置防火墙规则..."
    if [[ "${RELEASE}" == "centos" ]]; then
        firewall-cmd --zone=public --add-port=$PORT/tcp --add-port=$PORT/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    else
        iptables -I INPUT -p tcp --dport $PORT -j ACCEPT
        iptables -I INPUT -p udp --dport $PORT -j ACCEPT
        if [ -f /etc/debian_version ]; then
            netfilter-persistent save >/dev/null 2>&1
        else
            service iptables save >/dev/null 2>&1
        fi
    fi
}

# --- 7. 启动并自检 ---
start_and_check() {
    systemctl enable anytls >/dev/null 2>&1
    systemctl restart anytls
    sleep 2
    if systemctl is-active --quiet anytls; then
        return 0
    else
        echo -e ""
        print_err "服务启动失败！以下是错误日志："
        echo -e "${YELLOW}------------------------------------------------${PLAIN}"
        journalctl -u anytls -n 20 --no-pager
        echo -e "${YELLOW}------------------------------------------------${PLAIN}"
        return 1
    fi
}

# --- 8. 结果展示 ---
show_result() {
    if [[ ! -f "$CONFIG_FILE" ]]; then print_err "未找到配置"; return; fi

    source "$CONFIG_FILE"
    PORT=${LISTEN_ADDR##*:}
    
    if ! systemctl is-active --quiet anytls; then
        print_warn "警告：服务未运行。"
    fi

    IPV4=$(curl -s4m3 https://api.ipify.org)
    IPV6=$(curl -s6m3 https://api64.ipify.org)

    clear
    print_line
    echo -e "${BOLD}               AnyTLS-Go 配置详情${PLAIN}"
    print_line
    
    echo -e "${BOLD} [基本信息]${PLAIN}"
    echo -e "  监听端口 : ${GREEN}${PORT}${PLAIN}"
    echo -e "  连接密码 : ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "  监听地址 : ${CYAN}${LISTEN_ADDR}${PLAIN}"

    echo -e ""
    print_line
    echo -e "${BOLD} 🚀 连接链接${PLAIN}"
    echo -e ""
    
    HAS_LINK=false
    if [[ -n "$IPV4" ]]; then
        LINK4="anytls://${PASSWORD}@${IPV4}:${PORT}"
        echo -e "  ${BOLD}IPv4 链接:${PLAIN}"
        echo -e "  ${CYAN}${LINK4}${PLAIN}"
        echo ""
        HAS_LINK=true
    fi

    if [[ -n "$IPV6" ]]; then
        LINK6="anytls://${PASSWORD}@[${IPV6}]:${PORT}"
        echo -e "  ${BOLD}IPv6 链接:${PLAIN}"
        echo -e "  ${GREEN}${LINK6}${PLAIN}"
        echo ""
        HAS_LINK=true
    fi

    if [[ "$HAS_LINK" == "false" ]]; then
        print_err "无法获取公网 IP，请检查网络。"
    fi
    print_line
}

uninstall() {
    print_warn "正在卸载 AnyTLS-Go..."
    systemctl stop anytls
    systemctl disable anytls
    rm -f "$SERVICE_FILE" "/usr/bin/anytls" "/usr/local/bin/anytls"
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
    systemctl daemon-reload
    print_ok "卸载完成"
}

# --- 9. 菜单系统 ---
show_menu() {
    clear
    if systemctl is-active --quiet anytls; then
        STATUS="${GREEN}运行中${PLAIN}"
        PID=$(systemctl show -p MainPID anytls | cut -d= -f2)
        MEM=$(ps -o rss= -p $PID 2>/dev/null | awk '{printf "%.1fMB", $1/1024}')
    else
        STATUS="${RED}未运行${PLAIN}"
        PID="N/A"
        MEM="0MB"
    fi

    print_line
    echo -e "${BOLD}         AnyTLS-Go 管理面板 ${YELLOW}[V3.5]${PLAIN}"
    print_line
    echo -e "  状态: ${STATUS}  |  PID: ${YELLOW}${PID}${PLAIN}  |  内存: ${YELLOW}${MEM}${PLAIN}"
    print_line
    echo -e "  ${GREEN}1.${PLAIN}  全新安装 / 重置配置"
    echo -e "  ${GREEN}2.${PLAIN}  查看配置 / 导出链接"
    echo -e "  ${GREEN}3.${PLAIN}  查看实时日志"
    print_line
    echo -e "  ${YELLOW}4.${PLAIN}  启动服务"
    echo -e "  ${YELLOW}5.${PLAIN}  停止服务"
    echo -e "  ${YELLOW}6.${PLAIN}  重启服务"
    print_line
    echo -e "  ${RED}8.${PLAIN}  卸载程序"
    echo -e "  ${RED}0.${PLAIN}  退出"
    print_line
    
    read -p "  请输入选项 [0-8]: " num
    case "$num" in
        1) check_sys; install_deps; optimize_sysctl; install_core; configure; apply_firewall
           create_shortcut # 关键修复点
           start_and_check && show_result ;;
        2) [[ ! -f "$CONFIG_FILE" ]] && return; show_result; read -p "  按回车键返回菜单..." ; show_menu ;;
        3) echo -e "${CYAN}Ctrl+C 退出日志${PLAIN}"; journalctl -u anytls -f ;;
        4) start_and_check; read -p "按回车继续..."; show_menu ;;
        5) systemctl stop anytls; print_warn "已停止"; sleep 1; show_menu ;;
        6) start_and_check; read -p "按回车继续..."; show_menu ;;
        8) uninstall; exit 0 ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

if [[ $# > 0 ]]; then show_menu; else show_menu; fi
