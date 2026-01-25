#!/bin/bash

# ====================================================
# Hysteria 2 OpenClash 优化版 
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
# Systemd 路径
SYSTEMD_FILE="/etc/systemd/system/hysteria-server.service"
# OpenRC 路径 (Alpine)
OPENRC_FILE="/etc/init.d/hysteria-server"
SHORTCUT_BIN="/usr/bin/hy"

# --- 辅助函数 ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
print_info() { echo -e "${CYAN}➜${PLAIN} $1"; }
print_ok()   { echo -e "${GREEN}✔${PLAIN} $1"; }
print_err()  { echo -e "${RED}✖${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}⚡${PLAIN} $1"; }
# 【修复点】补回缺失的 print_line 函数
print_line() { echo -e "${CYAN}──────────────────────────────────────────────────────────${PLAIN}"; }

# --- 系统检查 ---
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

# --- 服务管理封装 ---
enable_service() {
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-update add hysteria-server default >/dev/null 2>&1
    else
        systemctl enable hysteria-server >/dev/null 2>&1
    fi
}

start_service() {
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service hysteria-server restart
    else
        systemctl restart hysteria-server
    fi
}

stop_service() {
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service hysteria-server stop
    else
        systemctl stop hysteria-server
    fi
}

check_service_status() {
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service hysteria-server status | grep -q "started"
    else
        systemctl is-active --quiet hysteria-server
    fi
}

# --- 安装依赖 ---
install_deps() {
    print_info "正在检测并安装依赖..."
    if [[ "$RELEASE" == "alpine" ]]; then
        apk update
        apk add wget curl jq openssl iptables ip6tables bc util-linux gcompat bash net-tools
    elif [[ "$RELEASE" == "centos" ]]; then
        yum install -y wget curl openssl iptables iptables-services jq net-tools bc util-linux
    else
        apt update
        apt install -y wget curl openssl iptables iptables-persistent jq net-tools bc uuid-runtime
    fi
}

# --- 创建快捷指令 ---
create_shortcut() {
    print_info "正在生成快捷指令 'hy'..."
    cp -f "$0" "$SHORTCUT_BIN"
    chmod +x "$SHORTCUT_BIN"
    print_ok "快捷指令创建成功！输入 'hy' 即可呼出面板"
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
    sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
    cat >> /etc/sysctl.conf <<EOF
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
EOF
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
    print_line
    echo -e " ${BOLD}Hysteria 2 配置向导 (无混淆版)${PLAIN}"
    print_line

    while true; do
        read -p "$(echo -e "${CYAN}::${PLAIN} 主监听端口 [回车默认 29949]: ")" PORT
        [[ -z "${PORT}" ]] && PORT=29949
        if check_port $PORT; then echo -e "   ➜ 使用端口: ${GREEN}$PORT${PLAIN}"; break; else print_err "端口占用"; fi
    done

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

    echo ""
    read -p "$(echo -e "${CYAN}::${PLAIN} 认证密码 [回车随机生成 UUID]: ")" PASSWORD
    if [[ -z "${PASSWORD}" ]]; then
        if command -v uuidgen &> /dev/null; then
            PASSWORD=$(uuidgen)
        else
            PASSWORD=$(cat /proc/sys/kernel/random/uuid)
        fi
        echo -e "   ➜ 随机 UUID: ${GREEN}$PASSWORD${PLAIN}"
    fi

    echo ""
    echo -e "${CYAN}::${PLAIN} 出站 IP 优先级"
    echo -e "   1) IPv4 优先 (46: 优先v4, v6备用)"
    echo -e "   2) IPv6 优先 (64: 优先v6, v4备用)"
    read -p "   请选择 [默认 1]: " PRIORITY_CHOICE
    
    if [[ "${PRIORITY_CHOICE}" == "2" ]]; then
        OUTBOUND_MODE="64"
    else
        OUTBOUND_MODE="46"
    fi

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

outbounds:
  - name: default
    type: direct
    direct:
      mode: $OUTBOUND_MODE
EOF
    chmod 600 "$CONF_FILE"

    if [[ -n "${QUIC_CONFIG}" ]]; then
        echo "$QUIC_CONFIG" >> $CONF_FILE
    fi

    if [[ "$RELEASE" == "alpine" ]]; then
        cat > $OPENRC_FILE <<EOF
#!/sbin/openrc-run

name="hysteria-server"
description="Hysteria 2 Server"
command="/usr/local/bin/hysteria"
command_args="server -c /etc/hysteria/config.yaml"
command_background=true
pidfile="/run/hysteria-server.pid"

depend() {
    need net
    after firewall
}
EOF
        chmod +x $OPENRC_FILE
    else
        cat > $SYSTEMD_FILE <<EOF
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
    fi
}

