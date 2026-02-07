#!/bin/bash

# ====================================================
# Sudoku (ASCII) 一键安装管理脚本
# 基于数独隐写的流量混淆代理协议
# 项目: github.com/SUDOKU-ASCII/sudoku
# OpenClash: wiki.metacubex.one/config/proxies/sudoku/
# ====================================================

# --- 全局配置 ---
REPO="SUDOKU-ASCII/sudoku"
SCRIPT_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main/sudoku.sh"
INSTALL_DIR="/opt/sudoku"
CONFIG_DIR="/etc/sudoku"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_FILE="${INSTALL_DIR}/sudoku"
VERSION_FILE="${INSTALL_DIR}/version"
SERVICE_FILE="/etc/systemd/system/sudoku-tunnel.service"
SHORTCUT_BIN="/usr/bin/sudoku"
GAI_CONF="/etc/gai.conf"
ENV_FILE="${CONFIG_DIR}/env.conf"

# --- 引入公共函数 ---
if [[ -f "common.sh" ]]; then
    source "common.sh"
else
    source <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/common.sh)
fi

# --- 系统服务检测 ---
check_sys_init() {
    # 必须确认 systemd 真正作为 PID 1 运行，而非仅安装了 systemd 二进制
    if [[ -d "/run/systemd/system" ]]; then
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

# --- 安装依赖 ---
install_deps() {
    print_info "安装 Sudoku 组件依赖..."
    if [[ "${RELEASE}" == "centos" ]]; then
        yum install -y curl tar jq net-tools iptables >/dev/null 2>&1
    elif [[ "${RELEASE}" == "alpine" ]]; then
        apk add curl tar jq net-tools iptables >/dev/null 2>&1
    else
        apt-get update >/dev/null 2>&1
        apt-get install -y curl tar jq net-tools iptables >/dev/null 2>&1
    fi
    print_ok "依赖安装完成"
}

# --- 安装核心 ---
install_core() {
    print_info "正在获取 Sudoku 最新版本..."

    local latest_json
    latest_json=$(curl -sL --max-time 10 -H "User-Agent: Mozilla/5.0" \
        "https://api.github.com/repos/$REPO/releases/latest")

    if [[ -z "$latest_json" ]] || echo "$latest_json" | grep -q "API rate limit"; then
        print_err "GitHub API 受限，请稍后重试。"
        exit 1
    fi

    local tag_version
    tag_version=$(echo "$latest_json" | jq -r '.tag_name' 2>/dev/null)
    if [[ -z "$tag_version" || "$tag_version" == "null" ]]; then
        print_err "获取版本号失败"
        exit 1
    fi
    print_info "最新版本: ${GREEN}${tag_version}${PLAIN}"

    # 架构检测
    local arch=$(uname -m)
    local dl_arch=""
    case "$arch" in
        x86_64|amd64) dl_arch="amd64" ;;
        aarch64|arm64) dl_arch="arm64" ;;
        *) print_err "不支持的架构: $arch"; exit 1 ;;
    esac

    # 下载
    local download_url="https://github.com/$REPO/releases/download/${tag_version}/sudoku-linux-${dl_arch}.tar.gz"
    local tmp_file="/tmp/sudoku-linux.tar.gz"
    local tmp_dir="/tmp/sudoku-extract"

    print_info "下载中: $download_url"
    curl -fSL --progress-bar -o "$tmp_file" "$download_url"
    if [[ ! -s "$tmp_file" ]]; then
        print_err "下载失败！"
        exit 1
    fi

    # 解压
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    tar xzf "$tmp_file" -C "$tmp_dir"

    # 查找二进制
    local found_bin
    found_bin=$(find "$tmp_dir" -type f -name "sudoku" | head -n 1)
    # 如果没找到名为 sudoku 的，找 sudoku-tunnel
    if [[ -z "$found_bin" ]]; then
        found_bin=$(find "$tmp_dir" -type f -name "sudoku-tunnel" | head -n 1)
    fi
    # 还没找到就找任何可执行文件
    if [[ -z "$found_bin" ]]; then
        found_bin=$(find "$tmp_dir" -type f -executable | head -n 1)
    fi

    if [[ -z "$found_bin" ]]; then
        print_err "安装包异常，未找到可执行文件！"
        rm -rf "$tmp_file" "$tmp_dir"
        exit 1
    fi

    # 停止旧服务
    service_stop sudoku-tunnel 2>/dev/null

    mkdir -p "$INSTALL_DIR"
    cp -f "$found_bin" "$BIN_FILE"
    chmod +x "$BIN_FILE"
    echo "$tag_version" > "$VERSION_FILE"

    rm -rf "$tmp_file" "$tmp_dir"
    print_ok "Sudoku 核心安装完成 ($tag_version)"
}

