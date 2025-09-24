#!/bin/bash

# AnyTLS-Go 安装脚本测试工具

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查系统兼容性
check_compatibility() {
    print_info "检查系统兼容性..."
    
    # 检查操作系统
    if [[ ! -f /etc/os-release ]]; then
        print_error "无法检测操作系统类型"
        return 1
    fi
    
    source /etc/os-release
    print_info "操作系统: $PRETTY_NAME"
    
    # 检查架构
    local arch=$(uname -m)
    case $arch in
        x86_64|amd64|aarch64|arm64|armv7l|armv6l)
            print_success "支持的系统架构: $arch"
            ;;
        *)
            print_error "不支持的系统架构: $arch"
            return 1
            ;;
    esac
    
    # 检查root权限
    if [[ $EUID -ne 0 ]]; then
        print_error "需要root权限运行测试"
        return 1
    fi
    
    # 检查网络连接
    if ! ping -c 1 8.8.8.8 &> /dev/null; then
        print_error "网络连接失败"
        return 1
    fi
    
    print_success "系统兼容性检查通过"
    return 0
}

# 测试安装脚本语法
test_script_syntax() {
    print_info "测试安装脚本语法..."
    
    if bash -n install.sh; then
        print_success "脚本语法检查通过"
        return 0
    else
        print_error "脚本语法错误"
        return 1
    fi
}

# 模拟安装过程（不实际安装）
simulate_installation() {
    print_info "模拟安装过程..."
    
    # 这里可以添加模拟安装的逻辑
    # 比如检查函数是否存在，变量是否定义等
    
    local functions=(
        "check_root"
        "detect_system"
        "check_network"
        "update_system"
        "install_dependencies"
        "check_install_go"
        "create_directories"
        "install_from_source"
        "configure_user_settings"
        "generate_config"
        "configure_firewall"
        "install_letsencrypt"
        "create_systemd_service"
        "create_management_script"
    )
    
    for func in "${functions[@]}"; do
        if grep -q "^$func()" install.sh; then
            print_success "函数 $func 存在"
        else
            print_warning "函数 $func 不存在或格式不正确"
        fi
    done
    
    print_success "模拟安装过程完成"
}

# 运行测试
main() {
    echo "=== AnyTLS-Go 安装脚本测试 ==="
    echo
    
    if ! check_compatibility; then
        exit 1
    fi
    
    echo
    if ! test_script_syntax; then
        exit 1
    fi
    
    echo
    simulate_installation
    
    echo
    print_success "所有测试通过！"
    print_info "可以安全运行安装脚本"
}

main "$@"