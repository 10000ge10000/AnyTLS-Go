#!/bin/bash

# Shadowsocks-2022 (Rust) 终极版 v3.1
# 特性：在线检测公网IP + 自动配置防火墙 + 双栈独立监听
# 作者：10000ge10000

set -e

# --- 变量配置 ---
readonly REPO="shadowsocks/shadowsocks-rust"
readonly INSTALL_DIR="/opt/ss-rust"
readonly CONFIG_DIR="/etc/shadowsocks-rust"
readonly SERVICE_NAME="shadowsocks-rust"

# --- 颜色 ---
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# --- 辅助函数 ---
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 在线 IP 获取函数 (多源轮询，5秒超时)
get_public_ip() {
    local version=$1 # -4 or -6
    local ip=""
    local urls=(
        "https://api.ip.sb/ip"
        "https://ifconfig.co/ip"
        "https://api64.ipify.org"
        "https://icanhazip.com"
        "http://checkip.amazonaws.com"
    )

    for url in "${urls[@]}"; do
        if [[ "$version" == "-6" ]] && [[ "$url" == *"amazonaws"* ]]; then continue; fi
        ip=$(curl -s $version --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" ]] && [[ ! "$ip" =~ "<" ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo ""
}

# 1. 权限与环境检查
[[ $EUID -ne 0 ]] && err "请使用 root 权限运行"

info "系统环境检测..."
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64) RUST_ARCH="x86_64" ;;
    aarch64|arm64) RUST_ARCH="aarch64" ;;
    *) err "不支持的架构: $ARCH" ;;
esac

# 2. 安装依赖
# net-tools 用于端口检查，curl 用于在线IP检测
DEPS=("curl" "wget" "tar" "openssl" "xz-utils" "netstat")
INSTALL_LIST=""
for dep in "${DEPS[@]}"; do
    if ! command -v $dep &> /dev/null; then
        if [[ "$dep" == "netstat" ]]; then INSTALL_LIST="$INSTALL_LIST net-tools";
        else INSTALL_LIST="$INSTALL_LIST $dep"; fi
    fi
done

if [[ -n "$INSTALL_LIST" ]]; then
    info "安装必要依赖: $INSTALL_LIST ..."
    if command -v apt &> /dev/null; then
        apt-get update -y && apt-get install -y $INSTALL_LIST
    elif command -v yum &> /dev/null; then
        yum install -y $INSTALL_LIST
    fi
fi

# 3. 时间同步 (防止 Time Skew 导致无法连接)
info "校准系统时间..."
if command -v timedatectl &> /dev/null; then
    timedatectl set-ntp true || true
fi

# 4. 下载与安装
info "下载 Shadowsocks-Rust..."
LATEST_VERSION=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | cut -d '"' -f 4)
[[ -z "$LATEST_VERSION" ]] && err "获取版本失败，请检查网络"

FILENAME="shadowsocks-${LATEST_VERSION}.${RUST_ARCH}-unknown-linux-gnu.tar.xz"
cd /tmp
wget -O "$FILENAME" "https://github.com/$REPO/releases/download/${LATEST_VERSION}/${FILENAME}" || err "下载失败"

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
tar -xf "$FILENAME" -C "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/ssserver"
ln -sf "$INSTALL_DIR/ssserver" /usr/local/bin/ssserver
rm -f "$FILENAME"

# 5. 配置向导
echo -e "\n${YELLOW}--- 配置向导 ---${NC}"
read -p "请输入端口 [默认 9000]: " USER_PORT
USER_PORT=${USER_PORT:-9000}

echo -e "加密方式: 1) aes-128-gcm (推荐)  2) chacha20-poly1305 (移动端)"
read -p "选择 [1-2] (默认 1): " M_OPT
if [[ "$M_OPT" == "2" ]]; then
    METHOD="2022-blake3-chacha20-poly1305"; KEY_LEN=32
else
    METHOD="2022-blake3-aes-128-gcm"; KEY_LEN=16
fi

USER_PASSWORD=$(openssl rand -base64 $KEY_LEN)