# --- 系统优化 ---
optimize_sysctl() {
    print_info "优化内核参数 (开启 BBR)..."

    cat > /etc/sysctl.d/99-sudoku.conf <<EOF
# --- Sudoku Optimization ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 16384 8388608
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 4096
# ---------------------------
EOF

    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null

    sysctl -p /etc/sysctl.d/99-sudoku.conf >/dev/null 2>&1
    sysctl --system >/dev/null 2>&1
    print_ok "网络优化已应用"
}

# --- 端口检测 ---
check_port_available() {
    local port=$1
    if command -v ss &>/dev/null; then
        if ss -tunlp 2>/dev/null | grep -q ":${port} "; then return 1; fi
    elif command -v netstat &>/dev/null; then
        if netstat -tunlp 2>/dev/null | grep -q ":${port} "; then return 1; fi
    fi
    return 0
}

# --- 生成密钥对 ---
generate_keypair() {
    print_info "生成 ED25519 密钥对..."
    local keygen_output
    keygen_output=$("$BIN_FILE" -keygen 2>&1)

    # 提取密钥
    MASTER_PUBLIC_KEY=$(echo "$keygen_output" | grep -i "Master Public Key" | awk '{print $NF}')
    MASTER_PRIVATE_KEY=$(echo "$keygen_output" | grep -i "Master Private Key" | awk '{print $NF}')
    CLIENT_PRIVATE_KEY=$(echo "$keygen_output" | grep -i "Available Private Key" | awk '{print $NF}')

    if [[ -z "$MASTER_PUBLIC_KEY" || -z "$CLIENT_PRIVATE_KEY" ]]; then
        print_err "密钥生成失败！完整输出:"
        echo "$keygen_output"
        return 1
    fi

    print_ok "密钥对生成成功"
    return 0
}

