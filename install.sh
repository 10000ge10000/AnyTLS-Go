#!/bin/bash

# AnyTLS-Go 一键安装脚本
# 版本：1.1.4
# 作者：10000ge10000
# 项目地址：https://github.com/anytls/anytls-go

set -euo pipefail

# 全局变量
readonly SCRIPT_VERSION="1.1.4"  # 1.1.4: 完全移除证书相关功能（生成/展示/加载），统一无证书模式；沿用1.1.3改动
readonly PROJECT_NAME="AnyTLS-Go"
readonly GITHUB_REPO="10000ge10000/AnyTLS-Go"
readonly INSTALL_DIR="/opt/anytls"
readonly CONFIG_DIR="/etc/anytls"
readonly LOG_DIR="/var/log/anytls"
readonly SERVICE_NAME="anytls"
readonly GO_MIN_VERSION="1.20"
readonly REQUIRED_GO_VERSION="1.24.0"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color
readonly BOLD='\033[1m'

# 系统信息
SYSTEM_TYPE=""
PACKAGE_MANAGER=""
FIREWALL_TYPE=""
ARCH=""
LOCAL_IP=""
PUBLIC_IP=""

# 用户配置
USER_MODE=""           # server 或 client
USER_PORT="8443"       # 服务端口
USER_PASSWORD=""       # 连接密码
USER_AUTO_START="y"    # 是否开机自启
USER_FIREWALL="y"      # 是否配置防火墙
USER_SNI=""           # 客户端SNI
USER_SERVER_ADDR=""   # 客户端连接的服务器地址
USER_LOCAL_ONLY="n"    # 是否仅本地监听 (y/n)

# 打印带颜色的信息
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

print_step() {
    echo -e "${PURPLE}[STEP]${NC} $1"
}

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "================================================================="
    echo "             $PROJECT_NAME 一键安装脚本 v$SCRIPT_VERSION"
    echo "================================================================="
    echo -e "${NC}"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要root权限运行，请使用 sudo 或 root 用户执行"
        exit 1
    fi
}

# 获取系统信息
detect_system() {
    print_step "检测系统信息..."
    
    # 检测架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l|armv6l)
            ARCH="arm"
            ;;
        *)
            print_error "不支持的系统架构: $ARCH"
            exit 1
            ;;
    esac
    
    # 检测操作系统
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        SYSTEM_TYPE=$ID
    else
        print_error "无法检测操作系统类型"
        exit 1
    fi
    
    # 确定包管理器
    case $SYSTEM_TYPE in
        ubuntu|debian)
            PACKAGE_MANAGER="apt"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            PACKAGE_MANAGER="yum"
            if command -v dnf &> /dev/null; then
                PACKAGE_MANAGER="dnf"
            fi
            ;;
        arch|manjaro)
            PACKAGE_MANAGER="pacman"
            ;;
        *)
            print_warning "未知的操作系统类型: $SYSTEM_TYPE，将尝试通用安装方法"
            ;;
    esac
    
    # 检测防火墙
    if command -v ufw &> /dev/null && ufw status &> /dev/null; then
        FIREWALL_TYPE="ufw"
    elif command -v firewall-cmd &> /dev/null; then
        FIREWALL_TYPE="firewalld"
    elif command -v iptables &> /dev/null; then
        FIREWALL_TYPE="iptables"
    else
        FIREWALL_TYPE="none"
    fi
    
    # 获取IP地址
    LOCAL_IP=$(hostname -I | awk '{print $1}')
    PUBLIC_IP=$(curl -s --max-time 10 ipv4.icanhazip.com 2>/dev/null || echo "未知")
    
    print_info "系统类型: $SYSTEM_TYPE"
    print_info "系统架构: $ARCH"
    print_info "包管理器: $PACKAGE_MANAGER"
    print_info "防火墙类型: $FIREWALL_TYPE"
    print_info "本地IP: $LOCAL_IP"
    print_info "公网IP: $PUBLIC_IP"
}

