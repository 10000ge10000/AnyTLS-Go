#!/bin/bash

# AnyTLS-Go 轻量级安装脚本
# 作者：10000ge10000

set -e # 遇到错误立即退出

# --- 变量配置 ---
readonly PROJECT_NAME="AnyTLS-Go"
readonly REPO="anytls/anytls-go" # 如果是你自己的仓库，请修改为 10000ge10000/AnyTLS-Go
readonly INSTALL_DIR="/opt/anytls"
readonly CONFIG_DIR="/etc/anytls"
readonly SERVICE_NAME="anytls"

# --- 颜色 ---
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# --- 辅助函数 ---
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# 1. 检查 Root
[[ $EUID -ne 0 ]] && err "请使用 root 权限运行此脚本"

# 2. 系统检测与依赖安装
info "检测系统环境..."
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) err "不支持的架构: $ARCH" ;;
esac

# 仅安装下载解压必须的工具
if ! command -v curl &> /dev/null || ! command -v unzip &> /dev/null; then
    info "安装基础工具 (curl, unzip)..."
    if command -v apt &> /dev/null; then
        apt-get update && apt-get install -y curl unzip
    elif command -v yum &> /dev/null; then
        yum install -y curl unzip
    else
        warn "无法自动安装依赖，请确保系统有 curl 和 unzip"
    fi
fi

# 3. 下载与安装
info "获取最新版本信息..."
LATEST_VERSION=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | cut -d '"' -f 4)
[[ -z "$LATEST_VERSION" ]] && err "无法获取版本信息，请检查网络或仓库地址"

info "正在下载版本: $LATEST_VERSION ($ARCH)..."
CLEAN_VER=${LATEST_VERSION#v}
FILENAME="anytls_${CLEAN_VER}_linux_${ARCH}.zip"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/${LATEST_VERSION}/${FILENAME}"

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "/var/log/anytls"
cd /tmp
curl -L -o "$FILENAME" "$DOWNLOAD_URL" || err "下载失败"

unzip -o -q "$FILENAME" -d "anytls_tmp"
if [[ -f "anytls_tmp/anytls-server" ]]; then
    mv anytls_tmp/anytls-server "$INSTALL_DIR/"
    mv anytls_tmp/anytls-client "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR/anytls-server" "$INSTALL_DIR/anytls-client"
    ln -sf "$INSTALL_DIR/anytls-server" /usr/local/bin/anytls-server
    ln -sf "$INSTALL_DIR/anytls-client" /usr/local/bin/anytls-client
else
    err "压缩包内未找到二进制文件"
fi
rm -rf "$FILENAME" "anytls_tmp"

# 4. 用户交互配置
echo -e "\n${YELLOW}--- 配置向导 ---${NC}"
read -p "请输入监听端口 [默认 8443]: " USER_PORT
USER_PORT=${USER_PORT:-8443}

read -p "请输入连接密码 [留空随机生成]: " USER_PASSWORD
if [[ -z "$USER_PASSWORD" ]]; then
    USER_PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
    info "已生成随机密码: $USER_PASSWORD"
fi

# 生成配置文件
cat > "$CONFIG_DIR/server.conf" << EOF
LISTEN_ADDR="0.0.0.0:${USER_PORT}"
PASSWORD="${USER_PASSWORD}"
LOG_LEVEL="info"
ENABLE_UDP="true"
MAX_CONNECTIONS="1000"
EOF

# 5. 配置 Systemd 服务
info "配置系统服务..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=AnyTLS-Go Server
After=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/anytls-server -l 0.0.0.0:${USER_PORT} -p "${USER_PASSWORD}"
Restart=always
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"

# 6. 简单的管理脚本 (可选)
cat > "/usr/local/bin/anytls" << 'EOF'
#!/bin/bash
case $1 in
    start)   systemctl start anytls; echo "已启动" ;;
    stop)    systemctl stop anytls; echo "已停止" ;;
    restart) systemctl restart anytls; echo "已重启" ;;
    status)  systemctl status anytls --no-pager ;;
    log)     journalctl -u anytls -f ;;
    *)       echo "用法: anytls [start|stop|restart|status|log]" ;;
esac
EOF
chmod +x /usr/local/bin/anytls

# 7. 完成
EXTERNAL_IP=$(curl -s ipv4.icanhazip.com || echo "你的公网IP")
echo -e "\n${GREEN}=========================================="
echo -e " AnyTLS-Go 安装成功！"
echo -e "==========================================${NC}"
echo -e " 监听地址: 0.0.0.0:$USER_PORT"
echo -e " 连接密码: $USER_PASSWORD"
echo -e " URI链接: anytls://${USER_PASSWORD}@${EXTERNAL_IP}:${USER_PORT}/"
echo -e "------------------------------------------"
echo -e " 管理命令: anytls [start|stop|restart|log]"
echo -e "${GREEN}==========================================${NC}\n"
