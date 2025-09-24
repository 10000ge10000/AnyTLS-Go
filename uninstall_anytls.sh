#!/bin/bash
#
# AnyTLS-Go 一键卸载脚本 v2.0.0
# 项目地址: https://github.com/10000ge10000/AnyTLS-Go
#

set +e

# 常量定义
readonly INSTALL_DIR="/opt/anytls"
readonly CONFIG_DIR="/etc/anytls"
readonly LOG_DIR="/var/log/anytls"
readonly SERVICE_NAME="anytls"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# 打印函数
print_info() { echo -e "${BLUE}[信息]${NC} $1"; }
print_success() { echo -e "${GREEN}[成功]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[警告]${NC} $1"; }
print_error() { echo -e "${RED}[错误]${NC} $1"; }
print_step() { echo; echo -e "${CYAN}>>> $1${NC}"; }

print_banner() {
    echo
    echo -e "${PURPLE}======================================${NC}"
    echo -e "${PURPLE}    AnyTLS-Go 一键卸载脚本 v2.0.0${NC}"
    echo -e "${PURPLE}======================================${NC}"
    echo
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "需要root权限，请使用: sudo $0"
        exit 1
    fi
}

# 确认卸载
confirm_uninstall() {
    print_step "卸载确认"
    echo -e "${YELLOW}警告：将完全删除AnyTLS-Go及其所有数据！${NC}"
    echo
    echo "将要删除："
    echo "  • systemd服务: $SERVICE_NAME"
    echo "  • 程序目录: $INSTALL_DIR"
    echo "  • 配置目录: $CONFIG_DIR"
    echo "  • 日志目录: $LOG_DIR"
    echo "  • 管理脚本和符号链接"
    echo "  • 系统用户: anytls"
    echo "  • 相关防火墙规则"
    echo
    
    read -p "确定继续？[y/N]: " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "已取消卸载"
        exit 0
    fi
}

# 停止和删除服务
cleanup_service() {
    print_step "清理systemd服务..."
    
    # 停止服务
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_info "停止服务..."
        systemctl stop "$SERVICE_NAME" || true
    fi
    
    # 禁用服务
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_info "禁用开机自启..."
        systemctl disable "$SERVICE_NAME" || true
    fi
    
    # 删除服务文件
    if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
        print_info "删除服务文件..."
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload 2>/dev/null || true
    fi
    
    print_success "服务清理完成"
}

# 删除文件和目录
cleanup_files() {
    print_step "清理文件和目录..."
    
    # 删除主要目录
    for dir in "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"; do
        if [[ -d "$dir" ]]; then
            print_info "删除目录: $dir"
            rm -rf "$dir" || print_warning "删除 $dir 失败"
        fi
    done
    
    # 删除管理脚本和符号链接
    for file in "/usr/local/bin/anytls" "/usr/local/bin/anytls-server" "/usr/local/bin/anytls-client"; do
        if [[ -f "$file" || -L "$file" ]]; then
            print_info "删除文件: $file"
            rm -f "$file" || print_warning "删除 $file 失败"
        fi
    done
    
    print_success "文件清理完成"
}

# 删除系统用户
cleanup_user() {
    print_step "清理系统用户..."
    
    if id "anytls" &>/dev/null; then
        print_info "删除用户: anytls"
        userdel anytls 2>/dev/null || print_warning "删除用户失败"
        
        # 尝试删除用户组
        if getent group anytls &>/dev/null; then
            groupdel anytls 2>/dev/null || true
        fi
        
        print_success "用户清理完成"
    else
        print_info "用户不存在，跳过"
    fi
}

# 清理防火墙规则
cleanup_firewall() {
    print_step "清理防火墙规则..."
    
    local cleaned=false
    
    # UFW
    if command -v ufw &>/dev/null; then
        print_info "清理UFW规则..."
        for port in 8443 8080 443 80; do
            ufw delete allow $port 2>/dev/null && cleaned=true || true
            ufw delete allow $port/tcp 2>/dev/null || true
            ufw delete allow $port/udp 2>/dev/null || true
        done
    fi
    
    # firewalld
    if command -v firewall-cmd &>/dev/null; then
        print_info "清理firewalld规则..."
        for port in 8443 8080 443 80; do
            firewall-cmd --permanent --remove-port=$port/tcp 2>/dev/null && cleaned=true || true
            firewall-cmd --permanent --remove-port=$port/udp 2>/dev/null || true
        done
        firewall-cmd --reload 2>/dev/null || true
    fi
    
    if [[ "$cleaned" == true ]]; then
        print_success "防火墙规则清理完成"
    else
        print_info "未发现需要清理的防火墙规则"
    fi
    
    # iptables提示
    if command -v iptables &>/dev/null && ! command -v ufw &>/dev/null && ! command -v firewall-cmd &>/dev/null; then
        print_warning "检测到iptables，如有相关规则请手动清理"
        print_info "参考命令: iptables -D INPUT -p tcp --dport 8443 -j ACCEPT"
    fi
}

# 验证清理
verify_cleanup() {
    print_step "验证清理结果..."
    
    local issues=0
    
    # 检查服务
    if systemctl list-units --all 2>/dev/null | grep -q "$SERVICE_NAME"; then
        print_warning "systemd服务仍存在"
        ((issues++))
    fi
    
    # 检查目录
    for dir in "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"; do
        if [[ -d "$dir" ]]; then
            print_warning "目录仍存在: $dir"
            ((issues++))
        fi
    done
    
    # 检查用户
    if id "anytls" &>/dev/null; then
        print_warning "用户仍存在: anytls"
        ((issues++))
    fi
    
    # 检查文件
    for file in "/usr/local/bin/anytls" "/usr/local/bin/anytls-server" "/usr/local/bin/anytls-client"; do
        if [[ -f "$file" || -L "$file" ]]; then
            print_warning "文件仍存在: $file"
            ((issues++))
        fi
    done
    
    if [[ $issues -eq 0 ]]; then
        print_success "验证通过：所有组件已完全清理"
    else
        print_warning "发现 $issues 个问题，部分组件可能需要手动清理"
    fi
}

# 显示完成信息
show_completion() {
    echo
    print_banner
    print_success "AnyTLS-Go 卸载完成！"
    echo
    echo -e "${CYAN}已清理组件：${NC}"
    echo "  ✓ systemd服务和配置"
    echo "  ✓ 所有程序文件和目录"
    echo "  ✓ 配置文件和TLS证书"
    echo "  ✓ 日志文件"
    echo "  ✓ 管理脚本和符号链接"
    echo "  ✓ 系统用户和用户组"
    echo "  ✓ 防火墙规则"
    echo
    echo -e "${PURPLE}感谢使用 AnyTLS-Go！${NC}"
    echo -e "${PURPLE}项目地址: https://github.com/10000ge10000/AnyTLS-Go${NC}"
    echo -e "${PURPLE}原项目: https://github.com/anytls/anytls-go${NC}"
    echo
}

# 主函数
main() {
    print_banner
    check_root
    confirm_uninstall
    
    print_info "开始卸载AnyTLS-Go..."
    
    cleanup_service
    cleanup_files
    cleanup_user
    cleanup_firewall
    verify_cleanup
    show_completion
}

# 执行主函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
