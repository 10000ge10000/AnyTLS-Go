#!/bin/bash

# Shadowsocks-2022 (Rust) 双栈兼容版安装脚本
# 特性：默认开启 IPv4 + IPv6 双栈监听
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

# 生成配置文件 (关键修改点：server 字段使用数组同时包含 :: 和 0.0.0.0)
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
# 如果服务已存在，先重启
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

# 7. 完成输出
# 获取 IPv4 和 IPv6 地址用于显示
IPV4=$(curl -s -4 --max-time 3 ipv4.icanhazip.com || echo "未知IPv4")
IPV6=$(curl -s -6 --max-time 3 ipv6.icanhazip.com || echo "未知IPv6")

# 生成 SS 链接 (使用 IPv4 作为默认显示的地址，因为兼容性最好)
# 注意：URI 格式中密码和方法需要 base64 编码
SS_URI="ss://$(echo -n "${METHOD}:${USER_PASSWORD}" | base64 -w 0)@${IPV4}:${USER_PORT}#SS-2022"

echo -e "\n${GREEN}=========================================="
echo -e " Shadowsocks-2022 (IPv4/IPv6) 安装成功！"
echo -e "==========================================${NC}"
echo -e " 服务端口: $USER_PORT"
echo -e " 加密方式: $METHOD"
echo -e " 访问密钥: $USER_PASSWORD"
echo -e "------------------------------------------"
echo -e " 监听状态: ${CYAN}IPv4 + IPv6 双栈已启用${NC}"
echo -e " IPv4 地址: $IPV4"
echo -e " IPv6 地址: $IPV6"
echo -e "------------------------------------------"
echo -e " 客户端导入链接 (默认使用 IPv4，可手动改为 IPv6):"
echo -e "${CYAN}${SS_URI}${NC}"
echo -e "------------------------------------------"
echo -e " 管理命令: ss-manage [status|log|restart]"
echo -e "${GREEN}==========================================${NC}"
echo -e "${YELLOW}提示: 若使用 IPv6 连接，请在客户端将地址改为: [${IPV6}]${NC}\n"
