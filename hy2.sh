#!/bin/bash

# ====================================================
# Hysteria 2 最终版
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
CONF_DIR="/etc/hysteria"
CONF_FILE="${CONF_DIR}/config.yaml"
CERT_FILE="${CONF_DIR}/server.crt"
KEY_FILE="${CONF_DIR}/server.key"
SERVICE_FILE="/etc/systemd/system/hysteria-server.service"
SHORTCUT_BIN="/usr/bin/hy"

# --- 辅助函数 ---
print_info() { echo -e "${CYAN}➜${PLAIN} $1"; }
print_ok()   { echo -e "${GREEN}✔${PLAIN} $1"; }
print_err()  { echo -e "${RED}✖${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}⚡${PLAIN} $1"; }

# --- 系统检查 ---
check_sys() {
    [[ $EUID -ne 0 ]] && print_err "请使用 root 运行" && exit 1
    if [ -f /etc/redhat-release ]; then RELEASE="centos"; else RELEASE="debian"; fi
}

install_deps() {
    if ! command -v wget &> /dev/null || ! command -v jq &> /dev/null || ! command -v bc &> /dev/null; then
        print_info "安装依赖 (wget, openssl, jq, bc)..."
        if [[ "${RELEASE}" == "centos" ]]; then
            yum install -y wget curl openssl iptables iptables-services jq net-tools bc >/dev/null 2>&1
        else
            apt update >/dev/null 2>&1
            apt install -y wget curl openssl iptables iptables-persistent jq net-tools bc >/dev/null 2>&1
        fi
    fi
}

# --- 核心安装 ---
install_core() {
    print_info "获取最新核心..."
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) HY_ARCH="amd64" ;;
        aarch64) HY_ARCH="arm64" ;;
        *) print_err "不支持架构: $ARCH"; exit 1 ;;
    esac

    # 获取最新版本，失败则使用固定稳定版
    LATEST_TAG=$(curl -sL https://api.github.com/repos/apernet/hysteria/releases/latest | jq -r .tag_name)
    [[ -z "$LATEST_TAG" || "$LATEST_TAG" == "null" ]] && LATEST_TAG="app/v2.2.4"
    
    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${LATEST_TAG}/hysteria-linux-${HY_ARCH}"
    wget -qO /usr/local/bin/hysteria "$DOWNLOAD_URL"
    
    if [[ $? -ne 0 ]]; then print_err "下载失败"; exit 1; fi
    chmod +x /usr/local/bin/hysteria
    mkdir -p $CONF_DIR
    print_ok "安装完成"
}

generate_cert() {
    print_info "生成证书..."
    openssl ecparam -genkey -name prime256v1 -out $KEY_FILE
    openssl req -new -x509 -days 36500 -key $KEY_FILE -out $CERT_FILE -subj "/CN=www.bing.com" >/dev/null 2>&1
    chmod 644 $CERT_FILE; chmod 600 $KEY_FILE
}

optimize_sysctl() {
    print_info "优化内核参数..."
    if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    # 移除旧配置
    sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
    # 写入高性能 QUIC 缓冲区配置
    cat >> /etc/sysctl.conf <<EOF
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
EOF
    sysctl -p >/dev/null 2>&1
}

check_port() {
    if [[ -n $(ss -tunlp | grep ":${1} " | grep "udp") ]]; then return 1; else return 0; fi
}