# --- 切换 IP 优先级 (新增) ---
set_ip_preference() {
    if [[ ! -f "$CONF_FILE" ]]; then print_err "未找到配置文件"; return; fi
    
    # 检查当前状态
    CURRENT_MODE=$(grep "mode:" "$CONF_FILE" | awk '{print $2}')
    if [[ "$CURRENT_MODE" == "46" ]]; then
        CURRENT_SHOW="${GREEN}IPv4 优先 (46)${PLAIN}"
    elif [[ "$CURRENT_MODE" == "64" ]]; then
        CURRENT_SHOW="${CYAN}IPv6 优先 (64)${PLAIN}"
    else
        CURRENT_SHOW="${YELLOW}其他 ($CURRENT_MODE)${PLAIN}"
    fi

    clear
    print_line
    echo -e " ${BOLD}出站 IP 优先级设置${PLAIN}"
    print_line
    echo -e " 当前状态: ${CURRENT_SHOW}"
    print_line
    echo -e " 1. 设置为 ${GREEN}IPv4 优先${PLAIN} (优先v4, v6备用)"
    echo -e " 2. 设置为 ${CYAN}IPv6 优先${PLAIN} (优先v6, v4备用)"
    print_line
    read -p " 请输入选项 [1-2]: " choice
    
    case "$choice" in
        1) MODE="46" ;;
        2) MODE="64" ;;
        *) print_err "无效选项"; return ;;
    esac

    # 修改配置
    if grep -q "mode:" "$CONF_FILE"; then
        sed -i "s/mode: .*/mode: $MODE/" "$CONF_FILE"
    else
        print_err "配置文件格式不匹配，建议重装。"
        return
    fi

    print_warn "正在重启服务以应用更改..."
    start_service
    print_ok "设置成功！"
    read -p "按回车返回..."
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
        if [[ -n "$HOPPING_RANGE" ]]; then
            INTERFACE=$(ip route get 8.8.8.8 | grep -oP 'dev \K\S+')
            iptables -t nat -A PREROUTING -i $INTERFACE -p udp --dport $HOPPING_RANGE -j REDIRECT --to-ports $PORT
        fi
        
        if [[ -f /etc/debian_version ]]; then
            netfilter-persistent save >/dev/null 2>&1
        elif [[ "$RELEASE" == "alpine" ]]; then
            /etc/init.d/iptables save >/dev/null 2>&1
            rc-update add iptables default >/dev/null 2>&1
        fi
    fi
}

# --- 启动并自检 ---
start_and_check() {
    enable_service
    start_service
    sleep 2
    if check_service_status; then
        return 0
    else
        echo -e ""
        print_err "服务启动失败！日志如下："
        echo -e "${YELLOW}------------------------------------------------${PLAIN}"
        if [[ "$RELEASE" == "alpine" ]]; then
            echo "请运行: tail -f /var/log/messages"
        else
            journalctl -u hysteria-server -n 20 --no-pager
        fi
        echo -e "${YELLOW}------------------------------------------------${PLAIN}"
        return 1
    fi
}

