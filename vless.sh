#!/bin/bash

# ====================================================
# VLESS (TCP-Vision/XHTTP/WS) + REALITY/TLS 一键脚本
# ====================================================

# --- 全局配置 ---
SCRIPT_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main/vless.sh"
INSTALL_DIR="/opt/xray"
CONFIG_DIR="/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_FILE="${INSTALL_DIR}/xray"
SERVICE_FILE="/etc/systemd/system/xray.service"
SHORTCUT_BIN="/usr/bin/vless"
ENV_FILE="${CONFIG_DIR}/env.conf"
CERT_DIR="${CONFIG_DIR}/cert"

# --- 引入公共函数 ---
if [[ -f "common.sh" ]]; then
    source "common.sh"
else
    source <(curl -fsSL https://raw.githubusercontent.com/10000ge10000/own-rules/main/common.sh)
fi

# --- 扩展变量 ---
# (统一使用 Official Xray-core)

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
    print_info "安装 VLESS 组件依赖..."
    if [[ "${RELEASE}" == "centos" ]]; then
        yum install -y jq tar unzip openssl socat cronie
        if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
            systemctl start crond
            systemctl enable crond
        fi
    else
        apt update
        apt install -y jq tar unzip openssl socat cron
    fi
}

# --- Cloudflared 安装与配置 ---
install_cloudflared() {
    local token=$1
    if [[ -z "$token" ]]; then return; fi
    
    print_info "正在安装 Cloudflared..."
    local cf_bin="/usr/local/bin/cloudflared"
    
    if [[ ! -f "$cf_bin" ]]; then
        local arch=$(uname -m)
        local cf_url=""
        case "$arch" in
            x86_64|amd64) cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
            aarch64|arm64) cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
            *) print_err "Cloudflared 不支持此架构: $arch"; return ;;
        esac
        
        wget -q --show-progress -O "$cf_bin" "$cf_url"
        chmod +x "$cf_bin"
    fi
    
    # 停止旧服务
    "$cf_bin" service uninstall >/dev/null 2>&1
    
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        # 安装新服务
        "$cf_bin" service install "$token" >/dev/null 2>&1
        systemctl restart cloudflared
        systemctl enable cloudflared
        print_ok "Cloudflared Tunnel 已启动"
    else
        print_warn "检测到非 Systemd 环境，正在后台启动 Cloudflared..."
        nohup "$cf_bin" tunnel run --token "$token" >/dev/null 2>&1 &
        print_ok "Cloudflared Tunnel 已后台运行"
    fi
}

# --- ACME 证书申请函数 ---
issue_cert() {
    local domain=$1
    local cert_file="${CERT_DIR}/${domain}.cer"
    local key_file="${CERT_DIR}/${domain}.key"

    mkdir -p "$CERT_DIR"
    
    # 安装 acme.sh
    if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then
        print_info "正在安装 acme.sh..."
        curl https://get.acme.sh | sh
    fi
    
    # 开放 80 端口用于验证
    apply_firewall_rule 80 "tcp"

    # 申请证书 (Standalone 模式)
    print_info "正在为 $domain 申请证书 (请确保域名已解析到本机 IP)..."
    
    # 停止占用 80 端口的服务 (如果需要)
    systemctl stop nginx >/dev/null 2>&1
    
    "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone -k ec-256 --force
    
    if [[ $? -ne 0 ]]; then
        print_err "证书申请失败！请检查：1. 域名是否解析正确 2. 80 端口是否开放"
        return 1
    fi

    # 安装证书到指定目录
    "$HOME/.acme.sh/acme.sh" --installcert -d "$domain" --fullchain-file "$cert_file" --key-file "$key_file" --ecc
    
    # 设置权限
    chmod 644 "$cert_file"
    chmod 600 "$key_file"
    
    print_ok "证书申请成功！"
    echo "$cert_file"
    echo "$key_file"
    return 0
}

