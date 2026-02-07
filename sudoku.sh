#!/bin/bash

# ====================================================
# Sudoku (ASCII) 一键安装脚本
# 基于数独伪装的代理协议
# ====================================================

# --- 全局配置 ---
SCRIPT_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main/sudoku.sh"
INSTALL_DIR="/opt/sudoku"
CONFIG_DIR="/etc/sudoku"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_FILE="${INSTALL_DIR}/sudoku"
SERVICE_FILE="/etc/systemd/system/sudoku.service"
SHORTCUT_BIN="/usr/bin/sudoku"
ENV_FILE="${CONFIG_DIR}/env.conf"

# --- 引入公共函数 ---
if [[ -f "common.sh" ]]; then
    source "common.sh"
else
    source <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/common.sh)
fi

# --- 系统服务检测 ---
check_sys_init() {
    if [[ -d "/run/systemd/system" ]] || grep -q systemd <(ls -l /sbin/init); then
        SYSTEMD_AVAILABLE=true
    else
        SYSTEMD_AVAILABLE=false
    fi
}
check_sys_init

# --- 状态检测 ---
check_status() {
    if [[ -f "$BIN_FILE" ]]; then
        STATUS_INSTALL="${GREEN}已安装${PLAIN}"
    else
        STATUS_INSTALL="${RED}未安装${PLAIN}"
    fi

    if pgrep -f "$BIN_FILE" > /dev/null 2>&1; then
        STATUS_RUNNING="${GREEN}运行中${PLAIN}"
    else
        STATUS_RUNNING="${RED}未运行${PLAIN}"
    fi
}

# --- 补充依赖 ---
install_specific_deps() {
    print_info "安装 Sudoku 组件依赖..."
    if [[ "${RELEASE}" == "centos" ]]; then
        yum install -y jq tar wget openssl
    else
        apt update
        apt install -y jq tar wget openssl
    fi
}

# --- 安装核心 ---
install_sudoku_core() {
    print_info "正在获取 Sudoku 核心 (Source: SUDOKU-ASCII/sudoku)..."
    
    local arch=$(uname -m)
    local sudoku_arch=""
    case "$arch" in
        x86_64|x64|amd64) sudoku_arch="linux_amd64" ;;
        aarch64|arm64) sudoku_arch="linux_arm64" ;;
        armv7l) sudoku_arch="linux_armv7" ;;
        *) print_warn "未识别架构: $arch, 尝试 amd64"; sudoku_arch="linux_amd64" ;;
    esac

    # 获取最新版本
    local tag_version=""
    local api_url="https://api.github.com/repos/SUDOKU-ASCII/sudoku/releases/latest"
    
    if command -v jq >/dev/null 2>&1; then
        tag_version=$(curl -s "$api_url" | jq -r '.tag_name')
    fi
    
    if [[ -z "$tag_version" || "$tag_version" == "null" ]]; then
        tag_version=$(curl -s "$api_url" | grep -o '"tag_name": *"[^"]*"' | sed 's/.*: *"//;s/"$//')
    fi
    
    if [[ -z "$tag_version" ]]; then
        print_warn "获取版本失败，尝试使用 IPv4 API 或默认版本..."
        tag_version=$(curl -4 -s "$api_url" | grep -o '"tag_name": *"[^"]*"' | sed 's/.*: *"//;s/"$//')
    fi
    [[ -z "$tag_version" ]] && tag_version="v0.2.2"

    # 构造下载链接
    local download_url="https://github.com/SUDOKU-ASCII/sudoku/releases/download/${tag_version}/sudoku_${tag_version#v}_${sudoku_arch}.tar.gz"
    local temp_tar="/tmp/sudoku.tar.gz"
    local temp_dir="/tmp/sudoku-extract"

    print_info "下载核心组件: $tag_version ($sudoku_arch)..."
    wget -q --show-progress -O "$temp_tar" "$download_url"
    
    if [[ ! -s "$temp_tar" ]]; then
        print_err "下载失败: $download_url"
        exit 1
    fi

    # 解压提取
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    tar -xzf "$temp_tar" -C "$temp_dir"
    
    print_info "安装 Sudoku 核心..."
    mkdir -p "$INSTALL_DIR"
    
    # 查找二进制文件
    local extracted_bin=$(find "$temp_dir" -name "sudoku" -type f | head -n 1)

    if [[ -f "$extracted_bin" ]]; then
        cp -f "$extracted_bin" "$BIN_FILE"
        chmod +x "$BIN_FILE"
        echo "$tag_version" > "${INSTALL_DIR}/version"
        print_ok "核心安装成功 ($tag_version)"
    else
        print_err "未找到核心文件！"
        exit 1
    fi

    rm -f "$temp_tar"
    rm -rf "$temp_dir"
}