# --- BDP 计算 ---
calc_bdp() {
    echo -e "${CYAN}::${PLAIN} 智能参数计算 (基于 BDP)"
    read -p "   本地带宽 (Mbps) [默认 1000]: " BW_MBPS
    [[ -z "${BW_MBPS}" ]] && BW_MBPS=1000
    
    read -p "   Ping值 (ms)    [默认 150]: " LATENCY_MS
    [[ -z "${LATENCY_MS}" ]] && LATENCY_MS=150
    
    if ! command -v bc &> /dev/null; then
        print_warn "未找到 bc，使用通用高性能参数。"
        REC_STREAM=8388608
        REC_CONN=20971520
    else
        BDP_BYTES=$(echo "$BW_MBPS * 1000000 / 8 * $LATENCY_MS / 1000" | bc 2>/dev/null)
        [[ -z "$BDP_BYTES" ]] && BDP_BYTES=10000000
        
        REC_STREAM=$(echo "$BDP_BYTES * 1.5" | bc | awk '{printf("%d\n",$1)}')
        REC_CONN=$(echo "$REC_STREAM * 2.5" | bc | awk '{printf("%d\n",$1)}')
        
        # 设限
        if (( REC_STREAM < 8388608 )); then REC_STREAM=8388608; fi
        if (( REC_CONN < 20971520 )); then REC_CONN=20971520; fi
    fi
    
    echo -e "   ➜ 计算结果: 流 ${GREEN}$(echo $REC_STREAM | awk '{printf "%.1fMB", $1/1048576}')${PLAIN}, 连接 ${GREEN}$(echo $REC_CONN | awk '{printf "%.1fMB", $1/1048576}')${PLAIN}"
    
    QUIC_CONFIG=$(cat <<EOF

quic:
  initStreamReceiveWindow: $REC_STREAM
  maxStreamReceiveWindow: $REC_STREAM
  initConnReceiveWindow: $REC_CONN
  maxConnReceiveWindow: $REC_CONN
EOF
)
}

# --- 交互配置 ---
configure() {
    clear
    echo -e "${CYAN}──────────────────────────────────────────────────────────${PLAIN}"
    echo -e " ${BOLD}Hysteria 2 配置向导${PLAIN}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────${PLAIN}"

    # 1. 端口
    while true; do
        read -p "$(echo -e "${CYAN}::${PLAIN} 主监听端口 [回车默认 29949]: ")" PORT
        [[ -z "${PORT}" ]] && PORT=29949
        if check_port $PORT; then echo -e "   ➜ 使用端口: ${GREEN}$PORT${PLAIN}"; break; else print_err "端口占用"; fi
    done

    # 2. 端口跳跃
    echo ""
    read -p "$(echo -e "${CYAN}::${PLAIN} 是否开启端口跳跃? (y/n) [回车默认 y]: ")" ENABLE_HOPPING
    [[ -z "${ENABLE_HOPPING}" ]] && ENABLE_HOPPING="y"

    HOPPING_RANGE=""
    if [[ "${ENABLE_HOPPING}" =~ ^[yY]$ ]]; then
        read -p "$(echo -e "${CYAN}::${PLAIN} 跳跃范围 [回车默认 29950-30000]: ")" INPUT_RANGE
        [[ -z "${INPUT_RANGE}" ]] && INPUT_RANGE="29950-30000"
        HOPPING_RANGE=${INPUT_RANGE//-/:} 
        SHOW_RANGE=${INPUT_RANGE//:/-}
        echo -e "   ➜ 已启用范围: ${GREEN}$SHOW_RANGE${PLAIN}"
    else
        echo -e "   ➜ 已禁用端口跳跃"
    fi

    # 3. 密码
    echo ""
    read -p "$(echo -e "${CYAN}::${PLAIN} 认证密码 [回车随机生成]: ")" PASSWORD
    if [[ -z "${PASSWORD}" ]]; then
        PASSWORD=$(date +%s%N | md5sum | head -c 16)
        echo -e "   ➜ 随机密码: ${GREEN}$PASSWORD${PLAIN}"
    fi

    # 4. 混淆
    echo ""
    read -p "$(echo -e "${CYAN}::${PLAIN} 是否启用混淆? (y/n) [回车默认 n]: ")" ENABLE_OBFS
    [[ -z "${ENABLE_OBFS}" ]] && ENABLE_OBFS="n"
    
    OBFS_PASS=""
    if [[ "${ENABLE_OBFS}" =~ ^[yY]$ ]]; then
        read -p "$(echo -e "${CYAN}::${PLAIN} 混淆密码 [回车与认证密码一致]: ")" INPUT_OBFS
        [[ -z "${INPUT_OBFS}" ]] && OBFS_PASS=${PASSWORD} || OBFS_PASS=${INPUT_OBFS}
    fi

    # 5. IP 优先级 (修改思路：配置 outbound 模式)
    echo ""
    echo -e "${CYAN}::${PLAIN} 出站 IP 优先级"
    echo -e "   1) IPv4 优先 (强制 v4)"
    echo -e "   2) IPv6 优先"
    read -p "   请选择 [默认 1]: " PRIORITY_CHOICE
    
    # 这里设置 outbounds 的 mode
    # mode: 4 (IPv4 only), 64 (IPv6 first, then IPv4)
    # 不使用 auto，确保控制权
    if [[ "${PRIORITY_CHOICE}" == "2" ]]; then
        OUTBOUND_MODE="64"
    else
        OUTBOUND_MODE="4"
    fi

    # 6. QUIC 参数
    echo ""
    echo -e "${CYAN}::${PLAIN} QUIC 参数配置模式"
    echo -e "   1) 智能计算 (推荐)"
    echo -e "   2) 固定高性能"
    echo -e "   3) 默认值"
    read -p "   请选择 [默认 1]: " QUIC_MODE
    
    QUIC_CONFIG=""
    case "$QUIC_MODE" in
        2) 
            QUIC_CONFIG=$(cat <<EOF

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF
) ;;
        3) ;;
        *) calc_bdp ;;
    esac

    # 写入配置 (关键修改: 不使用 ACL，直接定义 outbounds)
    cat > $CONF_FILE <<EOF