# 检查网络连接
check_network() {
    print_step "检查网络连接..."

    # 工具存在性检测
    local has_ping=0
    local has_curl=0
    local has_wget=0

    if command -v ping &>/dev/null; then
        has_ping=1
    else
        print_warning "未检测到 ping，跳过 ICMP 连通性检测"
    fi

    if command -v curl &>/dev/null; then
        has_curl=1
    else
        print_warning "未检测到 curl，GitHub 访问检测将跳过（安装核心工具后会安装 curl）"
    fi

    if command -v wget &>/dev/null; then
        has_wget=1
    fi

    # ICMP 测试（多目标容错）
    local icmp_ok=0
    if [[ $has_ping -eq 1 ]]; then
        local targets=("1.1.1.1" "223.5.5.5" "8.8.8.8")
        for t in "${targets[@]}"; do
            if ping -c 1 -W 2 "$t" &>/dev/null; then
                icmp_ok=1
                print_info "ICMP 测试通过: $t"
                break
            fi
        done
        if [[ $icmp_ok -eq 0 ]]; then
            print_warning "ICMP 测试未通过（可能被防火墙/云安全组拦截或网络抖动），将继续进行 HTTP 测试"
        fi
    fi

    # HTTP 测试兜底（curl 或 wget 任一即可）
    local http_ok=0
    if [[ $has_curl -eq 1 ]]; then
        if curl -sI --max-time 5 --connect-timeout 3 http://1.1.1.1 &>/dev/null; then
            http_ok=1
            print_info "HTTP 测试通过 (curl)"
        fi
    elif [[ $has_wget -eq 1 ]]; then
        if wget -q --timeout=5 --tries=1 --spider http://1.1.1.1; then
            http_ok=1
            print_info "HTTP 测试通过 (wget)"
        else
            print_warning "HTTP 测试 (wget) 未通过"
        fi
    else
        print_warning "未检测到 curl/wget，跳过 HTTP 连通性测试"
    fi

    # 若 ICMP 与 HTTP 均未通过，则判定网络不可用
    if [[ $icmp_ok -eq 0 && $http_ok -eq 0 ]]; then
        print_error "网络连通性检测失败：ICMP 和 HTTP 均不可用或测试未通过"
        print_error "请检查网络设置或安装基础网络工具（ping/curl/wget）后重试"
        exit 1
    fi

    # GitHub 可访问性检测（仅当存在 curl 时执行；不可达仅警告，允许继续）
    if [[ $has_curl -eq 1 ]]; then
        if ! curl -s --max-time 10 https://github.com &>/dev/null; then
            print_warning "无法访问 GitHub，预编译版本与版本信息获取可能失败。可稍后重试或配置代理/使用镜像。"
        else
            print_info "GitHub 访问正常"
        fi
    else
        print_warning "跳过 GitHub 访问检测（未安装 curl）"
    fi

    print_success "网络连接正常或已通过替代检测"
}

# 更新系统包
update_system() {
    print_step "更新系统软件包..."
    
    case $PACKAGE_MANAGER in
        apt)
            apt update && apt upgrade -y
            ;;
        yum|dnf)
            $PACKAGE_MANAGER update -y
            ;;
        pacman)
            pacman -Syu --noconfirm
            ;;
    esac
    
    print_success "系统更新完成"
}

# 安装核心系统工具
install_core_dependencies() {
    print_step "安装核心系统工具 (curl, wget, tar, unzip)..."
    
    local packages="curl wget tar unzip"
    
    case $PACKAGE_MANAGER in
        apt)
            apt install -y $packages
            ;;
        yum|dnf)
            $PACKAGE_MANAGER install -y $packages
            ;;
        pacman)
            pacman -S --noconfirm $packages
            ;;
    esac
    
    print_success "核心工具安装完成"
}

# 安装构建工具
install_build_dependencies() {
    print_step "安装构建工具 (git, build-essential)..."
    
    case $PACKAGE_MANAGER in
        apt)
            apt install -y git build-essential
            ;;
        yum|dnf)
            if [[ $PACKAGE_MANAGER == "yum" ]]; then
                yum groupinstall -y "Development Tools"
                yum install -y git
            else
                dnf groupinstall -y "Development Tools"
                dnf install -y git
            fi
            ;;
        pacman)
            pacman -S --noconfirm base-devel git
            ;;
    esac
    
    print_success "构建工具安装完成"
}

# 检查并安装Go环境
check_install_go() {
    print_step "检查Go语言环境..."
    
    local go_version=""
    if command -v go &> /dev/null; then
        go_version=$(go version | grep -oE 'go[0-9]+\.[0-9]+\.[0-9]+' | sed 's/go//')
        print_info "检测到Go版本: $go_version"
        
        # 检查Go版本是否满足要求
        if version_compare "$go_version" "$GO_MIN_VERSION"; then
            print_success "Go版本满足要求"
            return 0
        else
            print_warning "Go版本过低，需要安装新版本"
        fi
    fi
    
    print_step "安装Go ${REQUIRED_GO_VERSION}..."
    
    # 下载并安装Go
    local go_archive="go${REQUIRED_GO_VERSION}.linux-${ARCH}.tar.gz"
    local download_url="https://go.dev/dl/${go_archive}"
    
    print_info "下载地址: $download_url"
    
    # 删除旧的Go安装
    rm -rf /usr/local/go
    
    # 下载Go
    wget -O "/tmp/${go_archive}" "$download_url"
    
    # 解压安装
    tar -C /usr/local -xzf "/tmp/${go_archive}"
    
    # 设置环境变量
    if ! grep -q "/usr/local/go/bin" /etc/profile; then
        echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile
    fi
    
    export PATH=$PATH:/usr/local/go/bin
    
    # 清理下载文件
    rm -f "/tmp/${go_archive}"
    
    # 验证安装
    if command -v go &> /dev/null; then
        go_version=$(go version | grep -oE 'go[0-9]+\.[0-9]+\.[0-9]+' | sed 's/go//')
        print_success "Go ${go_version} 安装成功"
    else
        print_error "Go安装失败"
        exit 1
    fi
}