# --- 安装核心 ---
install_xray_core() {
    print_info "正在获取 Xray 核心 (Source: XTLS/Xray-core)..."
    
    local arch=$(uname -m)
    local xray_arch=""
    case "$arch" in
        x86_64|x64|amd64) xray_arch="64" ;;
        aarch64|arm64) xray_arch="arm64-v8a" ;;
        *) print_warn "未识别架构: $arch, 尝试 64"; xray_arch="64" ;;
    esac

    # 获取最新 vTAG
    local tag_version=""
    local api_url="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    
    # 尝试使用 jq 解析 (更稳健)
    if command -v jq >/dev/null 2>&1; then
        tag_version=$(curl -s "$api_url" | jq -r '.tag_name')
    fi
    
    # 如果 jq 失败或未安装，使用 grep/sed 提取
    if [[ -z "$tag_version" || "$tag_version" == "null" ]]; then
        # grep -o 提取 "tag_name": "v..." 避免贪婪匹配问题
        tag_version=$(curl -s "$api_url" | grep -o '"tag_name": *"[^"]*"' | sed 's/.*: *"//;s/"$//')
    fi
    
    if [[ -z "$tag_version" ]]; then
        print_warn "获取版本失败，尝试使用 IPv4 API 或默认版本..."
        tag_version=$(curl -4 -s "$api_url" | grep -o '"tag_name": *"[^"]*"' | sed 's/.*: *"//;s/"$//')
    fi
    [[ -z "$tag_version" ]] && tag_version="v26.1.23"

    # 构造下载链接 (Official Xray-core is zip)
    local download_url="https://github.com/XTLS/Xray-core/releases/download/${tag_version}/Xray-linux-${xray_arch}.zip"
    local temp_zip="/tmp/Xray-linux.zip"
    local temp_dir="/tmp/Xray-extract"

    print_info "下载核心组件: $tag_version ($xray_arch)..."
    wget -q --show-progress -O "$temp_zip" "$download_url"
    
    if [[ ! -s "$temp_zip" ]]; then
        print_err "下载失败: $download_url"
        exit 1
    fi

    # 解压提取
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"
    unzip -q "$temp_zip" -d "$temp_dir"
    
    print_info "安装 Xray 核心..."
    mkdir -p "$INSTALL_DIR"
    
    local extracted_bin="$temp_dir/xray"

    if [[ -f "$extracted_bin" ]]; then
        cp -f "$extracted_bin" "$BIN_FILE"
        chmod +x "$BIN_FILE"
        echo "$tag_version" > "${INSTALL_DIR}/version"
        print_ok "核心安装成功 ($tag_version)"
    else
        print_err "未找到核心文件！"
        exit 1
    fi

    rm -f "$temp_zip"
    rm -rf "$temp_dir"
}