# --- 链接与详情 ---
show_result() {
    if [[ ! -f $CONF_FILE ]]; then print_err "未找到配置"; return; fi
    
    local C_PORT=$(grep "listen:" $CONF_FILE | awk '{print $2}' | sed 's/://')
    local C_PWD=$(grep -A 5 "auth:" $CONF_FILE | grep "password:" | awk '{print $2}')
    
    local Q_STREAM=$(grep "initStreamReceiveWindow:" $CONF_FILE | awk '{print $2}')
    local Q_CONN=$(grep "initConnReceiveWindow:" $CONF_FILE | awk '{print $2}')

    local HOP_RANGE_DETECT=$(iptables -t nat -S PREROUTING 2>/dev/null | grep "REDIRECT" | grep "to-ports ${C_PORT}" | grep -oP 'dport \K\S+' | head -n 1)
    HOP_RANGE_DETECT=${HOP_RANGE_DETECT/:/-}

    # 获取指纹
    local CERT_FINGERPRINT=$(openssl x509 -noout -fingerprint -sha256 -in $CERT_FILE | cut -d= -f2)

    IPV4=$(curl -s4m8 https://api.ipify.org)
    [[ -z "$IPV4" ]] && IPV4=$(curl -s4m8 https://ifconfig.me)
    [[ -z "$IPV4" ]] && IPV4="无法获取IPv4"
    IPV6=$(curl -s6m8 https://api64.ipify.org)
    [[ -z "$IPV6" ]] && IPV6="无法获取IPv6"

    PARAMS="alpn=h3&insecure=1&up=100&down=1000"
    [[ -n "${HOP_RANGE_DETECT}" ]] && PARAMS="${PARAMS}&mport=${HOP_RANGE_DETECT}"
    LINK4="hysteria2://${C_PWD}@${IPV4}:${C_PORT}?${PARAMS}#Hy2-${HOSTNAME}"

    clear
    print_line
    echo -e "       Hysteria 2 配置详情"
    print_line
    echo -e " 本地 IP (IPv4) : ${GREEN}${IPV4}${PLAIN}"
    echo -e " 本地 IP (IPv6) : ${GREEN}${IPV6}${PLAIN}"
    echo ""

    echo -e " 🔗 导出链接 (直接导入)"
    echo -e "${CYAN}${LINK4}${PLAIN}"
    echo ""

    echo -e " 📝 OpenClash (Meta内核) 填空指引"
    echo -e " ┌─────────────────────┬──────────────────────────────────────┐"
    echo -e " │ OpenClash 选项      │ 应填内容                             │"
    echo -e " ├─────────────────────┼──────────────────────────────────────┤"
    
    printf " │ 服务器地址          │ %-36s │\n" "${IPV4}"
    printf " │ 端口                │ %-36s │\n" "${C_PORT}"

    if [[ -n "${HOP_RANGE_DETECT}" ]]; then
        printf " │ 端口跳跃            │ %-36s │\n" "${HOP_RANGE_DETECT}"
    else
        printf " │ 端口跳跃            │ %-36s │\n" "未启用"
    fi

    printf " │ 协议类型            │ %-36s │\n" "hysteria2"
    printf " │ UUID / 密码         │ %-36s │\n" "${C_PWD}"
    printf " │ SNI                 │ %-36s │\n" "www.bing.com"
    printf " │ 跳过证书验证        │ %-36s │\n" "☑ 勾选 (True)"
    printf " │ UDP模式             │ %-36s │\n" "☑ 勾选 (True)"

    echo -e " └─────────────────────┴──────────────────────────────────────┘"
    echo ""

    echo -e " 📄 YAML 配置代码 (Meta 内核专用 / 性能增强版)"
    echo -e ""
    echo -e "${GREEN}  - name: ${PLAIN}\"Hysteria2\""
    echo -e "${GREEN}    type: ${PLAIN}hysteria2"
    echo -e "${GREEN}    server: ${PLAIN}${IPV4}"
    echo -e "${GREEN}    port: ${PLAIN}${C_PORT}"
    
    if [[ -n "${HOP_RANGE_DETECT}" ]]; then
        echo -e "${GREEN}    ports: ${PLAIN}${HOP_RANGE_DETECT}"
    fi

    echo -e "${GREEN}    password: ${PLAIN}${C_PWD}"
    echo -e "${GREEN}    sni: ${PLAIN}www.bing.com"
    echo -e "${GREEN}    skip-cert-verify: ${PLAIN}true"
    
    # 指纹输出
    if [[ -n "${CERT_FINGERPRINT}" ]]; then
        echo -e "${GREEN}    fingerprint: ${PLAIN}${CERT_FINGERPRINT}"
    fi

    echo -e "${GREEN}    up: ${PLAIN}1000 mbps"
    echo -e "${GREEN}    down: ${PLAIN}1000 mbps"
    echo -e "${GREEN}    alpn: ${PLAIN}[h3]"
    echo -e "${GREEN}    hop-interval: ${PLAIN}30"
    
    if [[ -n "${Q_STREAM}" ]]; then
        echo -e "${GREEN}    init-stream-receive-window: ${PLAIN}${Q_STREAM}"
        echo -e "${GREEN}    max-stream-receive-window: ${PLAIN}${Q_STREAM}"
        echo -e "${GREEN}    init-conn-receive-window: ${PLAIN}${Q_CONN}"
        echo -e "${GREEN}    max-conn-receive-window: ${PLAIN}${Q_CONN}"
    fi

    echo -e ""
    print_line
}

uninstall() {
    print_warn "正在卸载 Hysteria 2..."
    stop_service
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-update del hysteria-server default >/dev/null 2>&1
        rm -f $OPENRC_FILE
    else
        systemctl disable hysteria-server >/dev/null 2>&1
        rm -f $SERVICE_FILE
        systemctl daemon-reload
    fi
    rm -f $SHORTCUT_BIN
    rm -rf $CONF_DIR /usr/local/bin/hysteria
    iptables -t nat -F PREROUTING 2>/dev/null
    print_ok "卸载完成"
}

# --- 菜单 ---
show_menu() {
    clear
    if check_service_status; then
        STATUS="${GREEN}运行中${PLAIN}"
        if [[ "$RELEASE" == "alpine" ]]; then
            PID=$(cat /run/hysteria-server.pid 2>/dev/null)
        else
            PID=$(systemctl show -p MainPID hysteria-server | cut -d= -f2)
        fi
    else
        STATUS="${RED}未运行${PLAIN}"
        PID="N/A"
    fi

    print_line
    echo -e "${BOLD}     Hysteria 2 OpenClash 优化版 (Alpine Fix)${PLAIN}"
    print_line
    echo -e "  状态: ${STATUS}  |  PID: ${YELLOW}${PID}${PLAIN}"
    print_line
    echo -e "  ${GREEN}1.${PLAIN}  全新安装 / 重置配置"
    echo -e "  ${GREEN}2.${PLAIN}  修改配置 (保留核心)"
    echo -e "  ${GREEN}3.${PLAIN}  查看配置 / 导出链接"
    echo -e "  ${GREEN}4.${PLAIN}  查看实时日志"
    print_line
    echo -e "  ${YELLOW}5.${PLAIN}  启动服务"
    echo -e "  ${YELLOW}6.${PLAIN}  停止服务"
    echo -e "  ${YELLOW}7.${PLAIN}  重启服务"
    echo -e "${CYAN}----------------------------------------------------------${PLAIN}"
    echo -e "  ${YELLOW}9. 出站 IP 偏好设置 (IPv4/IPv6)${PLAIN}"
    print_line
    echo -e "  ${RED}8.${PLAIN}  卸载程序"
    echo -e "  ${RED}0.${PLAIN}  退出"
    print_line
    
    read -p "  请输入选项 [0-8]: " num
    case "$num" in
        1) check_sys; install_deps; optimize_sysctl; install_core; generate_cert; configure; apply_firewall
           create_shortcut 
           start_and_check && show_result ;;
        2) [[ ! -f $CONF_FILE ]] && return; configure; apply_firewall; start_and_check && show_result ;;
        3) show_result; read -p "  按回车键返回菜单..." ; show_menu ;;
        4) echo -e "${CYAN}Ctrl+C 退出日志${PLAIN}"; 
           if [[ "$RELEASE" == "alpine" ]]; then tail -f /var/log/messages | grep hysteria; else journalctl -u hysteria-server -f; fi ;;
        5) start_and_check; read -p "按回车继续..."; show_menu ;;
        6) stop_service; print_warn "已停止"; sleep 1; show_menu ;;
        7) start_and_check; read -p "按回车继续..."; show_menu ;;
        9) set_ip_preference; show_menu ;;
        8) uninstall; exit 0 ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

if [[ $# > 0 ]]; then show_menu; else show_menu; fi