# 版本比较函数
version_compare() {
    local version1=$1
    local version2=$2
    
    # 将版本号转换为数组
    IFS='.' read -ra V1 <<< "$version1"
    IFS='.' read -ra V2 <<< "$version2"
    
    # 比较版本号
    for i in 0 1 2; do
        local v1=${V1[i]:-0}
        local v2=${V2[i]:-0}
        
        if (( v1 > v2 )); then
            return 0
        elif (( v1 < v2 )); then
            return 1
        fi
    done
    
    return 0
}

# 创建系统目录
create_directories() {
    print_step "创建系统目录..."
    
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "/usr/local/bin"
    
    print_success "目录创建完成"
}

# 获取最新版本信息
get_latest_version() {
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/anytls/anytls-go/releases/latest" | grep '"tag_name"' | cut -d '"' -f 4)
    
    if [[ -z "$latest_version" ]]; then
        return 1
    fi
    
    echo "$latest_version"
}

# 尝试下载预编译版本
try_download_precompiled() {
    print_step "尝试下载预编译版本..."
    print_step "获取最新版本信息..."
    
    local version
    version=$(get_latest_version)
    
    if [[ -z "$version" ]]; then
        print_warning "无法获取版本信息，跳过预编译下载"
        return 1
    fi
    
    print_info "最新版本: $version"
    
    # 构建下载URL
    local clean_version=${version#v}  # 移除版本号前的 'v' 前缀
    local filename="anytls_${clean_version}_linux_${ARCH}.zip"
    local download_url="https://github.com/anytls/anytls-go/releases/download/${version}/${filename}"
    
    print_info "尝试下载: $download_url"
    print_info "使用预编译版本可以大大节省安装时间（无需下载Go编译环境）"
    
    # 下载文件
    cd /tmp
    # 创建独立的解压目录避免文件冲突
    local extract_dir="/tmp/anytls_extract_$$"
    mkdir -p "$extract_dir"
    
    if wget -q "$download_url" -O "$filename"; then
        print_success "预编译版本下载成功"
        
        # 解压文件到独立目录
        if command -v unzip &> /dev/null; then
            unzip -o -q "$filename" -d "$extract_dir"
            
            # 查找二进制文件
            local server_bin=$(find "$extract_dir" -name "anytls-server" -type f 2>/dev/null | head -1)
            local client_bin=$(find "$extract_dir" -name "anytls-client" -type f 2>/dev/null | head -1)
            
            if [[ -f "$server_bin" && -f "$client_bin" ]]; then
                # 安装二进制文件
                install -m 755 "$server_bin" "$INSTALL_DIR/"
                install -m 755 "$client_bin" "$INSTALL_DIR/"
                
                # 创建软链接
                ln -sf "$INSTALL_DIR/anytls-server" /usr/local/bin/anytls-server
                ln -sf "$INSTALL_DIR/anytls-client" /usr/local/bin/anytls-client
                
                # 清理
                cd /
                rm -rf /tmp/anytls_*
                rm -rf "$extract_dir"
                
                print_success "预编译版本安装完成"
                return 0
            else
                print_warning "预编译版本中未找到可执行文件"
            fi
        else
            print_warning "系统缺少unzip工具"
        fi
    else
        print_warning "预编译版本下载失败"
    fi
    
    # 清理失败的下载文件和解压目录
    rm -f "/tmp/$filename"
    rm -rf "$extract_dir"
    return 1
}

# 智能安装程序（优先预编译版本）
install_anytls() {
    print_step "开始安装AnyTLS程序..."
    
    # 首先尝试下载预编译版本
    if try_download_precompiled; then
        print_success "使用预编译版本安装成功"
        # 预编译版本安装成功，无需Go环境
        export SKIP_GO_INSTALL=true
        return 0
    fi
    
    # 如果预编译版本失败，确保Go环境可用后从源码编译
    print_info "预编译版本不可用，从源码编译安装..."
    print_warning "源码编译需要下载Go编译环境，可能需要较长时间"
    check_install_go  # 只在需要编译时才安装Go
    install_from_source
}

# 从源码编译安装
install_from_source() {
    print_step "从源码编译安装..."
    
    # 安装构建依赖
    install_build_dependencies
    
    # 克隆源码
    cd /tmp
    rm -rf anytls-go
    git clone "https://github.com/anytls/anytls-go.git"
    cd anytls-go
    
    # 编译服务端和客户端
    print_info "编译服务端..."
    go build -o anytls-server ./cmd/server
    
    print_info "编译客户端..."
    go build -o anytls-client ./cmd/client
    
    # 安装二进制文件
    install -m 755 anytls-server "$INSTALL_DIR/"
    install -m 755 anytls-client "$INSTALL_DIR/"
    
    # 创建软链接
    ln -sf "$INSTALL_DIR/anytls-server" /usr/local/bin/anytls-server
    ln -sf "$INSTALL_DIR/anytls-client" /usr/local/bin/anytls-client
    
    # 清理
    cd /
    rm -rf /tmp/anytls-go
    
    print_success "编译安装完成"
}

# 用户配置向导
configure_user_settings() {
    print_step "开始配置向导..."
    
    echo -e "${CYAN}${BOLD}"
    echo "================================================================="
    echo "                      AnyTLS 服务端配置"
    echo "================================================================="
    echo -e "${NC}"
    
    USER_MODE="server"  # 固定为服务端模式
    configure_server_mode
    
    # 默认开机自启
    USER_AUTO_START="y"
    print_info "已设置开机自启（默认）"
    
    # 默认配置防火墙
    if [[ $FIREWALL_TYPE != "none" ]]; then
        USER_FIREWALL="y"
        print_info "已配置防火墙（默认）"
    else
        USER_FIREWALL="n"
        print_warning "未检测到防火墙，跳过防火墙配置"
    fi
}

# 服务端模式配置
configure_server_mode() {
    echo -e "${CYAN}>>> 服务端配置${NC}"
    
    # 端口配置
    while true; do
        echo -n -e "${YELLOW}请输入监听端口 [默认: 8443]: ${NC}"
        read -r port
        if [[ -z "$port" ]]; then
            USER_PORT="8443"
            break
        elif [[ $port =~ ^[0-9]+$ ]] && [[ $port -ge 1 ]] && [[ $port -le 65535 ]]; then
            USER_PORT="$port"
            break
        else
            print_error "无效端口，请输入1-65535之间的数字"
        fi
    done
    
    # 密码配置
    echo -n -e "${YELLOW}请输入连接密码 [建议12位以上，回车则随机生成]: ${NC}"
    read -r password
    if [[ -z "$password" ]]; then
        # 生成16位随机密码
        USER_PASSWORD=$(head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)
        print_info "已随机生成密码: ${USER_PASSWORD}"
    else
        USER_PASSWORD="$password"
        print_info "密码已设置"
    fi
    
    # 已移除证书配置交互
    # IP版本优先级配置
    # 已移除 IP版本优先级交互（统一使用 IPv4 监听）
    # 监听范围交互已移除，默认对外监听。如需本地监听请手动修改 server.conf 中 LISTEN_ADDR
    USER_LOCAL_ONLY="n"
    local display_listen_addr="0.0.0.0:$USER_PORT"
    
    print_info "服务端将监听: $display_listen_addr"
    print_info "连接密码: $USER_PASSWORD"
    # 已移除证书配置输出
    
    # 已移除 IP版本配置显示
}

# 客户端模式配置
# 生成配置文件
generate_config() {
    print_step "生成配置文件..."
    generate_server_config
    print_success "配置文件生成完成"
}

# 生成服务端配置
generate_server_config() {
    local listen_addr="0.0.0.0:${USER_PORT}"
    if [[ "$USER_LOCAL_ONLY" == "y" ]]; then
        listen_addr="127.0.0.1:${USER_PORT}"
    fi
    cat > "$CONFIG_DIR/server.conf" << EOF
# AnyTLS Server Configuration
# 生成时间: $(date)

# 服务器监听地址和端口
LISTEN_ADDR="${listen_addr}"

# 连接密码
PASSWORD="${USER_PASSWORD}"

# 已移除证书相关字段（anytls-server 不支持外部证书）

# 日志级别 (debug, info, warn, error)
LOG_LEVEL="info"

# 填充方案文件路径（可选）
PADDING_SCHEME=""

# 其他配置
ENABLE_UDP="true"
MAX_CONNECTIONS="1000"
EOF
}

# 已移除 configure_self_signed_cert（anytls-server 不支持外部证书）

# 配置防火墙
configure_firewall() {
    if [[ $USER_FIREWALL == "n" ]]; then
        print_info "跳过防火墙配置"
        return 0
    fi
    
    print_step "配置防火墙..."
    
    case $FIREWALL_TYPE in
        ufw)
            configure_ufw
            ;;
        firewalld)
            configure_firewalld
            ;;
        iptables)
            configure_iptables
            ;;
        *)
            print_warning "未知的防火墙类型，跳过配置"
            return 0
            ;;
    esac
    
    print_success "防火墙配置完成"
}

