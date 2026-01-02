#!/bin/bash

# ====================================================
# TUIC v5 管理脚本
# 架构: 复刻 SS-Rust V4.2 | 核心: eaimty/tuic
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
# 官方核心仓库
REPO="eaimty/tuic"

# 脚本下载地址 (用于修复快捷指令，请确保文件名正确)
SCRIPT_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main/tuic.sh"

# 目录与文件
INSTALL_DIR="/opt/tuic"
CONFIG_DIR="/etc/tuic"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CERT_FILE="${CONFIG_DIR}/server.crt"
KEY_FILE="${CONFIG_DIR}/server.key"
SERVICE_FILE="/etc/systemd/system/tuic.service"
SHORTCUT_BIN="/usr/bin/tuic"

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
    # 需要 openssl 生成证书, uuid-runtime 生成 UUID
    if ! command -v curl &> /dev/null || ! command -v openssl &> /dev/null || ! command -v jq &> /dev/null || ! command -v uuidgen &> /dev/null; then
        print_info "安装依赖 (curl, openssl, uuid, jq)..."
        if [[ "${RELEASE}" == "centos" ]]; then
            yum install -y curl wget jq openssl util-linux iptables-services >/dev/null 2>&1
        else
            apt update >/dev/null 2>&1
            apt install -y curl wget jq openssl uuid-runtime iptables-persistent >/dev/null 2>&1
        fi
    fi
}

# --- 2. 创建快捷指令 (V4.2 逻辑) ---
create_shortcut() {
    print_info "正在配置快捷指令 'tuic'..."
    
    # 优先使用本地文件
    if [[ -f "$0" ]]; then
        cp -f "$0" "$SHORTCUT_BIN"
        print_ok "已使用本地文件更新快捷指令"
    else
        print_warn "检测到在线运行，正在从 GitHub 拉取脚本..."
        wget -qO "$SHORTCUT_BIN" "$SCRIPT_URL"
    fi

    if [[ -s "$SHORTCUT_BIN" ]]; then
        chmod +x "$SHORTCUT_BIN"
        # 覆盖 /usr/local/bin 防止路径冲突
        cp -f "$SHORTCUT_BIN" "/usr/local/bin/tuic"
        chmod +x "/usr/local/bin/tuic"
        print_ok "快捷指令创建成功！输入 'tuic' 即可管理"
    else
        print_err "快捷指令创建失败，请检查网络。"
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

    # 获取最新 Release
    LATEST_JSON=$(curl -s "https://api.github.com/repos/$REPO/releases/latest")
    LATEST_VERSION=$(echo "$LATEST_JSON" | jq -r .tag_name 2>/dev/null)
    
    if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
        TAGS_JSON=$(curl -s "https://api.github.com/repos/$REPO/tags")
        LATEST_VERSION=$(echo "$TAGS_JSON" | jq -r '.[0].name' 2>/dev/null)
    fi

    if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "null" ]]; then
        print_warn "无法自动获取版本，请手动输入 [如 v1.0.0]: "
        read MANUAL_VERSION
        [[ -z "$MANUAL_VERSION" ]] && exit 1
        LATEST_VERSION=$MANUAL_VERSION
    fi

    # 构造下载链接 (eaimty/tuic 发布的通常是直接的二进制文件)
    # 格式示例: tuic-server-1.0.0-x86_64-unknown-linux-gnu
    CLEAN_VER=${LATEST_VERSION#v}
    FILENAME="tuic-server-${CLEAN_VER}-${FILE_ARCH}-unknown-linux-gnu"
    # 部分版本可能是 musl，优先尝试 gnu，如果这里下载失败可能需要调整
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/${LATEST_VERSION}/${FILENAME}"

    print_info "正在下载: ${GREEN}$LATEST_VERSION${PLAIN}..."
    
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
    cd /tmp
    curl -L -o "tuic-server" "$DOWNLOAD_URL"
    
    if [[ $? -ne 0 ]]; then 
        print_err "下载失败！可能该版本无预编译二进制文件。"
        rm -f "tuic-server"
        exit 1
    fi

    if [[ -f "tuic-server" ]]; then
        systemctl stop tuic 2>/dev/null
        mv tuic-server "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/tuic-server"
        print_ok "核心安装完成"
    else
        print_err "文件移动失败"
        exit 1
    fi
}

