#!/bin/bash

# ====================================================
# Shadowsocks-Rust OpenClash 优化版
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
REPO="shadowsocks/shadowsocks-rust"

# 脚本源
SCRIPT_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main/ss2022.sh"

# 目录与文件
INSTALL_DIR="/opt/ss-rust"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"
SHORTCUT_BIN="/usr/bin/ss"
SHORTCUT_LOCAL_BIN="/usr/local/bin/ss"

# --- 辅助函数 ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
print_info() { echo -e "${CYAN}➜${PLAIN} $1"; }
print_ok()   { echo -e "${GREEN}✔${PLAIN} $1"; }
print_err()  { echo -e "${RED}✖${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}⚡${PLAIN} $1"; }
print_line() { echo -e "${CYAN}──────────────────────────────────────────────────────────${PLAIN}"; }

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

# --- 安装依赖 (前台模式) ---
install_deps() {
    if ! command -v curl &> /dev/null || ! command -v tar &> /dev/null || ! command -v xz &> /dev/null || ! command -v jq &> /dev/null || ! command -v netstat &> /dev/null; then
        print_info "安装依赖 (curl, tar, xz, jq, net-tools)..."
        # 已移除 >/dev/null 2>&1
        if [[ "${RELEASE}" == "centos" ]]; then
            yum install -y curl wget tar xz jq net-tools iptables-services
        else
            apt update
            apt install -y curl wget tar xz-utils jq net-tools iptables-persistent
        fi
    fi
}

# --- 2. 创建快捷指令 (修复版) ---
create_shortcut() {
    print_info "正在配置快捷指令 'ss'..."
    
    # 强制覆盖逻辑：
    # 1. 优先尝试复制当前执行脚本 ($0)
    # 2. 如果无法获取当前脚本，则在线拉取
    
    if [[ -f "$0" ]]; then
        cp -f "$0" "$SHORTCUT_BIN"
        cp -f "$0" "$SHORTCUT_LOCAL_BIN"
    else
        print_warn "正在从网络拉取脚本..."
        wget -qO "$SHORTCUT_BIN" "$SCRIPT_URL"
        wget -qO "$SHORTCUT_LOCAL_BIN" "$SCRIPT_URL"
    fi

    # 赋予权限并检查
    chmod +x "$SHORTCUT_BIN"
    chmod +x "$SHORTCUT_LOCAL_BIN"

    if [[ -s "$SHORTCUT_BIN" ]]; then
        print_ok "快捷指令创建成功！(覆盖 /usr/bin/ss)"
    else
        print_err "快捷指令创建可能失败，请检查。"
    fi
}

# --- 3. 核心安装 ---
install_core() {
    print_info "获取最新版本信息 (来自官方)..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) FILE_ARCH="x86_64" ;;
        aarch64|arm64) FILE_ARCH="aarch64" ;;
        *) print_err "不支持架构: $ARCH"; exit 1 ;;
    esac

    LATEST_JSON=$(curl -s "https://api.github.com/repos/$REPO/releases/latest")
    LATEST_VERSION=$(echo "$LATEST_JSON" | jq -r .tag_name 2>/dev/null)
    
    if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
        TAGS_JSON=$(curl -s "https://api.github.com/repos/$REPO/tags")
        LATEST_VERSION=$(echo "$TAGS_JSON" | jq -r '.[0].name' 2>/dev/null)
    fi

    if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
        print_warn "无法自动获取版本 (可能网络受限)"
        read -p "   请手动输入版本号 [例如 v1.15.3]: " MANUAL_VERSION
        [[ -z "$MANUAL_VERSION" ]] && print_err "未输入版本，退出" && exit 1
        LATEST_VERSION=$MANUAL_VERSION
    fi

    FILENAME="shadowsocks-${LATEST_VERSION}.${FILE_ARCH}-unknown-linux-gnu.tar.xz"
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

    print_info "正在解压安装..."
    tar -xf "$FILENAME" -C "$INSTALL_DIR"
    
    if [[ -f "$INSTALL_DIR/ssserver" ]]; then
        systemctl stop shadowsocks-rust 2>/dev/null
        chmod +x "$INSTALL_DIR/ssserver"
        rm -f "$FILENAME"
        print_ok "核心安装完成"
    else
        print_err "解压异常，未找到 ssserver 二进制文件"
        rm -f "$FILENAME"
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
    sed -i '/fs.file-max/d' /etc/sysctl.conf
    echo "fs.file-max = 1000000" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
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