# 配置UFW防火墙
configure_ufw() {
    print_info "配置UFW防火墙..."
    
    # 启用UFW
    ufw --force enable
    
    # 允许SSH
    ufw allow 22/tcp
    
    # 开放服务端口
    ufw allow "$USER_PORT/tcp"
    print_info "已开放服务端口: $USER_PORT/tcp"
    
    # 重新加载规则
    ufw reload
}

# 配置firewalld防火墙
configure_firewalld() {
    print_info "配置firewalld防火墙..."
    
    # 启动firewalld
    systemctl enable firewalld
    systemctl start firewalld
    
    # 开放服务端口
    firewall-cmd --permanent --add-port="$USER_PORT/tcp"
    print_info "已开放服务端口: $USER_PORT/tcp"
    
    # 重新加载规则
    firewall-cmd --reload
}

# 配置iptables防火墙
configure_iptables() {
    print_info "配置iptables防火墙..."
    
    if [[ $USER_MODE == "server" ]]; then
        # 服务端模式：开放服务端口
        iptables -I INPUT -p tcp --dport "$USER_PORT" -j ACCEPT
        print_info "已开放服务端口: $USER_PORT/tcp"
        
        # 保存iptables规则
        if command -v iptables-save &> /dev/null; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
}

# 安装Let's Encrypt证书
# 创建systemd服务
create_systemd_service() {
    print_step "创建systemd服务..."
    
    # 已移除系统网络优化配置
    
    create_server_service
    
    # 重新加载systemd
    systemctl daemon-reload
    
    # 启用并立即启动服务
    systemctl enable --now "$SERVICE_NAME"
    print_info "已设置开机自启并启动服务"
    
    # 等待2秒确保服务已启动，然后检查状态
    sleep 2
    local service_status=$(systemctl is-active "$SERVICE_NAME")
    if [[ "$service_status" == "active" ]]; then
        print_success "服务启动成功"
    else
        print_warning "服务启动可能有问题，请检查日志: journalctl -u $SERVICE_NAME -f"
    fi
    
    print_success "systemd服务创建完成"
}

