#!/bin/bash

# ====================================================
# 公共函数库 - own-rules 项目
# 版本: 1.0.0
# 说明: 所有脚本共享的通用函数，减少代码重复
# ====================================================

# --- 视觉与颜色 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 日志函数 (带时间戳) ---
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
print_info() { echo -e "${CYAN}➜${PLAIN} $1"; }
print_ok()   { echo -e "${GREEN}✔${PLAIN} $1"; }
print_err()  { echo -e "${RED}✖${PLAIN} $1"; }
print_warn() { echo -e "${YELLOW}⚡${PLAIN} $1"; }
print_line() { echo -e "${CYAN}──────────────────────────────────────────────────────────${PLAIN}"; }

# --- 系统检测 ---
detect_os() {
    if [[ $EUID -ne 0 ]]; then
        print_err "请使用 root 权限运行此脚本"
        exit 1
    fi
    
    if [ -f /etc/alpine-release ]; then
        RELEASE="alpine"
    elif [ -f /etc/redhat-release ]; then
        RELEASE="centos"
    elif [ -f /etc/debian_version ]; then
        RELEASE="debian"
    else
        RELEASE="unknown"
    fi
    
    export RELEASE
}

# --- 架构检测 ---
detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)
            ARCH_STD="amd64"
            ARCH_ALT="x86_64"
            ;;
        aarch64|arm64)
            ARCH_STD="arm64"
            ARCH_ALT="aarch64"
            ;;
        *)
            print_err "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    
    export ARCH ARCH_STD ARCH_ALT
}

# --- 端口检测 (兼容 ss 和 netstat) ---
check_port() {
    local port=$1
    # 优先使用 ss 命令
    if command -v ss &>/dev/null; then
        if ss -tunlp 2>/dev/null | grep -q ":${port} "; then
            return 1  # 端口被占用
        fi
    # 备选使用 netstat
    elif command -v netstat &>/dev/null; then
        if netstat -tunlp 2>/dev/null | grep -q ":${port} "; then
            return 1  # 端口被占用
        fi
    fi
    return 0  # 端口可用
}