# 配置文件 (使用 servers 数组模式，最稳妥的双栈配置)
cat > "$CONFIG_DIR/config.json" << EOF
{
    "servers": [
        {
            "address": "0.0.0.0",
            "port": $USER_PORT,
            "password": "$USER_PASSWORD",
            "method": "$METHOD"
        },
        {
            "address": "::",
            "port": $USER_PORT,
            "password": "$USER_PASSWORD",
            "method": "$METHOD"
        }
    ],
    "mode": "tcp_and_udp",
    "timeout": 300,
    "fast_open": true
}
EOF

# 6. 配置 Systemd
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Shadowsocks-Rust
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/ssserver -c ${CONFIG_DIR}/config.json
Restart=always
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
sleep 2

# 7. 防火墙自动放行 (解决连接不通的关键)
info "正在配置防火墙..."
FIREWALL_UPDATED=0

# UFW (Ubuntu/Debian)
if command -v ufw &> /dev/null && systemctl is-active --quiet ufw; then
    ufw allow "$USER_PORT"/tcp
    ufw allow "$USER_PORT"/udp
    info "已添加 UFW 规则"
    FIREWALL_UPDATED=1
fi

# Firewalld (CentOS/Fedora)
if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="$USER_PORT"/tcp
    firewall-cmd --permanent --add-port="$USER_PORT"/udp
    firewall-cmd --reload
    info "已添加 Firewalld 规则"
    FIREWALL_UPDATED=1
fi

# IPTables (通用兜底)
if command -v iptables &> /dev/null; then
    iptables -I INPUT -p tcp --dport "$USER_PORT" -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport "$USER_PORT" -j ACCEPT 2>/dev/null || true
    info "已尝试添加 iptables 规则"
    FIREWALL_UPDATED=1
fi

if [[ $FIREWALL_UPDATED -eq 0 ]]; then
    warn "未检测到活跃的防火墙服务，已跳过。请确保云厂商安全组放行端口：$USER_PORT"
fi

# 8. 启动自检
info "执行启动自检..."
if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    err "服务启动失败！请检查日志: journalctl -u shadowsocks-rust -n 20"
fi

if ! netstat -lnp | grep -q ":$USER_PORT "; then
    err "服务已启动但未监听端口。请检查端口 $USER_PORT 是否被占用。"
else
    info "检测通过：端口 $USER_PORT 正在监听"
fi

# 9. 在线获取 IP 并输出 (恢复你需要的功能)
info "正在联网获取真实公网 IP..."
IPV4=$(get_public_ip -4)
IPV6=$(get_public_ip -6)

# 显示处理
if [[ -z "$IPV4" ]]; then
    IPV4_DISPLAY="检测失败 (请手动填写)"
    URI_HOST="YOUR_IPV4_IP"
else
    IPV4_DISPLAY="$IPV4"
    URI_HOST="$IPV4"
fi

[[ -z "$IPV6" ]] && IPV6_DISPLAY="未检测到 IPv6" || IPV6_DISPLAY="$IPV6"

SS_URI="ss://$(echo -n "${METHOD}:${USER_PASSWORD}" | base64 -w 0)@${URI_HOST}:${USER_PORT}#SS-2022"

echo -e "\n${GREEN}=========================================="
echo -e " Shadowsocks-2022 (v3.1) 安装成功！"
echo -e "==========================================${NC}"
echo -e " 端口: $USER_PORT"
echo -e " 密码: $USER_PASSWORD"
echo -e " 加密: $METHOD"
echo -e "------------------------------------------"
echo -e " 公网 IPv4: $IPV4_DISPLAY"
echo -e " 公网 IPv6: $IPV6_DISPLAY"
echo -e "------------------------------------------"
echo -e " 客户端链接 (直接复制):"
echo -e "${GREEN}${SS_URI}${NC}"
echo -e "------------------------------------------"
if [[ "$URI_HOST" != "YOUR_IPV4_IP" ]]; then
    echo -e "${YELLOW}提示: 此链接已包含你的真实公网 IP，可直接导入。${NC}"
else
    echo -e "${RED}警告: 未能获取公网IP，请将链接中的 YOUR_IPV4_IP 手动替换为你的服务器IP。${NC}"
fi
echo -e "\n如果仍无法连接，请务必去云服务商网页后台(安全组)放行 TCP/UDP 端口 $USER_PORT"