listen: :$PORT

tls:
  cert: $CERT_FILE
  key: $KEY_FILE

auth:
  type: password
  password: $PASSWORD

bandwidth:
  up: 1000 mbps
  down: 1000 mbps

ignore_client_bandwidth: false

# 关键：定义名为 default 的 outbound，Hysteria 会默认使用它
outbounds:
  - name: default
    type: direct
    direct:
      mode: $OUTBOUND_MODE
EOF

    if [[ -n "${OBFS_PASS}" ]]; then
        echo -e "\nobfs:\n  type: salamander\n  password: $OBFS_PASS" >> $CONF_FILE
    fi
    if [[ -n "${QUIC_CONFIG}" ]]; then
        echo "$QUIC_CONFIG" >> $CONF_FILE
    fi

    cat > $SERVICE_FILE <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# --- 防火墙 ---
apply_firewall() {
    [[ -z "$PORT" ]] && PORT=$(grep "listen:" $CONF_FILE | awk '{print $2}' | sed 's/://')
    
    print_info "应用防火墙规则..."
    if [[ "${RELEASE}" == "centos" ]]; then
        firewall-cmd --zone=public --add-port=$PORT/udp --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    else
        iptables -I INPUT -p udp --dport $PORT -j ACCEPT
    fi
    iptables -t nat -F PREROUTING 2>/dev/null

    if [[ -n "$HOPPING_RANGE" ]]; then
        INTERFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
        iptables -t nat -A PREROUTING -i $INTERFACE -p udp --dport $HOPPING_RANGE -j REDIRECT --to-ports $PORT
        
        if [[ -f /etc/debian_version ]]; then
            netfilter-persistent save >/dev/null 2>&1
        elif [[ -f /etc/redhat-release ]]; then
            service iptables save >/dev/null 2>&1
        fi
    fi
}

# --- 启动并自检 ---
start_and_check() {
    systemctl enable hysteria-server >/dev/null 2>&1
    systemctl restart hysteria-server
    sleep 2
    if systemctl is-active --quiet hysteria-server; then
        return 0
    else
        echo -e ""
        print_err "服务启动失败！以下是错误日志："
        echo -e "${YELLOW}------------------------------------------------${PLAIN}"
        journalctl -u hysteria-server -n 20 --no-pager
        echo -e "${YELLOW}------------------------------------------------${PLAIN}"
        print_err "请检查配置或尝试重置。"
        return 1
    fi
}