# --- 获取公网 IP (增加超时时间) ---
get_ipv4() {
    local ip=""
    ip=$(curl -s4m8 https://api.ipify.org 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s4m8 https://ifconfig.me 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s4m8 https://ip.sb 2>/dev/null)
    echo "${ip:-无法获取IPv4}"
}

get_ipv6() {
    local ip=""
    ip=$(curl -s6m8 https://api64.ipify.org 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s6m8 https://ifconfig.me 2>/dev/null)
    echo "${ip:-无法获取IPv6}"
}

# --- 下载文件 (支持 wget 和 curl fallback) ---
download_file() {
    local url=$1
    local output=$2
    
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$output" "$url" 2>/dev/null || \
        wget -q -O "$output" "$url"
    elif command -v curl &>/dev/null; then
        curl -fsSL -o "$output" "$url"
    else
        print_err "未找到 wget 或 curl，请先安装"
        return 1
    fi
    
    # 检查下载是否成功
    if [[ ! -s "$output" ]]; then
        print_err "下载失败: $url"
        return 1
    fi
    return 0
}

# --- 安全保存配置文件 ---
save_config_secure() {
    local file=$1
    local content=$2
    
    echo "$content" > "$file"
    chmod 600 "$file"
}

# --- 系统优化 (BBR) ---
optimize_sysctl_bbr() {
    print_info "优化内核参数 (开启 BBR)..."
    [[ ! -f /etc/sysctl.conf ]] && touch /etc/sysctl.conf
    
    # 开启 BBR
    if ! grep -q "net.ipv4.tcp_congestion_control" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    
    # 优化 UDP 缓冲区
    sed -i '/net.core.rmem_max/d' /etc/sysctl.conf
    sed -i '/net.core.wmem_max/d' /etc/sysctl.conf
    cat >> /etc/sysctl.conf <<EOF
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
EOF
    
    sysctl -p >/dev/null 2>&1
    print_ok "内核参数优化完成"
}

# --- IP 优先级配置 ---
GAI_CONF="/etc/gai.conf"

apply_ip_preference() {
    local choice=$1
    
    # 确保 gai.conf 存在
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

    if [[ "$choice" == "1" || "$choice" == "ipv4" ]]; then
        # IPv4 优先
        sed -i '/^precedence ::ffff:0:0\/96/d' "$GAI_CONF"
        echo "precedence ::ffff:0:0/96  100" >> "$GAI_CONF"
        print_ok "已设置: 优先使用 IPv4"
    else
        # IPv6 优先 (系统默认)
        sed -i '/^precedence ::ffff:0:0\/96.*100/d' "$GAI_CONF"
        if ! grep -q "^precedence ::ffff:0:0/96" "$GAI_CONF"; then
            echo "precedence ::ffff:0:0/96  10" >> "$GAI_CONF"
        fi
        print_ok "已恢复: 系统默认 (IPv6 优先)"
    fi
}

get_current_ip_preference() {
    if grep -q "^precedence ::ffff:0:0/96.*100" "$GAI_CONF" 2>/dev/null; then
        echo "ipv4"
    else
        echo "ipv6"
    fi
}

# --- 防火墙规则 ---
apply_firewall_rule() {
    local port=$1
    local protocol=${2:-"tcp"}  # 默认 tcp，可选 udp 或 both
    
    print_info "配置防火墙规则 (端口: $port, 协议: $protocol)..."
    
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        # firewalld (CentOS/RHEL)
        if [[ "$protocol" == "both" || "$protocol" == "tcp" ]]; then
            firewall-cmd --zone=public --add-port=${port}/tcp --permanent >/dev/null 2>&1
        fi
        if [[ "$protocol" == "both" || "$protocol" == "udp" ]]; then
            firewall-cmd --zone=public --add-port=${port}/udp --permanent >/dev/null 2>&1
        fi
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables &>/dev/null; then
        # iptables
        if [[ "$protocol" == "both" || "$protocol" == "tcp" ]]; then
            iptables -C INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport ${port} -j ACCEPT
        fi
        if [[ "$protocol" == "both" || "$protocol" == "udp" ]]; then
            iptables -C INPUT -p udp --dport ${port} -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport ${port} -j ACCEPT
        fi
        
        # 保存规则
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save >/dev/null 2>&1
        elif [[ -f /etc/debian_version ]]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
        elif [[ "$RELEASE" == "centos" ]]; then
            service iptables save >/dev/null 2>&1
        elif [[ "$RELEASE" == "alpine" ]]; then
            /etc/init.d/iptables save >/dev/null 2>&1
        fi
    fi
    
    print_ok "防火墙规则已应用"
}

# --- 服务管理通用函数 ---
service_enable() {
    local name=$1
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-update add "$name" default >/dev/null 2>&1
    else
        systemctl enable "$name" >/dev/null 2>&1
    fi
}

service_start() {
    local name=$1
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service "$name" start
    else
        systemctl start "$name"
    fi
}

service_stop() {
    local name=$1
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service "$name" stop 2>/dev/null
    else
        systemctl stop "$name" 2>/dev/null
    fi
}

service_restart() {
    local name=$1
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service "$name" restart
    else
        systemctl restart "$name"
    fi
}

service_status() {
    local name=$1
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service "$name" status 2>/dev/null | grep -q "started"
    else
        systemctl is-active --quiet "$name"
    fi
}

# --- GitHub API 相关 ---
github_get_latest_release() {
    local repo=$1
    local json=""
    
    json=$(curl -sL --max-time 10 -H "User-Agent: Mozilla/5.0" \
        "https://api.github.com/repos/$repo/releases/latest")
    
    if [[ -z "$json" ]] || echo "$json" | grep -q "API rate limit"; then
        print_warn "GitHub API 受限，尝试获取 tags..."
        json=$(curl -sL --max-time 10 -H "User-Agent: Mozilla/5.0" \
            "https://api.github.com/repos/$repo/tags")
        if [[ -n "$json" ]]; then
            echo "$json" | jq -r '.[0].name' 2>/dev/null
            return
        fi
        return 1
    fi
    
    echo "$json" | jq -r '.tag_name' 2>/dev/null
}

github_get_release_json() {
    local repo=$1
    curl -sL --max-time 10 -H "User-Agent: Mozilla/5.0" \
        "https://api.github.com/repos/$repo/releases/latest"
}

# --- 生成随机密码 ---
generate_password() {
    local length=${1:-16}
    head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$length"
}

generate_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        # fallback: 使用 openssl 生成伪 UUID
        openssl rand -hex 16 | sed 's/\(..\{8\}\)\(..\{4\}\)\(..\{4\}\)\(..\{4\}\)\(..\{12\}\)/\1-\2-\3-\4-\5/'
    fi
}

# --- 版本比较 ---
version_gt() {
    # 返回 0 如果 $1 > $2
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

# --- 清理临时文件 ---
cleanup_temp() {
    rm -rf /tmp/install_* /tmp/*.zip /tmp/*.tar.* 2>/dev/null
}

# 导出所有函数供子脚本使用
export -f log print_info print_ok print_err print_warn print_line
export -f detect_os detect_arch check_port
export -f get_ipv4 get_ipv6 download_file save_config_secure
export -f optimize_sysctl_bbr apply_ip_preference get_current_ip_preference
export -f apply_firewall_rule
export -f service_enable service_start service_stop service_restart service_status
export -f github_get_latest_release github_get_release_json
export -f generate_password generate_uuid version_gt cleanup_temp
