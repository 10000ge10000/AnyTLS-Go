#!/bin/bash

# ====================================================
# OneKey - OpenClash 代理一键管理聚合脚本
# 项目: github.com/10000ge10000/own-rules
# 版本: 1.0.0
# ====================================================

# --- 版本信息 ---
VERSION="1.0.0"
SCRIPT_NAME="onekey.sh"
REPO_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main"
VERSION_FILE="$HOME/.onekey_version"
SHORTCUT_BIN="/usr/bin/x"

# --- 颜色定义 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
GRAY='\033[90m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 服务配置表 ---
# 格式: 名称|描述|服务名|配置文件|端口字段|脚本名
declare -A SERVICES
SERVICES=(
    ["1"]="AnyTLS|隐匿传输|anytls|/etc/anytls/server.conf|PORT|anytls.sh"
    ["2"]="TUIC|QUIC高速|tuic|/etc/tuic/config.json|port|tuic.sh"
    ["3"]="SS-2022|Rust高性能|shadowsocks-rust|/etc/shadowsocks-rust/config.json|port|ss2022.sh"
    ["4"]="Hysteria2|暴力加速|hysteria-server|/etc/hysteria/config.yaml|listen|hy2.sh"
    ["5"]="Mieru|流量混淆|mita|/etc/mieru/server_config.json|port|mieru.sh"
    ["6"]="VLESS|全能协议/XHTTP|xray|/etc/xray/config.json|port|vless.sh"
    ["7"]="Sudoku|数独隐写|sudoku-tunnel|/etc/sudoku/config.json|local_port|sudoku.sh"
)

declare -A TOOLS
TOOLS=(
    ["8"]="IPF|端口转发|ipf|/etc/ip-forward/conf.db|ipf.sh"
    ["9"]="DNS监控|智能优选|autodns|/etc/autodns/config.env|dns_monitor_install.sh"
    ["10"]="DNS修复|永久锁定|fixdns|/etc/systemd/resolved.conf.d/dns.conf|setup_dns.sh"
    ["11"]="Alice分流|家宽路由|xray-socks|/etc/xray/socks_route.json|socks_route.sh"
)

# ============================================================
# 辅助函数
# ============================================================

print_line() {
    echo -e "${CYAN}─────────────────────────────────────────────────────────${PLAIN}"
}

print_double_line() {
    echo -e "${CYAN}═════════════════════════════════════════════════════════${PLAIN}"
}