# --- 链接与详情 ---
show_result() {
    if [[ ! -f $CONF_FILE ]]; then print_err "未找到配置"; return; fi
    
    if ! systemctl is-active --quiet hysteria-server; then
        print_warn "警告：服务未运行。"
    fi

    local C_PORT=$(grep "listen:" $CONF_FILE | awk '{print $2}' | sed 's/://')
    local C_PWD=$(grep -A 5 "auth:" $CONF_FILE | grep "password:" | awk '{print $2}')
    local C_OBFS=$(grep -A 5 "obfs:" $CONF_FILE | grep "password:" | awk '{print $2}')
    local OUT_MODE=$(grep -A 5 "direct:" $CONF_FILE | grep "mode:" | awk '{print $2}')
    
    local L_HOP=$SHOW_RANGE
    if [[ -z "$L_HOP" ]] && iptables -t nat -S PREROUTING | grep -q "REDIRECT"; then
        L_HOP="(已启用)"
    fi
    local Q_STREAM=$(grep "initStreamReceiveWindow:" $CONF_FILE | awk '{print $2}')
    local Q_CONN=$(grep "initConnReceiveWindow:" $CONF_FILE | awk '{print $2}')

    # 实测 IP 连接性
    IPV4=$(curl -s4m3 https://api.ipify.org)
    IPV6=$(curl -s6m3 https://api64.ipify.org)

    PARAMS="alpn=h3&insecure=1&up=100&down=1000"
    [[ -n "${C_OBFS}" ]] && PARAMS="${PARAMS}&obfs=salamander&obfs-password=${C_OBFS}"
    [[ -n "${SHOW_RANGE}" ]] && PARAMS="${PARAMS}&mport=${SHOW_RANGE}"

    clear
    echo -e "${CYAN}==========================================================${PLAIN}"
    echo -e "${BOLD}               Hysteria 2 配置详情列表${PLAIN}"
    echo -e "${CYAN}==========================================================${PLAIN}"
    
    echo -e "${BOLD} [基本信息]${PLAIN}"
    echo -e "  监听端口 : ${GREEN}${C_PORT}${PLAIN}"
    echo -e "  认证密码 : ${YELLOW}${C_PWD}${PLAIN}"
    [[ -n "${C_OBFS}" ]] && echo -e "  混淆密码 : ${YELLOW}${C_OBFS}${PLAIN}" || echo -e "  混淆模式 : ${CYAN}未启用${PLAIN}"
    [[ -n "${L_HOP}" ]] && echo -e "  端口跳跃 : ${GREEN}${L_HOP}${PLAIN}" || echo -e "  端口跳跃 : ${CYAN}未启用${PLAIN}"
    echo -e "  出站优先 : ${GREEN}$([ "$OUT_MODE" == "64" ] && echo "IPv6 优先" || echo "IPv4 强制")${PLAIN}"
    echo -e "  SNI 伪装 : ${CYAN}www.bing.com${PLAIN}"
    echo -e "  跳过验证 : ${GREEN}True (Insecure)${PLAIN}"

    echo -e ""
    echo -e "${CYAN}----------------------------------------------------------${PLAIN}"
    
    echo -e "${BOLD} [OpenClash QUIC 参数对照表]${PLAIN}"
    if [[ -n "${Q_STREAM}" ]]; then
        echo -e "  ${BLUE}initial_stream_receive_window     :${PLAIN} ${GREEN}${Q_STREAM}${PLAIN}"
        echo -e "  ${BLUE}max_stream_receive_window         :${PLAIN} ${GREEN}${Q_STREAM}${PLAIN}"
        echo -e "  ${BLUE}initial_connection_receive_window :${PLAIN} ${GREEN}${Q_CONN}${PLAIN}"
        echo -e "  ${BLUE}max_connection_receive_window     :${PLAIN} ${GREEN}${Q_CONN}${PLAIN}"
    else
        echo -e "  ${YELLOW}使用默认参数 (未配置)${PLAIN}"
    fi

    echo -e "${CYAN}==========================================================${PLAIN}"
    echo -e "${BOLD} 🚀 一键导入链接 (实测生成)${PLAIN}"
    echo -e ""
    
    HAS_LINK=false
    # 只有实测能通的 IP 才会生成链接
    if [[ -n "$IPV4" ]]; then
        LINK4="hysteria2://${C_PWD}@${IPV4}:${C_PORT}?${PARAMS}#Hy2-${HOSTNAME}-v4"
        echo -e "  ${BOLD}IPv4 链接:${PLAIN}"
        echo -e "  ${CYAN}${LINK4}${PLAIN}"
        echo ""
        HAS_LINK=true
    fi

    if [[ -n "$IPV6" ]]; then
        LINK6="hysteria2://${C_PWD}@[${IPV6}]:${C_PORT}?${PARAMS}#Hy2-${HOSTNAME}-v6"
        echo -e "  ${BOLD}IPv6 链接:${PLAIN}"
        echo -e "  ${GREEN}${LINK6}${PLAIN}"
        echo ""
        HAS_LINK=true
    fi

    if [[ "$HAS_LINK" == "false" ]]; then
        print_err "检测到服务器无法连接外网 (v4/v6 check failed)。"
    fi
    echo -e "${CYAN}==========================================================${PLAIN}"
}

uninstall() {
    print_warn "正在卸载 Hysteria 2..."
    systemctl stop hysteria-server
    systemctl disable hysteria-server
    rm -f $SERVICE_FILE $SHORTCUT_BIN
    rm -rf $CONF_DIR /usr/local/bin/hysteria
    iptables -t nat -F PREROUTING 2>/dev/null
    print_ok "卸载完成"
}

# --- 菜单 ---
show_menu() {
    clear
    if systemctl is-active --quiet hysteria-server; then
        STATUS="${GREEN}运行中${PLAIN}"
        PID=$(systemctl show -p MainPID hysteria-server | cut -d= -f2)
        MEM=$(ps -o rss= -p $PID 2>/dev/null | awk '{printf "%.1fMB", $1/1024}')
    else
        STATUS="${RED}未运行${PLAIN}"
        PID="N/A"
        MEM="0MB"
    fi

    echo -e "${CYAN}==========================================================${PLAIN}"
    echo -e "${BOLD}         Hysteria 2 管理面板 ${YELLOW}[V8.0]${PLAIN}"
    echo -e "${CYAN}==========================================================${PLAIN}"
    echo -e "  状态: ${STATUS}  |  PID: ${YELLOW}${PID}${PLAIN}  |  内存: ${YELLOW}${MEM}${PLAIN}"
    echo -e "${CYAN}==========================================================${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN}  全新安装 / 重置配置"
    echo -e "  ${GREEN}2.${PLAIN}  修改配置 (保留核心)"
    echo -e "  ${GREEN}3.${PLAIN}  查看配置 / 导出链接"
    echo -e "  ${GREEN}4.${PLAIN}  查看实时日志"
    echo -e "${CYAN}----------------------------------------------------------${PLAIN}"
    echo -e "  ${YELLOW}5.${PLAIN}  启动服务"
    echo -e "  ${YELLOW}6.${PLAIN}  停止服务"
    echo -e "  ${YELLOW}7.${PLAIN}  重启服务"
    echo -e "${CYAN}----------------------------------------------------------${PLAIN}"
    echo -e "  ${RED}8.${PLAIN}  卸载程序"
    echo -e "  ${RED}0.${PLAIN}  退出"
    echo -e "${CYAN}==========================================================${PLAIN}"
    
    read -p "  请输入选项 [0-8]: " num
    case "$num" in
        1) check_sys; install_deps; optimize_sysctl; install_core; generate_cert; configure; apply_firewall
           cp -f "$0" "$SHORTCUT_BIN"; chmod +x "$SHORTCUT_BIN"
           start_and_check && show_result ;;
        2) [[ ! -f $CONF_FILE ]] && return; configure; apply_firewall; start_and_check && show_result ;;
        3) show_result; read -p "  按回车键返回菜单..." ; show_menu ;;
        4) echo -e "${CYAN}Ctrl+C 退出日志${PLAIN}"; journalctl -u hysteria-server -f ;;
        5) start_and_check; read -p "按回车继续..."; show_menu ;;
        6) systemctl stop hysteria-server; print_warn "已停止"; sleep 1; show_menu ;;
        7) start_and_check; read -p "按回车继续..."; show_menu ;;
        8) uninstall; exit 0 ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

if [[ $# > 0 ]]; then show_menu; else show_menu; fi