# --- 交互配置 ---
configure_sudoku() {
    clear
    print_line
    echo -e " ${BOLD}🧩 Sudoku (ASCII) 配置向导${PLAIN}"
    print_line
    echo ""

    # ============================================================
    # 0. 教育用户：为什么这么设置
    # ============================================================
    echo -e "${BLUE}═══════════════════════════════════════════════════════${PLAIN}"
    echo -e " ${BOLD}📖 Sudoku 协议说明 & 最佳实践${PLAIN}"
    echo -e "${BLUE}───────────────────────────────────────────────────────${PLAIN}"
    echo -e " Sudoku 是基于 4x4 数独隐写的代理协议，核心优势："
    echo -e "   • ${GREEN}数独隐写${PLAIN}: 流量映射为ASCII/低熵字节，规避 DPI 检测"
    echo -e "   • ${GREEN}防御性回落${PLAIN}: 非法探测自动转发到诱饵站点"
    echo -e "   • ${GREEN}AEAD 加密${PLAIN}: ChaCha20-Poly1305 保证数据安全"
    echo -e "   • ${GREEN}HTTP 伪装${PLAIN}: 可选 HTTPMask 过 CDN (如 Cloudflare)"
    echo ""
    echo -e " ${YELLOW}推荐配置 (本脚本默认值):${PLAIN}"
    echo -e "   • AEAD: ${CYAN}chacha20-poly1305${PLAIN} (强制推荐, 性能安全兼顾)"
    echo -e "   • table-type: ${CYAN}prefer_entropy${PLAIN} (低熵模式, 汉明重量≈3.0)"
    echo -e "   • enable-pure-downlink: ${CYAN}false${PLAIN} (带宽优化下行, 效率≈80%)"
    echo -e "   • padding: ${CYAN}2-7${PLAIN} (概率填充, 隐藏协议特征)"
    echo -e "   • custom_table: ${CYAN}xpxvvpvv${PLAIN} (自定义字节布局, 增加多样性)"
    echo -e "   • http-mask: ${CYAN}开启 (legacy)${PLAIN} (HTTP伪装, 更难被识别)"
    echo -e "   • suspicious_action: ${CYAN}fallback${PLAIN} (回落到诱饵, 抗主动探测)"
    echo ""
    echo -e " ${YELLOW}为什么是最优?${PLAIN}"
    echo -e "   1. prefer_entropy 使数据熵值低于 GFW 阻断阈值 (3.4~4.6)"
    echo -e "   2. 关闭 pure_downlink 在 AEAD 保护下极大提升下行速度"
    echo -e "   3. custom_table 让每个用户的字节特征都不同，审查更难"
    echo -e "   4. HTTPMask 让流量看起来像正常 HTTP, 过 CDN/反代"
    echo -e "${BLUE}═══════════════════════════════════════════════════════${PLAIN}"
    echo ""

    # ============================================================
    # 1. 端口
    # ============================================================
    while true; do
        read -p "$(echo -e "${CYAN}::${PLAIN} 监听端口 [默认 9530]: ")" PORT
        [[ -z "$PORT" ]] && PORT=9530
        if check_port_available "$PORT"; then
            echo -e "   ➜ 使用端口: ${GREEN}$PORT${PLAIN}"
            break
        else
            print_err "端口 $PORT 被占用，请换一个"
        fi
    done

    # ============================================================
    # 2. 密钥生成
    # ============================================================
    echo ""
    echo -e "${CYAN}::${PLAIN} 密钥配置"
    echo -e "   Sudoku 使用 ED25519 密钥对:"
    echo -e "   • 服务端填 ${GREEN}Master Public Key${PLAIN} (32字节)"
    echo -e "   • 客户端填 ${GREEN}Available Private Key${PLAIN} (64字节)"
    echo ""

    generate_keypair
    if [[ $? -ne 0 ]]; then
        print_err "密钥生成失败，无法继续"
        return 1
    fi

    echo -e "   ${YELLOW}Master Public Key (服务端):${PLAIN}"
    echo -e "   ${GREEN}${MASTER_PUBLIC_KEY}${PLAIN}"
    echo -e "   ${YELLOW}Client Private Key (客户端):${PLAIN}"
    echo -e "   ${GREEN}${CLIENT_PRIVATE_KEY}${PLAIN}"
    echo ""

    # ============================================================
    # 3. AEAD 加密方式
    # ============================================================
    echo -e "${CYAN}::${PLAIN} AEAD 加密方式"
    echo -e "   1. ${GREEN}chacha20-poly1305${PLAIN} ${YELLOW}(推荐: ARM 友好, 高安全)${PLAIN}"
    echo -e "   2. aes-128-gcm (x86 AES-NI 高性能)"
    echo -e "   3. none (仅测试, 不推荐)"
    read -p "   请选择 [1-3] (默认 1): " AEAD_CHOICE
    case "$AEAD_CHOICE" in
        2) AEAD_METHOD="aes-128-gcm" ;;
        3) AEAD_METHOD="none" ;;
        *) AEAD_METHOD="chacha20-poly1305" ;;
    esac
    echo -e "   ➜ AEAD: ${GREEN}${AEAD_METHOD}${PLAIN}"

    # ============================================================
    # 4. table-type (映射风格)
    # ============================================================
    echo ""
    echo -e "${CYAN}::${PLAIN} 映射风格 (table-type)"
    echo -e "   1. ${GREEN}prefer_entropy${PLAIN} ${YELLOW}(推荐: 低熵, 汉明重量≈3.0, 低于封锁阈值)${PLAIN}"
    echo -e "   2. prefer_ascii (全ASCII, 明文特征, 汉明重量≈4.0)"
    read -p "   请选择 [1-2] (默认 1): " TABLE_CHOICE
    case "$TABLE_CHOICE" in
        2) TABLE_TYPE="prefer_ascii" ;;
        *) TABLE_TYPE="prefer_entropy" ;;
    esac
    echo -e "   ➜ table-type: ${GREEN}${TABLE_TYPE}${PLAIN}"

    # ============================================================
    # 5. Custom table
    # ============================================================
    echo ""
    echo -e "${CYAN}::${PLAIN} 自定义字节布局 (custom_table)"
    echo -e "   格式: 8个字符, 必须包含 2个x + 2个p + 4个v"
    echo -e "   共 420 种排列, 每个用户不同可增加审查难度"
    read -p "   请输入 [默认 xpxvvpvv]: " CUSTOM_TABLE
    [[ -z "$CUSTOM_TABLE" ]] && CUSTOM_TABLE="xpxvvpvv"
    echo -e "   ➜ custom_table: ${GREEN}${CUSTOM_TABLE}${PLAIN}"

    # ============================================================
    # 6. Padding
    # ============================================================
    echo ""
    echo -e "${CYAN}::${PLAIN} 填充参数 (padding)"
    echo -e "   随机填充非数据字节, 范围 0-100 (概率百分比)"
    read -p "   padding_min [默认 2]: " PADDING_MIN
    [[ -z "$PADDING_MIN" ]] && PADDING_MIN=2
    read -p "   padding_max [默认 7]: " PADDING_MAX
    [[ -z "$PADDING_MAX" ]] && PADDING_MAX=7
    echo -e "   ➜ padding: ${GREEN}${PADDING_MIN}-${PADDING_MAX}${PLAIN}"

    # ============================================================
    # 7. 下行模式
    # ============================================================
    echo ""
    echo -e "${CYAN}::${PLAIN} 下行模式 (enable_pure_downlink)"
    echo -e "   1. ${GREEN}false (带宽优化)${PLAIN} ${YELLOW}(推荐: 下行效率≈80%, 需 AEAD≠none)${PLAIN}"
    echo -e "   2. true (纯数独编码, 上下行一致)"
    read -p "   请选择 [1-2] (默认 1): " DOWNLINK_CHOICE
    case "$DOWNLINK_CHOICE" in
        2) ENABLE_PURE_DOWNLINK=true ;;
        *) ENABLE_PURE_DOWNLINK=false ;;
    esac
    # 校验: 带宽优化模式必须有 AEAD
    if [[ "$ENABLE_PURE_DOWNLINK" == "false" && "$AEAD_METHOD" == "none" ]]; then
        print_warn "带宽优化下行要求 AEAD≠none, 已自动切换为纯数独下行"
        ENABLE_PURE_DOWNLINK=true
    fi
    echo -e "   ➜ enable_pure_downlink: ${GREEN}${ENABLE_PURE_DOWNLINK}${PLAIN}"

    # ============================================================
    # 8. Fallback (回落地址)
    # ============================================================
    echo ""
    echo -e "${CYAN}::${PLAIN} 回落地址 (fallback)"
    echo -e "   当检测到非法探测时, 将连接转发到此地址"
    echo -e "   建议: 指向本地 Nginx/Apache 诱饵站, 或留默认"
    read -p "   回落地址 [默认 127.0.0.1:80]: " FALLBACK_ADDR
    [[ -z "$FALLBACK_ADDR" ]] && FALLBACK_ADDR="127.0.0.1:80"
    echo -e "   ➜ fallback: ${GREEN}${FALLBACK_ADDR}${PLAIN}"

    # ============================================================
    # 9. HTTPMask
    # ============================================================
    echo ""
    echo -e "${CYAN}::${PLAIN} HTTP 伪装 (HTTPMask)"
    echo -e "   1. ${GREEN}开启 (legacy 模式)${PLAIN} ${YELLOW}(推荐: 直连场景)${PLAIN}"
    echo -e "   2. 开启 (auto 模式) - 可过 CDN/反代"
    echo -e "   3. 关闭"
    read -p "   请选择 [1-3] (默认 1): " HTTPMASK_CHOICE
    case "$HTTPMASK_CHOICE" in
        2)
            HTTPMASK_DISABLE=false
            HTTPMASK_MODE="auto"
            ;;
        3)
            HTTPMASK_DISABLE=true
            HTTPMASK_MODE="legacy"
            ;;
        *)
            HTTPMASK_DISABLE=false
            HTTPMASK_MODE="legacy"
            ;;
    esac
    echo -e "   ➜ http-mask: ${GREEN}$([ "$HTTPMASK_DISABLE" == "true" ] && echo "关闭" || echo "开启 ($HTTPMASK_MODE)")${PLAIN}"

    # HTTPMask 扩展选项 (仅在 auto/stream/poll 模式下)
    HTTPMASK_TLS=false
    HTTPMASK_HOST=""
    HTTPMASK_PATH_ROOT=""
    HTTPMASK_MULTIPLEX="off"

    if [[ "$HTTPMASK_MODE" != "legacy" && "$HTTPMASK_DISABLE" != "true" ]]; then
        echo ""
        echo -e "   ${CYAN}HTTPMask 高级选项:${PLAIN}"
        read -p "   启用 HTTPS (TLS)? [y/N]: " tls_choice
        [[ "$tls_choice" == "y" || "$tls_choice" == "Y" ]] && HTTPMASK_TLS=true

        read -p "   Host/SNI 覆盖 (留空不设): " HTTPMASK_HOST
        read -p "   路径前缀 path_root (留空不设): " HTTPMASK_PATH_ROOT

        echo -e "   多路复用 (multiplex):"
        echo -e "   1. off (默认)"
        echo -e "   2. auto (复用连接, 减少 RTT)"
        echo -e "   3. on (单隧道多目标)"
        read -p "   请选择 [1-3] (默认 1): " mux_choice
        case "$mux_choice" in
            2) HTTPMASK_MULTIPLEX="auto" ;;
            3) HTTPMASK_MULTIPLEX="on" ;;
            *) HTTPMASK_MULTIPLEX="off" ;;
        esac
    fi

    # ============================================================
    # 10. IP 策略
    # ============================================================
    echo ""
    echo -e "${CYAN}::${PLAIN} 出站 IP 策略"
    echo -e "   1. ${GREEN}IPv4 优先${PLAIN} (推荐, 兼容性好)"
    echo -e "   2. IPv6 优先 (系统默认)"
    read -p "   请选择 [1-2] (默认 1): " IP_CHOICE
    [[ -z "$IP_CHOICE" ]] && IP_CHOICE=1
    apply_ip_preference "$IP_CHOICE"

    # ============================================================
    # 生成服务端配置文件
    # ============================================================
    print_info "生成配置文件..."
    mkdir -p "$CONFIG_DIR"

    # 构建 httpmask JSON
    local httpmask_json
    if [[ "$HTTPMASK_DISABLE" == "true" ]]; then
        httpmask_json='{
        "disable": true
    }'
    else
        httpmask_json=$(cat <<HMEOF
{
        "disable": false,
        "mode": "${HTTPMASK_MODE}",
        "tls": ${HTTPMASK_TLS},
        "host": "${HTTPMASK_HOST}",
        "path_root": "${HTTPMASK_PATH_ROOT}",
        "multiplex": "${HTTPMASK_MULTIPLEX}"
    }
HMEOF
        )
    fi

    cat > "$CONFIG_FILE" <<EOF
{
    "mode": "server",
    "local_port": ${PORT},
    "server_address": "",
    "fallback_address": "${FALLBACK_ADDR}",
    "key": "${MASTER_PUBLIC_KEY}",
    "aead": "${AEAD_METHOD}",
    "suspicious_action": "fallback",
    "ascii": "${TABLE_TYPE}",
    "padding_min": ${PADDING_MIN},
    "padding_max": ${PADDING_MAX},
    "custom_table": "${CUSTOM_TABLE}",
    "enable_pure_downlink": ${ENABLE_PURE_DOWNLINK},
    "httpmask": ${httpmask_json}
}
EOF
    chmod 600 "$CONFIG_FILE"

    # 保存环境变量 (供展示和 onekey 使用)
    cat > "$ENV_FILE" <<EOF