# --- 生成密钥对 ---
generate_keypair() {
    print_info "正在生成 Sudoku 密钥对..."
    
    if [[ ! -f "$BIN_FILE" ]]; then
        print_err "Sudoku 核心未安装，无法生成密钥"
        exit 1
    fi
    
    # 执行 keygen
    local keygen_output=$("$BIN_FILE" -keygen 2>/dev/null)
    
    # 提取公钥和私钥
    local public_key=$(echo "$keygen_output" | grep "Master Public Key:" | awk '{print $NF}')
    local private_key=$(echo "$keygen_output" | grep "Available Private Key:" | awk '{print $1}' | tail -n 1)
    
    if [[ -z "$public_key" || -z "$private_key" ]]; then
        print_err "密钥生成失败"
        exit 1
    fi
    
    echo "$public_key|$private_key"
}

# --- 生成配置 ---
configure_sudoku() {
    mkdir -p "$CONFIG_DIR"
    
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e " ${BOLD}Sudoku 配置向导${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    
    # 端口配置
    local default_port=8080
    read -p " 请输入监听端口 [默认 ${default_port}]: " PORT
    [[ -z "$PORT" ]] && PORT=$default_port
    
    # Fallback 地址
    local default_fallback="127.0.0.1:80"
    read -p " 请输入 Fallback 地址 [默认 ${default_fallback}]: " FALLBACK_ADDR
    [[ -z "$FALLBACK_ADDR" ]] && FALLBACK_ADDR=$default_fallback
    
    # 生成密钥对
    print_info "正在生成密钥对..."
    local keypair=$(generate_keypair)
    local PUBLIC_KEY=$(echo "$keypair" | cut -d'|' -f1)
    local PRIVATE_KEY=$(echo "$keypair" | cut -d'|' -f2)
    
    print_ok "密钥对生成成功"
    echo -e " ${YELLOW}服务端公钥 (Public Key):${PLAIN} ${CYAN}${PUBLIC_KEY}${PLAIN}"
    echo -e " ${YELLOW}客户端私钥 (Private Key):${PLAIN} ${CYAN}${PRIVATE_KEY}${PLAIN}"
    
    # AEAD 加密方式
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    echo " 请选择 AEAD 加密方式:"
    echo " 1. chacha20-poly1305 (推荐)"
    echo " 2. aes-128-gcm"
    echo " 3. none (不加密，仅混淆)"
    read -p " 请选择 [1-3] (默认 1): " aead_choice
    
    local AEAD_METHOD="chacha20-poly1305"
    case "$aead_choice" in
        2) AEAD_METHOD="aes-128-gcm" ;;
        3) AEAD_METHOD="none" ;;
        *) AEAD_METHOD="chacha20-poly1305" ;;
    esac
    
    # 填充参数
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    read -p " 请输入最小填充字节数 [默认 2]: " PADDING_MIN
    [[ -z "$PADDING_MIN" ]] && PADDING_MIN=2
    
    read -p " 请输入最大填充字节数 [默认 7]: " PADDING_MAX
    [[ -z "$PADDING_MAX" ]] && PADDING_MAX=7
    
    # 字节布局策略
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    echo " 请选择字节布局策略 (Table Type):"
    echo " 1. prefer_ascii (全 ASCII 映射)"
    echo " 2. prefer_entropy (低熵值，汉明权重 < 3)"
    read -p " 请选择 [1-2] (默认 1): " table_choice
    
    local TABLE_TYPE="prefer_ascii"
    case "$table_choice" in
        2) TABLE_TYPE="prefer_entropy" ;;
        *) TABLE_TYPE="prefer_ascii" ;;
    esac
    
    # 自定义布局
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    read -p " 是否使用自定义字节布局? [y/n] (默认 n): " use_custom_table
    local CUSTOM_TABLE=""
    local CUSTOM_TABLES_JSON="[]"
    
    if [[ "$use_custom_table" == "y" || "$use_custom_table" == "Y" ]]; then
        read -p " 请输入自定义布局 (格式: xpxvvpvv, 需包含 2x/2p/4v) [默认 xpxvvpvv]: " input_custom_table
        CUSTOM_TABLE="${input_custom_table:-xpxvvpvv}"
        
        read -p " 是否启用多表轮换? [y/n] (默认 n): " use_multi_table
        if [[ "$use_multi_table" == "y" || "$use_multi_table" == "Y" ]]; then
            read -p " 请输入第二个布局 (格式: vxpvxvvp) [默认 vxpvxvvp]: " custom_table2
            custom_table2="${custom_table2:-vxpvxvvp}"
            CUSTOM_TABLES_JSON="[\"$CUSTOM_TABLE\", \"$custom_table2\"]"
        fi
    fi
    
    # HTTP Mask 配置
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    read -p " 是否启用 HTTP 掩码 (支持 CDN)? [y/n] (默认 n): " enable_http_mask
    
    local HTTP_MASK_DISABLE="true"
    local HTTP_MASK_MODE="legacy"
    local HTTP_MASK_TLS="false"
    local HTTP_MASK_HOST=""
    local PATH_ROOT=""
    local HTTP_MASK_MULTIPLEX="off"
    
    if [[ "$enable_http_mask" == "y" || "$enable_http_mask" == "Y" ]]; then
        HTTP_MASK_DISABLE="false"
        
        echo " 请选择 HTTP Mask 模式:"
        echo " 1. legacy (默认)"
        echo " 2. stream (支持 CDN)"
        echo " 3. poll (支持 CDN)"
        echo " 4. auto (自动选择)"
        read -p " 请选择 [1-4] (默认 1): " mask_mode_choice
        
        case "$mask_mode_choice" in
            2) HTTP_MASK_MODE="stream" ;;
            3) HTTP_MASK_MODE="poll" ;;
            4) HTTP_MASK_MODE="auto" ;;
            *) HTTP_MASK_MODE="legacy" ;;
        esac
        
        if [[ "$HTTP_MASK_MODE" != "legacy" ]]; then
            read -p " 是否启用 TLS? [y/n] (默认 n): " enable_tls
            [[ "$enable_tls" == "y" || "$enable_tls" == "Y" ]] && HTTP_MASK_TLS="true"
            
            read -p " 请输入自定义 Host/SNI (留空使用服务器地址): " input_host
            HTTP_MASK_HOST="$input_host"
            
            read -p " 请输入路径前缀 (例如: aabbcc): " input_path_root
            PATH_ROOT="$input_path_root"
            
            echo " 请选择连接复用策略:"
            echo " 1. off (默认)"
            echo " 2. auto (复用底层连接)"
            echo " 3. on (单隧道多路复用)"
            read -p " 请选择 [1-3] (默认 1): " multiplex_choice
            
            case "$multiplex_choice" in
                2) HTTP_MASK_MULTIPLEX="auto" ;;
                3) HTTP_MASK_MULTIPLEX="on" ;;
                *) HTTP_MASK_MULTIPLEX="off" ;;
            esac
        fi
    fi
    
    # 纯混淆下行
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    read -p " 是否启用纯混淆下行 (降低性能但更安全)? [y/n] (默认 y): " enable_pure_downlink
    local ENABLE_PURE_DOWNLINK="true"
    [[ "$enable_pure_downlink" == "n" || "$enable_pure_downlink" == "N" ]] && ENABLE_PURE_DOWNLINK="false"
    
    # 生成服务端配置
    local httpmask_json=""
    if [[ "$HTTP_MASK_DISABLE" == "false" ]]; then
        httpmask_json=",
  \"httpmask\": {
    \"disable\": false,
    \"mode\": \"$HTTP_MASK_MODE\",
    \"tls\": $HTTP_MASK_TLS"
        
        [[ -n "$HTTP_MASK_HOST" ]] && httpmask_json="$httpmask_json,
    \"host\": \"$HTTP_MASK_HOST\""
        
        [[ -n "$PATH_ROOT" ]] && httpmask_json="$httpmask_json,
    \"path_root\": \"$PATH_ROOT\""
        
        httpmask_json="$httpmask_json,
    \"multiplex\": \"$HTTP_MASK_MULTIPLEX\"
  }"
    else
        httpmask_json=",
  \"httpmask\": {
    \"disable\": true
  }"
    fi
    
    # 自定义表配置
    local custom_table_json=""
    if [[ -n "$CUSTOM_TABLE" ]]; then
        if [[ "$CUSTOM_TABLES_JSON" != "[]" ]]; then
            custom_table_json=",
  \"custom_tables\": $CUSTOM_TABLES_JSON"
        else
            custom_table_json=",
  \"custom_table\": \"$CUSTOM_TABLE\""
        fi
    fi
    
    cat > "$CONFIG_FILE" <<EOF
{
  "mode": "server",
  "local_port": $PORT,
  "server_address": "",
  "fallback_address": "$FALLBACK_ADDR",
  "key": "$PUBLIC_KEY",
  "aead": "$AEAD_METHOD",
  "suspicious_action": "fallback",
  "ascii": "$TABLE_TYPE",
  "padding_min": $PADDING_MIN,
  "padding_max": $PADDING_MAX${custom_table_json},
  "enable_pure_downlink": $ENABLE_PURE_DOWNLINK${httpmask_json}
}
EOF
    
    print_ok "配置文件生成成功: $CONFIG_FILE"
    
    # 保存环境变量
    cat > "$ENV_FILE" <<EOF