# --- 检测服务状态 ---
get_service_status() {
    local service_name=$1
    local config_file=$2
    local port_field=$3
    
    # 特殊处理工具类
    if [[ "$service_name" == "ipf" ]]; then
        if [[ -f "$config_file" && -s "$config_file" ]]; then
            local count=$(wc -l < "$config_file" 2>/dev/null)
            echo "configured|${count}条规则"
        else
            echo "not_installed|"
        fi
        return
    fi
    
    if [[ "$service_name" == "autodns" ]]; then
        if systemctl is-active --quiet dns_monitor 2>/dev/null; then
            echo "running|"
        elif [[ -f "/etc/autodns/config.env" ]]; then
            echo "stopped|"
        else
            echo "not_installed|"
        fi
        return
    fi
    
    if [[ "$service_name" == "fixdns" ]]; then
        if [[ -f "$config_file" ]]; then
            echo "configured|"
        else
            echo "not_installed|"
        fi
        return
    fi
    
    if [[ "$service_name" == "xray-socks" ]]; then
        if systemctl is-active --quiet xray-socks 2>/dev/null; then
            local port=""
            if command -v jq &>/dev/null && [[ -f "$config_file" ]]; then
                port=$(jq -r '.socks_inbound.port // empty' "$config_file" 2>/dev/null)
            fi
            echo "running|${port}"
        elif [[ -f "$config_file" ]]; then
            echo "stopped|"
        else
            echo "not_installed|"
        fi
        return
    fi
    
    # 代理服务检测 — 多维度判断是否已安装
    # 优先级: 配置文件 > 二进制文件 > systemd unit > 特殊目录
    local installed=0
    
    if [[ -f "$config_file" ]]; then
        installed=1
    fi
    
    # VLESS/Xray 特殊: 多节点配置在 /etc/xray/nodes/
    if [[ "$service_name" == "xray" ]]; then
        if [[ -d "/etc/xray/nodes" ]] && ls /etc/xray/nodes/*.conf &>/dev/null; then
            installed=1
        fi
        # 也检查二进制是否存在
        if [[ -f "/opt/xray/xray" || -f "/usr/local/bin/xray" ]]; then
            installed=1
        fi
    fi
    
    # 通用: 检查二进制文件是否存在
    if [[ $installed -eq 0 ]]; then
        local bin_path=""
        case "$service_name" in
            "anytls")           bin_path="/opt/anytls/anytls-server" ;;
            "tuic")             bin_path="/opt/tuic/tuic-server" ;;
            "shadowsocks-rust") bin_path="/opt/shadowsocks-rust/ssserver" ;;
            "hysteria-server")  bin_path="/usr/local/bin/hysteria" ;;
            "mita")             bin_path="/opt/mieru/mita" ;;
            "xray")             bin_path="/opt/xray/xray" ;;
            "sudoku-tunnel")    bin_path="/opt/sudoku/sudoku" ;;
        esac
        if [[ -n "$bin_path" && -f "$bin_path" ]]; then
            installed=1
        fi
    fi
    
    # 通用: 检查 systemd unit 文件是否存在
    if [[ $installed -eq 0 ]]; then
        if [[ -f "/etc/systemd/system/${service_name}.service" ]] || \
           [[ -f "/usr/lib/systemd/system/${service_name}.service" ]]; then
            installed=1
        fi
    fi
    
    if [[ $installed -eq 0 ]]; then
        echo "not_installed|"
        return
    fi
    
    # 获取端口
    local port=""
    if [[ -f "$config_file" ]]; then
        if [[ "$config_file" == *.json ]]; then
            if command -v jq &>/dev/null; then
                # 处理不同的 JSON 结构
                if [[ "$service_name" == "shadowsocks-rust" ]]; then
                    port=$(jq -r '.servers[0].port // .port // empty' "$config_file" 2>/dev/null)
                elif [[ "$service_name" == "tuic" ]]; then
                    # TUIC v5 用 server 字段，v4 用 port 字段
                    local server_str=$(jq -r '.server // empty' "$config_file" 2>/dev/null)
                    if [[ -n "$server_str" ]]; then
                        port=${server_str##*:}
                    else
                        port=$(jq -r '.port // empty' "$config_file" 2>/dev/null)
                    fi
                elif [[ "$service_name" == "mita" ]]; then
                    # Mieru: portBindings[0].port 或 portRange
                    port=$(jq -r '.portBindings[0].port // .portBindings[0].portRange // empty' "$config_file" 2>/dev/null)
                else
                    port=$(jq -r ".$port_field // empty" "$config_file" 2>/dev/null)
                fi
            fi
        elif [[ "$config_file" == *.yaml || "$config_file" == *.yml ]]; then
            # Hysteria2: listen: :PORT
            port=$(grep -E "^listen:" "$config_file" 2>/dev/null | sed 's/.*://' | tr -d ' ')
        elif [[ "$config_file" == *.conf ]]; then
            # AnyTLS: PORT="xxx"
            port=$(grep -E "^PORT=" "$config_file" 2>/dev/null | cut -d'"' -f2)
        fi
    fi
    
    # 检查服务运行状态 (systemd 优先，pgrep 兜底)
    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        echo "running|${port}"
    else
        # systemd 不可用时 (WSL/Docker)，用 pgrep 兜底检测
        local pgrep_bin=""
        case "$service_name" in
            "anytls")           pgrep_bin="/opt/anytls/anytls-server" ;;
            "tuic")             pgrep_bin="/opt/tuic/tuic-server" ;;
            "shadowsocks-rust") pgrep_bin="/opt/shadowsocks-rust/ssserver" ;;
            "hysteria-server")  pgrep_bin="/usr/local/bin/hysteria" ;;
            "mita")             pgrep_bin="/opt/mieru/mita" ;;
            "xray")             pgrep_bin="/opt/xray/xray" ;;
            "sudoku-tunnel")    pgrep_bin="/opt/sudoku/sudoku" ;;
        esac
        if [[ -n "$pgrep_bin" ]] && pgrep -f "$pgrep_bin" >/dev/null 2>&1; then
            echo "running|${port}"
        else
            echo "stopped|${port}"
        fi
    fi
}

# --- 格式化状态显示 (Emoji + 颜色) ---
format_status() {
    local status=$1
    local extra=$2
    
    case "$status" in
        "running")
            if [[ -n "$extra" ]]; then
                echo -e "${GREEN}✅ 运行中 :${extra}${PLAIN}"
            else
                echo -e "${GREEN}✅ 运行中${PLAIN}"
            fi
            ;;
        "stopped")
            if [[ -n "$extra" ]]; then
                echo -e "${YELLOW}⏸️  已停止 :${extra}${PLAIN}"
            else
                echo -e "${YELLOW}⏸️  已停止${PLAIN}"
            fi
            ;;
        "configured")
            if [[ -n "$extra" ]]; then
                echo -e "${GREEN}✅ ${extra}${PLAIN}"
            else
                echo -e "${GREEN}✅ 已配置${PLAIN}"
            fi
            ;;
        "not_installed")
            echo -e "${GRAY}⬜ 未安装${PLAIN}"
            ;;
        *)
            echo -e "${GRAY}❓ 未知${PLAIN}"
            ;;
    esac
}

# --- 检查更新 ---
check_update() {
    local remote_version=""
    remote_version=$(curl -sL --max-time 3 --connect-timeout 2 "${REPO_URL}/onekey.sh" 2>/dev/null | grep -m1 -E '^VERSION="' | cut -d'"' -f2)
    
    if [[ -n "$remote_version" && "$remote_version" != "$VERSION" ]]; then
        echo "$remote_version"
    else
        echo ""
    fi
}

# --- 执行更新 ---
do_update() {
    echo -e "${CYAN}➜${PLAIN} 正在更新脚本..."
    
    local tmp_file="/tmp/onekey_update.sh"
    local cache_dir="$HOME/.onekey"
    local cache_script="$cache_dir/onekey.sh"
    
    if curl -fsSL -o "$tmp_file" "${REPO_URL}/onekey.sh" 2>/dev/null && [[ -s "$tmp_file" ]]; then
        chmod +x "$tmp_file"
        
        # 更新本地缓存
        mkdir -p "$cache_dir" 2>/dev/null
        cp -f "$tmp_file" "$cache_script"
        chmod +x "$cache_script"
        
        # 如果当前脚本是常规文件，也更新它
        if [[ -f "$0" && "$0" != "/dev/"* && "$0" != "/proc/"* ]]; then
            cp -f "$tmp_file" "$0" 2>/dev/null
        fi
        
        rm -f "$tmp_file"
        
        # 重新生成 wrapper 脚本
        create_shortcut
        
        echo -e "${GREEN}✔${PLAIN} 更新完成！请重新运行脚本。"
        exit 0
    else
        rm -f "$tmp_file" 2>/dev/null
        echo -e "${RED}✖${PLAIN} 更新失败，请检查网络。"
    fi
}

# --- 创建快捷命令 ---
create_shortcut() {
    # 策略: 生成一个独立的 wrapper 脚本到 /usr/bin/x
    # 不依赖 $0 (因为 bash <(curl ...) 时 $0 是 /dev/stdin，无法拷贝)
    # wrapper 脚本逻辑: 优先执行本地缓存，否则在线拉取
    local CACHE_DIR="$HOME/.onekey"
    local CACHE_SCRIPT="$CACHE_DIR/onekey.sh"
    
    mkdir -p "$CACHE_DIR" 2>/dev/null
    
    # 1. 缓存当前脚本到本地 (仅当来源有效时)
    #    判断 $0 是否为有效的常规文件
    if [[ -f "$0" && -s "$0" && "$0" != "/dev/"* && "$0" != "/proc/"* ]]; then
        cp -f "$0" "$CACHE_SCRIPT" 2>/dev/null
        chmod +x "$CACHE_SCRIPT" 2>/dev/null
    else
        # 来源无效 (bash <(curl ...) 等场景), 在线下载缓存
        curl -fsSL -o "$CACHE_SCRIPT" "${REPO_URL}/onekey.sh" 2>/dev/null
        chmod +x "$CACHE_SCRIPT" 2>/dev/null
    fi
    
    # 2. 生成 /usr/bin/x wrapper 脚本 (始终可用)
    cat > "$SHORTCUT_BIN" << 'WRAPPER_EOF'
#!/bin/bash
# OneKey 快捷入口 - 由 onekey.sh 自动生成
CACHE_SCRIPT="$HOME/.onekey/onekey.sh"
REPO_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main"

if [[ -f "$CACHE_SCRIPT" && -s "$CACHE_SCRIPT" ]]; then
    bash "$CACHE_SCRIPT" "$@"
else
    echo "本地缓存不存在，正在在线拉取..."
    mkdir -p "$HOME/.onekey" 2>/dev/null
    curl -fsSL -o "$CACHE_SCRIPT" "${REPO_URL}/onekey.sh" 2>/dev/null
    if [[ -f "$CACHE_SCRIPT" && -s "$CACHE_SCRIPT" ]]; then
        chmod +x "$CACHE_SCRIPT"
        bash "$CACHE_SCRIPT" "$@"
    else
        echo "拉取失败，尝试直接在线执行..."
        bash <(curl -fsSL "${REPO_URL}/onekey.sh") "$@"
    fi
fi
WRAPPER_EOF
    chmod +x "$SHORTCUT_BIN" 2>/dev/null
    
    # 3. 备份到 /usr/local/bin/x (PATH 兜底)
    cp -f "$SHORTCUT_BIN" "/usr/local/bin/x" 2>/dev/null
    chmod +x "/usr/local/bin/x" 2>/dev/null
    
    # 4. 清理旧的 alias 方式 (避免与脚本冲突)
    local bashrc="$HOME/.bashrc"
    if [[ -f "$bashrc" ]]; then
        sed -i '/^alias x=/d' "$bashrc" 2>/dev/null
    fi
    local profile="$HOME/.profile"
    if [[ -f "$profile" ]]; then
        sed -i '/^alias x=/d' "$profile" 2>/dev/null
    fi
    
    # 5. 确保 /usr/bin 在 PATH 中 (极少数精简系统可能缺失)
    if ! echo "$PATH" | grep -q "/usr/bin"; then
        export PATH="/usr/bin:$PATH"
        if [[ -f "$bashrc" ]]; then
            if ! grep -q 'export PATH=.*/usr/bin' "$bashrc"; then
                echo 'export PATH="/usr/bin:$PATH"' >> "$bashrc"
            fi
        fi
    fi
}