PORT="${PORT}"
MASTER_PUBLIC_KEY="${MASTER_PUBLIC_KEY}"
MASTER_PRIVATE_KEY="${MASTER_PRIVATE_KEY}"
CLIENT_PRIVATE_KEY="${CLIENT_PRIVATE_KEY}"
AEAD_METHOD="${AEAD_METHOD}"
TABLE_TYPE="${TABLE_TYPE}"
CUSTOM_TABLE="${CUSTOM_TABLE}"
PADDING_MIN="${PADDING_MIN}"
PADDING_MAX="${PADDING_MAX}"
ENABLE_PURE_DOWNLINK="${ENABLE_PURE_DOWNLINK}"
FALLBACK_ADDR="${FALLBACK_ADDR}"
HTTPMASK_DISABLE="${HTTPMASK_DISABLE}"
HTTPMASK_MODE="${HTTPMASK_MODE}"
HTTPMASK_TLS="${HTTPMASK_TLS}"
HTTPMASK_HOST="${HTTPMASK_HOST}"
HTTPMASK_PATH_ROOT="${HTTPMASK_PATH_ROOT}"
HTTPMASK_MULTIPLEX="${HTTPMASK_MULTIPLEX}"
EOF
    chmod 600 "$ENV_FILE"

    print_ok "配置文件生成完毕！"
}