# --- 4. 证书生成 (自签名) ---
generate_cert() {
    print_info "生成自签名 ECC 证书 (SNI: www.bing.com)..."
    openssl ecparam -genkey -name prime256v1 -out "$KEY_FILE"
    openssl req -new -x509 -days 36500 -key "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=www.bing.com" >/dev/null 2>&1
    chmod 644 "$CERT_FILE"
    chmod 600 "$KEY_FILE"
    print_ok "证书生成完成"
}

# --- 5. 系统优化 (QUIC 必备) ---
optimize_sysctl() {
    print_info "优化内核参数 (BBR + UDP Buffer)..."
    if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    # 增大 UDP 缓冲区
    sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
    cat >> /etc/sysctl.conf <<EOF
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
EOF
    sysctl -p >/dev/null 2>&1
}

check_port() {
    if [[ -n $(netstat -tunlp | grep ":${1} " | grep -E "tcp|udp") ]]; then return 1; else return 0; fi
}

# --- 6. 交互配置 ---
configure() {
    clear
    print_line
    echo -e " ${BOLD}TUIC v5 配置向导${PLAIN}"
    print_line

    # 1. 端口
    while true; do
        read -p "$(echo -e "${CYAN}::${PLAIN} 监听端口 [回车默认 8443]: ")" PORT
        [[ -z "${PORT}" ]] && PORT=8443
        if check_port $PORT; then echo -e "   ➜ 使用端口: ${GREEN}$PORT${PLAIN}"; break; else print_err "端口被占用"; fi
    done

    # 2. UUID
    echo ""
    read -p "$(echo -e "${CYAN}::${PLAIN} 用户 UUID [回车随机生成]: ")" UUID
    if [[ -z "$UUID" ]]; then
        UUID=$(uuidgen)
        echo -e "   ➜ 随机生成: ${GREEN}$UUID${PLAIN}"
    fi

    # 3. 密码
    echo ""
    read -p "$(echo -e "${CYAN}::${PLAIN} 连接密码 [回车随机生成]: ")" PASSWORD
    if [[ -z "$PASSWORD" ]]; then
        PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8)
        echo -e "   ➜ 随机生成: ${GREEN}$PASSWORD${PLAIN}"
    fi

    # 生成证书
    generate_cert

    # 写入配置 (TUIC v5 JSON 格式)
    cat > "$CONFIG_FILE" << EOF
{
    "server": "[::]:$PORT",
    "users": {
        "$UUID": "$PASSWORD"
    },
    "certificate": "$CERT_FILE",
    "private_key": "$KEY_FILE",
    "congestion_control": "bbr",
    "alpn": ["h3", "spdy/3.1"],
    "log_level": "info"
}
EOF

    # 写入 Service
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=TUIC v5 Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=${INSTALL_DIR}/tuic-server -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# --- 7. 防火墙 ---
apply_firewall() {
    # 从配置文件读取端口 (TUIC 是 UDP 协议)
    # JSON 提取稍微复杂，这里直接用刚才的变量，或者重新提取
    PORT=$(grep '"server":' "$CONFIG_FILE" | cut -d ':' -f 3 | tr -d '",')
    
    print_info "配置防火墙规则 (UDP)..."
    if [[ "${RELEASE}" == "centos" ]]; then
        firewall-cmd --zone=public --add-port=$PORT/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    else
        iptables -I INPUT -p udp --dport $PORT -j ACCEPT
        if [ -f /etc/debian_version ]; then netfilter-persistent save >/dev/null 2>&1; else service iptables save >/dev/null 2>&1; fi
    fi
}

# --- 8. 启动与自检 ---
start_and_check() {
    systemctl enable tuic >/dev/null 2>&1
    systemctl restart tuic
    sleep 2
    if systemctl is-active --quiet tuic; then
        return 0
    else
        echo -e ""
        print_err "启动失败，请检查日志："
        print_line
        journalctl -u tuic -n 10 --no-pager
        print_line
        return 1
    fi
}