# 创建服务端systemd服务
create_server_service() {
    # 统一使用 IPv4 监听，移除 IP 版本优先逻辑
    local listen_addr
    local env_vars=""

    if [[ "$USER_LOCAL_ONLY" == "y" ]]; then
        listen_addr="127.0.0.1:${USER_PORT}"
        print_info "监听范围：仅本地 (${listen_addr})"
    else
        listen_addr="0.0.0.0:${USER_PORT}"
        print_info "监听范围：对外 (${listen_addr})"
    fi

    local server_cmd="${INSTALL_DIR}/anytls-server -l ${listen_addr} -p \"${USER_PASSWORD}\""

    # 已移除证书参数集成（anytls-server 不支持外部证书）

    print_info "服务端启动命令: ${server_cmd}"

    # 创建专用系统用户
    if ! id "anytls" &>/dev/null; then
        print_info "创建专用的系统用户 'anytls' 用于运行服务..."
        useradd -r -s /usr/sbin/nologin -d /dev/null anytls
    fi

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=AnyTLS-Go Server
Documentation=https://github.com/anytls/anytls-go
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=anytls
Group=anytls
ExecStart=${server_cmd}
Restart=on-failure
RestartSec=5
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
}

# 已移除 optimize_network_for_ip_version 函数

# 创建客户端systemd服务
# 创建管理脚本
create_management_script() {
    print_step "创建管理脚本..."
    
    cat > "/usr/local/bin/anytls" << 'EOF'
#!/bin/bash

# AnyTLS 管理脚本
readonly SERVICE_NAME="anytls"
readonly CONFIG_DIR="/etc/anytls"
readonly LOG_DIR="/var/log/anytls"
readonly INSTALL_DIR="/opt/anytls"
readonly GITHUB_REPO="anytls/anytls-go"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

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

print_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "================================================================="
    echo "                    AnyTLS 管理面板"
    echo "================================================================="
    echo -e "${NC}"
}

