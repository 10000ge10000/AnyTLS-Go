#!/bin/bash

# Shadowsocks-2022 (Rust) 一键卸载脚本
# 作者：10000ge10000

# --- 变量配置 (必须与安装脚本一致) ---
readonly SERVICE_NAME="shadowsocks-rust"
readonly INSTALL_DIR="/opt/ss-rust"
readonly CONFIG_DIR="/etc/shadowsocks-rust"
readonly MANAGE_SCRIPT="/usr/local/bin/ss-manage"
readonly BIN_SYMLINK="/usr/local/bin/ssserver"
readonly SYSTEMD_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# --- 颜色 ---
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# --- 辅助函数 ---
info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# 1. 权限检查
[[ $EUID -ne 0 ]] && { echo -e "${RED}[ERROR] 请使用 root 权限运行${NC}"; exit 1; }

# 2. 确认卸载
echo -e "${YELLOW}警告：这将完全删除 Shadowsocks-Rust 服务、配置文件和日志。${NC}"
read -p "确定要继续吗？(y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "操作已取消。"
    exit 0
fi

# 3. 停止并禁用服务
info "正在停止系统服务..."
if systemctl list-units --full -all | grep -q "$SERVICE_NAME.service"; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    info "服务已停止并禁用开机自启"
else
    warn "服务未运行或不存在，跳过停止步骤"
fi

# 4. 删除文件
info "正在清理文件..."

# 删除主程序目录
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    info "已删除安装目录: $INSTALL_DIR"
fi

# 删除配置目录
if [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    info "已删除配置目录: $CONFIG_DIR"
fi

# 删除 Systemd 服务文件
if [[ -f "$SYSTEMD_FILE" ]]; then
    rm -f "$SYSTEMD_FILE"
    systemctl daemon-reload
    info "已删除系统服务文件: $SYSTEMD_FILE"
fi

# 删除管理脚本
if [[ -f "$MANAGE_SCRIPT" ]]; then
    rm -f "$MANAGE_SCRIPT"
    info "已删除管理脚本: $MANAGE_SCRIPT"
fi

# 删除二进制软链接
if [[ -L "$BIN_SYMLINK" ]]; then
    rm -f "$BIN_SYMLINK"
    info "已删除命令软链接: $BIN_SYMLINK"
fi

# 5. 完成
echo -e "\n${GREEN}=========================================="
echo -e " 卸载完成！"
echo -e "==========================================${NC}"
echo -e "系统已清理干净。依赖包 (curl, wget, openssl 等) "
echo -e "属于通用工具，未被删除以防影响其他软件。"
echo -e "${GREEN}==========================================${NC}\n"
