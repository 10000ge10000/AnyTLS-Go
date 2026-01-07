#!/bin/bash

# ====================================================
# TUIC多版本 OpenClash优化版
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
REPO="EAimTY/tuic"
SCRIPT_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main/tuic.sh"

INSTALL_DIR="/opt/tuic"
CONFIG_DIR="/etc/tuic"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CERT_FILE="${CONFIG_DIR}/server.crt"
KEY_FILE="${CONFIG_DIR}/server.key"
SERVICE_FILE="/etc/systemd/system/tuic.service"
SHORTCUT_BIN="/usr/bin/tuic"
GAI_CONF="/etc/gai.conf"

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
    if ! command -v curl &> /dev/null || ! command -v openssl &> /dev/null || ! command -v jq &> /dev/null || ! command -v uuidgen &> /dev/null; then
        print_info "安装依赖..."
        if [[ "${RELEASE}" == "centos" ]]; then
            yum install -y curl wget jq openssl util-linux iptables-services
        else
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget jq openssl uuid-runtime iptables-persistent
        fi
    fi
}

create_shortcut() {
    if [[ -f "$0" ]]; then cp -f "$0" "$SHORTCUT_BIN"; else wget -qO "$SHORTCUT_BIN" "$SCRIPT_URL"; fi
    chmod +x "$SHORTCUT_BIN"
    cp -f "$SHORTCUT_BIN" "/usr/local/bin/tuic"
    chmod +x "/usr/local/bin/tuic"
}

# --- 3. 核心安装 ---
install_core() {
    clear
    print_line
    echo -e " ${BOLD}TUIC 版本选择${PLAIN}"
    print_line
    echo -e " ${GREEN}1.${PLAIN} TUIC v5 ${YELLOW}(推荐)${PLAIN}"
    echo -e "    - 最新协议，支持 Meta 内核 (Mihomo)"
    echo -e "    - 验证: UUID + 密码"
    echo ""
    echo -e " ${GREEN}2.${PLAIN} TUIC v4 ${YELLOW}(OpenClash 专用)${PLAIN}"
    echo -e "    - 适用于未切换内核的 OpenClash"
    echo -e "    - 验证: Token (令牌)"
    print_line
    
    read -p "请选择安装版本 [1-2] (默认 1): " VER_CHOICE
    [[ -z "$VER_CHOICE" ]] && VER_CHOICE=1

    print_info "准备下载..."
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64) KEYWORD_ARCH="x86_64" ;;
        aarch64|arm64) KEYWORD_ARCH="aarch64" ;;
        *) print_err "不支持架构: $ARCH"; exit 1 ;;
    esac

    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
    cd /tmp

    if [[ "$VER_CHOICE" == "2" ]]; then
        TARGET_VERSION="0.8.5"
        print_info "已选择 TUIC v4 (核心版本: $TARGET_VERSION)"
        FILENAME="tuic-server-${TARGET_VERSION}-${KEYWORD_ARCH}-linux-gnu"
        DOWNLOAD_URL="https://github.com/$REPO/releases/download/${TARGET_VERSION}/${FILENAME}"
        curl -L -o "tuic-server" "$DOWNLOAD_URL"
        if [[ $? -ne 0 ]] || ! grep -q "ELF" "tuic-server"; then
            DOWNLOAD_URL="https://github.com/$REPO/releases/download/v${TARGET_VERSION}/${FILENAME}"
            curl -L -o "tuic-server" "$DOWNLOAD_URL"
        fi
    else
        print_info "已选择 TUIC v5 (最新版)"
        LATEST_JSON=$(curl -sL -H "User-Agent: Mozilla/5.0" "https://api.github.com/repos/$REPO/releases/latest")
        if [[ -z "$LATEST_JSON" ]] || echo "$LATEST_JSON" | grep -q "API rate limit"; then
             print_err "GitHub API 受限，建议稍后再试或选择 v4。"
             exit 1
        fi
        TARGET_VERSION=$(echo "$LATEST_JSON" | jq -r .tag_name 2>/dev/null)
        [[ -z "$TARGET_VERSION" || "$TARGET_VERSION" == "null" ]] && TARGET_VERSION="v1.0.0" && LATEST_JSON=$(curl -sL -H "User-Agent: Mozilla/5.0" "https://api.github.com/repos/$REPO/releases/tags/$TARGET_VERSION")

        DOWNLOAD_URL=$(echo "$LATEST_JSON" | jq -r --arg arch "$KEYWORD_ARCH" '.assets[] | select(.name | contains("linux") and contains($arch) and contains("gnu")) | .browser_download_url' | head -n 1)
        if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
            DOWNLOAD_URL=$(echo "$LATEST_JSON" | jq -r --arg arch "$KEYWORD_ARCH" '.assets[] | select(.name | contains("linux") and contains($arch) and contains("musl")) | .browser_download_url' | head -n 1)
        fi
        
        if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then print_err "未找到 v5 适配文件"; exit 1; fi
        curl -L -o "tuic-server" "$DOWNLOAD_URL"
    fi
    
    if [[ ! -f "tuic-server" ]]; then print_err "下载失败"; exit 1; fi
    chmod +x "tuic-server"
    if ! ./tuic-server --version &>/dev/null; then print_err "文件损坏"; rm -f "tuic-server"; exit 1; fi

    systemctl stop tuic 2>/dev/null
    mv tuic-server "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/tuic-server"
    echo "$VER_CHOICE" > "$INSTALL_DIR/version_type"
    print_ok "核心安装完成"
}

