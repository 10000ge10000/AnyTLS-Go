#!/bin/bash

# ====================================================
# Mieru (Mita) 一键安装脚本
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
REPO="enfein/mieru"
# 你的仓库地址
SCRIPT_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main/mieru.sh"

BIN_NAME="mita" 
INSTALL_BIN="/usr/local/bin/$BIN_NAME"
CONFIG_DIR="/etc/mieru"
CONFIG_FILE="${CONFIG_DIR}/server_config.json"
SERVICE_FILE="/etc/systemd/system/mita.service"
SHORTCUT_BIN="/usr/bin/mieru"
GAI_CONF="/etc/gai.conf"

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

# --- 2. 依赖安装 ---
install_deps() {
    print_info "检查系统依赖..."
    CMD_INSTALL=""
    if command -v apt-get &>/dev/null; then
        CMD_INSTALL="apt-get install -y"
        apt-get update >/dev/null 2>&1
        $CMD_INSTALL uuid-runtime >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        CMD_INSTALL="yum install -y"
    else
        print_err "不支持的系统"
        exit 1
    fi
    $CMD_INSTALL curl wget jq tar net-tools >/dev/null 2>&1
    
    # 确保 uuidgen 可用
    if ! command -v uuidgen &>/dev/null; then
        $CMD_INSTALL util-linux >/dev/null 2>&1
    fi
}