# 显示服务状态
show_status() {
    echo -e "${PURPLE}>>> 服务状态${NC}"
    systemctl status "$SERVICE_NAME" --no-pager -l
    echo
    
    echo -e "${PURPLE}>>> 网络监听${NC}"
    if command -v ss &> /dev/null; then
        ss -tlnp | grep -E "(1080|8443|:$(grep LISTEN_ADDR "$CONFIG_DIR"/*.conf 2>/dev/null | cut -d: -f3 || echo ""))"
    elif command -v netstat &> /dev/null; then
        netstat -tlnp | grep -E "(1080|8443|:$(grep LISTEN_ADDR "$CONFIG_DIR"/*.conf 2>/dev/null | cut -d: -f3 || echo ""))"
    fi
    echo
    
    echo -e "${PURPLE}>>> 最近日志${NC}"
    journalctl -u "$SERVICE_NAME" --no-pager -n 10
}

# 启动服务
start_service() {
    print_info "启动AnyTLS服务..."
    systemctl start "$SERVICE_NAME"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "服务启动成功"
    else
        print_error "服务启动失败"
        systemctl status "$SERVICE_NAME" --no-pager -l
    fi
}

# 停止服务
stop_service() {
    print_info "停止AnyTLS服务..."
    systemctl stop "$SERVICE_NAME"
    print_success "服务已停止"
}

# 重启服务
restart_service() {
    print_info "重启AnyTLS服务..."
    systemctl restart "$SERVICE_NAME"
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "服务重启成功"
    else
        print_error "服务重启失败"
        systemctl status "$SERVICE_NAME" --no-pager -l
    fi
}

# 查看日志
view_logs() {
    echo "选择查看日志的方式:"
    echo "1) 实时日志 (按Ctrl+C退出)"
    echo "2) 最近50行日志"
    echo "3) 指定行数日志"
    echo -n "请选择 [1-3]: "
    read -r choice
    
    case $choice in
        1)
            journalctl -u "$SERVICE_NAME" -f
            ;;
        2)
            journalctl -u "$SERVICE_NAME" --no-pager -n 50
            ;;
        3)
            echo -n "请输入要查看的行数: "
            read -r lines
            if [[ $lines =~ ^[0-9]+$ ]]; then
                journalctl -u "$SERVICE_NAME" --no-pager -n "$lines"
            else
                print_error "无效的行数"
            fi
            ;;
        *)
            print_error "无效选择"
            ;;
    esac
}

# 检查更新
check_update() {
    print_info "检查版本更新..."
    
    # 获取当前版本
    local current_version="unknown"
    if [[ -f "$INSTALL_DIR/anytls-server" ]]; then
        current_version=$("$INSTALL_DIR/anytls-server" --version 2>/dev/null || echo "unknown")
    fi
    
    # 获取最新版本
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/anytls/anytls-go/releases/latest" | grep '"tag_name"' | cut -d '"' -f 4)
    
    if [[ -z "$latest_version" ]]; then
        print_warning "无法获取最新版本信息"
        return 1
    fi
    
    echo "当前版本: $current_version"
    echo "最新版本: $latest_version"
    
    if [[ "$current_version" != "$latest_version" ]]; then
        print_warning "发现新版本！建议更新"
        echo -n "是否现在更新? [y/N]: "
        read -r update_choice
        case ${update_choice,,} in
            y|yes)
                update_anytls
                ;;
            *)
                print_info "跳过更新"
                ;;
        esac
    else
        print_success "已是最新版本"
    fi
}

# 更新程序
update_anytls() {
    print_info "开始更新AnyTLS..."
    
    # 停止服务
    systemctl stop "$SERVICE_NAME"
    
    # 备份当前版本
    cp "$INSTALL_DIR/anytls-server" "$INSTALL_DIR/anytls-server.bak" 2>/dev/null || true
    cp "$INSTALL_DIR/anytls-client" "$INSTALL_DIR/anytls-client.bak" 2>/dev/null || true
    
    # 尝试使用预编译版本更新
    if try_download_precompiled; then
        print_success "使用预编译版本更新完成"
    else
        print_info "预编译版本不可用，从源码编译更新..."
        
        # 重新编译安装
        cd /tmp
        rm -rf anytls-go
        git clone "https://github.com/anytls/anytls-go.git"
        cd anytls-go
        
        # 编译
        go build -o anytls-server ./cmd/server
        go build -o anytls-client ./cmd/client
        
        # 安装
        install -m 755 anytls-server "$INSTALL_DIR/"
        install -m 755 anytls-client "$INSTALL_DIR/"
        
        # 清理
        cd /
        rm -rf /tmp/anytls-go
        
        print_success "从源码编译更新完成"
    fi
    
    # 重启服务
    systemctl start "$SERVICE_NAME"
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_success "更新完成，服务已重启"
    else
        print_error "更新后服务启动失败，正在恢复备份..."
        # 恢复备份
        mv "$INSTALL_DIR/anytls-server.bak" "$INSTALL_DIR/anytls-server" 2>/dev/null || true
        mv "$INSTALL_DIR/anytls-client.bak" "$INSTALL_DIR/anytls-client" 2>/dev/null || true
        systemctl start "$SERVICE_NAME"
        print_error "已恢复到之前版本"
    fi
}