# --- 设置 Systemd 服务 ---
setup_service() {
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sudoku Tunnel Server
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
Nice=-10
CPUSchedulingPolicy=batch
ExecStart=${BIN_FILE} -c ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1000000
LimitNPROC=10000

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sudoku-tunnel >/dev/null 2>&1
        systemctl restart sudoku-tunnel

        sleep 2
        if systemctl is-active --quiet sudoku-tunnel; then
            print_ok "Systemd 服务已启动"
            return 0
        else
            print_err "服务启动失败！日志如下:"
            journalctl -u sudoku-tunnel -n 20 --no-pager
            return 1
        fi
    else
        print_warn "检测到非 Systemd 环境，正在后台启动..."
        killall sudoku >/dev/null 2>&1
        nohup "$BIN_FILE" -c "$CONFIG_FILE" >/var/log/sudoku.log 2>&1 &
        sleep 2
        if pgrep -f "$BIN_FILE" > /dev/null 2>&1; then
            print_ok "后台服务已启动 (日志: /var/log/sudoku.log)"
            return 0
        else
            print_err "启动失败！"
            return 1
        fi
    fi
}

# --- 防火墙 ---
apply_firewall() {
    if [[ ! -f "$ENV_FILE" ]]; then return; fi
    source "$ENV_FILE" 2>/dev/null
    [[ -z "$PORT" ]] && return

    print_info "配置防火墙 (端口: $PORT)..."
    apply_firewall_rule "$PORT" "tcp"
    print_ok "防火墙规则已应用"
}

# --- 快捷命令 ---
create_shortcut() {
    if [[ -f "$0" ]]; then cp -f "$0" "$SHORTCUT_BIN"; else curl -fsSL -o "$SHORTCUT_BIN" "$SCRIPT_URL"; fi
    chmod +x "$SHORTCUT_BIN"
    cp -f "$SHORTCUT_BIN" "/usr/local/bin/sudoku" 2>/dev/null
    chmod +x "/usr/local/bin/sudoku" 2>/dev/null
    print_ok "快捷指令: sudoku"
}