# --- 3. 系统优化 (BBR) ---
optimize_sysctl() {
    print_info "优化内核参数 (开启 BBR)..."
    [[ ! -f /etc/sysctl.conf ]] && touch /etc/sysctl.conf
    if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
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

# --- 4. 创建 mita 系统用户 ---
create_user() {
    # 必须存在 mita 用户，否则服务无法启动
    if id "mita" &>/dev/null; then
        :
    else
        print_info "创建系统用户 'mita'..."
        useradd -r -M -s /usr/sbin/nologin mita
    fi
}

# --- 5. 快捷指令 (适配你的仓库) ---
create_shortcut() {
    # 如果本地有脚本文件则复制，否则从 URL 下载 (参考 tuic.sh 逻辑)
    if [[ -f "$0" ]]; then 
        cp -f "$0" "$SHORTCUT_BIN"
    else 
        wget -qO "$SHORTCUT_BIN" "$SCRIPT_URL"
    fi
    chmod +x "$SHORTCUT_BIN"
    
    # 同时在 /usr/local/bin 创建，确保兼容性
    cp -f "$SHORTCUT_BIN" "/usr/local/bin/mieru"
    chmod +x "/usr/local/bin/mieru"
}

# --- 6. 核心安装 ---
install_core() {
    clear
    print_line
    echo -e " ${BOLD}Mieru (Mita) 安装向导${PLAIN}"
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

    print_info "下载服务端 (mita)..."
    
    # 严格过滤：必须包含 mita，排除 mieru
    ALL_URLS=$(echo "$LATEST_JSON" | jq -r '.assets[].browser_download_url')
    DOWNLOAD_URL=$(echo "$ALL_URLS" | grep -i "mita" | grep -i "linux" | grep -i "$KW_ARCH" | grep -i "tar.gz" | head -n 1)

    if [[ -z "$DOWNLOAD_URL" ]]; then
        print_err "未找到服务端安装包！"
        exit 1
    fi

    wget -q --show-progress -O "/tmp/mieru_pkg.tar.gz" "$DOWNLOAD_URL"
    if [[ ! -s "/tmp/mieru_pkg.tar.gz" ]]; then print_err "下载失败"; exit 1; fi

    print_info "解压并验证..."
    rm -rf /tmp/mieru_extract
    mkdir -p /tmp/mieru_extract
    tar -zxf /tmp/mieru_pkg.tar.gz -C /tmp/mieru_extract
    
    FOUND_BIN=$(find /tmp/mieru_extract -type f -name "mita" | head -n 1)
    
    if [[ -z "$FOUND_BIN" ]]; then 
        print_err "安装包中未找到 'mita'！"
        exit 1
    fi
    
    systemctl stop mita 2>/dev/null
    cp -f "$FOUND_BIN" "$INSTALL_BIN"
    chmod +x "$INSTALL_BIN"
    rm -rf /tmp/mieru_pkg.tar.gz /tmp/mieru_extract

    if ! "$INSTALL_BIN" version &>/dev/null; then 
        print_err "二进制文件验证失败。"
        exit 1
    fi

    mkdir -p "$CONFIG_DIR"
    chown -R mita:mita "$CONFIG_DIR"
    print_ok "核心安装完成"
}

# --- 7. 交互配置 ---
configure() {
    clear
    print_line
    echo -e " ${BOLD}Mieru 配置向导${PLAIN}"
    print_line

    # === 端口 ===
    echo -e " ${YELLOW}提示：默认端口范围 39950 - 40000${PLAIN}"
    echo ""
    while true; do
        read -p "$(echo -e "${CYAN}::${PLAIN} 起始端口 [回车 39950]: ")" PORT_START
        [[ -z "${PORT_START}" ]] && PORT_START=39950
        read -p "$(echo -e "${CYAN}::${PLAIN} 结束端口 [回车 40000]: ")" PORT_END
        [[ -z "${PORT_END}" ]] && PORT_END=40000
        
        # 优先使用 ss 命令，fallback 到 netstat
        local port_in_use=0
        if command -v ss &>/dev/null; then
            if ss -tunlp 2>/dev/null | grep -q ":${PORT_START} "; then port_in_use=1; fi
        elif command -v netstat &>/dev/null; then
            if netstat -tunlp 2>/dev/null | grep -q ":${PORT_START} "; then port_in_use=1; fi
        fi
        
        if [[ $port_in_use -eq 1 ]]; then
            print_err "端口 $PORT_START 被占用"; continue
        fi
        echo -e "   ➜ 端口: ${GREEN}$PORT_START - $PORT_END${PLAIN}"; break
    done

    # === 传输协议 (Transport) ===
    echo ""
    echo -e " ${BOLD}传输协议 (Transport Protocol)${PLAIN}"
    echo -e " 1. ${GREEN}TCP + UDP${PLAIN} (推荐，双栈监听)"
    echo -e " 2. ${GREEN}TCP Only${PLAIN}  (仅 TCP)"
    echo -e " 3. ${GREEN}UDP Only${PLAIN}  (仅 UDP)"
    read -p " 请选择 [1-3] (默认 1): " TRANS_CHOICE
    [[ -z "$TRANS_CHOICE" ]] && TRANS_CHOICE=1
    
    case "$TRANS_CHOICE" in
        2) 
            PROTO_STR="TCP"
            CLIENT_TRANS="TCP"
            ;;
        3) 
            PROTO_STR="UDP"
            CLIENT_TRANS="UDP"
            ;;
        *) 
            PROTO_STR="BOTH"
            CLIENT_TRANS="TCP" # 双栈时 OpenClash 默认填 TCP 较稳妥
            ;;
    esac
    echo -e "   ➜ 已选择: ${CYAN}${PROTO_STR}${PLAIN}"

    # === 用户名 ===
    echo ""
    RND_USER=$(head /dev/urandom | tr -dc 'a-z' | head -c 8)
    read -p "$(echo -e "${CYAN}::${PLAIN} 用户名 [回车随机: $RND_USER]: ")" USERNAME
    [[ -z "$USERNAME" ]] && USERNAME=$RND_USER
    
    # === 密码 (UUID) ===
    echo ""
    RND_PASS=$(uuidgen)
    read -p "$(echo -e "${CYAN}::${PLAIN} 密码 [回车随机 UUID]: ")" PASSWORD
    [[ -z "$PASSWORD" ]] && PASSWORD=$RND_PASS
    echo -e "   ➜ 密码: ${GREEN}$PASSWORD${PLAIN}"

    # === IP 策略 ===
    echo ""
    echo -e " ${BOLD}出站 IP 策略${PLAIN}"
    echo -e " 1. ${GREEN}USE_FIRST_IP${PLAIN} (默认)"
    echo -e " 2. ${GREEN}PREFER_IPv4${PLAIN}"
    echo -e " 3. ${GREEN}PREFER_IPv6${PLAIN}"
    echo -e " 4. ${GREEN}ONLY_IPv4${PLAIN}"
    echo -e " 5. ${GREEN}ONLY_IPv6${PLAIN}"
    read -p " 选择 [1-5] (默认 1): " DNS_CHOICE
    case "$DNS_CHOICE" in
        2) DNS_STR="PREFER_IPv4" ;;
        3) DNS_STR="PREFER_IPv6" ;;
        4) DNS_STR="ONLY_IPv4" ;;
        5) DNS_STR="ONLY_IPv6" ;;
        *) DNS_STR="USE_FIRST_IP" ;;
    esac

    # === NTP ===
    echo ""
    echo -e " ${BOLD}NTP 时间同步${PLAIN}"
    read -p " 安装 NTP 服务? [y/N]: " INSTALL_NTP
    if [[ "$INSTALL_NTP" =~ ^[yY]$ ]]; then
        print_info "安装 NTP..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y ntp >/dev/null 2>&1
            systemctl enable ntp >/dev/null 2>&1; systemctl start ntp >/dev/null 2>&1
        else
            yum install -y ntp >/dev/null 2>&1
            systemctl enable ntpd >/dev/null 2>&1; systemctl start ntpd >/dev/null 2>&1
        fi
    fi

    # === 生成配置 ===
    if [[ "$PROTO_STR" == "BOTH" ]]; then
        if [[ "$PORT_START" == "$PORT_END" ]]; then
            BINDINGS_JSON=$(cat <<EOF
    { "port": $PORT_START, "protocol": "TCP" },
    { "port": $PORT_START, "protocol": "UDP" }
EOF
)
        else
            BINDINGS_JSON=$(cat <<EOF
    { "portRange": "${PORT_START}-${PORT_END}", "protocol": "TCP" },
    { "portRange": "${PORT_START}-${PORT_END}", "protocol": "UDP" }
EOF
)
        fi
    elif [[ "$PROTO_STR" == "TCP" ]]; then
        if [[ "$PORT_START" == "$PORT_END" ]]; then
            BINDINGS_JSON=$(cat <<EOF
    { "port": $PORT_START, "protocol": "TCP" }
EOF
)
        else
            BINDINGS_JSON=$(cat <<EOF
    { "portRange": "${PORT_START}-${PORT_END}", "protocol": "TCP" }
EOF
)
        fi
    else # UDP
        if [[ "$PORT_START" == "$PORT_END" ]]; then
            BINDINGS_JSON=$(cat <<EOF
    { "port": $PORT_START, "protocol": "UDP" }
EOF
)
        else
            BINDINGS_JSON=$(cat <<EOF
    { "portRange": "${PORT_START}-${PORT_END}", "protocol": "UDP" }
EOF
)
        fi
    fi

    cat > "$CONFIG_FILE" << EOF
{
  "portBindings": [ $BINDINGS_JSON ],
  "users": [ { "name": "$USERNAME", "password": "$PASSWORD" } ],
  "loggingLevel": "INFO",
  "mtu": 1400,
  "dns": { "dualStack": "$DNS_STR" }
}
EOF
    chmod 600 "$CONFIG_FILE"
    # 保存 transport 偏好
    echo "$CLIENT_TRANS" > "${CONFIG_DIR}/client_transport_pref"
    chown mita:mita "$CONFIG_FILE" "${CONFIG_DIR}/client_transport_pref"

    # === 服务配置 ===
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Mieru Proxy Server (Mita)
After=network.target