PORT="$PORT"
PUBLIC_KEY="$PUBLIC_KEY"
PRIVATE_KEY="$PRIVATE_KEY"
AEAD_METHOD="$AEAD_METHOD"
PADDING_MIN="$PADDING_MIN"
PADDING_MAX="$PADDING_MAX"
TABLE_TYPE="$TABLE_TYPE"
CUSTOM_TABLE="$CUSTOM_TABLE"
CUSTOM_TABLES="$CUSTOM_TABLES_JSON"
HTTP_MASK_DISABLE="$HTTP_MASK_DISABLE"
HTTP_MASK_MODE="$HTTP_MASK_MODE"
HTTP_MASK_TLS="$HTTP_MASK_TLS"
HTTP_MASK_HOST="$HTTP_MASK_HOST"
PATH_ROOT="$PATH_ROOT"
HTTP_MASK_MULTIPLEX="$HTTP_MASK_MULTIPLEX"
ENABLE_PURE_DOWNLINK="$ENABLE_PURE_DOWNLINK"
FALLBACK_ADDR="$FALLBACK_ADDR"
EOF
}

# --- 启动服务 ---
setup_service() {
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sudoku Proxy Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=$BIN_FILE -c $CONFIG_FILE
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable sudoku >/dev/null 2>&1
        systemctl restart sudoku
        print_ok "Systemd 服务已启动/重启"
    else
        print_warn "检测到非 Systemd 环境，正在后台启动 Sudoku..."
        killall sudoku >/dev/null 2>&1
        nohup "$BIN_FILE" -c "$CONFIG_FILE" >/var/log/sudoku.log 2>&1 &
        print_ok "Sudoku 已后台运行 (日志: /var/log/sudoku.log)"
    fi
    
    # 配置防火墙
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
        if [[ -n "$PORT" ]]; then
            print_info "配置防火墙规则 (端口: $PORT)..."
            apply_firewall_rule "$PORT" "tcp"
        fi
    fi
    
    print_ok "服务已启动/重启"
}