# --- 5. 交互配置 ---
configure() {
    clear
    print_line
    echo -e " ${BOLD}Shadowsocks-Rust 配置向导${PLAIN}"
    print_line

    # 1. 端口 (默认修改为 9529)
    while true; do
        read -p "$(echo -e "${CYAN}::${PLAIN} 监听端口 [回车默认 9529]: ")" PORT
        [[ -z "${PORT}" ]] && PORT=9529
        if check_port $PORT; then echo -e "   ➜ 使用端口: ${GREEN}$PORT${PLAIN}"; break; else print_err "端口被占用，请更换"; fi
    done

    # 2. 加密方式
    echo ""
    echo -e "${CYAN}::${PLAIN} 加密方式"
    echo -e "   1) aes-128-gcm (2022新协议，推荐)"
    echo -e "   2) chacha20-poly1305 (2022新协议，适合移动端)"
    read -p "   请选择 [默认 1]: " M_OPT
    if [[ "$M_OPT" == "2" ]]; then
        METHOD="2022-blake3-chacha20-poly1305"
        KEY_LEN=32
    else
        METHOD="2022-blake3-aes-128-gcm"
        KEY_LEN=16
    fi
    echo -e "   ➜ 已选加密: ${GREEN}$METHOD${PLAIN}"

    # 3. 密码
    echo ""
    read -p "$(echo -e "${CYAN}::${PLAIN} 连接密码 [回车随机生成]: ")" PASSWORD
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD=$(openssl rand -base64 $KEY_LEN)
        echo -e "   ➜ 自动生成 SS-2022 密钥: ${GREEN}$PASSWORD${PLAIN}"
    fi

    cat > "$CONFIG_FILE" << EOF
{
    "servers": [
        {
            "address": "0.0.0.0",
            "port": $PORT,
            "password": "$PASSWORD",
            "method": "$METHOD"
        },
        {
            "address": "::",
            "port": $PORT,
            "password": "$PASSWORD",
            "method": "$METHOD"
        }
    ],
    "mode": "tcp_and_udp",
    "timeout": 300,
    "fast_open": true
}
EOF
    chmod 600 "$CONFIG_FILE"

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/ssserver -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# --- 6. 防火墙 ---
apply_firewall() {
    # 使用 jq 获取端口更准确
    if command -v jq &> /dev/null; then
        PORT=$(jq -r '.servers[0].port' "$CONFIG_FILE")
    else
        PORT=$(grep -o '"port": [0-9]*' "$CONFIG_FILE" | head -n 1 | awk '{print $2}')
    fi

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
    systemctl enable shadowsocks-rust >/dev/null 2>&1
    systemctl restart shadowsocks-rust
    sleep 2
    if systemctl is-active --quiet shadowsocks-rust; then
        return 0
    else
        echo -e ""
        print_err "服务启动失败！以下是错误日志："
        echo -e "${YELLOW}------------------------------------------------${PLAIN}"
        journalctl -u shadowsocks-rust -n 20 --no-pager
        echo -e "${YELLOW}------------------------------------------------${PLAIN}"
        return 1
    fi
}

# --- 8. 结果展示 (UI重构版) ---
show_result() {
    if [[ ! -f "$CONFIG_FILE" ]]; then print_err "未找到配置"; return; fi

    # 使用 jq 解析配置
    if command -v jq &> /dev/null; then
        local R_PORT=$(jq -r '.servers[0].port' "$CONFIG_FILE")
        local R_PWD=$(jq -r '.servers[0].password' "$CONFIG_FILE")
        local R_METHOD=$(jq -r '.servers[0].method' "$CONFIG_FILE")
    else
        local R_PORT=$(grep -o '"port": [0-9]*' "$CONFIG_FILE" | head -n 1 | awk '{print $2}')
        local R_PWD=$(grep -o '"password": "[^"]*"' "$CONFIG_FILE" | head -n 1 | cut -d '"' -f 4)
        local R_METHOD=$(grep -o '"method": "[^"]*"' "$CONFIG_FILE" | head -n 1 | cut -d '"' -f 4)
    fi
    
    if ! systemctl is-active --quiet shadowsocks-rust; then
        print_warn "警告：服务未运行。"
    fi

    # 获取 IP - 增加超时和备用源
    local IPV4=$(curl -s4m8 https://api.ipify.org)
    [[ -z "$IPV4" ]] && IPV4=$(curl -s4m8 https://ifconfig.me)
    [[ -z "$IPV4" ]] && IPV4="无法获取IPv4"
    local IPV6=$(curl -s6m8 https://api64.ipify.org)
    [[ -z "$IPV6" ]] && IPV6="无法获取IPv6"

    # 生成 SIP002 链接 (base64 method:password)
    local CRED=$(echo -n "${R_METHOD}:${R_PWD}" | base64 -w 0)
    
    local LINK4=""
    local LINK6=""
    
    if [[ "$IPV4" != "无法获取IPv4" ]]; then
        LINK4="ss://${CRED}@${IPV4}:${R_PORT}#SS-Rust-v4"
    fi
    if [[ "$IPV6" != "无法获取IPv6" ]]; then
        LINK6="ss://${CRED}@[${IPV6}]:${R_PORT}#SS-Rust-v6"
    fi

    clear
    print_line
    echo -e "       Shadowsocks-Rust 配置详情"
    print_line
    # 1. 本地 IP 显示
    echo -e " 本地 IP (IPv4) : ${GREEN}${IPV4}${PLAIN}"
    echo -e " 本地 IP (IPv6) : ${GREEN}${IPV6}${PLAIN}"
    echo ""

    # 2. 导出链接 (置顶)
    echo -e "${BOLD} 🔗 导出链接 (直接导入)${PLAIN}"
    if [[ -n "$LINK4" ]]; then
        echo -e " IPv4: ${CYAN}${LINK4}${PLAIN}"
    fi
    if [[ -n "$LINK6" ]]; then
        echo -e " IPv6: ${GREEN}${LINK6}${PLAIN}"
    fi
    echo ""
    
    # 3. OpenClash 填空指引 (表格)
    echo -e "${BOLD} 📝 OpenClash (Meta内核) 填空指引${PLAIN}"
    echo -e "┌─────────────────────┬──────────────────────────────────────┐"
    echo -e "│ OpenClash 选项      │ 应填内容                             │"
    echo -e "├─────────────────────┼──────────────────────────────────────┤"
    printf "│ 服务器地址          │ %-36s │\n" "${IPV4}"
    printf "│ 端口                │ %-36s │\n" "${R_PORT}"
    printf "│ 协议类型            │ %-36s │\n" "ss (Shadowsocks)"
    printf "│ 加密方式            │ %-36s │\n" "${R_METHOD}"
    printf "│ 密码                │ %-36s │\n" "${R_PWD}"
    printf "│ UDP转发             │ %-36s │\n" "✅ 勾选 (True)"
    echo -e "└─────────────────────┴──────────────────────────────────────┘"
    echo ""

    # 4. YAML 配置代码
    echo -e "${BOLD} 📋 YAML 配置代码 (Meta 内核专用)${PLAIN}"
    echo -e "${GREEN}"
    cat << EOF
  - name: "SS-Rust"
    type: ss
    server: ${IPV4}
    port: ${R_PORT}
    cipher: ${R_METHOD}
    password: ${R_PWD}
    udp: true
EOF
    echo -e "${PLAIN}"
    print_line
}

uninstall() {
    print_warn "正在卸载 Shadowsocks-Rust..."
    systemctl stop shadowsocks-rust
    systemctl disable shadowsocks-rust
    rm -f "$SERVICE_FILE" "/usr/bin/ss" "/usr/local/bin/ss"
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
    systemctl daemon-reload
    print_ok "卸载完成"
}

# --- 9. 菜单系统 ---
show_menu() {
    clear
    if systemctl is-active --quiet shadowsocks-rust; then
        STATUS="${GREEN}运行中${PLAIN}"
        PID=$(systemctl show -p MainPID shadowsocks-rust | cut -d= -f2)
        MEM=$(ps -o rss= -p $PID 2>/dev/null | awk '{printf "%.1fMB", $1/1024}')
    else
        STATUS="${RED}未运行${PLAIN}"
        PID="N/A"
        MEM="0MB"
    fi

    print_line
    echo -e "${BOLD}     Shadowsocks-Rust OpenClash 优化版${PLAIN}"
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
           create_shortcut 
           start_and_check && show_result ;;
        2) [[ ! -f "$CONFIG_FILE" ]] && return; show_result; read -p "  按回车键返回菜单..." ; show_menu ;;
        3) echo -e "${CYAN}Ctrl+C 退出日志${PLAIN}"; journalctl -u shadowsocks-rust -f ;;
        4) start_and_check; read -p "按回车继续..."; show_menu ;;
        5) systemctl stop shadowsocks-rust; print_warn "已停止"; sleep 1; show_menu ;;
        6) start_and_check; read -p "按回车继续..."; show_menu ;;
        8) uninstall; exit 0 ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

if [[ $# > 0 ]]; then show_menu; else show_menu; fi