# --- 生成配置 ---
configure_vless() {
    mkdir -p "$CONFIG_DIR"
    mkdir -p "${CONFIG_DIR}/cert"
    
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e " ${BOLD}请选择 VLESS 模式 (支持多选，用空格分隔):${PLAIN}"
    echo -e "${BLUE}--------------------------------------------------${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} VLESS-TCP-REALITY-Vision ${YELLOW}(推荐: 抗封锁/高性能)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} VLESS-XHTTP-REALITY-ENC  ${YELLOW}(定制: 强伪装+加密)${PLAIN}"
    echo -e " ${GREEN}3.${PLAIN} VLESS-XHTTP-ENC          ${YELLOW}(定制: XHTTP+加密)${PLAIN}"
    echo -e " ${GREEN}4.${PLAIN} VLESS-WS-ENC             ${YELLOW}(定制: WS+加密)${PLAIN}"
    echo -e " ${GREEN}5.${PLAIN} VLESS-XHTTP-TLS          ${YELLOW}(标准: 支持 CDN)${PLAIN}"
    echo -e " ${GREEN}6.${PLAIN} VLESS-WS-TLS             ${YELLOW}(标准: 支持 CDN)${PLAIN}"
    echo -e "${BLUE}==================================================${PLAIN}"
    echo -e " 例如: 1 5 (同时安装 Reality 和 TLS 节点)"
    read -p " 请输入数字 [1-6]: " mode_choices_input

    # 默认值处理
    [[ -z "$mode_choices_input" ]] && mode_choices_input="1"

    # --- 询问是否覆盖 (提前到这里) ---
    local is_append=false
    if [[ -f "$CONFIG_FILE" || -d "${CONFIG_DIR}/nodes" ]]; then
        echo -e "${BLUE}------------------------------------------------${PLAIN}"
        read -p " 检测到已有配置，是否保留旧节点并追加新节点? (y=追加, n=覆盖清空) [y/n] [默认 n]: " append_choice
        if [[ "$append_choice" == "y" || "$append_choice" == "Y" ]]; then
            is_append=true
        else
            print_info " 将清除旧配置..."
            rm -rf "${CONFIG_DIR}/nodes"
            mkdir -p "${CONFIG_DIR}/nodes"
        fi
    fi

    # 生成通用 UUID
    local uuid=""
    read -p " 请输入 UUID (回车随机): " input_uuid
    if [[ -n "$input_uuid" ]]; then
        uuid="$input_uuid"
    else
        if [[ ! -f "$BIN_FILE" ]]; then
             if command -v uuidgen &>/dev/null; then uuid=$(uuidgen); else uuid=$(cat /proc/sys/kernel/random/uuid); fi
        else
            uuid=$("$BIN_FILE" uuid)
        fi
    fi

    # IP 策略 (全局询问)
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    echo " 请选择出站 IP 策略:"
    echo " 1. 默认 (跟随系统)"
    echo " 2. IPv4 优先"
    echo " 3. IPv6 优先"
    read -p " 请输入选择 [1-3] (默认 1): " ip_choice
    local domain_strategy="AsIs"
    case "$ip_choice" in
        2) domain_strategy="UseIPv4" ;;
        3) domain_strategy="UseIPv6" ;;
        *) domain_strategy="AsIs" ;;
    esac

    # 预设 SNI
    local rand_sni="v1-dy.ixigua.com"
    local last_sni=""
    
    # 准备存储 Inbounds
    local created_inbounds_files=()
    local last_port=9525

    # 尝试读取已有端口避免冲突
    if [[ "$is_append" == "true" ]]; then
        for f in "${CONFIG_DIR}/nodes"/*.conf; do
            if [[ -f "$f" ]]; then
                local p=$(grep "^PORT=" "$f" | cut -d= -f2)
                if [[ -n "$p" && "$p" -gt "$last_port" ]]; then last_port=$p; fi
            fi
        done
    fi

    # 循环处理所有选择
    for mode_choice in $mode_choices_input; do
        print_line
        echo -e " ${BOLD}正在配置模式: [${mode_choice}]${PLAIN}"
        
        # 端口自增逻辑
        local default_port=$((last_port + 1))
        read -p " 请输入端口 [默认 ${default_port}]: " PORT
        [[ -z "$PORT" ]] && PORT=$default_port
        last_port=$PORT

        # 初始化变量
        local protocol="vless"
        local network=""
        local security=""
        local flow=""
        local sni=""
        local ws_path=""
        local private_key=""
        local public_key=""
        local short_id=""
        local cert_path=""
        local key_path=""
        local type_tag=""
        local decryption="none"
        local encryption="none"
        
        # Argo
        local use_argo="false"
        local argo_domain=""
        local argo_token=""

        # 根据模式确定参数
        case "$mode_choice" in
            1) # TCP-REALITY-Vision
                type_tag="tcp-reality-vision"
                network="tcp"
                security="reality"
                flow="xtls-rprx-vision"
                ;;
            2) # XHTTP-REALITY-ENC
                type_tag="xhttp-reality-enc"
                network="xhttp"
                security="reality"
                flow="xtls-rprx-vision"
                decryption="yes" # 标记需要生成
                ;;
            3) # XHTTP-ENC
                type_tag="xhttp-enc"
                network="xhttp"
                security="none"
                decryption="yes"
                ;;
            4) # WS-ENC
                type_tag="ws-enc"
                network="ws"
                security="none"
                decryption="yes"
                ;;
            5) # XHTTP-TLS
                type_tag="xhttp-tls"
                network="xhttp"
                security="tls"
                ;;
            6) # WS-TLS
                type_tag="ws-tls"
                network="ws"
                security="tls"
                ;;
            *) continue ;; 
        esac

        # SNI 处理
        local default_sni="${last_sni:-$rand_sni}"
        if [[ "$security" == "tls" ]]; then
             read -p " 请输入域名 (留空自签/Argo): " input_sni
        else
             read -p " 请输入伪装域名 (SNI) [默认 $default_sni]: " input_sni
        fi
        sni="${input_sni:-$default_sni}"
        last_sni="$sni"

        # Argo 判断 (仅限非 Reality 的 TLS/None 模式，或者用户强行想玩)
        if [[ "$mode_choice" =~ ^(3|4|5|6)$ ]]; then
            read -p " 是否启用 Argo 隧道? [y/n]: " enable_argo
            if [[ "$enable_argo" == "y" || "$enable_argo" == "Y" ]]; then
                use_argo="true"
                read -p " 请输入 Argo 域名: " argo_domain
                read -p " 请输入 Argo Token: " argo_token
                install_cloudflared "$argo_token"
                
                #如果 Argo 启用且是 TLS 模式，通常本地改为 none
                if [[ "$security" == "tls" ]]; then
                     security="none" 
                     print_warn " Argo 模式下，本地 TLS 已自动关闭，交由 Cloudflared 处理。"
                fi
                sni="$argo_domain"
            fi
        fi

        # 证书/密钥逻辑
        if [[ "$security" == "tls" ]]; then
            # 只有没有启用 Argo 的才需要证书
            if [[ "$use_argo" != "true" ]]; then
                if [[ "$sni" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ -z "$sni" ]]; then
                     # IP 自签
                     local ip_val=${sni:-$(curl -s4m5 https://api.ipify.org)}
                     cert_path="${CERT_DIR}/${ip_val}.cer"
                     key_path="${CERT_DIR}/${ip_val}.key"
                     openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$key_path" -out "$cert_path" -days 3650 -subj "/CN=${ip_val}" 2>/dev/null
                else
                     issue_cert "$sni"
                     cert_path="${CERT_DIR}/${sni}.cer"
                     key_path="${CERT_DIR}/${sni}.key"
                fi
            fi
        elif [[ "$security" == "reality" ]]; then
            local keys=$("$BIN_FILE" x25519)
            private_key=$(echo "$keys" | grep -i "Private" | awk '{print $2}')
            public_key=$(echo "$keys" | grep -i "Public\|Password" | awk '{print $2}')
            short_id=$(openssl rand -hex 4)
        fi

        # 加密 Key 生成
        if [[ "$decryption" == "yes" ]]; then
             local vlkey=$("$BIN_FILE" vlessenc)
             
             local dec_tmp=""
             local enc_tmp=""
             
             # 尝试使用 jq 提取 (处理可能的多个 JSON 或日志混杂情况)
             if command -v jq >/dev/null 2>&1; then
                 # 提取所有出现的 decryption 值，过滤 null，取第一行
                 dec_tmp=$(echo "$vlkey" | jq -r .decryption 2>/dev/null | grep -v "null" | head -n 1)
                 enc_tmp=$(echo "$vlkey" | jq -r .encryption 2>/dev/null | grep -v "null" | head -n 1)
             fi

             # Fallback: 如果 jq 失败或未提取到，使用 grep/sed 正则提取
             if [[ -z "$dec_tmp" ]]; then
                 dec_tmp=$(echo "$vlkey" | grep -o '"decryption": *"[^"]*"' | sed 's/.*: *"//;s/"$//' | head -n 1)
                 enc_tmp=$(echo "$vlkey" | grep -o '"encryption": *"[^"]*"' | sed 's/.*: *"//;s/"$//' | head -n 1)
             fi
             
             # 赋值并清理可能的空白字符
             decryption="${dec_tmp//[[:space:]]/}"
             encryption="${enc_tmp//[[:space:]]/}"
             
             # 再次防空
             [[ -z "$decryption" ]] && decryption="none"
        else
             decryption="none"
        fi

        # 路径生成
        ws_path="/$(openssl rand -hex 4)"
        if [[ "$network" == "xhttp" ]]; then
            # XHTTP specific needs
            :
        fi

        # 构造 Inbound JSON
        local stream_settings="\"network\": \"$network\", \"security\": \"$security\""
        
        if [[ "$security" == "tls" ]]; then
            stream_settings="$stream_settings, \"tlsSettings\": { \"certificates\": [ { \"certificateFile\": \"$cert_path\", \"keyFile\": \"$key_path\" } ] }"
        elif [[ "$security" == "reality" ]]; then
            stream_settings="$stream_settings, \"realitySettings\": { \"show\": false, \"dest\": \"$sni:443\", \"xver\": 0, \"serverNames\": [\"$sni\"], \"privateKey\": \"$private_key\", \"shortIds\": [\"$short_id\"] }"
        fi

        if [[ "$network" == "xhttp" ]]; then
            stream_settings="$stream_settings, \"xhttpSettings\": { \"path\": \"$ws_path\" }"
        elif [[ "$network" == "ws" ]]; then
            stream_settings="$stream_settings, \"wsSettings\": { \"path\": \"$ws_path\" }"
        fi

        local this_inbound="{
            \"port\": $PORT,
            \"protocol\": \"vless\",
            \"settings\": {
                \"clients\": [ { \"id\": \"$uuid\", \"flow\": \"$flow\" } ],
                \"decryption\": \"$decryption\"
            },
            \"streamSettings\": { $stream_settings },
            \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\", \"tls\", \"quic\"] }
        }"
        
        # 临时保存 inbound 到文件
        echo "$this_inbound" > "/tmp/inbound_${PORT}.json"
        
        # 保存节点环境文件
        mkdir -p "${CONFIG_DIR}/nodes"
        local node_env_file="${CONFIG_DIR}/nodes/${PORT}.conf"
        cat > "$node_env_file" <<EOF
TYPE="$type_tag"
UUID="$uuid"
PORT="$PORT"
SNI="$sni"
WS_PATH="$ws_path"
PUBLIC_KEY="$public_key"
SHORT_ID="$short_id"
NETWORK="$network"
FLOW="$flow"
SECURITY="$security"
DECRYPTION="$decryption"
ENCRYPTION="$encryption"
USE_ARGO="$use_argo"
ARGO_DOMAIN="$argo_domain"
IP_STRATEGY="$domain_strategy"
EOF
        created_inbounds_files+=("/tmp/inbound_${PORT}.json")
        print_ok " 模式 [$mode_choice] 配置与准备完成 (Port: $PORT)"
    done

    # --- 合并 JSON ---
    print_info "正在生成最终配置文件..."
    
    local inbounds_json_array=""
    if [[ ${#created_inbounds_files[@]} -gt 0 ]]; then
        # 读取所有临时文件并组合成 array string, jq manual merge might be complex, use loop
        inbounds_json_array="["
        local first=true
        for f in "${created_inbounds_files[@]}"; do
            if [[ "$first" == "true" ]]; then first=false; else inbounds_json_array+=","; fi
            inbounds_json_array+=$(cat "$f")
            rm -f "$f"
        done
        inbounds_json_array+="]"
    else
        print_err "未生成任何有效配置"
        exit 1
    fi

    if [[ "$is_append" == "true" ]]; then
        # 使用 jq 将新 inbounds 追加到原来的 list
        # 需要先构造一个临时的 new_inbounds.json
        echo "{ \"new_inbounds\": $inbounds_json_array }" > /tmp/new_add.json
        
        # 即使是 append，也要检查 config.json 是否合法，不合法就当全新的
        if [[ -s "$CONFIG_FILE" ]]; then
             if jq -s '.[0].inbounds += .[1].new_inbounds | .[0]' "$CONFIG_FILE" /tmp/new_add.json > "${CONFIG_FILE}.tmp"; then
                 mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
             else
                 print_err "JSON 合并失败，将使用新配置覆盖。"
                 is_append=false
             fi
        else
            is_append=false
        fi
        rm -f /tmp/new_add.json
    fi

    # 覆盖生成逻辑 (nodes 已经在上方循环生成了，这里不要再删 nodes 目录了)
    if [[ "$is_append" != "true" ]]; then
        cat > "$CONFIG_FILE" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": $inbounds_json_array,
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "$domain_strategy" } },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
    fi

    print_ok "所有配置生成完毕！"
}

# --- 启动服务 ---
setup_service() {
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=$BIN_FILE run -c $CONFIG_FILE
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable xray >/dev/null 2>&1
        systemctl restart xray
        print_ok "Systemd 服务已启动/重启"
    else
        # 非 Systemd 环境直接启动
        print_warn "检测到非 Systemd 环境，正在后台启动 Xray..."
        killall xray >/dev/null 2>&1
        nohup "$BIN_FILE" run -c "$CONFIG_FILE" >/var/log/xray.log 2>&1 &
        print_ok "Xray 已后台运行 (日志: /var/log/xray.log)"
    fi
    
    # --- 防火墙自动配置 (多端口支持) ---
    local nodes_dir="${CONFIG_DIR}/nodes"
    if [[ -d "$nodes_dir" ]]; then
        for env_file in "$nodes_dir"/*.conf; do
            if [[ -f "$env_file" ]]; then
                # 在子 shell 中 source 避免污染全局或相互冲突
                (
                    source "$env_file"
                    if [[ -n "$PORT" ]]; then
                        print_info "配置防火墙规则 (端口: $PORT, 协议: tcp)..."
                        apply_firewall_rule "$PORT" "tcp"
                        if [[ "$NETWORK" == "xhttp" ]]; then
                             apply_firewall_rule "$PORT" "udp"
                        fi
                    fi
                )
            fi
        done
    elif [[ -f "$ENV_FILE" ]]; then
        # 旧逻辑 fallback
        (
            source "$ENV_FILE"
            if [[ -n "$PORT" ]]; then
                apply_firewall_rule "$PORT" "tcp"
                [[ "$NETWORK" == "xhttp" ]] && apply_firewall_rule "$PORT" "udp"
            fi
        )
    fi
    
    print_ok "服务已启动/重启"
}

# --- 展示信息 ---
show_info() {
    # 优先遍历 nodes 目录
    local nodes_dir="${CONFIG_DIR}/nodes"
    if [[ -d "$nodes_dir" && "$(ls -A $nodes_dir)" ]]; then
        for env_file in "$nodes_dir"/*.conf; do
            print_node_info "$env_file"
        done
        return
    fi

    # 兼容旧逻辑
    if [[ ! -f "$ENV_FILE" ]]; then print_err "未安装"; return; fi
    print_node_info "$ENV_FILE"
}

print_node_info() {
    local file=$1
    source "$file"
    
    local ip=$(curl -s4m8 https://api.ipify.org || curl -s4m8 https://ifconfig.me)
    local link=""
    
    # 确定加密字段
    local enc_val="none"
    if [[ -n "$ENCRYPTION" && "$ENCRYPTION" != "none" ]]; then
        enc_val="$ENCRYPTION"
    fi
    
    # 确定地址显示
    local addr_display="${ip}"
    local host_display="${SNI}"
    
    if [[ "$USE_ARGO" == "true" ]]; then
        addr_display="saas.sin.fan"
        host_display="${ARGO_DOMAIN}"
        # 对于 ARGO，SNI 通常设为隧道域名
        SNI="${ARGO_DOMAIN}"
    fi

    # --- 链接生成逻辑 (重构) ---
    
    # 1. 基础部分: vless://uuid@ip:port
    link="vless://${UUID}@${addr_display}:${PORT}"
    
    # 2. 参数构建
    local params="?encryption=${enc_val}&type=${NETWORK}"

    # Security & Flow
    if [[ "$SECURITY" == "reality" ]]; then
        params="${params}&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}"
        [[ -n "$FLOW" ]] && params="${params}&flow=${FLOW}"
    elif [[ "$SECURITY" == "tls" ]]; then
        params="${params}&security=tls&sni=${host_display}"
        [[ -n "$FLOW" ]] && params="${params}&flow=${FLOW}"
        # Argo 特殊处理
        if [[ "$USE_ARGO" == "true" ]]; then
             # 如果是 Argo，客户端看到的可能是 TLS，但本地配置可能是 none
             # 这里保持 env 中的 SECURITY 设置优先，如果是 tls
             :
        fi
    elif [[ "$SECURITY" == "none" ]]; then
        params="${params}&security=none"
        # 某些裸协议(如WS)可能需要 host
        if [[ "$NETWORK" == "ws" || "$NETWORK" == "xhttp" ]]; then
             params="${params}&host=${host_display}"
        fi
    fi

    # Path (for WS, XHTTP, GRPC, etc)
    if [[ "$NETWORK" == "ws" || "$NETWORK" == "xhttp" || "$NETWORK" == "grpc" ]]; then
        [[ -n "$WS_PATH" ]] && params="${params}&path=${WS_PATH}"
    fi

    # Mode (XHTTP specific, optional but good for compatibility)
    if [[ "$NETWORK" == "xhttp" ]]; then
         #params="${params}&mode=auto" # 暂时移除，视客户端兼容性而定
         :
    fi

    # Seed / HeaderType (quic/kcp) - 这里暂未涉及
    
    # 3. 组合: #name
    local remarks="${TYPE}"
    [[ "$USE_ARGO" == "true" ]] && remarks="${remarks}-Argo"
    remarks="${remarks}-${host_display}"

    link="${link}${params}#${remarks}"

    print_line
    echo -e "${GREEN}VLESS 节点信息 ($TYPE)${PLAIN}"
    echo -e "地址 (Address):     ${CYAN}${addr_display}${PLAIN}"
    echo -e "端口 (Port):        ${CYAN}${PORT}${PLAIN}"
    echo -e "UUID:               ${CYAN}${UUID}${PLAIN}"
    echo -e "传输 (Network):     ${CYAN}${NETWORK}${PLAIN}"
    echo -e "安全 (Security):    ${CYAN}${SECURITY}${PLAIN}"
    [[ -n "$FLOW" ]] && echo -e "流控 (Flow):        ${CYAN}${FLOW}${PLAIN}"
    [[ -n "$WS_PATH" ]] && echo -e "路径 (Path):        ${CYAN}${WS_PATH}${PLAIN}"
    if [[ "$SECURITY" == "reality" ]]; then
        echo -e "Public Key:         ${CYAN}${PUBLIC_KEY}${PLAIN}"
        echo -e "Short ID:           ${CYAN}${SHORT_ID}${PLAIN}"
        echo -e "SNI:                ${CYAN}${SNI}${PLAIN}"
    fi
    if [[ "$enc_val" != "none" ]]; then
        echo -e "${YELLOW}VLESS Encryption Key:${PLAIN} (已包含在链接中)"
        echo -e "${CYAN}${enc_val}${PLAIN}"
    fi
    print_line
    echo -e "${YELLOW}分享链接:${PLAIN}"
    echo -e "$link"
    print_line
}

# --- 快捷指令 ---
create_shortcut() {
    if [[ -f "$0" ]]; then cp -f "$0" "$SHORTCUT_BIN"; else wget -qO "$SHORTCUT_BIN" "$SCRIPT_URL"; fi
    chmod +x "$SHORTCUT_BIN"
    print_ok "快捷指令: vless"
}

# --- 更新核心 ---
update_core() {
    echo "=================================================="
    echo " Xray 核心更新 (Based on Official XTLS/Xray-core)"
    echo "--------------------------------------------------"
    
    # 获取当前版本
    local current_ver=""
    if [[ -f "${INSTALL_DIR}/version" ]]; then
        current_ver=$(cat "${INSTALL_DIR}/version")
    elif [[ -f "$BIN_FILE" ]]; then
        current_ver="Legacy ($("$BIN_FILE" version | head -n 1 | awk '{print $2}'))"
    else
        current_ver="未安装"
    fi

    print_info "正在检查最新版本..."
    local api_url="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    local latest_ver=""
    
    if command -v jq >/dev/null 2>&1; then
        latest_ver=$(curl -s "$api_url" | jq -r '.tag_name')
    fi
    
    if [[ -z "$latest_ver" || "$latest_ver" == "null" ]]; then
        latest_ver=$(curl -s "$api_url" | grep -o '"tag_name": *"[^"]*"' | sed 's/.*: *"//;s/"$//')
    fi
    
    if [[ -z "$latest_ver" ]]; then
        latest_ver=$(curl -4 -s "$api_url" | grep -o '"tag_name": *"[^"]*"' | sed 's/.*: *"//;s/"$//')
    fi
    [[ -z "$latest_ver" ]] && latest_ver="未知 (API Error)"

    echo -e " 当前版本: ${GREEN}${current_ver}${PLAIN}"
    echo -e " 最新版本: ${GREEN}${latest_ver}${PLAIN}"
    echo "--------------------------------------------------"

    local choice=""
    if [[ "$latest_ver" != "未知"* && "$current_ver" == "$latest_ver" ]]; then
        echo -e "${GREEN}当前已是最新版本。${PLAIN}"
        read -p "是否强制重新更新? [y/n]: " choice
    else
        if [[ "$latest_ver" != "未知"* ]]; then
             echo -e "${YELLOW}可能有新版本或版本号无法匹配。${PLAIN}"
        fi
        read -p "是否更新核心? [y/n]: " choice
    fi
    
    [[ "$choice" != "y" && "$choice" != "Y" ]] && return

    print_info "正在停止服务..."
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        systemctl stop xray
    else
        killall xray >/dev/null 2>&1
    fi

    # 调用核心安装
    install_xray_core
    
    print_info "正在重启服务..."
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        systemctl restart xray
    else
        nohup "$BIN_FILE" run -c "$CONFIG_FILE" >/var/log/xray.log 2>&1 &
    fi
    print_ok "核心更新完成"
}

# --- 卸载 ---
uninstall_vless() {
    echo "------------------------------------------------"
    echo -e "${RED}警告: 即将卸载 VLESS 及所有组件${PLAIN}"
    read -p "确认卸载? [y/n]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    print_info "正在停止 Xray 服务..."
    if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
        systemctl stop xray >/dev/null 2>&1
        systemctl disable xray >/dev/null 2>&1
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    else
        killall xray >/dev/null 2>&1
    fi

    # 清理 Cloudflared (Argo)
    if [[ -f "/usr/local/bin/cloudflared" ]]; then
        print_info "正在清理 Cloudflared..."
        # 尝试卸载服务
        "/usr/local/bin/cloudflared" service uninstall >/dev/null 2>&1
        # 确保进程终止
        killall cloudflared >/dev/null 2>&1
        rm -f "/usr/local/bin/cloudflared"
        print_ok "Cloudflared 已清理"
    fi

    print_info "清除安装文件..."
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$SHORTCUT_BIN" "/var/log/xray.log"

    # 询问清理 acme.sh
    if [[ -d "$HOME/.acme.sh" ]]; then
        echo -e "${YELLOW}检测到 acme.sh 证书工具${PLAIN}"
        read -p "是否一并卸载 acme.sh? (如果是共用环境请选 n) [y/n]: " rm_acme
        if [[ "$rm_acme" == "y" || "$rm_acme" == "Y" ]]; then
            "$HOME/.acme.sh/acme.sh" --uninstall >/dev/null 2>&1
            rm -rf "$HOME/.acme.sh"
            print_ok "acme.sh 已移除"
        fi
    fi

    print_ok "卸载完成，系统已清理。"
}

# --- 菜单 ---
menu() {
    check_status
    clear
    echo -e "${BLUE}################################################${PLAIN}"
    echo -e "${BLUE}#${PLAIN}         ${BOLD}VLESS 多模式一键管理脚本${PLAIN}             ${BLUE}#${PLAIN}"
    echo -e "${BLUE}#${PLAIN}     ${CYAN}支持: TCP-Vision / XHTTP / REALITY / TLS${PLAIN}   ${BLUE}#${PLAIN}"
    echo -e "${BLUE}################################################${PLAIN}"
    echo -e " 系统状态: ${STATUS_INSTALL} | ${STATUS_RUNNING}"
    echo -e "${BLUE}------------------------------------------------${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} 安装节点 / 添加配置 ${YELLOW}(支持多选)${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} 查看所有节点信息"
    echo -e " ${GREEN}3.${PLAIN} 重启服务"
    echo -e " ${GREEN}4.${PLAIN} 停止服务"
    echo -e " ${GREEN}5.${PLAIN} 更新 Xray 核心"
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
                systemctl restart xray && print_ok "重启成功"
            else
                killall xray >/dev/null 2>&1
                nohup "$BIN_FILE" run -c "$CONFIG_FILE" >/var/log/xray.log 2>&1 &
                print_ok "服务已重启 (后台)"
            fi
            ;;
        4) 
            if [[ "$SYSTEMD_AVAILABLE" == "true" ]]; then
                systemctl stop xray && print_ok "停止成功"
            else
                killall xray >/dev/null 2>&1 && print_ok "已结束后台进程"
            fi
            ;;
        5) update_core ;;
        6) uninstall_vless ;;
        0) exit 0 ;;
        *) print_err "无效输入"; menu ;;
    esac
}

# --- 智能安装入口 ---
start_installation() {
    detect_os
    
    # 检查核心是否已存在
    if [[ -f "$BIN_FILE" ]]; then
        print_info "检测到 Xray 核心已安装，跳过依赖安装与下载步骤。"
    else
        install_specific_deps
        install_xray_core
    fi
    
    # 进入配置
    configure_vless
    
    # 启动/重启
    setup_service
    
    # 快捷指令
    create_shortcut
    
    # 展示
    show_info
}

[[ -n "$1" ]] && { 
    case "$1" in
        install) start_installation ;;
        info) show_info ;;
        *) menu ;;
    esac
} || menu