[Service]
Type=simple
User=root
RuntimeDirectory=mita
RuntimeDirectoryMode=0755
Environment="MITA_CONFIG_JSON_FILE=${CONFIG_FILE}"
ExecStart=${INSTALL_BIN} run
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

apply_firewall() {
    local p_start=$PORT_START
    local p_end=$PORT_END
    [[ -z "$p_start" ]] && return
    
    print_info "配置防火墙..."
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --zone=public --add-port=${p_start}-${p_end}/tcp --permanent >/dev/null 2>&1
        firewall-cmd --zone=public --add-port=${p_start}-${p_end}/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p tcp --match multiport --dports ${p_start}:${p_end} -j ACCEPT
        iptables -I INPUT -p udp --match multiport --dports ${p_start}:${p_end} -j ACCEPT
        if command -v netfilter-persistent &>/dev/null; then netfilter-persistent save >/dev/null 2>&1; fi
    fi
}

start_and_check() {
    systemctl enable mita >/dev/null 2>&1
    systemctl restart mita
    sleep 3
    if systemctl is-active --quiet mita; then return 0; else
        echo ""
        print_err "启动失败！日志如下："
        journalctl -u mita -n 20 --no-pager
        return 1
    fi
}

show_result() {
    if ! command -v jq &> /dev/null; then return; fi
    
    if grep -q "portRange" "$CONFIG_FILE"; then
        P_DISPLAY=$(jq -r '.portBindings[0].portRange' "$CONFIG_FILE")
        P_MAIN=${P_DISPLAY%%-*}
    else
        P_DISPLAY=$(jq -r '.portBindings[0].port' "$CONFIG_FILE")
        P_MAIN=$P_DISPLAY
    fi
    U_NAME=$(jq -r '.users[0].name' "$CONFIG_FILE")
    U_PASS=$(jq -r '.users[0].password' "$CONFIG_FILE")
    
    if [[ -f "${CONFIG_DIR}/client_transport_pref" ]]; then
        C_TRANS=$(cat "${CONFIG_DIR}/client_transport_pref")
    else
        C_TRANS="TCP"
    fi
    
    IPV4=$(curl -s4m8 https://api.ipify.org)
    [[ -z "$IPV4" ]] && IPV4=$(curl -s4m8 https://ifconfig.me)
    [[ -z "$IPV4" ]] && IPV4="无法获取"

    clear
    print_line
    echo -e "       Mieru (Mita) 配置详情"
    print_line
    echo -e " IP: ${GREEN}${IPV4}${PLAIN}"
    echo ""
    
    echo -e "${BOLD} 📋 OpenClash (Meta) 配置代码${PLAIN}"
    echo -e "${GREEN}"
    cat << EOF
  - name: "Mieru-${P_MAIN}"
    type: mieru
    server: "${IPV4}"
    port: ${P_MAIN}
    username: "${U_NAME}"
    password: "${U_PASS}"
    udp: true
    transport: "${C_TRANS}"
    multiplexing: MULTIPLEXING_LOW
    # port-range: "${P_DISPLAY}"
EOF
    echo -e "${PLAIN}"
    print_line
}

show_menu() {
    clear
    if systemctl is-active --quiet mita; then STATUS="${GREEN}运行中${PLAIN}"; else STATUS="${RED}未运行${PLAIN}"; fi
    print_line
    echo -e "${BOLD}     Mieru (Mita) 管理脚本${PLAIN}"
    echo -e "  状态: ${STATUS}"
    print_line
    echo -e "  1. 安装 / 重置配置"
    echo -e "  2. 查看配置"
    echo -e "  3. 查看日志"
    echo -e "  4. 重启服务"
    echo -e "  8. 卸载"
    echo -e "  0. 退出"
    print_line
    read -p "  选择: " num
    case "$num" in
        1) run_install ;;
        2) [[ ! -f "$CONFIG_FILE" ]] && echo "无配置文件" && sleep 1 && show_menu; show_result; read -p "回车返回..." ; show_menu ;;
        3) journalctl -u mita -f ;;
        4) start_and_check; read -p "回车继续..."; show_menu ;;
        8) uninstall; exit 0 ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

uninstall() {
    print_warn "正在卸载..."
    systemctl stop mita; systemctl disable mita
    rm -f "$SERVICE_FILE" "$INSTALL_BIN" "$SHORTCUT_BIN" "/usr/local/bin/mieru"
    rm -rf "$CONFIG_DIR"
    userdel mita >/dev/null 2>&1
    systemctl daemon-reload
    print_ok "卸载完成"
}

run_install() {
    check_sys; install_deps; optimize_sysctl; create_user; install_core; create_shortcut; configure; apply_firewall; start_and_check && show_result
}

if [[ -f "$CONFIG_FILE" && "$1" != "install" ]]; then show_menu; else run_install; fi