# --- 9. 结果展示 ---
show_result() {
    if [[ ! -f "$CONFIG_FILE" ]]; then print_err "未找到配置"; return; fi

    # 提取信息
    PORT=$(grep '"server":' "$CONFIG_FILE" | cut -d ':' -f 3 | tr -d '",')
    UUID=$(grep -A 1 '"users":' "$CONFIG_FILE" | tail -n 1 | cut -d '"' -f 2)
    PASSWORD=$(grep -A 1 '"users":' "$CONFIG_FILE" | tail -n 1 | cut -d '"' -f 4)
    
    if ! systemctl is-active --quiet tuic; then print_warn "服务未运行"; fi

    IPV4=$(curl -s4m3 https://api.ipify.org)
    IPV6=$(curl -s6m3 https://api64.ipify.org)

    clear
    print_line
    echo -e "${BOLD}         TUIC v5 配置详情${PLAIN}"
    print_line
    echo -e "  监听端口 : ${GREEN}${PORT}${PLAIN} (UDP)"
    echo -e "  用户 UUID: ${CYAN}${UUID}${PLAIN}"
    echo -e "  连接密码 : ${YELLOW}${PASSWORD}${PLAIN}"
    echo -e "  ALPN     : ${CYAN}h3${PLAIN}"
    echo -e "  拥塞控制 : ${GREEN}bbr${PLAIN}"
    echo -e "  证书模式 : ${YELLOW}自签名 (allow_insecure=1)${PLAIN}"
    print_line
    
    # 构造链接
    # tuic://uuid:password@ip:port/?congestion_control=bbr&alpn=h3&sni=www.bing.com&allow_insecure=1
    PARAMS="congestion_control=bbr&alpn=h3&sni=www.bing.com&allow_insecure=1"
    
    HAS_LINK=false
    if [[ -n "$IPV4" ]]; then
        LINK4="tuic://${UUID}:${PASSWORD}@${IPV4}:${PORT}/?${PARAMS}#TUIC-v4"
        echo -e "  ${BOLD}IPv4 链接:${PLAIN}"
        echo -e "  ${CYAN}${LINK4}${PLAIN}"
        echo ""
        HAS_LINK=true
    fi

    if [[ -n "$IPV6" ]]; then
        LINK6="tuic://${UUID}:${PASSWORD}@[${IPV6}]:${PORT}/?${PARAMS}#TUIC-v6"
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
    print_warn "正在卸载 TUIC..."
    systemctl stop tuic
    systemctl disable tuic
    rm -f "$SERVICE_FILE" "/usr/bin/tuic" "/usr/local/bin/tuic"
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
    systemctl daemon-reload
    print_ok "卸载完成"
}

show_menu() {
    clear
    if systemctl is-active --quiet tuic; then
        STATUS="${GREEN}运行中${PLAIN}"
        PID=$(systemctl show -p MainPID tuic | cut -d= -f2)
        MEM=$(ps -o rss= -p $PID 2>/dev/null | awk '{printf "%.1fMB", $1/1024}')
    else
        STATUS="${RED}未运行${PLAIN}"
        PID="N/A"
        MEM="0MB"
    fi

    print_line
    echo -e "${BOLD}      TUIC v5 管理面板 ${YELLOW}[V1.0]${PLAIN}"
    print_line
    echo -e "  状态: ${STATUS}  |  PID: ${YELLOW}${PID}${PLAIN}  |  内存: ${YELLOW}${MEM}${PLAIN}"
    print_line
    echo -e "  ${GREEN}1.${PLAIN}  重置配置 (重新安装)"
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
        1) run_install ;;
        2) [[ ! -f "$CONFIG_FILE" ]] && return; show_result; read -p "按回车返回..." ; show_menu ;;
        3) echo -e "${CYAN}Ctrl+C 退出日志${PLAIN}"; journalctl -u tuic -f ;;
        4) start_and_check; read -p "按回车继续..."; show_menu ;;
        5) systemctl stop tuic; print_warn "已停止"; sleep 1; show_menu ;;
        6) start_and_check; read -p "按回车继续..."; show_menu ;;
        8) uninstall; exit 0 ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

# ====================================================
# 核心逻辑入口
# ====================================================

run_install() {
    check_sys
    install_deps
    optimize_sysctl
    install_core
    configure
    apply_firewall
    create_shortcut
    start_and_check && show_result
}

if [[ -f "$CONFIG_FILE" ]]; then
    show_menu
else
    run_install
fi