# 卸载程序
uninstall_anytls() {
    echo -e "${RED}警告: 这将完全卸载AnyTLS及其所有配置文件和数据！${NC}"
    echo -e "${RED}包括：程序文件、配置文件、日志文件、系统服务、管理面板等${NC}"
    echo -n "确认完全卸载? [y/N]: "
    read -r confirm
    case ${confirm,,} in
        y|yes)
            print_info "开始完全卸载AnyTLS..."
            
            # 停止并禁用服务
            print_info "停止系统服务..."
            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$SERVICE_NAME" 2>/dev/null || true
            
            # 删除系统服务文件
            print_info "删除系统服务配置..."
            rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
            systemctl daemon-reload
            
            # 删除程序文件目录
            print_info "删除程序文件..."
            rm -rf "$INSTALL_DIR"
            
            # 删除配置文件目录
            print_info "删除配置文件..."
            rm -rf "$CONFIG_DIR"
            
            # 删除日志文件目录
            print_info "删除日志文件..."
            rm -rf "$LOG_DIR"
            
            # 删除可执行文件链接
            print_info "删除系统命令..."
            rm -f "/usr/local/bin/anytls-server"
            rm -f "/usr/local/bin/anytls-client"
            rm -f "/usr/local/bin/anytls"
            rm -f "/usr/local/bin/anytls-manage"  # 兼容旧版本
            
            # 删除可能的临时文件
            print_info "清理临时文件..."
            rm -rf "/tmp/anytls"*
            rm -rf "/tmp/go*.tar.gz"
            
            # 删除可能的备份文件
            print_info "删除备份文件..."
            find "$INSTALL_DIR" -name "*.bak" -delete 2>/dev/null || true
            
            # 清理防火墙规则（可选，用户确认）
            echo -n "是否清理防火墙规则? [y/N]: "
            read -r clean_firewall
            case ${clean_firewall,,} in
                y|yes)
                    print_info "清理防火墙规则..."
                    # UFW规则清理
                    if command -v ufw &> /dev/null; then
                        # 这里不直接删除规则，因为可能影响其他服务
                        print_warning "请手动检查并清理UFW规则: sudo ufw status numbered"
                    fi
                    
                    # firewalld规则清理
                    if command -v firewall-cmd &> /dev/null; then
                        print_warning "请手动检查并清理firewalld规则: sudo firewall-cmd --list-ports"
                    fi
                    
                    print_warning "防火墙规则需要手动确认清理，以避免影响其他服务"
                    ;;
                *)
                    print_info "跳过防火墙规则清理"
                    ;;
            esac
            
            # 清理acme.sh证书（如果存在）
            if [[ -d ~/.acme.sh ]]; then
                echo -n "是否删除Let's Encrypt证书和acme.sh? [y/N]: "
                read -r clean_certs
                case ${clean_certs,,} in
                    y|yes)
                        print_info "删除Let's Encrypt证书..."
                        rm -rf ~/.acme.sh
                        ;;
                    *)
                        print_info "保留Let's Encrypt证书"
                        ;;
                esac
            fi
            
            # 最终确认清理
            print_info "执行最终清理..."
            # 清理可能残留的进程
            pkill -f "anytls" 2>/dev/null || true
            
            # 清理环境变量（如果有）
            sed -i '/anytls/Id' /etc/environment 2>/dev/null || true
            sed -i '/anytls/Id' ~/.bashrc 2>/dev/null || true
            
            echo
            print_success "AnyTLS已完全卸载！"
            print_info "已清理的内容："
            echo "  - 程序文件: $INSTALL_DIR"
            echo "  - 配置文件: $CONFIG_DIR"
            echo "  - 日志文件: $LOG_DIR"
            echo "  - 系统服务: ${SERVICE_NAME}.service"
            echo "  - 管理面板: /usr/local/bin/anytls"
            echo "  - 可执行文件链接"
            echo "  - 临时文件和备份文件"
            echo
            print_warning "如需重新安装，请重新运行安装脚本"
            ;;
        *)
            print_info "取消卸载"
            ;;
    esac
}

# 显示主菜单
show_menu() {
    print_banner
    echo "1)  查看状态"
    echo "2)  启动服务"
    echo "3)  停止服务"
    echo "4)  重启服务"
    echo "5)  查看日志"
    echo "6)  检查更新"
    echo "7)  卸载程序"
    echo "0)  退出"
    echo
}