# --- 展示配置信息 ---
show_info() {
    if [[ ! -f "$ENV_FILE" ]]; then
        print_err "未安装或配置丢失"
        return
    fi
    source "$ENV_FILE"

    local ipv4
    ipv4=$(curl -s4m8 https://api.ipify.org 2>/dev/null)
    [[ -z "$ipv4" ]] && ipv4=$(curl -s4m8 https://ifconfig.me 2>/dev/null)
    [[ -z "$ipv4" ]] && ipv4="无法获取IPv4"

    # 构建 sudoku:// 短链接 (使用服务端内置功能)
    local share_link=""
    if [[ -f "$BIN_FILE" && -f "$CONFIG_FILE" ]]; then
        local link_output
        link_output=$("$BIN_FILE" -c "$CONFIG_FILE" -export-link -public-host "${ipv4}:${PORT}" 2>/dev/null)
        # 输出格式: "Short link: sudoku://..."
        share_link=$(echo "$link_output" | grep -o 'sudoku://[^ ]*')
    fi

    clear
    print_line
    echo -e "       ${BOLD}🧩 Sudoku (ASCII) 配置详情${PLAIN}"
    print_line
    echo ""

    echo -e " ${BOLD}📡 服务端信息${PLAIN}"
    echo -e " ─────────────────────────────────────────────"
    echo -e " 服务器:     ${GREEN}${ipv4}${PLAIN}"
    echo -e " 端口:       ${GREEN}${PORT}${PLAIN}"
    echo -e " AEAD:       ${GREEN}${AEAD_METHOD}${PLAIN}"
    echo -e " table-type: ${GREEN}${TABLE_TYPE}${PLAIN}"
    echo -e " 自定义表:   ${GREEN}${CUSTOM_TABLE}${PLAIN}"
    echo -e " 填充:       ${GREEN}${PADDING_MIN}-${PADDING_MAX}${PLAIN}"
    echo -e " 纯下行:     ${GREEN}${ENABLE_PURE_DOWNLINK}${PLAIN}"
    echo -e " 回落:       ${GREEN}${FALLBACK_ADDR}${PLAIN}"
    echo -e " HTTPMask:   ${GREEN}$([ "$HTTPMASK_DISABLE" == "true" ] && echo "关闭" || echo "开启 ($HTTPMASK_MODE)")${PLAIN}"
    echo ""

    echo -e " ${BOLD}🔑 密钥信息${PLAIN}"
    echo -e " ─────────────────────────────────────────────"
    echo -e " ${YELLOW}服务端 Key (Master Public Key):${PLAIN}"
    echo -e " ${CYAN}${MASTER_PUBLIC_KEY}${PLAIN}"
    echo ""
    echo -e " ${YELLOW}客户端 Key (Available Private Key):${PLAIN}"
    echo -e " ${CYAN}${CLIENT_PRIVATE_KEY}${PLAIN}"
    echo ""

    # 分享链接
    if [[ -n "$share_link" && "$share_link" == sudoku://* ]]; then
        echo -e " ${BOLD}🔗 分享链接${PLAIN}"
        echo -e " ─────────────────────────────────────────────"
        echo -e " ${CYAN}${share_link}${PLAIN}"
        echo ""
    fi

    # OpenClash YAML 配置
    echo -e " ${BOLD}📋 OpenClash 配置 (YAML) - 完全匹配 Mihomo 内核${PLAIN}"
    echo -e " ─────────────────────────────────────────────"
    echo -e "${GREEN}"

    # 基础配置
    local yaml_text="  - name: \"Sudoku\"\n"
    yaml_text+="    type: sudoku\n"
    yaml_text+="    server: \"${ipv4}\"\n"
    yaml_text+="    port: ${PORT}\n"
    yaml_text+="    key: \"${CLIENT_PRIVATE_KEY}\"\n"
    yaml_text+="    aead-method: ${AEAD_METHOD}\n"
    yaml_text+="    padding-min: ${PADDING_MIN}\n"
    yaml_text+="    padding-max: ${PADDING_MAX}\n"
    yaml_text+="    table-type: ${TABLE_TYPE}\n"

    # custom-table
    if [[ -n "$CUSTOM_TABLE" ]]; then
        yaml_text+="    custom-table: ${CUSTOM_TABLE}\n"
    fi

    # http-mask
    if [[ "$HTTPMASK_DISABLE" != "true" ]]; then
        yaml_text+="    http-mask: true\n"
        if [[ "$HTTPMASK_MODE" != "legacy" ]]; then
            yaml_text+="    http-mask-mode: ${HTTPMASK_MODE}\n"
        fi
        if [[ "$HTTPMASK_TLS" == "true" ]]; then
            yaml_text+="    http-mask-tls: true\n"
        fi
        if [[ -n "$HTTPMASK_HOST" ]]; then
            yaml_text+="    http-mask-host: \"${HTTPMASK_HOST}\"\n"
        fi
        if [[ -n "$HTTPMASK_PATH_ROOT" ]]; then
            yaml_text+="    path-root: \"${HTTPMASK_PATH_ROOT}\"\n"
        fi
        if [[ "$HTTPMASK_MULTIPLEX" != "off" ]]; then
            yaml_text+="    http-mask-multiplex: ${HTTPMASK_MULTIPLEX}\n"
        fi
    else
        yaml_text+="    http-mask: false\n"
    fi

    # enable-pure-downlink
    yaml_text+="    enable-pure-downlink: ${ENABLE_PURE_DOWNLINK}"

    echo -e "$yaml_text"
    echo -e "${PLAIN}"

    # OpenClash 填空指引
    echo -e " ${BOLD}📝 OpenClash 填空指引${PLAIN}"
    echo -e "┌──────────────────────┬──────────────────────────────────────────────────┐"
    printf "│ %-20s │ %-48s │\n" "选项" "推荐填入值"
    echo -e "├──────────────────────┼──────────────────────────────────────────────────┤"
    printf "│ %-20s │ %-48s │\n" "类型 (type)" "sudoku"
    printf "│ %-20s │ %-48s │\n" "服务器地址" "${ipv4}"
    printf "│ %-20s │ %-48s │\n" "端口" "${PORT}"
    printf "│ %-20s │ %-48s │\n" "key" "${CLIENT_PRIVATE_KEY:0:32}..."
    printf "│ %-20s │ %-48s │\n" "aead-method" "${AEAD_METHOD}"
    printf "│ %-20s │ %-48s │\n" "padding-min" "${PADDING_MIN}"
    printf "│ %-20s │ %-48s │\n" "padding-max" "${PADDING_MAX}"
    printf "│ %-20s │ %-48s │\n" "table-type" "${TABLE_TYPE}"
    printf "│ %-20s │ %-48s │\n" "custom-table" "${CUSTOM_TABLE}"
    printf "│ %-20s │ %-48s │\n" "http-mask" "$([ "$HTTPMASK_DISABLE" == "true" ] && echo "false" || echo "true")"
    printf "│ %-20s │ %-48s │\n" "enable-pure-downlink" "${ENABLE_PURE_DOWNLINK}"
    echo -e "└──────────────────────┴──────────────────────────────────────────────────┘"
    echo ""

    echo -e " ${YELLOW}⚠️  注意事项:${PLAIN}"
    echo -e "   • key 填 ${CYAN}客户端私钥 (Available Private Key)${PLAIN}, 不是公钥!"
    echo -e "   • 服务端/客户端 enable-pure-downlink 必须一致"
    echo -e "   • 如需过 CDN, http-mask-mode 应选 auto/stream/poll"
    echo -e "   • custom-table 服务端客户端必须一致"
    print_line
}

# --- IP 优先级菜单 ---
set_ip_menu() {
    clear
    print_line
    echo -e " ${BOLD}出站 IP 优先级设置${PLAIN}"
    print_line
    if grep -q "^precedence ::ffff:0:0/96.*100" "$GAI_CONF" 2>/dev/null; then
        echo -e " 当前状态: ${GREEN}IPv4 优先${PLAIN}"
    else
        echo -e " 当前状态: ${CYAN}IPv6 优先 (默认)${PLAIN}"
    fi
    echo ""
    echo -e " 1. 强制 ${GREEN}IPv4${PLAIN} 优先"
    echo -e " 2. 恢复 ${CYAN}IPv6${PLAIN} 优先 (默认)"
    print_line
    read -p " 请选择 [1-2]: " choice
    case "$choice" in
        1|2) apply_ip_preference "$choice" ;;
        *) print_err "无效输入" ;;
    esac
    print_warn "即时生效, 无需重启服务。"
    read -p "按回车返回..."
}

# --- 内核升级 ---
update_core() {
    print_info "正在检查新版本..."

    local local_ver=""
    if [[ -f "$VERSION_FILE" ]]; then
        local_ver=$(cat "$VERSION_FILE")
    else
        local_ver="未知/未安装"
    fi

    local latest_json
    latest_json=$(curl -sL --max-time 10 -H "User-Agent: Mozilla/5.0" \
        "https://api.github.com/repos/$REPO/releases/latest")
    local remote_ver
    remote_ver=$(echo "$latest_json" | jq -r '.tag_name' 2>/dev/null)

    if [[ -z "$remote_ver" || "$remote_ver" == "null" ]]; then
        print_err "无法获取最新版本信息。"
        read -p "按回车返回..."
        return
    fi

    print_line
    echo -e " 当前版本: ${YELLOW}${local_ver}${PLAIN}"
    echo -e " 最新版本: ${GREEN}${remote_ver}${PLAIN}"
    print_line

    if [[ "$local_ver" == "$remote_ver" ]]; then
        print_ok "当前已是最新版本。"
        read -p "按回车返回..."
        return
    fi

    read -p " 发现新版本, 是否立即升级? [y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        install_core
        if service_status sudoku-tunnel 2>/dev/null || pgrep -f "$BIN_FILE" > /dev/null 2>&1; then
            service_restart sudoku-tunnel 2>/dev/null || {
                killall sudoku >/dev/null 2>&1
                nohup "$BIN_FILE" -c "$CONFIG_FILE" >/var/log/sudoku.log 2>&1 &
            }
            print_ok "服务已重启"
        fi
        read -p "升级完成, 按回车返回..."
    fi
}

# --- 卸载 ---
uninstall_sudoku() {
    echo ""
    echo -e "${RED}警告: 即将卸载 Sudoku 及所有配置文件${PLAIN}"
    read -p "确认卸载? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    print_info "正在停止服务..."
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        systemctl stop sudoku-tunnel >/dev/null 2>&1
        systemctl disable sudoku-tunnel >/dev/null 2>&1
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    else
        killall sudoku >/dev/null 2>&1
    fi

    print_info "清除安装文件..."
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR"
    rm -f "$SHORTCUT_BIN" "/usr/local/bin/sudoku-mgr"
    rm -f /var/log/sudoku.log
    rm -f /etc/sysctl.d/99-sudoku.conf
    sysctl --system >/dev/null 2>&1

    print_ok "卸载完成！"
}

# --- 完整安装流程 ---
start_installation() {
    detect_os

    if [[ -f "$BIN_FILE" ]]; then
        print_info "检测到 Sudoku 核心已安装, 跳过下载步骤。"
    else
        install_deps
        install_core
    fi

    optimize_sysctl
    configure_sudoku
    setup_service
    apply_firewall
    create_shortcut
    show_info
}

# --- 主菜单 ---
menu() {
    check_status
    clear

    local local_ver="未安装"
    [[ -f "$VERSION_FILE" ]] && local_ver=$(cat "$VERSION_FILE")

    local pid="N/A"
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        pid=$(systemctl show -p MainPID sudoku-tunnel 2>/dev/null | cut -d= -f2)
        [[ "$pid" == "0" ]] && pid="N/A"
    else
        pid=$(pgrep -f "$BIN_FILE" 2>/dev/null | head -1)
        [[ -z "$pid" ]] && pid="N/A"
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e "         ${BOLD}🧩 Sudoku (ASCII) 管理面板${PLAIN}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${PLAIN}"
    echo -e " 运行状态 : ${STATUS_RUNNING}"
    echo -e " 安装状态 : ${STATUS_INSTALL}"
    echo -e " 进程 PID : ${YELLOW}${pid}${PLAIN}"
    echo -e " 内核版本 : ${YELLOW}${local_ver}${PLAIN}"
    echo -e "${CYAN}─────────────────────────────────────────────${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN}  安装 / 重新配置"
    echo -e "  ${GREEN}2.${PLAIN}  查看配置 & 链接"
    echo -e "  ${GREEN}3.${PLAIN}  查看日志"
    echo -e ""
    echo -e "  ${GREEN}4.${PLAIN}  启动服务"
    echo -e "  ${GREEN}5.${PLAIN}  停止服务"
    echo -e "  ${GREEN}6.${PLAIN}  重启服务"
    echo -e ""
    echo -e "  ${GREEN}7.${PLAIN}  内核升级 (检测更新)"
    echo -e "  ${GREEN}8.${PLAIN}  出站 IP 偏好设置"
    echo -e "  ${RED}9.${PLAIN}  卸载程序"
    echo -e "  ${RED}0.${PLAIN}  退出脚本"
    echo -e "${CYAN}─────────────────────────────────────────────${PLAIN}"

    read -p " 请输入选项: " num
    case "$num" in
        1) start_installation ;;
        2)
            [[ ! -f "$ENV_FILE" ]] && { print_err "未安装"; read -p "按回车返回..."; menu; return; }
            show_info
            read -p "按回车返回..."
            menu
            ;;
        3)
            if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
                journalctl -u sudoku-tunnel -f
            else
                tail -f /var/log/sudoku.log 2>/dev/null || print_err "无日志文件"
            fi
            ;;
        4)
            if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
                systemctl start sudoku-tunnel && print_ok "启动成功"
            else
                nohup "$BIN_FILE" -c "$CONFIG_FILE" >/var/log/sudoku.log 2>&1 &
                print_ok "后台启动"
            fi
            read -p "按回车继续..."
            menu
            ;;
        5)
            if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
                systemctl stop sudoku-tunnel && print_ok "停止成功"
            else
                killall sudoku >/dev/null 2>&1 && print_ok "已停止"
            fi
            sleep 1
            menu
            ;;
        6)
            if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
                systemctl restart sudoku-tunnel && print_ok "重启成功"
            else
                killall sudoku >/dev/null 2>&1
                nohup "$BIN_FILE" -c "$CONFIG_FILE" >/var/log/sudoku.log 2>&1 &
                print_ok "已重启 (后台)"
            fi
            read -p "按回车继续..."
            menu
            ;;
        7) update_core; menu ;;
        8) set_ip_menu; menu ;;
        9) uninstall_sudoku; exit 0 ;;
        0) exit 0 ;;
        *) menu ;;
    esac
}

# --- 入口 ---
if [[ -f "$ENV_FILE" && "$1" != "install" ]]; then
    menu
else
    case "${1:-}" in
        install) start_installation ;;
        info) show_info ;;
        *) start_installation ;;
    esac
fi