# --- 展示信息 ---
show_info() {
    if [[ ! -f "$ENV_FILE" ]]; then
        print_err "未安装或配置文件缺失"
        return
    fi
    
    source "$ENV_FILE"
    
    local ip=$(curl -s4m8 https://api.ipify.org || curl -s4m8 https://ifconfig.me)
    
    print_line
    echo -e "${GREEN}Sudoku 节点信息${PLAIN}"
    echo -e "服务器 (Server):    ${CYAN}${ip}${PLAIN}"
    echo -e "端口 (Port):        ${CYAN}${PORT}${PLAIN}"
    echo -e "客户端密钥 (Key):   ${CYAN}${PRIVATE_KEY}${PLAIN}"
    echo -e "AEAD 加密:          ${CYAN}${AEAD_METHOD}${PLAIN}"
    echo -e "填充范围:           ${CYAN}${PADDING_MIN}-${PADDING_MAX}${PLAIN}"
    echo -e "字节布局:           ${CYAN}${TABLE_TYPE}${PLAIN}"
    [[ -n "$CUSTOM_TABLE" ]] && echo -e "自定义布局:         ${CYAN}${CUSTOM_TABLE}${PLAIN}"
    [[ "$CUSTOM_TABLES" != "[]" ]] && echo -e "多表轮换:           ${CYAN}${CUSTOM_TABLES}${PLAIN}"
    echo -e "纯混淆下行:         ${CYAN}${ENABLE_PURE_DOWNLINK}${PLAIN}"
    
    if [[ "$HTTP_MASK_DISABLE" == "false" ]]; then
        echo -e "HTTP 掩码:          ${CYAN}已启用 (${HTTP_MASK_MODE})${PLAIN}"
        [[ "$HTTP_MASK_TLS" == "true" ]] && echo -e "TLS:                ${CYAN}已启用${PLAIN}"
        [[ -n "$HTTP_MASK_HOST" ]] && echo -e "Host/SNI:           ${CYAN}${HTTP_MASK_HOST}${PLAIN}"
        [[ -n "$PATH_ROOT" ]] && echo -e "路径前缀:           ${CYAN}${PATH_ROOT}${PLAIN}"
        [[ "$HTTP_MASK_MULTIPLEX" != "off" ]] && echo -e "连接复用:           ${CYAN}${HTTP_MASK_MULTIPLEX}${PLAIN}"
    fi
    
    print_line
    echo -e "${YELLOW}OpenClash 配置示例:${PLAIN}"
    echo ""
    
    # 生成 OpenClash YAML
    local server_addr="$ip"
    local server_port="$PORT"
    
    if [[ "$HTTP_MASK_DISABLE" == "false" && -n "$HTTP_MASK_HOST" ]]; then
        server_addr="$HTTP_MASK_HOST"
        if [[ "$HTTP_MASK_TLS" == "true" ]]; then
            server_port="443"
        else
            server_port="80"
        fi
    fi
    
    cat <<EOF
proxies:
  - name: "Sudoku-${ip}"
    type: sudoku
    server: ${server_addr}
    port: ${server_port}
    key: "${PRIVATE_KEY}"
    aead-method: ${AEAD_METHOD}
    padding-min: ${PADDING_MIN}
    padding-max: ${PADDING_MAX}
    table-type: ${TABLE_TYPE}
EOF

    if [[ -n "$CUSTOM_TABLE" ]]; then
        if [[ "$CUSTOM_TABLES" != "[]" ]]; then
            echo "    custom-tables: ${CUSTOM_TABLES}"
        else
            echo "    custom-table: ${CUSTOM_TABLE}"
        fi
    fi
    
    if [[ "$HTTP_MASK_DISABLE" == "false" ]]; then
        echo "    http-mask: true"
        echo "    http-mask-mode: ${HTTP_MASK_MODE}"
        [[ "$HTTP_MASK_TLS" == "true" ]] && echo "    http-mask-tls: true"
        [[ -n "$HTTP_MASK_HOST" ]] && echo "    http-mask-host: ${HTTP_MASK_HOST}"
        [[ -n "$PATH_ROOT" ]] && echo "    path-root: ${PATH_ROOT}"
        [[ "$HTTP_MASK_MULTIPLEX" != "off" ]] && echo "    http-mask-multiplex: ${HTTP_MASK_MULTIPLEX}"
    fi
    
    echo "    enable-pure-downlink: ${ENABLE_PURE_DOWNLINK}"
    
    print_line
}

# --- 快捷指令 ---
create_shortcut() {
    if [[ -f "$0" ]]; then cp -f "$0" "$SHORTCUT_BIN"; else wget -qO "$SHORTCUT_BIN" "$SCRIPT_URL"; fi
    chmod +x "$SHORTCUT_BIN"
    print_ok "快捷指令: sudoku"
}

# --- 更新核心 ---
update_core() {
    echo "=================================================="
    echo " Sudoku 核心更新"
    echo "--------------------------------------------------"
    
    local current_ver=""
    if [[ -f "${INSTALL_DIR}/version" ]]; then
        current_ver=$(cat "${INSTALL_DIR}/version")
    else
        current_ver="未知"
    fi

    print_info "正在检查最新版本..."
    local api_url="https://api.github.com/repos/SUDOKU-ASCII/sudoku/releases/latest"
    local latest_ver=""
    
    if command -v jq >/dev/null 2>&1; then
        latest_ver=$(curl -s "$api_url" | jq -r '.tag_name')
    fi
    
    if [[ -z "$latest_ver" || "$latest_ver" == "null" ]]; then
        latest_ver=$(curl -s "$api_url" | grep -o '"tag_name": *"[^"]*"' | sed 's/.*: *"//;s/"$//')
    fi
    [[ -z "$latest_ver" ]] && latest_ver="未知"

    echo -e " 当前版本: ${GREEN}${current_ver}${PLAIN}"
    echo -e " 最新版本: ${GREEN}${latest_ver}${PLAIN}"
    echo "--------------------------------------------------"

    local choice=""
    if [[ "$latest_ver" != "未知" && "$current_ver" == "$latest_ver" ]]; then
        echo -e "${GREEN}当前已是最新版本。${PLAIN}"
        read -p "是否强制重新更新? [y/n]: " choice
    else
        read -p "是否更新核心? [y/n]: " choice
    fi
    
    [[ "$choice" != "y" && "$choice" != "Y" ]] && return

    print_info "正在停止服务..."
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        systemctl stop sudoku
    else
        killall sudoku >/dev/null 2>&1
    fi

    install_sudoku_core
    
    print_info "正在重启服务..."
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        systemctl restart sudoku
    else
        nohup "$BIN_FILE" -c "$CONFIG_FILE" >/var/log/sudoku.log 2>&1 &
    fi
    print_ok "核心更新完成"
}

# --- 卸载 ---
uninstall_sudoku() {
    echo "------------------------------------------------"
    echo -e "${RED}警告: 即将卸载 Sudoku 及所有组件${PLAIN}"
    read -p "确认卸载? [y/n]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    print_info "正在停止 Sudoku 服务..."
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        systemctl stop sudoku >/dev/null 2>&1
        systemctl disable sudoku >/dev/null 2>&1
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    else
        killall sudoku >/dev/null 2>&1
    fi

    print_info "清除安装文件..."
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$SHORTCUT_BIN" "/var/log/sudoku.log"

    print_ok "卸载完成，系统已清理。"
}

# --- 菜单 ---
menu() {
    check_status
    clear
    echo -e "${BLUE}################################################${PLAIN}"
    echo -e "${BLUE}#${PLAIN}         ${BOLD}Sudoku 一键管理脚本${PLAIN}                ${BLUE}#${PLAIN}"
    echo -e "${BLUE}#${PLAIN}     ${CYAN}基于数独伪装的代理协议${PLAIN}               ${BLUE}#${PLAIN}"
    echo -e "${BLUE}################################################${PLAIN}"
    echo -e " 系统状态: ${STATUS_INSTALL} | ${STATUS_RUNNING}"
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} 安装/重新配置"
    echo -e " ${GREEN}2.${PLAIN} 查看节点信息"
    echo -e " ${GREEN}3.${PLAIN} 重启服务"
    echo -e " ${GREEN}4.${PLAIN} 停止服务"
    echo -e " ${GREEN}5.${PLAIN} 更新核心"
    echo -e " ${GREEN}6.${PLAIN} 卸载脚本"
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    echo -e " ${GREEN}0.${PLAIN} 退出"
    echo -e "${BLUE}################################################${PLAIN}"
    read -p " 请选择操作 [0-6]: " n

    case "$n" in
        1) start_installation ;;
        2) show_info ;;
        3) 
            if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
                systemctl restart sudoku && print_ok "重启成功"
            else
                killall sudoku >/dev/null 2>&1
                nohup "$BIN_FILE" -c "$CONFIG_FILE" >/var/log/sudoku.log 2>&1 &
                print_ok "服务已重启 (后台)"
            fi
            ;;
        4) 
            if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
                systemctl stop sudoku && print_ok "停止成功"
            else
                killall sudoku >/dev/null 2>&1 && print_ok "已结束后台进程"
            fi
            ;;
        5) update_core ;;
        6) uninstall_sudoku ;;
        0) exit 0 ;;
        *) print_err "无效输入"; menu ;;
    esac
}

# --- 智能安装入口 ---
start_installation() {
    detect_os
    
    if [[ -f "$BIN_FILE" ]]; then
        print_info "检测到 Sudoku 核心已安装，跳过下载步骤。"
    else
        install_specific_deps
        install_sudoku_core
    fi
    
    configure_sudoku
    setup_service
    create_shortcut
    show_info
}

[[ -n "$1" ]] && { 
    case "$1" in
        install) start_installation ;;
        info) show_info ;;
        *) menu ;;
    esac
} || menu
