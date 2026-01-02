#!/bin/bash

# ====================================================
# Shadowsocks-2022 (Rust) 管理脚本
# 版本: V4.2 | 修复: 优先使用本地文件作为命令
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

# 脚本源 (仅在 curl 在线安装时使用)
SCRIPT_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main/install_ss2022.sh"

# 目录与文件
INSTALL_DIR="/opt/ss-rust"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/shadowsocks-rust.service"
SHORTCUT_BIN="/usr/bin/ss"

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
    if ! command -v curl &> /dev/null || ! command -v tar &> /dev/null || ! command -v xz &> /dev/null || ! command -v jq &> /dev/null || ! command -v netstat &> /dev/null; then
        print_info "安装依赖 (curl, tar, xz, jq, net-tools)..."
        if [[ "${RELEASE}" == "centos" ]]; then
            yum install -y curl wget tar xz jq net-tools iptables-services >/dev/null 2>&1
        else
            apt update >/dev/null 2>&1
            apt install -y curl wget tar xz-utils jq net-tools iptables-persistent >/dev/null 2>&1
        fi
    fi
}

# --- 2. 创建快捷指令 (逻辑修正) ---
create_shortcut() {
    print_info "正在配置快捷指令 'ss'..."
    
    # 【修复核心】优先判断当前运行的是否为本地文件
    # 如果是本地文件运行 (bash install.sh)，直接复制自己，保证版本一致
    if [[ -f "$0" ]]; then
        cp -f "$0" "$SHORTCUT_BIN"
        print_ok "已使用本地文件更新快捷指令 (V4.2)"
    else
        # 只有在 curl 在线运行 ($0 不是文件) 时，才去下载
        print_warn "检测到在线运行，正在从 GitHub 拉取脚本..."
        wget -qO "$SHORTCUT_BIN" "$SCRIPT_URL"
    fi

    # 检查结果
    if [[ -s "$SHORTCUT_BIN" ]]; then
        chmod +x "$SHORTCUT_BIN"
        # 覆盖 /usr/local/bin 防止路径冲突
        cp -f "$SHORTCUT_BIN" "/usr/local/bin/ss"
        chmod +x "/usr/local/bin/ss"
        print_ok "快捷指令创建成功！输入 'ss' 即可管理"
    else
        print_err "快捷指令创建失败，请检查网络或手动复制脚本到 /usr/bin/ss"
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
    # 强制使用 netstat 避免与脚本名 ss 冲突
    if [[ -n $(netstat -tunlp | grep ":${1} " | grep -E "tcp|udp") ]]; then return 1; else return 0; fi
}

# --- 5. 交互配置 ---
configure() {
    clear
    print_line
    echo -e " ${BOLD}Shadowsocks-Rust 配置向导${PLAIN}"
    print_line

    while true; do
        read -p "$(echo -e "${CYAN}::${PLAIN} 监听端口 [回车默认 9000]: ")" PORT
        [[ -z "${PORT}" ]] && PORT=9000
        if check_port $PORT; then echo -e "   ➜ 使用端口: ${GREEN}$PORT${PLAIN}"; break; else print_err "端口被占用，请更换"; fi
    done

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
    PORT=$(grep -o '"port": [0-9]*' "$CONFIG_FILE" | head -n 1 | awk '{print $2}')
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

# --- 8. 结果展示 ---
show_result() {
    if [[ ! -f "$CONFIG_FILE" ]]; then print_err "未找到配置"; return; fi

    PORT=$(grep -o '"port": [0-9]*' "$CONFIG_FILE" | head -n 1 | awk '{print $2}')
    PASSWORD=$(grep -o '"password": "[^"]*"' "$CONFIG_FILE" | head -n 1 | cut -d '"' -f 4)
    METHOD=$(grep -o '"method": "[^"]*"' "$CONFIG_FILE" | head -n 1 | cut -d '"' -f 4)
    
    if ! systemctl is-active --quiet shadowsocks-rust; then
        print_warn "警告：服务未运行。"
    fi

    IPV4=$(curl -s4m3 https://api.ipify.org || curl -s4m3 https://icanhazip.com)
    IPV6=$(curl -s6m3 https://api64.ipify.org || curl -s6m3 https://icanhazip.com)

    CREDENTIALS=$(echo -n "${METHOD}:${PASSWORD}" | base64 -w 0)
    
    clear
    print_line
    echo -e "${BOLD}         Shadowsocks-Rust 配置详情${PLAIN}"
    print_line
    
    echo -e "${BOLD} [基本信息]${PLAIN}"
    echo -e "  监听端口 : ${GREEN}${PORT}${PLAIN}"
    echo -e "  加密方式 : ${CYAN}${METHOD}${PLAIN}"
    echo -e "  连接密码 : ${YELLOW}${PASSWORD}${PLAIN}"

    echo -e ""
    print_line
    echo -e "${BOLD} 🚀 快速导入链接${PLAIN}"
    echo -e ""
    
    HAS_LINK=false
    if [[ -n "$IPV4" ]]; then
        LINK4="ss://${CREDENTIALS}@${IPV4}:${PORT}#SS-Rust-v4"
        echo -e "  ${BOLD}IPv4 链接:${PLAIN}"
        echo -e "  ${CYAN}${LINK4}${PLAIN}"
        echo ""
        HAS_LINK=true
    fi

    if [[ -n "$IPV6" ]]; then
        LINK6="ss://${CREDENTIALS}@[${IPV6}]:${PORT}#SS-Rust-v6"
        echo -e "  ${BOLD}IPv6 链接:${PLAIN}"
        echo -e "  ${GREEN}${LINK6}${PLAIN}"
        echo ""
        HAS_LINK=true
    fi

    if [[ "$HAS_LINK" == "false" ]]; then
        print_err "无法获取公网 IP，请手动拼接链接。"
    fi
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
    echo -e "${BOLD}      Shadowsocks-Rust 管理面板 ${YELLOW}[V4.2]${PLAIN}"
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