# --- 执行子脚本 ---
run_script() {
    local script_name=$1
    local script_url="${REPO_URL}/${script_name}"
    
    echo ""
    echo -e "${CYAN}➜${PLAIN} 正在加载 ${GREEN}${script_name}${PLAIN} ..."
    echo ""
    
    # 在线执行
    bash <(curl -fsSL "$script_url")
    
    echo ""
    read -p "按回车键返回主菜单..." 
}

# ============================================================
# 一键查看所有配置
# ============================================================

show_all_configs() {
    clear
    print_double_line
    echo -e "${BOLD}       📋 已安装服务配置汇总${PLAIN}"
    print_double_line
    echo ""
    
    local found=0
    
    # 遍历代理服务
    for key in 1 2 3 4 5 6 7; do
        IFS='|' read -r name desc service_name config_file port_field script_name <<< "${SERVICES[$key]}"
        
        local status_info=$(get_service_status "$service_name" "$config_file" "$port_field")
        local status=$(echo "$status_info" | cut -d'|' -f1)
        
        if [[ "$status" == "not_installed" ]]; then
            continue
        fi
        
        found=1
        print_line
        echo -e "${BOLD} 🔹 ${name} (${desc})${PLAIN}"
        print_line
        
        # 根据不同服务显示配置
        case "$service_name" in
            "xray")
                # VLESS 多节点支持
                if [[ -d "/etc/xray/nodes" ]]; then
                    for node_conf in /etc/xray/nodes/*.conf; do
                        if [[ -f "$node_conf" ]]; then
                             source "$node_conf"
                             local ipv4=$(curl -s4m5 https://api.ipify.org 2>/dev/null)
                             [[ -z "$ipv4" ]] && ipv4=$(curl -s4m5 https://ifconfig.me 2>/dev/null)
                             
                             echo -e " 节点:   ${GREEN}${TYPE}${PLAIN}"
                             echo -e " 版本:   ${GREEN}${NETWORK}${PLAIN}"
                             echo -e " 服务器: ${GREEN}${ipv4}${PLAIN}"
                             echo -e " 端口:   ${GREEN}${PORT}${PLAIN}"
                             echo -e " UUID:   ${GREEN}${UUID}${PLAIN}"
                             if [[ -n "$SNI" ]]; then
                                echo -e " SNI:    ${GREEN}${SNI}${PLAIN}"
                             fi
                             echo -e " ${CYAN}请进入 VLESS 菜单 (选项 6 -> 2) 查看完整分享链接${PLAIN}"
                             echo "---"
                        fi
                    done
                fi
                ;;
            "anytls")
                if [[ -f "$config_file" ]]; then
                    source "$config_file" 2>/dev/null
                    local ipv4=$(curl -s4m5 https://api.ipify.org 2>/dev/null)
                    [[ -z "$ipv4" ]] && ipv4=$(curl -s4m5 https://ifconfig.me 2>/dev/null)
                    echo -e " 服务器: ${GREEN}${ipv4}${PLAIN}"
                    echo -e " 端口:   ${GREEN}${PORT}${PLAIN}"
                    echo -e " 密码:   ${GREEN}${PASSWORD}${PLAIN}"
                    echo ""
                    echo -e " ${CYAN}链接:${PLAIN}"
                    echo -e " anytls://${PASSWORD}@${ipv4}:${PORT}?sni=www.bing.com&insecure=1#AnyTLS"
                fi
                ;;
            "tuic")
                if command -v jq &>/dev/null && [[ -f "$config_file" ]]; then
                    local ipv4=$(curl -s4m5 https://api.ipify.org 2>/dev/null)
                    [[ -z "$ipv4" ]] && ipv4=$(curl -s4m5 https://ifconfig.me 2>/dev/null)
                    
                    # 判断 v4 还是 v5
                    if jq -e '.server' "$config_file" &>/dev/null; then
                        # v5
                        local server_str=$(jq -r '.server' "$config_file")
                        local port=${server_str##*:}
                        local uuid=$(jq -r '.users | keys_unsorted[0]' "$config_file")
                        local password=$(jq -r --arg u "$uuid" '.users[$u]' "$config_file")
                        echo -e " 版本:   ${GREEN}v5${PLAIN}"
                        echo -e " 服务器: ${GREEN}${ipv4}${PLAIN}"
                        echo -e " 端口:   ${GREEN}${port}${PLAIN}"
                        echo -e " UUID:   ${GREEN}${uuid}${PLAIN}"
                        echo -e " 密码:   ${GREEN}${password}${PLAIN}"
                        echo ""
                        echo -e " ${CYAN}链接:${PLAIN}"
                        echo -e " tuic://${uuid}:${password}@${ipv4}:${port}?congestion_control=bbr&alpn=h3&sni=www.bing.com&udp_relay_mode=native&allow_insecure=1#TUIC-v5"
                    else
                        # v4
                        local port=$(jq -r '.port' "$config_file")
                        local token=$(jq -r '.token[0]' "$config_file")
                        echo -e " 版本:   ${GREEN}v4${PLAIN}"
                        echo -e " 服务器: ${GREEN}${ipv4}${PLAIN}"
                        echo -e " 端口:   ${GREEN}${port}${PLAIN}"
                        echo -e " Token:  ${GREEN}${token}${PLAIN}"
                    fi
                fi
                ;;
            "shadowsocks-rust")
                if command -v jq &>/dev/null && [[ -f "$config_file" ]]; then
                    local ipv4=$(curl -s4m5 https://api.ipify.org 2>/dev/null)
                    [[ -z "$ipv4" ]] && ipv4=$(curl -s4m5 https://ifconfig.me 2>/dev/null)
                    local port=$(jq -r '.servers[0].port' "$config_file")
                    local password=$(jq -r '.servers[0].password' "$config_file")
                    local method=$(jq -r '.servers[0].method' "$config_file")
                    echo -e " 服务器: ${GREEN}${ipv4}${PLAIN}"
                    echo -e " 端口:   ${GREEN}${port}${PLAIN}"
                    echo -e " 密码:   ${GREEN}${password}${PLAIN}"
                    echo -e " 加密:   ${GREEN}${method}${PLAIN}"
                    echo ""
                    echo -e " ${CYAN}链接:${PLAIN}"
                    local cred=$(echo -n "${method}:${password}" | base64 -w 0)
                    echo -e " ss://${cred}@${ipv4}:${port}#SS-Rust"
                fi
                ;;
            "hysteria-server")
                if [[ -f "$config_file" ]]; then
                    local ipv4=$(curl -s4m5 https://api.ipify.org 2>/dev/null)
                    [[ -z "$ipv4" ]] && ipv4=$(curl -s4m5 https://ifconfig.me 2>/dev/null)
                    local port=$(grep -E "^listen:" "$config_file" | sed 's/.*://' | tr -d ' ')
                    local password=$(grep -A5 "auth:" "$config_file" | grep "password:" | awk '{print $2}')
                    echo -e " 服务器: ${GREEN}${ipv4}${PLAIN}"
                    echo -e " 端口:   ${GREEN}${port}${PLAIN}"
                    echo -e " 密码:   ${GREEN}${password}${PLAIN}"
                    echo ""
                    echo -e " ${CYAN}链接:${PLAIN}"
                    echo -e " hysteria2://${password}@${ipv4}:${port}?alpn=h3&insecure=1#Hy2"
                fi
                ;;
            "mita")
                if command -v jq &>/dev/null && [[ -f "$config_file" ]]; then
                    local ipv4=$(curl -s4m5 https://api.ipify.org 2>/dev/null)
                    [[ -z "$ipv4" ]] && ipv4=$(curl -s4m5 https://ifconfig.me 2>/dev/null)
                    local port=$(jq -r '.portBindings[0].port // .portBindings[0].portRange' "$config_file")
                    local username=$(jq -r '.users[0].name' "$config_file")
                    local password=$(jq -r '.users[0].password' "$config_file")
                    echo -e " 服务器: ${GREEN}${ipv4}${PLAIN}"
                    echo -e " 端口:   ${GREEN}${port}${PLAIN}"
                    echo -e " 用户名: ${GREEN}${username}${PLAIN}"
                    echo -e " 密码:   ${GREEN}${password}${PLAIN}"
                fi
                ;;
            "sudoku-tunnel")
                local env_file="/etc/sudoku/env.conf"
                if [[ -f "$env_file" ]]; then
                    source "$env_file" 2>/dev/null
                    local ipv4=$(curl -s4m5 https://api.ipify.org 2>/dev/null)
                    [[ -z "$ipv4" ]] && ipv4=$(curl -s4m5 https://ifconfig.me 2>/dev/null)
                    echo -e " 服务器:     ${GREEN}${ipv4}${PLAIN}"
                    echo -e " 端口:       ${GREEN}${PORT}${PLAIN}"
                    echo -e " AEAD:       ${GREEN}${AEAD_METHOD}${PLAIN}"
                    echo -e " table-type: ${GREEN}${TABLE_TYPE}${PLAIN}"
                    echo -e " 自定义表:   ${GREEN}${CUSTOM_TABLE}${PLAIN}"
                    echo -e " 客户端Key:  ${GREEN}${CLIENT_PRIVATE_KEY:0:32}...${PLAIN}"
                    echo ""
                    echo -e " ${CYAN}请进入 Sudoku 菜单 (选项 7 -> 2) 查看完整配置和链接${PLAIN}"
                fi
                ;;
        esac
        echo ""
    done
    
    if [[ $found -eq 0 ]]; then
        echo -e "${YELLOW}⚠️  暂无已安装的代理服务${PLAIN}"
        echo ""
    fi
    
    print_double_line
    read -p "按回车键返回主菜单..."
}

# ============================================================
# 卸载菜单
# ============================================================

show_uninstall_menu() {
    clear
    print_double_line
    echo -e "${BOLD}       🗑️  卸载服务${PLAIN}"
    print_double_line
    echo ""
    
    echo -e " ${RED}⚠️  警告: 卸载将删除服务及其配置文件${PLAIN}"
    echo ""
    print_line
    
    # 显示已安装的服务
    local installed=()
    local idx=1
    
    for key in 1 2 3 4 5 6 7; do
        IFS='|' read -r name desc service_name config_file port_field script_name <<< "${SERVICES[$key]}"
        local is_installed=0
        if [[ -f "$config_file" ]]; then
            is_installed=1
        elif [[ "$service_name" == "xray" ]]; then
            # VLESS 多节点目录检测
            if [[ -d "/etc/xray/nodes" ]] && ls /etc/xray/nodes/*.conf &>/dev/null; then
                is_installed=1
            elif [[ -f "/opt/xray/xray" || -f "/usr/local/bin/xray" ]]; then
                is_installed=1
            fi
        fi
        # 兜底: 检查二进制或 systemd unit
        if [[ $is_installed -eq 0 ]]; then
            if [[ -f "/etc/systemd/system/${service_name}.service" ]] || \
               [[ -f "/usr/lib/systemd/system/${service_name}.service" ]]; then
                is_installed=1
            fi
        fi
        if [[ $is_installed -eq 1 ]]; then
            installed+=("$key")
            echo -e "  ${RED}${idx}.${PLAIN} 卸载 ${name} (${desc})"
            ((idx++))
        fi
    done
    
    for key in 8 9 10 11; do
        IFS='|' read -r name desc service_name config_file script_name <<< "${TOOLS[$key]}"
        if [[ -f "$config_file" ]]; then
            installed+=("$key")
            echo -e "  ${RED}${idx}.${PLAIN} 卸载 ${name} (${desc})"
            ((idx++))
        fi
    done
    
    if [[ ${#installed[@]} -eq 0 ]]; then
        echo -e "  ${GRAY}暂无已安装的服务${PLAIN}"
        echo ""
        print_line
        read -p "按回车键返回主菜单..."
        return
    fi
    
    echo ""
    echo -e "  ${GRAY}0.${PLAIN} 返回主菜单"
    print_line
    echo ""
    
    read -p "请选择要卸载的服务 [0-${#installed[@]}]: " choice
    
    if [[ "$choice" == "0" || -z "$choice" ]]; then
        return
    fi
    
    if [[ "$choice" -ge 1 && "$choice" -le ${#installed[@]} ]]; then
        local target_key=${installed[$((choice-1))]}
        
        # 获取服务信息
        if [[ "$target_key" -le 7 ]]; then
            IFS='|' read -r name desc service_name config_file port_field script_name <<< "${SERVICES[$target_key]}"
        else
            IFS='|' read -r name desc service_name config_file script_name <<< "${TOOLS[$target_key]}"
        fi
        
        echo ""
        read -p "确认卸载 ${name}? (y/N): " confirm
        
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            echo -e "${CYAN}➜${PLAIN} 正在卸载 ${name}..."
            
            # 调用对应脚本的卸载功能
            # 大多数脚本运行后选择卸载选项
            run_script "$script_name"
        fi
    fi
}

# ============================================================
# 主菜单
# ============================================================

show_menu() {
    # 检查更新 (静默)
    local new_version=$(check_update)
    
    clear
    print_double_line
    echo -e "${BOLD}        🚀 OpenClash 代理一键管理脚本 v${VERSION}${PLAIN}"
    echo -e "${GRAY}           github.com/10000ge10000/own-rules${PLAIN}"
    print_double_line
    echo ""
    
    # === 代理协议 ===
    echo -e " ${BOLD}📡 代理协议${PLAIN}"
    print_line
    
    # 使用固定格式字符串确保对齐 (手动处理中文宽度)
    local services_display=(
        "1|AnyTLS    |隐匿传输  "
        "2|TUIC      |QUIC高速  "
        "3|SS-2022   |Rust高性能"
        "4|Hysteria2 |暴力加速  "
        "5|Mieru     |流量混淆  "
        "6|VLESS     |全能协议  "
        "7|Sudoku    |数独隐写  "
    )
    
    for item in "${services_display[@]}"; do
        local key=$(echo "$item" | cut -d'|' -f1)
        local name_fmt=$(echo "$item" | cut -d'|' -f2)
        local desc_fmt=$(echo "$item" | cut -d'|' -f3)
        
        IFS='|' read -r name desc service_name config_file port_field script_name <<< "${SERVICES[$key]}"
        local status_info=$(get_service_status "$service_name" "$config_file" "$port_field")
        local status=$(echo "$status_info" | cut -d'|' -f1)
        local extra=$(echo "$status_info" | cut -d'|' -f2)
        local status_display=$(format_status "$status" "$extra")
        
        echo -e "  ${GREEN}${key}.${PLAIN} ${name_fmt} ${GRAY}(${desc_fmt})${PLAIN} ${status_display}"
    done
    
    echo ""
    
    # === 实用工具 ===
    echo -e " ${BOLD}🔧 实用工具${PLAIN}"
    print_line
    
    local tools_display=(
        "8|IPF      |端口转发  "
        "9|DNS监控  |智能优选  "
        "10|DNS修复  |永久锁定  "
        "11|Alice分流|家宽路由  "
    )
    
    for item in "${tools_display[@]}"; do
        local key=$(echo "$item" | cut -d'|' -f1)
        local name_fmt=$(echo "$item" | cut -d'|' -f2)
        local desc_fmt=$(echo "$item" | cut -d'|' -f3)
        
        IFS='|' read -r name desc service_name config_file script_name <<< "${TOOLS[$key]}"
        local status_info=$(get_service_status "$service_name" "$config_file" "")
        local status=$(echo "$status_info" | cut -d'|' -f1)
        local extra=$(echo "$status_info" | cut -d'|' -f2)
        local status_display=$(format_status "$status" "$extra")
        
        echo -e "  ${GREEN}${key}.${PLAIN} ${name_fmt} ${GRAY}(${desc_fmt})${PLAIN} ${status_display}"
    done
    
    echo ""
    
    # === 系统功能 ===
    echo -e " ${BOLD}⚙️  系统功能${PLAIN}"
    print_line
    echo -e "  ${GREEN}12.${PLAIN} 📋 一键查看所有配置/链接"
    echo -e "  ${RED}13.${PLAIN} 🗑️  卸载服务"
    echo ""
    echo -e "  ${GRAY}0.${PLAIN}  退出脚本"
    
    print_double_line
    
    # 更新提示
    if [[ -n "$new_version" ]]; then
        echo -e " ${YELLOW}💡 发现新版本 v${new_version}，输入 'u' 更新脚本${PLAIN}"
        print_line
    fi
    
    echo ""
    read -p " 请输入选项 [0-13]: " choice
    
    case "$choice" in
        1) run_script "anytls.sh" ;;
        2) run_script "tuic.sh" ;;
        3) run_script "ss2022.sh" ;;
        4) run_script "hy2.sh" ;;
        5) run_script "mieru.sh" ;;
        6) run_script "vless.sh" ;;
        7) run_script "sudoku.sh" ;;
        8) run_script "ipf.sh" ;;
        9) run_script "dns_monitor_install.sh" ;;
        10) run_script "setup_dns.sh" ;;
        11) run_script "socks_route.sh" ;;
        12) show_all_configs ;;
        13) show_uninstall_menu ;;
        0) 
            echo ""
            echo -e "${GREEN}感谢使用，再见！${PLAIN}"
            exit 0 
            ;;
        u|U)
            if [[ -n "$new_version" ]]; then
                do_update
            else
                echo -e "${YELLOW}当前已是最新版本${PLAIN}"
                sleep 1
            fi
            ;;
        *)
            echo -e "${RED}无效选项${PLAIN}"
            sleep 1
            ;;
    esac
}

# ============================================================
# 主入口
# ============================================================

main() {
    # 检查 root
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}✖ 请使用 root 权限运行此脚本${PLAIN}"
        exit 1
    fi
    
    # 创建快捷命令
    create_shortcut
    
    # 主循环
    while true; do
        show_menu
    done
}

main "$@"