# 主循环
main() {
    while true; do
        show_menu
        echo -n "请选择操作 [0-7]: "
        read -r choice
        echo
        
        case $choice in
            1)
                show_status
                ;;
            2)
                start_service
                ;;
            3)
                stop_service
                ;;
            4)
                restart_service
                ;;
            5)
                view_logs
                ;;
            6)
                check_update
                ;;
            7)
                uninstall_anytls
                ;;
            0)
                print_info "退出管理面板"
                exit 0
                ;;
            *)
                print_error "无效选择，请重新输入"
                ;;
        esac
        
        echo
        echo -n "按回车键继续..."
        read -r
        clear
    done
}

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    print_error "此脚本需要root权限运行"
    exit 1
fi

# 如果有参数，直接执行对应功能
case "${1:-}" in
    status)
        show_status
        ;;
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    restart)
        restart_service
        ;;
    logs)
        view_logs
        ;;
    update)
        check_update
        ;;
    uninstall)
        uninstall_anytls
        ;;
    *)
        main
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/anytls
    print_success "管理脚本创建完成"
}

# 显示安装完成信息
show_completion_info() {
    echo
    print_banner
    print_success "AnyTLS-Go 安装完成！"
    echo
    
    echo -e "${CYAN}>>> 安装信息${NC}"
    echo "安装目录: $INSTALL_DIR"
    echo "配置目录: $CONFIG_DIR"
    echo "日志目录: $LOG_DIR"
    echo "服务名称: $SERVICE_NAME"
    echo
    
    echo -e "${CYAN}>>> 运行模式${NC}"
    echo "模式: 服务端"
    echo "监听地址: 0.0.0.0:$USER_PORT"
    echo "连接密码: $USER_PASSWORD"
    echo
    echo "客户端连接示例:"
    echo "  anytls-client -l 127.0.0.1:1080 -s ${PUBLIC_IP}:${USER_PORT} -p '${USER_PASSWORD}'"
    echo
    echo "URI格式:"
    echo "  anytls://${USER_PASSWORD}@${PUBLIC_IP}:${USER_PORT}/"
    echo
    
    echo -e "${CYAN}>>> 管理命令${NC}"
    echo "管理面板: anytls"
    echo "查看状态: anytls status"
    echo "启动服务: anytls start"
    echo "停止服务: anytls stop"
    echo "重启服务: anytls restart"
    echo "查看日志: anytls logs"
    echo
    
    echo -e "${CYAN}>>> systemd 命令${NC}"
    echo "启动: systemctl start $SERVICE_NAME"
    echo "停止: systemctl stop $SERVICE_NAME"
    echo "重启: systemctl restart $SERVICE_NAME"
    echo "状态: systemctl status $SERVICE_NAME"
    echo "日志: journalctl -u $SERVICE_NAME -f"
    echo
    
    # 检查并显示服务状态
    local service_status=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "inactive")
    if [[ "$service_status" == "active" ]]; then
        echo -e "${GREEN}✓${NC} 服务状态: 运行中 (active)"
    else
        echo -e "${RED}✗${NC} 服务状态: 未运行 ($service_status)"
    fi
    
    echo -e "${GREEN}✓${NC} 已设置开机自启"
    
    if [[ $USER_FIREWALL == "y" ]]; then
        echo -e "${GREEN}✓${NC} 已配置防火墙"
    else
        echo -e "${YELLOW}!${NC} 未配置防火墙，请手动配置"
    fi
    
    # 已移除证书配置状态显示
    
    # 已移除 IP版本配置状态显示
    
    echo
    echo -e "${PURPLE}感谢使用 AnyTLS-Go！${NC}"
    echo -e "${PURPLE}原项目地址: https://github.com/anytls/anytls-go${NC}"
    echo -e "${PURPLE}安装项目地址: https://github.com/10000ge10000/AnyTLS-Go${NC}"
    echo
}

# 主函数
main() {
    print_banner
    
    # 检查root权限
    check_root
    
    # 系统检测
    detect_system
    check_network
    
    # 系统准备
    update_system
    install_core_dependencies
    create_directories
    
    # 安装程序（智能选择预编译或源码编译）
    install_anytls
    
    # 只有在源码编译时才显示Go安装信息
    if [[ "$SKIP_GO_INSTALL" != "true" ]]; then
        print_info "已安装Go环境用于源码编译"
    else
        print_info "使用预编译版本，跳过Go环境安装"
    fi
    
    # 用户配置
    configure_user_settings
    
    # 生成配置文件
    generate_config
    
    # 已移除自签名证书配置调用
    
    # 配置防火墙
    configure_firewall
    
    # 创建systemd服务
    create_systemd_service
    
    # 创建管理脚本
    create_management_script
    
    # 显示完成信息
    show_completion_info
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi