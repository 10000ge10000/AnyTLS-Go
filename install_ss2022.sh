#!/bin/bash

# Shadowsocks-2022 (Rust) 双栈兼容版安装脚本 v2.1
# 特性：默认开启 IPv4 + IPv6 双栈监听 + 多重 IP 检测机制
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
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# --- 辅助函数 ---
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 新增：健壮的 IP 获取函数（尝试多个源）
get_public_ip() {
    local version=$1 # -4 or -6
    local ip=""
    
    # 定义多个 IP 查询接口作为备选
    local urls=(
        "https://api.ip.sb/ip"
        "https://ifconfig.co/ip"
        "https://api64.ipify.org"
        "https://icanhazip.com"
        "http://checkip.amazonaws.com" # 仅支持IPv4
    )

    for url in "${urls[@]}"; do
        # 跳过 IPv6 不支持的 URL (简单判断)
        if [[ "$version" == "-6" ]] && [[ "$url" == *"amazonaws"* ]]; then continue; fi

        # 尝试获取 IP，超时时间设置为 5 秒
        ip=$(curl -s $version --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        
        # 简单验证 IP 格式（非空且不包含 HTML 标签）
        if [[ -n "$ip" ]] && [[ ! "$ip" =~ "<" ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    echo "" # 如果都失败，返回空
}

# 1. 权限检查
[[ $EUID -ne 0 ]] && err "请使用 root 权限运行此脚本"

# 2. 依赖检查与架构识别
info "检测系统环境..."
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64) RUST_ARCH="x86_64" ;;
    aarch64|arm64) RUST_ARCH="aarch64" ;;
    *) err "不支持的架构: $ARCH" ;;
esac

# 检查必要工具
DEPS=("curl" "wget" "tar" "openssl" "xz-utils")
INSTALL_LIST=""
for dep in "${DEPS[@]}"; do
    if ! command -v $dep &> /dev/null; then
        INSTALL_LIST="$INSTALL_LIST $dep"
    fi
done

if [[ -n "$INSTALL_LIST" ]]; then
    info "安装缺失依赖: $INSTALL_LIST ..."
    if command -v apt &> /dev/null; then
        apt-get update && apt-get install -y $INSTALL_LIST
    elif command -v yum &> /dev/null; then
        yum install -y $INSTALL_LIST
    else
        warn "无法自动安装依赖，请手动安装: $INSTALL_LIST"
    fi
fi

# 3. 下载 shadowsocks-rust
info "获取最新版本信息..."
LATEST_VERSION=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | cut -d '"' -f 4)
[[ -z "$LATEST_VERSION" ]] && err "无法获取版本信息"

info "正在下载版本: $LATEST_VERSION ($RUST_ARCH)..."
FILENAME="shadowsocks-${LATEST_VERSION}.${RUST_ARCH}-unknown-linux-gnu.tar.xz"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/${LATEST_VERSION}/${FILENAME}"

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
cd /tmp
wget -O "$FILENAME" "$DOWNLOAD_URL" || err "下载失败"

info "解压安装..."
tar -xf "$FILENAME" -C "$INSTALL_DIR"
chmod +x "$INSTALL_DIR/ssserver"
ln -sf "$INSTALL_DIR/ssserver" /usr/local/bin/ssserver
rm -f "$FILENAME"

# 4. 用户交互配置
echo -e "\n${CYAN}--- Shadowsocks-2022 (IPv6兼容版) 配置向导 ---${NC}"

# 端口选择
read -p "请输入端口 [默认 9000]: " USER_PORT
USER_PORT=${USER_PORT:-9000}

# 协议/加密方式选择
echo -e "\n请选择加密方式 (推荐使用 2022 新协议):"
echo "1) 2022-blake3-aes-128-gcm (极速，推荐 VPS 有 AES 指令集使用)"
echo "2) 2022-blake3-chacha20-poly1305 (通用，推荐 手机端/ARM 使用)"
echo "3) 2022-blake3-aes-256-gcm (高安，性能消耗稍大)"
read -p "请选择 [1-3] (默认 1): " METHOD_CHOICE

case "$METHOD_CHOICE" in
    2)
        METHOD="2022-blake3-chacha20-poly1305"
        KEY_LEN=32
        ;;
    3)
        METHOD="2022-blake3-aes-256-gcm"
        KEY_LEN=32
        ;;
    *)
        METHOD="2022-blake3-aes-128-gcm"
        KEY_LEN=16
        ;;
esac

# 密钥生成
info "正在生成符合 $METHOD 标准的密钥..."
USER_PASSWORD=$(openssl rand -base64 $KEY_LEN)

# 生成配置文件
cat > "$CONFIG_DIR/config.json" << EOF
{
    "server": ["::", "0.0.0.0"],
    "server_port": $USER_PORT,
    "password": "$USER_PASSWORD",
    "method": "$METHOD",
    "mode": "tcp_and_udp",
    "timeout": 300,
    "fast_open": true
}
EOF

# 5. 配置 Systemd 服务
info "配置系统服务..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Shadowsocks-Rust Server (Dual Stack)
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
if systemctl is-active --quiet "$SERVICE_NAME"; then
    systemctl restart "$SERVICE_NAME"
else
    systemctl enable --now "$SERVICE_NAME"
fi

# 6. 管理脚本
cat > "/usr/local/bin/ss-manage" << 'EOF'
#!/bin/bash
case $1 in
    start)   systemctl start shadowsocks-rust; echo "已启动" ;;
    stop)    systemctl stop shadowsocks-rust; echo "已停止" ;;
    restart) systemctl restart shadowsocks-rust; echo "已重启" ;;
    status)  systemctl status shadowsocks-rust --no-pager ;;
    log)     journalctl -u shadowsocks-rust -f ;;
    config)  cat /etc/shadowsocks-rust/config.json ;;
    *)       echo "用法: ss-manage [start|stop|restart|status|log|config]" ;;
esac
EOF
chmod +x /usr/local/bin/ss-manage

# 7. 完成输出 (修复 IP 获取逻辑)
info "正在获取公网 IP 地址 (尝试多个接口)..."

IPV4=$(get_public_ip -4)
IPV6=$(get_public_ip -6)

# 如果 IPv4 获取失败，设置默认提示
if [[ -z "$IPV4" ]]; then
    IPV4_DISPLAY="无法获取 (请检查网络)"
    # 如果没获取到 IP，链接里填 YOUR_IPV4_IP 提示用户手动填
    URI_HOST="YOUR_IPV4_IP"
else
    IPV4_DISPLAY="$IPV4"
    URI_HOST="$IPV4"
fi

if [[ -z "$IPV6" ]]; then
    IPV6_DISPLAY="未检测到 IPv6"
else
    IPV6_DISPLAY="$IPV6"
fi

# 生成 SS 链接
SS_URI="ss://$(echo -n "${METHOD}:${USER_PASSWORD}" | base64 -w 0)@${URI_HOST}:${USER_PORT}#SS-2022"

echo -e "\n${GREEN}=========================================="
echo -e " Shadowsocks-2022 (IPv4/IPv6) 安装成功！"
echo -e "==========================================${NC}"
echo -e " 服务端口: $USER_PORT"
echo -e " 加密方式: $METHOD"
echo -e " 访问密钥: $USER_PASSWORD"
echo -e "------------------------------------------"
echo -e " 监听状态: ${CYAN}IPv4 + IPv6 双栈已启用${NC}"
echo -e " IPv4 地址: $IPV4_DISPLAY"
echo -e " IPv6 地址: $IPV6_DISPLAY"
echo -e "------------------------------------------"
echo -e " 客户端导入链接 (默认使用 IPv4):"
echo -e "${CYAN}${SS_URI}${NC}"
echo -e "------------------------------------------"
echo -e " 管理命令: ss-manage [status|log|restart]"
echo -e "${GREEN}==========================================${NC}"
if [[ "$URI_HOST" == "YOUR_IPV4_IP" ]]; then
    echo -e "${YELLOW}注意: 自动获取 IP 失败，请在客户端中手动填写服务器 IP。${NC}"
fi
echo -e "${YELLOW}提示: 若使用 IPv6 连接，请在客户端将地址改为: [${IPV6}]${NC}\n"