# --- 4. 证书生成 (带 SAN) ---
generate_cert() {
    print_info "生成自签名证书 (带 SAN)..."
    openssl ecparam -genkey -name prime256v1 -out "$KEY_FILE"
    
    cat > "/tmp/openssl_san.cnf" << EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = www.bing.com
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = www.bing.com
EOF

    openssl req -new -x509 -days 36500 -key "$KEY_FILE" -out "$CERT_FILE" -config "/tmp/openssl_san.cnf" 2>/dev/null
    rm -f "/tmp/openssl_san.cnf"
    chmod 644 "$CERT_FILE"
    chmod 600 "$KEY_FILE"
}

# --- 5. 系统优化 ---
optimize_sysctl() {
    print_info "优化内核参数..."
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

check_port() {
    if [[ -n $(netstat -tunlp | grep ":${1} " | grep -E "tcp|udp") ]]; then return 1; else return 0; fi
}

# --- 6. 交互配置 (集成 IP 优先询问) ---
configure() {
    VER_TYPE=$(cat "$INSTALL_DIR/version_type")
    clear
    print_line
    if [[ "$VER_TYPE" == "2" ]]; then echo -e " ${BOLD}TUIC v4 配置向导${PLAIN}"; else echo -e " ${BOLD}TUIC v5 配置向导${PLAIN}"; fi
    print_line

    while true; do
        read -p "$(echo -e "${CYAN}::${PLAIN} 监听端口 [回车默认 9528]: ")" PORT
        [[ -z "${PORT}" ]] && PORT=9528
        if check_port $PORT; then echo -e "   ➜ 使用端口: ${GREEN}$PORT${PLAIN}"; break; else print_err "端口被占用"; fi
    done

    echo ""
    read -p "$(echo -e "${CYAN}::${PLAIN} 用户 UUID/Token [回车随机生成]: ")" UUID
    if [[ -z "$UUID" ]]; then UUID=$(uuidgen); echo -e "   ➜ 随机生成: ${GREEN}$UUID${PLAIN}"; fi

    PASSWORD=""
    if [[ "$VER_TYPE" == "1" ]]; then
        echo ""
        read -p "$(echo -e "${CYAN}::${PLAIN} 连接密码 [回车随机生成]: ")" PASSWORD
        if [[ -z "$PASSWORD" ]]; then PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 8); echo -e "   ➜ 随机生成: ${GREEN}$PASSWORD${PLAIN}"; fi
    fi

    # === 新增：安装时询问 IP 优先级 ===
    echo ""
    print_line
    echo -e " ${BOLD}出站 IP 策略 (IPv4/IPv6)${PLAIN}"
    echo -e " 提示: 如果你经常访问 Netflix/Disney+ 且 VPS 有 IPv6，建议强制 IPv4 优先以防止被识别为代理。"
    echo -e " ${GREEN}1.${PLAIN} 系统默认 (通常 IPv6 优先)"
    echo -e " ${GREEN}2.${PLAIN} 强制 IPv4 优先 (推荐)"
    read -p " 请选择 [1-2] (默认 1): " IP_CHOICE
    [[ -z "$IP_CHOICE" ]] && IP_CHOICE=1

    [[ ! -f "$GAI_CONF" ]] && touch "$GAI_CONF"
    if [[ "$IP_CHOICE" == "2" ]]; then
        sed -i '/^precedence ::ffff:0:0\/96  100/d' "$GAI_CONF"
        echo "precedence ::ffff:0:0/96  100" >> "$GAI_CONF"
        echo -e "   ➜ 已设置: ${GREEN}IPv4 优先${PLAIN}"
    else
        sed -i '/^precedence ::ffff:0:0\/96  100/d' "$GAI_CONF"
        echo -e "   ➜ 已设置: ${CYAN}系统默认${PLAIN}"
    fi
    print_line
    # ================================

    generate_cert

    if [[ "$VER_TYPE" == "2" ]]; then
        cat > "$CONFIG_FILE" << EOF
{
    "port": $PORT,
    "token": ["$UUID"],
    "certificate": "$CERT_FILE",
    "private_key": "$KEY_FILE",
    "congestion_controller": "bbr",
    "alpn": ["h3"],
    "log_level": "info"
}
EOF
    else
        cat > "$CONFIG_FILE" << EOF
{
    "server": "[::]:$PORT",
    "users": { "$UUID": "$PASSWORD" },
    "certificate": "$CERT_FILE",
    "private_key": "$KEY_FILE",
    "congestion_control": "bbr",
    "alpn": ["h3", "spdy/3.1"],
    "log_level": "info"
}
EOF
    fi

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=TUIC Server
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

apply_firewall() {
    if grep -q "server" "$CONFIG_FILE"; then
        SERVER_STR=$(jq -r '.server' "$CONFIG_FILE")
        PORT=${SERVER_STR##*:}
    else
        PORT=$(jq -r '.port' "$CONFIG_FILE")
    fi
    print_info "配置防火墙规则..."
    if [[ "${RELEASE}" == "centos" ]]; then
        firewall-cmd --zone=public --add-port=$PORT/udp --permanent >/dev/null 2>&1; firewall-cmd --reload >/dev/null 2>&1
    else
        iptables -I INPUT -p udp --dport $PORT -j ACCEPT; if [ -f /etc/debian_version ]; then netfilter-persistent save >/dev/null 2>&1; else service iptables save >/dev/null 2>&1; fi
    fi
}

start_and_check() {
    systemctl enable tuic >/dev/null 2>&1; systemctl restart tuic; sleep 2
    if systemctl is-active --quiet tuic; then return 0; else echo -e ""; print_err "启动失败，请检查日志"; return 1; fi
}

show_result() {
    if [[ ! -f "$CONFIG_FILE" ]]; then print_err "未找到配置"; return; fi
    VER_TYPE=$(cat "$INSTALL_DIR/version_type" 2>/dev/null || echo "1")
    
    # 获取 IP (v4 & v6)
    IPV4=$(curl -s4m3 https://api.ipify.org)
    [[ -z "$IPV4" ]] && IPV4="无法获取IPv4"
    IPV6=$(curl -s6m3 https://api64.ipify.org)
    [[ -z "$IPV6" ]] && IPV6="无法获取IPv6"
    
    if ! command -v jq &> /dev/null; then install_deps; fi

    clear
    print_line
    echo -e "       TUIC 配置详情"
    print_line
    # 显示本地 IP
    echo -e " 本地 IP (IPv4) : ${GREEN}${IPV4}${PLAIN}"
    echo -e " 本地 IP (IPv6) : ${GREEN}${IPV6}${PLAIN}"
    echo ""

    # 分支处理：v4 和 v5
    if [[ "$VER_TYPE" == "2" ]]; then
        PORT=$(jq -r '.port' "$CONFIG_FILE")
        TOKEN=$(jq -r '.token[0]' "$CONFIG_FILE")

        # 导出链接 (置顶)
        echo -e "${BOLD} 🔗 导出链接 (直接导入)${PLAIN}"
        # v4 没有标准链接格式，此处仅留空或提示
        echo -e "${YELLOW}TUIC v4 无标准分享链接格式，请手动填入 OpenClash。${PLAIN}"
        echo ""
        
        # 表格
        echo -e "${BOLD} 📝 OpenClash (v4) 填空指引${PLAIN}"
        echo -e "┌─────────────────────┬──────────────────────────────────────┐"
        echo -e "│ OpenClash 选项      │ 应填内容                             │"
        echo -e "├─────────────────────┼──────────────────────────────────────┤"
        printf "│ 服务器地址          │ %-36s │\n" "${IPV4}"
        printf "│ 端口                │ %-36s │\n" "${PORT}"
        printf "│ 协议类型            │ %-36s │\n" "tuic"
        printf "│ 令牌 (Token)        │ %-36s │\n" "${TOKEN}"
        printf "│ 关闭 SNI            │ %-36s │\n" "❌ 不勾选 (False)"
        printf "│ 跳过证书验证        │ %-36s │\n" "✅ 勾选 (True)"
        echo -e "└─────────────────────┴──────────────────────────────────────┘"

    else
        # TUIC v5 处理
        SERVER_STR=$(jq -r '.server' "$CONFIG_FILE")
        PORT=${SERVER_STR##*:}
        
        UUID=$(jq -r '.users | keys_unsorted[0]' "$CONFIG_FILE")
        PASSWORD=$(jq -r --arg u "$UUID" '.users[$u]' "$CONFIG_FILE")
        
        # 导出链接 (置顶)
        echo -e "${BOLD} 🔗 导出链接 (直接导入)${PLAIN}"
        PARAMS="congestion_control=bbr&alpn=h3&sni=www.bing.com&udp_relay_mode=native&allow_insecure=1"
        if [[ -n "$IPV4" ]]; then 
            echo -e "${CYAN}tuic://${UUID}:${PASSWORD}@${IPV4}:${PORT}?${PARAMS}#TUIC-v5${PLAIN}"
        fi
        echo ""

        # 表格 (丰富版)
        echo -e "${BOLD} 📝 OpenClash (Meta内核) 填空指引${PLAIN}"
        echo -e "┌─────────────────────┬──────────────────────────────────────┐"
        echo -e "│ OpenClash 选项      │ 应填内容                             │"
        echo -e "├─────────────────────┼──────────────────────────────────────┤"
        printf "│ 服务器地址          │ %-36s │\n" "${IPV4}"
        printf "│ 端口                │ %-36s │\n" "${PORT}"
        printf "│ 协议类型            │ %-36s │\n" "tuic"
        printf "│ UUID                │ %-36s │\n" "${UUID}"
        printf "│ 密码                │ %-36s │\n" "${PASSWORD}"
        printf "│ SNI                 │ %-36s │\n" "www.bing.com"
        printf "│ 跳过证书验证        │ %-36s │\n" "✅ 勾选 (True)"
        printf "│ UDP转发模式         │ %-36s │\n" "native"
        printf "│ 拥塞控制            │ %-36s │\n" "bbr"
        printf "│ ALPN                │ %-36s │\n" "h3"
        echo -e "└─────────────────────┴──────────────────────────────────────┘"
        echo ""

        echo -e "${BOLD} 📋 YAML 配置代码 (Meta 内核专用 / 性能增强版)${PLAIN}"
        echo -e "${GREEN}"
        cat << EOF
  - name: "TUIC-v5"
    type: tuic
    server: www.bing.com
    port: ${PORT}
    ip: ${IPV4}
    uuid: ${UUID}
    password: ${PASSWORD}
    heartbeat-interval: 10000
    alpn: [h3]
    disable-sni: false
    reduce-rtt: true
    fast-open: true
    skip-cert-verify: true
    sni: www.bing.com
    udp-relay-mode: native
    congestion-controller: bbr
EOF
        echo -e "${PLAIN}"
    fi
    print_line
}

set_ip_preference() {
    clear
    print_line
    echo -e " ${BOLD}出站 IP 优先级设置${PLAIN}"
    print_line
    if grep -q "^precedence ::ffff:0:0/96  100" "$GAI_CONF" 2>/dev/null; then
        CURRENT_PREF="${GREEN}IPv4 优先${PLAIN}"
    else
        CURRENT_PREF="${CYAN}默认 (IPv6 优先)${PLAIN}"
    fi
    echo -e " 当前状态: ${CURRENT_PREF}"
    print_line
    echo -e " 1. 设置为 ${GREEN}IPv4 优先${PLAIN}"
    echo -e " 2. 恢复为 ${CYAN}系统默认${PLAIN}"
    print_line
    read -p " 请输入选项 [1-2]: " choice
    [[ ! -f "$GAI_CONF" ]] && touch "$GAI_CONF"
    case "$choice" in
        1)
            sed -i '/^precedence ::ffff:0:0\/96  100/d' "$GAI_CONF"
            echo "precedence ::ffff:0:0/96  100" >> "$GAI_CONF"
            print_ok "已设置为 IPv4 优先！"
            ;;
        2)
            sed -i '/^precedence ::ffff:0:0\/96  100/d' "$GAI_CONF"
            print_ok "已恢复默认 (IPv6 优先)！"
            ;;
        *) print_err "无效选项"; return ;;
    esac
    print_warn "重启服务中..."
    systemctl restart tuic
    print_ok "设置完成。"
    read -p "按回车返回..."
}

uninstall() {
    print_warn "正在卸载..."
    systemctl stop tuic; systemctl disable tuic
    rm -f "$SERVICE_FILE" "/usr/bin/tuic" "/usr/local/bin/tuic"
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
    systemctl daemon-reload
    print_ok "卸载完成"
}

show_menu() {
    clear
    if systemctl is-active --quiet tuic; then STATUS="${GREEN}运行中${PLAIN}"; else STATUS="${RED}未运行${PLAIN}"; fi
    print_line
    echo -e "${BOLD}     TUIC多版本 OpenClash优化版${PLAIN}"
    echo -e "  状态: ${STATUS}"
    print_line
    echo -e "  1. 重装 (v4/v5)"
    echo -e "  2. 查看配置 (表格/链接/YAML)"
    echo -e "  3. 实时日志"
    print_line
    echo -e "  4. 启动服务"
    echo -e "  5. 停止服务"
    echo -e "  6. 重启服务"
    print_line
    echo -e "  ${YELLOW}9. 出站 IP 偏好设置 (IPv4/IPv6)${PLAIN}"
    print_line
    echo -e "  8. 卸载"
    echo -e "  0. 退出"
    print_line
    read -p "  选择: " num
    case "$num" in
        1) run_install ;;
        2) [[ ! -f "$CONFIG_FILE" ]] && return; show_result; read -p "按回车返回..." ; show_menu ;;
        3) journalctl -u tuic -f ;;
        4) start_and_check; read -p "按回车继续..."; show_menu ;;
        5) systemctl stop tuic; print_warn "已停止"; sleep 1; show_menu ;;
        6) start_and_check; read -p "按回车继续..."; show_menu ;;
        9) set_ip_preference; show_menu ;;
        8) uninstall; exit 0 ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

run_install() {
    check_sys; install_deps; optimize_sysctl; install_core; configure; apply_firewall; create_shortcut; start_and_check && show_result
}

if [[ -f "$CONFIG_FILE" ]]; then show_menu; else run_install; fi
