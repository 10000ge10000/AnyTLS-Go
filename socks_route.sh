#!/bin/bash

# ====================================================
# SOCKS5 家宽出口 + 分流管理脚本
# 项目: github.com/10000ge10000/own-rules
# 版本: 1.0.0
# 说明: 在 Xray 上配置 SOCKS5 入站 + 链式代理出站 + 分流规则
#       适用于需要家宽 IP 出口解锁流媒体等场景
# ====================================================

VERSION="1.0.0"
REPO_URL="https://raw.githubusercontent.com/10000ge10000/own-rules/main"

# --- 颜色 ---
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
GRAY='\033[90m'
PLAIN='\033[0m'
BOLD='\033[1m'

# --- 路径 ---
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
SOCKS_DB="${XRAY_CONFIG_DIR}/socks_route.json"
SOCKS_SERVICE="xray-socks"

# ============================================================
# 基础工具函数
# ============================================================

print_line()   { echo -e "${CYAN}─────────────────────────────────────────────────────────${PLAIN}"; }
print_dline()  { echo -e "${CYAN}═════════════════════════════════════════════════════════${PLAIN}"; }
print_ok()     { echo -e "${GREEN}✔${PLAIN} $1"; }
print_err()    { echo -e "${RED}✖${PLAIN} $1"; }
print_warn()   { echo -e "${YELLOW}⚡${PLAIN} $1"; }
print_info()   { echo -e "${CYAN}➜${PLAIN} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_err "请使用 root 权限运行此脚本"
        exit 1
    fi
}

check_jq() {
    if ! command -v jq &>/dev/null; then
        print_info "安装 jq..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq jq >/dev/null 2>&1
        elif command -v yum &>/dev/null; then
            yum install -y -q jq >/dev/null 2>&1
        elif command -v apk &>/dev/null; then
            apk add --quiet jq >/dev/null 2>&1
        fi
        if ! command -v jq &>/dev/null; then
            print_err "jq 安装失败，请手动安装"
            exit 1
        fi
    fi
}

# 获取公网 IP
get_ipv4() {
    local ip=""
    ip=$(curl -s4m8 https://api.ipify.org 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s4m8 https://ifconfig.me 2>/dev/null)
    echo "${ip:-N/A}"
}

get_ipv6() {
    local ip=""
    ip=$(curl -s6m8 https://api64.ipify.org 2>/dev/null)
    echo "${ip:-}"
}

# 生成随机端口 (10000-60000)
gen_port() {
    local port
    while true; do
        port=$((RANDOM % 50000 + 10000))
        if ! ss -tunlp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
}

# 生成随机密码
gen_password() {
    local len=${1:-16}
    head /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$len"
}

# ============================================================
# 数据库操作 (JSON 文件)
# ============================================================

db_init() {
    mkdir -p "$XRAY_CONFIG_DIR"
    if [[ ! -f "$SOCKS_DB" ]]; then
        cat > "$SOCKS_DB" <<'EOF'
{
  "socks_inbound": null,
  "chain_nodes": [],
  "routing_rules": [],
  "balancer_groups": [],
  "direct_ip_version": "as_is"
}
EOF
    fi
}

# --- SOCKS5 入站 ---
db_get_socks_inbound() {
    jq -r '.socks_inbound // empty' "$SOCKS_DB" 2>/dev/null
}

db_set_socks_inbound() {
    local json="$1"
    local tmp=$(mktemp)
    jq --argjson val "$json" '.socks_inbound = $val' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
}

db_del_socks_inbound() {
    local tmp=$(mktemp)
    jq '.socks_inbound = null' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
}

# --- 链式代理节点 ---
db_get_nodes() {
    jq -c '.chain_nodes // []' "$SOCKS_DB" 2>/dev/null
}

db_get_node() {
    local name="$1"
    jq -c --arg n "$name" '.chain_nodes[] | select(.name == $n)' "$SOCKS_DB" 2>/dev/null
}

db_add_node() {
    local node_json="$1"
    local name=$(echo "$node_json" | jq -r '.name')
    # 删除同名旧节点
    local tmp=$(mktemp)
    jq --arg n "$name" '.chain_nodes = [.chain_nodes[]? | select(.name != $n)]' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
    # 添加新节点
    tmp=$(mktemp)
    jq --argjson node "$node_json" '.chain_nodes += [$node]' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
}

db_del_node() {
    local name="$1"
    local tmp=$(mktemp)
    jq --arg n "$name" '.chain_nodes = [.chain_nodes[]? | select(.name != $n)]' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
}

db_clear_nodes() {
    local tmp=$(mktemp)
    jq '.chain_nodes = []' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
}

# --- 分流规则 ---
db_get_rules() {
    jq -c '.routing_rules // []' "$SOCKS_DB" 2>/dev/null
}

db_add_rule() {
    local rule_type="$1" outbound="$2" domains="${3:-}" ip_version="${4:-as_is}"
    local id=$(date +%s%N | tail -c 10)
    local tmp=$(mktemp)
    jq --arg type "$rule_type" --arg out "$outbound" --arg dom "$domains" \
       --arg ipv "$ip_version" --arg id "$id" \
       '.routing_rules += [{id:$id, type:$type, outbound:$out, domains:$dom, ip_version:$ipv}]' \
       "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
}

db_del_rule() {
    local id="$1"
    local tmp=$(mktemp)
    jq --arg id "$id" '.routing_rules = [.routing_rules[]? | select(.id != $id)]' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
}

db_clear_rules() {
    local tmp=$(mktemp)
    jq '.routing_rules = []' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
}

# --- 负载均衡组 ---
db_get_balancer_groups() {
    jq -c '.balancer_groups // []' "$SOCKS_DB" 2>/dev/null
}

db_add_balancer_group() {
    local group_json="$1"
    local name=$(echo "$group_json" | jq -r '.name')
    local tmp=$(mktemp)
    # 删除同名旧组
    jq --arg n "$name" '.balancer_groups = [.balancer_groups[]? | select(.name != $n)]' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
    tmp=$(mktemp)
    jq --argjson g "$group_json" '.balancer_groups += [$g]' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
}

db_del_balancer_group() {
    local name="$1"
    local tmp=$(mktemp)
    jq --arg n "$name" '.balancer_groups = [.balancer_groups[]? | select(.name != $n)]' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
}

# ============================================================
# Xray 安装
# ============================================================

install_xray() {
    if [[ -f "$XRAY_BIN" ]]; then
        local ver=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')
        print_ok "Xray 已安装 (v${ver})"
        return 0
    fi

    print_info "安装 Xray..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>&1 | tail -5

    if [[ ! -f "$XRAY_BIN" ]]; then
        print_err "Xray 安装失败"
        return 1
    fi

    local ver=$("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}')
    print_ok "Xray v${ver} 安装完成"
}

# ============================================================
# 分享链接解析
# ============================================================

parse_share_link() {
    local link="$1"
    
    if [[ "$link" =~ ^socks5?:// ]]; then
        _parse_socks_link "$link"
    elif [[ "$link" =~ ^ss:// ]]; then
        _parse_ss_link "$link"
    elif [[ "$link" =~ ^vmess:// ]]; then
        _parse_vmess_link "$link"
    elif [[ "$link" =~ ^vless:// ]]; then
        _parse_vless_link "$link"
    elif [[ "$link" =~ ^trojan:// ]]; then
        _parse_trojan_link "$link"
    else
        echo ""
    fi
}

_parse_socks_link() {
    local link="$1"
    # socks5://user:pass@host:port#name
    local body="${link#*://}"
    local name="${body##*#}"
    body="${body%%#*}"
    
    local userinfo="" hostport=""
    if [[ "$body" == *@* ]]; then
        userinfo="${body%%@*}"
        hostport="${body#*@}"
    else
        hostport="$body"
    fi
    
    local host port username="" password=""
    # 处理 IPv6 地址 [::1]:port
    if [[ "$hostport" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="${hostport%%:*}"
        port="${hostport##*:}"
    fi
    
    if [[ -n "$userinfo" ]]; then
        username="${userinfo%%:*}"
        password="${userinfo#*:}"
    fi
    
    [[ -z "$name" || "$name" == "$body" ]] && name="SOCKS5-${host}"
    
    jq -n --arg name "$name" --arg server "$host" --argjson port "$port" \
        --arg username "$username" --arg password "$password" \
        '{name:$name, type:"socks", server:$server, port:$port, username:$username, password:$password}'
}

_parse_ss_link() {
    local link="$1"
    local body="${link#ss://}"
    local name="${body##*#}"
    body="${body%%#*}"
    
    local decoded=""
    if [[ "$body" == *@* ]]; then
        # 新格式: method:password@host:port
        local userinfo="${body%%@*}"
        local hostport="${body#*@}"
        decoded=$(echo "$userinfo" | base64 -d 2>/dev/null || echo "$userinfo")
        local method="${decoded%%:*}"
        local password="${decoded#*:}"
        local host="${hostport%%:*}"
        local port="${hostport##*:}"
    else
        decoded=$(echo "$body" | base64 -d 2>/dev/null)
        local method="${decoded%%:*}"
        local rest="${decoded#*:}"
        local password="${rest%%@*}"
        local hostport="${rest#*@}"
        local host="${hostport%%:*}"
        local port="${hostport##*:}"
    fi
    
    [[ -z "$name" || "$name" == "$body" ]] && name="SS-${host}"
    
    jq -n --arg name "$name" --arg server "$host" --argjson port "${port:-0}" \
        --arg method "$method" --arg password "$password" \
        '{name:$name, type:"shadowsocks", server:$server, port:$port, method:$method, password:$password}'
}

_parse_vmess_link() {
    local link="$1"
    local body="${link#vmess://}"
    local decoded=$(echo "$body" | base64 -d 2>/dev/null)
    [[ -z "$decoded" ]] && return
    
    local name=$(echo "$decoded" | jq -r '.ps // "VMess"')
    local server=$(echo "$decoded" | jq -r '.add')
    local port=$(echo "$decoded" | jq -r '.port')
    local uuid=$(echo "$decoded" | jq -r '.id')
    local aid=$(echo "$decoded" | jq -r '.aid // 0')
    local net=$(echo "$decoded" | jq -r '.net // "tcp"')
    local tls=$(echo "$decoded" | jq -r '.tls // ""')
    local path=$(echo "$decoded" | jq -r '.path // "/"')
    local host=$(echo "$decoded" | jq -r '.host // ""')
    
    jq -n --arg name "$name" --arg server "$server" --argjson port "${port:-0}" \
        --arg uuid "$uuid" --argjson aid "${aid:-0}" --arg network "$net" \
        --arg tls "$tls" --arg wsPath "$path" --arg wsHost "$host" \
        '{name:$name, type:"vmess", server:$server, port:$port, uuid:$uuid, alterId:$aid, network:$network, tls:$tls, wsPath:$wsPath, wsHost:$wsHost}'
}

_parse_vless_link() {
    local link="$1"
    local body="${link#vless://}"
    local name="${body##*#}"
    name=$(python3 -c "import urllib.parse; print(urllib.parse.unquote('$name'))" 2>/dev/null || echo "$name")
    body="${body%%#*}"
    
    local uuid="${body%%@*}"
    local rest="${body#*@}"
    local hostport="${rest%%\?*}"
    local params="${rest#*\?}"
    
    local host port
    if [[ "$hostport" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="${hostport%%:*}"
        port="${hostport##*:}"
    fi
    
    # 解析参数
    local security="" sni="" fp="" pbk="" sid="" flow="" net="" path="" serviceName=""
    while IFS='=' read -r key val; do
        case "$key" in
            security) security="$val" ;;
            sni) sni="$val" ;;
            fp) fp="$val" ;;
            pbk) pbk="$val" ;;
            sid) sid="$val" ;;
            flow) flow="$val" ;;
            type) net="$val" ;;
            path) path="$val" ;;
            serviceName) serviceName="$val" ;;
        esac
    done < <(echo "$params" | tr '&' '\n')
    
    [[ -z "$name" || "$name" == "$body" ]] && name="VLESS-${host}"
    
    jq -n --arg name "$name" --arg server "$host" --argjson port "${port:-0}" \
        --arg uuid "$uuid" --arg security "${security:-none}" --arg sni "$sni" \
        --arg fp "${fp:-chrome}" --arg pbk "$pbk" --arg sid "$sid" \
        --arg flow "$flow" --arg network "${net:-tcp}" --arg path "$path" \
        '{name:$name, type:"vless", server:$server, port:$port, uuid:$uuid, security:$security, sni:$sni, fingerprint:$fp, publicKey:$pbk, shortId:$sid, flow:$flow, network:$network, wsPath:$path}'
}

_parse_trojan_link() {
    local link="$1"
    local body="${link#trojan://}"
    local name="${body##*#}"
    name=$(python3 -c "import urllib.parse; print(urllib.parse.unquote('$name'))" 2>/dev/null || echo "$name")
    body="${body%%#*}"
    
    local password="${body%%@*}"
    local rest="${body#*@}"
    local hostport="${rest%%\?*}"
    
    local host port
    if [[ "$hostport" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="${hostport%%:*}"
        port="${hostport##*:}"
    fi
    
    [[ -z "$name" || "$name" == "$body" ]] && name="Trojan-${host}"
    
    jq -n --arg name "$name" --arg server "$host" --argjson port "${port:-0}" \
        --arg password "$password" \
        '{name:$name, type:"trojan", server:$server, port:$port, password:$password}'
}

# ============================================================
# Xray 配置生成
# ============================================================

# 生成 Xray outbound JSON (链式代理出站)
gen_xray_outbound() {
    local node_json="$1" tag="${2:-proxy}"
    
    local type=$(echo "$node_json" | jq -r '.type')
    local server=$(echo "$node_json" | jq -r '.server')
    local port=$(echo "$node_json" | jq -r '.port')
    port=$(echo "$port" | tr -d '"' | tr -d ' ')
    
    case "$type" in
        socks)
            local username=$(echo "$node_json" | jq -r '.username // ""')
            local password=$(echo "$node_json" | jq -r '.password // ""')
            if [[ -n "$username" && -n "$password" ]]; then
                jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                    --arg user "$username" --arg pass "$password" \
                    '{tag:$tag,protocol:"socks",settings:{servers:[{address:$server,port:$port,users:[{user:$user,pass:$pass}]}]}}'
            else
                jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                    '{tag:$tag,protocol:"socks",settings:{servers:[{address:$server,port:$port}]}}'
            fi
            ;;
        shadowsocks)
            local method=$(echo "$node_json" | jq -r '.method')
            local password=$(echo "$node_json" | jq -r '.password')
            jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                --arg method "$method" --arg password "$password" \
                '{tag:$tag,protocol:"shadowsocks",settings:{servers:[{address:$server,port:$port,method:$method,password:$password}]}}'
            ;;
        vmess)
            local uuid=$(echo "$node_json" | jq -r '.uuid')
            local aid=$(echo "$node_json" | jq -r '.alterId // 0')
            local net=$(echo "$node_json" | jq -r '.network // "tcp"')
            local tls=$(echo "$node_json" | jq -r '.tls // ""')
            local path=$(echo "$node_json" | jq -r '.wsPath // "/"')
            local wshost=$(echo "$node_json" | jq -r '.wsHost // ""')
            
            local stream='{"network":"tcp"}'
            [[ "$net" == "ws" ]] && stream=$(jq -n --arg path "$path" --arg host "$wshost" \
                '{network:"ws",wsSettings:{path:$path,headers:{Host:$host}}}')
            [[ "$tls" == "tls" ]] && stream=$(echo "$stream" | jq --arg sni "$server" '.security="tls"|.tlsSettings={serverName:$sni}')
            
            jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                --arg uuid "$uuid" --argjson aid "${aid:-0}" --argjson stream "$stream" \
                '{tag:$tag,protocol:"vmess",settings:{vnext:[{address:$server,port:$port,users:[{id:$uuid,alterId:$aid}]}]},streamSettings:$stream}'
            ;;
        vless)
            local uuid=$(echo "$node_json" | jq -r '.uuid')
            local security=$(echo "$node_json" | jq -r '.security // "none"')
            local sni=$(echo "$node_json" | jq -r '.sni // ""')
            local fp=$(echo "$node_json" | jq -r '.fingerprint // "chrome"')
            local pbk=$(echo "$node_json" | jq -r '.publicKey // ""')
            local sid=$(echo "$node_json" | jq -r '.shortId // ""')
            local flow=$(echo "$node_json" | jq -r '.flow // ""')
            local net=$(echo "$node_json" | jq -r '.network // "tcp"')
            local path=$(echo "$node_json" | jq -r '.wsPath // "/"')
            
            local vnext=$(jq -n --arg server "$server" --argjson port "$port" \
                --arg uuid "$uuid" --arg flow "$flow" \
                '{address:$server,port:$port,users:[{id:$uuid,encryption:"none",flow:$flow}]}')
            
            local stream='{"network":"tcp"}'
            if [[ "$security" == "reality" ]]; then
                stream=$(jq -n --arg sni "$sni" --arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" \
                    '{network:"tcp",security:"reality",realitySettings:{serverName:$sni,fingerprint:$fp,publicKey:$pbk,shortId:$sid}}')
            elif [[ "$security" == "tls" ]]; then
                stream=$(jq -n --arg sni "$sni" --arg fp "$fp" \
                    '{network:"tcp",security:"tls",tlsSettings:{serverName:$sni,fingerprint:$fp}}')
            fi
            if [[ "$net" == "ws" ]]; then
                stream=$(echo "$stream" | jq --arg path "$path" '.network="ws"|.wsSettings={path:$path}')
            fi
            
            jq -n --arg tag "$tag" --argjson vnext "$vnext" --argjson stream "$stream" \
                '{tag:$tag,protocol:"vless",settings:{vnext:[$vnext]},streamSettings:$stream}'
            ;;
        trojan)
            local password=$(echo "$node_json" | jq -r '.password')
            jq -n --arg tag "$tag" --arg server "$server" --argjson port "$port" \
                --arg password "$password" \
                '{tag:$tag,protocol:"trojan",settings:{servers:[{address:$server,port:$port,password:$password}]},streamSettings:{network:"tcp",security:"tls",tlsSettings:{serverName:$server}}}'
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# 预设路由规则域名
declare -A ROUTING_DOMAINS
ROUTING_DOMAINS=(
    ["openai"]="openai.com,chatgpt.com,oaiusercontent.com,oaistatic.com,auth0.com,intercom.io,sentry.io,challenges.cloudflare.com"
    ["netflix"]="netflix.com,netflix.net,nflximg.com,nflximg.net,nflxvideo.net,nflxso.net,nflxext.com"
    ["disney"]="disney.com,disneyplus.com,dssott.com,bamgrid.com,disney-plus.net,disneystreaming.com"
    ["youtube"]="youtube.com,googlevideo.com,ytimg.com,yt.be,youtube-nocookie.com,youtu.be"
    ["spotify"]="spotify.com,spotifycdn.com,scdn.co,spotify.design"
    ["tiktok"]="tiktok.com,tiktokv.com,tiktokcdn.com,musical.ly,byteoversea.com,ibytedtos.com"
    ["telegram"]="telegram.org,t.me,telegram.me,telesco.pe,tdesktop.com,telegra.ph"
    ["google"]="google.com,googleapis.com,gstatic.com,google.co,google.com.hk,google.co.jp"
    ["mytvsuper"]="mytvsuper.com,tvb.com"
)

declare -A ROUTING_NAMES
ROUTING_NAMES=(
    ["openai"]="OpenAI/ChatGPT"
    ["netflix"]="Netflix"
    ["disney"]="Disney+"
    ["youtube"]="YouTube"
    ["spotify"]="Spotify"
    ["tiktok"]="TikTok"
    ["telegram"]="Telegram"
    ["google"]="Google"
    ["mytvsuper"]="MyTVSuper"
    ["all"]="所有流量"
    ["custom"]="自定义"
)

# 生成完整的 Xray 配置
generate_xray_config() {
    local socks_inbound=$(db_get_socks_inbound)
    if [[ -z "$socks_inbound" || "$socks_inbound" == "null" ]]; then
        print_warn "未配置 SOCKS5 入站，跳过"
        return 1
    fi
    
    local port=$(echo "$socks_inbound" | jq -r '.port')
    local username=$(echo "$socks_inbound" | jq -r '.username // ""')
    local password=$(echo "$socks_inbound" | jq -r '.password // ""')
    local auth_mode=$(echo "$socks_inbound" | jq -r '.auth_mode // "password"')
    local listen_addr=$(echo "$socks_inbound" | jq -r '.listen // "0.0.0.0"')
    
    # === 入站 ===
    local inbound=""
    if [[ "$auth_mode" == "noauth" ]]; then
        inbound=$(jq -n --argjson port "$port" --arg listen "$listen_addr" \
            '{port:$port, listen:$listen, protocol:"socks", settings:{auth:"noauth",udp:true}, tag:"socks-in"}')
    else
        inbound=$(jq -n --argjson port "$port" --arg listen "$listen_addr" \
            --arg user "$username" --arg pass "$password" \
            '{port:$port, listen:$listen, protocol:"socks", settings:{auth:"password",udp:true,accounts:[{user:$user,pass:$pass}]}, tag:"socks-in"}')
    fi
    
    # === 出站 ===
    local outbounds='[{"tag":"direct","protocol":"freedom","settings":{}}]'
    local nodes=$(db_get_nodes)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    
    # 为每个节点生成出站
    if [[ "$node_count" -gt 0 ]]; then
        while IFS= read -r node; do
            local name=$(echo "$node" | jq -r '.name')
            local tag="chain-${name}"
            local out=$(gen_xray_outbound "$node" "$tag")
            if [[ -n "$out" ]]; then
                outbounds=$(echo "$outbounds" | jq --argjson o "$out" '. += [$o]')
            fi
            
            # 为 prefer_ipv4 生成额外出站
            local tag_v4="chain-${name}-prefer-ipv4"
            local out_v4=$(gen_xray_outbound "$node" "$tag_v4")
            if [[ -n "$out_v4" ]]; then
                out_v4=$(echo "$out_v4" | jq '.settings.domainStrategy = "UseIPv4"')
                outbounds=$(echo "$outbounds" | jq --argjson o "$out_v4" '. += [$o]')
            fi
        done < <(echo "$nodes" | jq -c '.[]')
    fi
    
    # 负载均衡组的 outbound (observatory 配合)
    local balancer_groups=$(db_get_balancer_groups)
    local balancer_count=$(echo "$balancer_groups" | jq 'length' 2>/dev/null || echo 0)
    
    # === 路由规则 ===
    local routing_rules='[]'
    local rules=$(db_get_rules)
    local rule_count=$(echo "$rules" | jq 'length' 2>/dev/null || echo 0)
    
    if [[ "$rule_count" -gt 0 ]]; then
        while IFS= read -r rule; do
            local rule_type=$(echo "$rule" | jq -r '.type')
            local outbound=$(echo "$rule" | jq -r '.outbound')
            local domains=$(echo "$rule" | jq -r '.domains // ""')
            
            # 确定出站 tag
            local out_tag="direct"
            if [[ "$outbound" == "direct" ]]; then
                out_tag="direct"
            elif [[ "$outbound" == chain:* ]]; then
                local node_name="${outbound#chain:}"
                out_tag="chain-${node_name}-prefer-ipv4"
            elif [[ "$outbound" == balancer:* ]]; then
                # 负载均衡处理
                local group_name="${outbound#balancer:}"
                out_tag="balancer-${group_name}"
            fi
            
            # 获取域名列表
            local domain_list=""
            if [[ "$rule_type" == "custom" && -n "$domains" ]]; then
                domain_list="$domains"
            elif [[ "$rule_type" == "all" ]]; then
                # 全局规则, 在最后作为 catch-all
                :
            elif [[ -n "${ROUTING_DOMAINS[$rule_type]}" ]]; then
                domain_list="${ROUTING_DOMAINS[$rule_type]}"
            fi
            
            if [[ "$rule_type" == "all" ]]; then
                # 全局匹配 - 匹配所有流量
                routing_rules=$(echo "$routing_rules" | jq --arg tag "$out_tag" \
                    '. += [{"type":"field","network":"tcp,udp","outboundTag":$tag}]')
            elif [[ -n "$domain_list" ]]; then
                # 拆分为域名数组
                local domains_json=$(echo "$domain_list" | tr ',' '\n' | jq -R . | jq -s .)
                
                # 区分 geosite/geoip/普通域名
                local geosite_arr=$(echo "$domains_json" | jq '[.[] | select(startswith("geosite:"))]')
                local geoip_arr=$(echo "$domains_json" | jq '[.[] | select(startswith("geoip:"))]')
                local domain_arr=$(echo "$domains_json" | jq '[.[] | select((startswith("geosite:") or startswith("geoip:")) | not)]')
                
                # 普通域名/geosite 规则
                local combined=$(echo "$domain_arr" | jq --argjson gs "$geosite_arr" '. + $gs')
                if [[ $(echo "$combined" | jq 'length') -gt 0 ]]; then
                    routing_rules=$(echo "$routing_rules" | jq --arg tag "$out_tag" --argjson domains "$combined" \
                        '. += [{"type":"field","domain":$domains,"outboundTag":$tag}]')
                fi
                
                # geoip 规则
                if [[ $(echo "$geoip_arr" | jq 'length') -gt 0 ]]; then
                    routing_rules=$(echo "$routing_rules" | jq --arg tag "$out_tag" --argjson ips "$geoip_arr" \
                        '. += [{"type":"field","ip":$ips,"outboundTag":$tag}]')
                fi
            fi
        done < <(echo "$rules" | jq -c '.[]')
    fi
    
    # === 负载均衡 ===
    local balancers='[]'
    if [[ "$balancer_count" -gt 0 ]]; then
        while IFS= read -r group; do
            local group_name=$(echo "$group" | jq -r '.name')
            local strategy=$(echo "$group" | jq -r '.strategy // "random"')
            local group_nodes=$(echo "$group" | jq -r '.nodes')
            
            # 生成 selector
            local selectors='[]'
            while IFS= read -r n; do
                selectors=$(echo "$selectors" | jq --arg s "chain-${n}" '. += [$s]')
            done < <(echo "$group_nodes" | jq -r '.[]')
            
            balancers=$(echo "$balancers" | jq --arg tag "balancer-${group_name}" \
                --arg strategy "$strategy" --argjson sel "$selectors" \
                '. += [{"tag":$tag,"selector":$sel,"strategy":{"type":$strategy}}]')
            
            # 对应的 outbound (freedom tag 占位)
            # Xray 的 balancer 不需要额外 outbound, 路由中直接 balancerTag
        done < <(echo "$balancer_groups" | jq -c '.[]')
        
        # 修正路由规则 — 将 balancer 类型的 outboundTag 改为 balancerTag
        local tmp_rules='[]'
        while IFS= read -r r; do
            local tag=$(echo "$r" | jq -r '.outboundTag // ""')
            if [[ "$tag" == balancer-* ]]; then
                r=$(echo "$r" | jq --arg bt "$tag" 'del(.outboundTag) | .balancerTag = $bt')
            fi
            tmp_rules=$(echo "$tmp_rules" | jq --argjson rule "$r" '. += [$rule]')
        done < <(echo "$routing_rules" | jq -c '.[]')
        routing_rules="$tmp_rules"
    fi
    
    # === 组装完整配置 ===
    local config=""
    if [[ $(echo "$balancers" | jq 'length') -gt 0 ]]; then
        config=$(jq -n \
            --argjson inbound "$inbound" \
            --argjson outbounds "$outbounds" \
            --argjson rules "$routing_rules" \
            --argjson balancers "$balancers" \
            '{
                log: {loglevel:"warning"},
                inbounds: [$inbound],
                outbounds: $outbounds,
                routing: {domainStrategy:"AsIs", rules: $rules, balancers: $balancers}
            }')
    else
        config=$(jq -n \
            --argjson inbound "$inbound" \
            --argjson outbounds "$outbounds" \
            --argjson rules "$routing_rules" \
            '{
                log: {loglevel:"warning"},
                inbounds: [$inbound],
                outbounds: $outbounds,
                routing: {domainStrategy:"AsIs", rules: $rules}
            }')
    fi
    
    echo "$config" | jq . > "$XRAY_CONFIG"
    print_ok "Xray 配置已生成: $XRAY_CONFIG"
}

# ============================================================
# systemd 服务管理
# ============================================================

create_service() {
    cat > /etc/systemd/system/${SOCKS_SERVICE}.service <<EOF
[Unit]
Description=Xray SOCKS5 Routing Service
After=network.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c ${XRAY_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

svc_start() {
    create_service
    systemctl enable ${SOCKS_SERVICE} >/dev/null 2>&1
    systemctl restart ${SOCKS_SERVICE}
    sleep 1
    if systemctl is-active --quiet ${SOCKS_SERVICE}; then
        print_ok "服务已启动"
    else
        print_err "服务启动失败，查看日志: journalctl -u ${SOCKS_SERVICE} -n 20"
    fi
}

svc_stop() {
    systemctl stop ${SOCKS_SERVICE} 2>/dev/null
    systemctl disable ${SOCKS_SERVICE} 2>/dev/null
    print_ok "服务已停止"
}

svc_restart() {
    create_service
    systemctl restart ${SOCKS_SERVICE}
    sleep 1
    if systemctl is-active --quiet ${SOCKS_SERVICE}; then
        print_ok "服务已重启"
    else
        print_err "服务重启失败"
    fi
}

svc_status() {
    if systemctl is-active --quiet ${SOCKS_SERVICE} 2>/dev/null; then
        return 0
    fi
    return 1
}

# ============================================================
# 交互菜单函数
# ============================================================

# --- 安装 SOCKS5 入站 ---
setup_socks_inbound() {
    echo ""
    print_dline
    echo -e "${BOLD}  📡 配置 SOCKS5 入站${PLAIN}"
    print_dline
    echo ""
    
    local existing=$(db_get_socks_inbound)
    if [[ -n "$existing" && "$existing" != "null" ]]; then
        local ex_port=$(echo "$existing" | jq -r '.port')
        local ex_auth=$(echo "$existing" | jq -r '.auth_mode // "password"')
        print_warn "已存在 SOCKS5 入站配置 (端口: ${ex_port}, 认证: ${ex_auth})"
        read -rp "  是否重新配置? [y/N]: " redo
        [[ ! "$redo" =~ ^[Yy]$ ]] && return
    fi
    
    # 端口
    local default_port=$(gen_port)
    read -rp "  SOCKS5 端口 [${default_port}]: " port
    port=${port:-$default_port}
    
    # 认证模式
    echo ""
    print_line
    echo -e "  ${BOLD}认证设置${PLAIN}"
    print_line
    echo -e "  ${GREEN}1.${PLAIN} 用户名密码认证 ${GRAY}(推荐)${PLAIN}"
    echo -e "  ${GREEN}2.${PLAIN} 无认证 ${GRAY}(需限制监听地址)${PLAIN}"
    echo ""
    read -rp "  选择 [1]: " auth_choice
    
    local auth_mode="password" username="" password="" listen_addr="0.0.0.0"
    
    if [[ "$auth_choice" == "2" ]]; then
        auth_mode="noauth"
        read -rp "  监听地址 [127.0.0.1]: " listen_addr
        listen_addr=${listen_addr:-127.0.0.1}
    else
        local default_user=$(gen_password 8)
        local default_pass=$(gen_password 16)
        read -rp "  用户名 [${default_user}]: " username
        username=${username:-$default_user}
        read -rp "  密码 [${default_pass}]: " password
        password=${password:-$default_pass}
    fi
    
    # 保存配置
    local inbound_json=$(jq -n --argjson port "$port" --arg user "$username" \
        --arg pass "$password" --arg auth "$auth_mode" --arg listen "$listen_addr" \
        '{port:$port, username:$user, password:$pass, auth_mode:$auth, listen:$listen}')
    
    db_set_socks_inbound "$inbound_json"
    
    echo ""
    print_line
    echo -e "  ${BOLD}SOCKS5 入站配置${PLAIN}"
    print_line
    echo -e "  端口:     ${GREEN}${port}${PLAIN}"
    echo -e "  监听:     ${GREEN}${listen_addr}${PLAIN}"
    if [[ "$auth_mode" == "password" ]]; then
        echo -e "  用户名:   ${GREEN}${username}${PLAIN}"
        echo -e "  密码:     ${GREEN}${password}${PLAIN}"
    else
        echo -e "  认证:     ${GRAY}无认证${PLAIN}"
    fi
    print_line
    
    # 安装 Xray
    install_xray || return 1
    
    # 生成配置并启动
    generate_xray_config
    svc_start
    
    # 防火墙
    if command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
        iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT
    fi
    
    # 显示连接信息
    echo ""
    local ipv4=$(get_ipv4)
    print_ok "SOCKS5 服务已就绪"
    echo ""
    echo -e "  ${CYAN}连接信息:${PLAIN}"
    if [[ "$auth_mode" == "password" ]]; then
        echo -e "  socks5://${username}:${password}@${ipv4}:${port}#SOCKS5"
    else
        echo -e "  SOCKS5 ${ipv4}:${port} (无认证)"
    fi
    echo ""
}

# --- 添加链式代理节点 ---
add_chain_node() {
    echo ""
    print_dline
    echo -e "${BOLD}  🔗 添加链式代理节点${PLAIN}"
    print_dline
    echo ""
    echo -e "  ${GRAY}支持: socks5://, ss://, vmess://, vless://, trojan://${PLAIN}"
    echo ""
    
    read -rp "  分享链接: " link
    if [[ -z "$link" ]]; then
        print_err "链接不能为空"
        return
    fi
    
    local node=$(parse_share_link "$link")
    if [[ -z "$node" || "$node" == "null" ]]; then
        print_err "无法解析分享链接"
        return
    fi
    
    local name=$(echo "$node" | jq -r '.name')
    local type=$(echo "$node" | jq -r '.type')
    local server=$(echo "$node" | jq -r '.server')
    local port=$(echo "$node" | jq -r '.port')
    
    db_add_node "$node"
    print_ok "节点已添加: ${name} (${type} @ ${server}:${port})"
    
    # 重新生成配置
    _reload_config
}

# --- 批量导入 Alice SOCKS5 节点 ---
import_alice_nodes() {
    echo ""
    print_dline
    echo -e "${BOLD}  🏠 导入 Alice SOCKS5 家宽节点${PLAIN}"
    print_dline
    echo ""
    echo -e "  ${GRAY}Alice 提供 8 个 SOCKS5 出口 (端口 10001-10008)${PLAIN}"
    echo ""
    
    # 清理旧节点
    local nodes=$(db_get_nodes)
    local deleted=0
    if [[ $(echo "$nodes" | jq 'length') -gt 0 ]]; then
        while IFS= read -r n; do
            if [[ "$n" =~ ^Alice-TW-SOCKS5- ]]; then
                db_del_node "$n"
                ((deleted++))
            fi
        done < <(echo "$nodes" | jq -r '.[].name')
        [[ $deleted -gt 0 ]] && echo -e "  ${CYAN}清理了 ${deleted} 个旧 Alice 节点${PLAIN}"
    fi
    
    local server="2a14:67c0:116::1"
    local username="alice"
    local password="alicefofo123..OVO"
    local imported=0
    
    for i in {1..8}; do
        local port=$((10000 + i))
        local name=$(printf "Alice-TW-SOCKS5-%02d" "$i")
        local node=$(jq -n --arg name "$name" --arg server "$server" \
            --argjson port "$port" --arg user "$username" --arg pass "$password" \
            '{name:$name,type:"socks",server:$server,port:$port,username:$user,password:$pass}')
        db_add_node "$node"
        echo -e "  ${GREEN}✓${PLAIN} ${name} (端口 ${port})"
        ((imported++))
    done
    
    print_ok "导入 ${imported} 个 Alice 节点"
    
    # 询问是否创建负载均衡组
    echo ""
    read -rp "  创建负载均衡组? [Y/n]: " create_lb
    if [[ ! "$create_lb" =~ ^[Nn]$ ]]; then
        local group_nodes='[]'
        for i in {1..8}; do
            local name=$(printf "Alice-TW-SOCKS5-%02d" "$i")
            group_nodes=$(echo "$group_nodes" | jq --arg n "$name" '. += [$n]')
        done
        local group=$(jq -n --arg name "Alice-TW-LB" --arg strategy "random" \
            --argjson nodes "$group_nodes" \
            '{name:$name, strategy:$strategy, nodes:$nodes}')
        db_add_balancer_group "$group"
        print_ok "负载均衡组 'Alice-TW-LB' 已创建 (随机策略)"
    fi
    
    _reload_config
}

# --- 配置分流规则 ---
setup_routing_rules() {
    while true; do
        echo ""
        print_dline
        echo -e "${BOLD}  🔀 分流规则管理${PLAIN}"
        print_dline
        
        # 显示当前规则
        _show_current_rules
        
        echo ""
        echo -e "  ${GREEN}1.${PLAIN} 添加分流规则"
        echo -e "  ${GREEN}2.${PLAIN} 删除分流规则"
        echo -e "  ${GREEN}3.${PLAIN} 清空所有规则"
        echo -e "  ${GREEN}4.${PLAIN} 测试分流效果"
        echo -e "  ${GRAY}0.${PLAIN} 返回"
        print_line
        
        read -rp "  请选择: " choice
        case "$choice" in
            1) _add_rule ;;
            2) _del_rule ;;
            3)
                read -rp "  确认清空所有分流规则? [y/N]: " confirm
                [[ "$confirm" =~ ^[Yy]$ ]] && { db_clear_rules; _reload_config; print_ok "已清空"; }
                ;;
            4) _test_routing ;;
            0) return ;;
        esac
    done
}

_show_current_rules() {
    local rules=$(db_get_rules)
    local count=$(echo "$rules" | jq 'length' 2>/dev/null || echo 0)
    
    echo ""
    echo -e "  ${CYAN}当前规则 (${count} 条)${PLAIN}"
    print_line
    
    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${GRAY}暂无分流规则 (所有流量直连)${PLAIN}"
        return
    fi
    
    local idx=1
    while IFS= read -r rule; do
        local rule_type=$(echo "$rule" | jq -r '.type')
        local outbound=$(echo "$rule" | jq -r '.outbound')
        local domains=$(echo "$rule" | jq -r '.domains // ""')
        
        local name="${ROUTING_NAMES[$rule_type]:-$rule_type}"
        [[ "$rule_type" == "custom" && -n "$domains" ]] && name="自定义(${domains:0:20})"
        
        local out_name="直连"
        if [[ "$outbound" == chain:* ]]; then
            out_name="${outbound#chain:}"
        elif [[ "$outbound" == balancer:* ]]; then
            out_name="${outbound#balancer:} (负载均衡)"
        fi
        
        echo -e "  ${GREEN}${idx}.${PLAIN} ${name} → ${CYAN}${out_name}${PLAIN}"
        ((idx++))
    done < <(echo "$rules" | jq -c '.[]')
    print_line
}

_add_rule() {
    echo ""
    print_line
    echo -e "  ${BOLD}选择规则类型${PLAIN}"
    print_line
    echo -e "  ${GREEN}1.${PLAIN} OpenAI/ChatGPT"
    echo -e "  ${GREEN}2.${PLAIN} Netflix"
    echo -e "  ${GREEN}3.${PLAIN} Disney+"
    echo -e "  ${GREEN}4.${PLAIN} YouTube"
    echo -e "  ${GREEN}5.${PLAIN} Spotify"
    echo -e "  ${GREEN}6.${PLAIN} TikTok"
    echo -e "  ${GREEN}7.${PLAIN} Telegram"
    echo -e "  ${GREEN}8.${PLAIN} Google"
    echo -e "  ${GREEN}9.${PLAIN} MyTVSuper"
    echo -e "  ${GREEN}c.${PLAIN} 自定义域名"
    echo -e "  ${GREEN}a.${PLAIN} 所有流量"
    echo -e "  ${GRAY}0.${PLAIN} 返回"
    print_line
    
    read -rp "  选择: " rule_choice
    
    local rule_type="" custom_domains=""
    case "$rule_choice" in
        1) rule_type="openai" ;;
        2) rule_type="netflix" ;;
        3) rule_type="disney" ;;
        4) rule_type="youtube" ;;
        5) rule_type="spotify" ;;
        6) rule_type="tiktok" ;;
        7) rule_type="telegram" ;;
        8) rule_type="google" ;;
        9) rule_type="mytvsuper" ;;
        c|C)
            rule_type="custom"
            echo -e "  ${GRAY}示例: google.com,youtube.com 或 geosite:netflix${PLAIN}"
            read -rp "  匹配规则 (逗号分隔): " custom_domains
            [[ -z "$custom_domains" ]] && return
            ;;
        a|A) rule_type="all" ;;
        0|"") return ;;
        *) print_warn "无效选项"; return ;;
    esac
    
    # 选择出口
    echo ""
    local outbound=$(_select_outbound)
    [[ -z "$outbound" ]] && return
    
    db_add_rule "$rule_type" "$outbound" "$custom_domains"
    
    local name="${ROUTING_NAMES[$rule_type]:-$rule_type}"
    print_ok "已添加: ${name} → ${outbound}"
    
    _reload_config
}

_select_outbound() {
    print_line
    echo -e "  ${BOLD}选择出口${PLAIN}"
    print_line
    
    local outbounds=()
    local display=()
    
    # 直连
    outbounds+=("direct")
    display+=("DIRECT (直连)")
    
    # 链式代理节点
    local nodes=$(db_get_nodes)
    local count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$count" -gt 0 ]]; then
        while IFS=$'\t' read -r name type server; do
            outbounds+=("chain:${name}")
            display+=("${name} (${type} @ ${server})")
        done < <(echo "$nodes" | jq -r '.[] | [.name,.type,.server] | @tsv')
    fi
    
    # 负载均衡组
    local groups=$(db_get_balancer_groups)
    local gcount=$(echo "$groups" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$gcount" -gt 0 ]]; then
        while IFS=$'\t' read -r name strategy node_cnt; do
            outbounds+=("balancer:${name}")
            display+=("${name} (负载均衡/${strategy}/${node_cnt}节点)")
        done < <(echo "$groups" | jq -r '.[] | [.name, .strategy, (.nodes|length|tostring)] | @tsv')
    fi
    
    local idx=1
    for d in "${display[@]}"; do
        echo -e "  ${GREEN}${idx}.${PLAIN} ${d}"
        ((idx++))
    done
    echo -e "  ${GRAY}0.${PLAIN} 取消"
    print_line
    
    read -rp "  选择: " sel
    if [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 1 && "$sel" -le ${#outbounds[@]} ]]; then
        echo "${outbounds[$((sel-1))]}"
    fi
}

_del_rule() {
    local rules=$(db_get_rules)
    local count=$(echo "$rules" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && { print_warn "没有规则"; return; }
    
    _show_current_rules
    read -rp "  删除第几条 [1-${count}]: " idx
    
    if [[ "$idx" =~ ^[0-9]+$ && "$idx" -ge 1 && "$idx" -le "$count" ]]; then
        local rule_id=$(echo "$rules" | jq -r ".[$((idx-1))].id")
        db_del_rule "$rule_id"
        print_ok "已删除"
        _reload_config
    fi
}

_test_routing() {
    echo ""
    print_line
    echo -e "  ${BOLD}测试分流效果${PLAIN}"
    print_line
    
    local socks_inbound=$(db_get_socks_inbound)
    if [[ -z "$socks_inbound" || "$socks_inbound" == "null" ]]; then
        print_warn "未配置 SOCKS5 入站"
        return
    fi
    
    if ! svc_status; then
        print_warn "服务未运行"
        return
    fi
    
    local port=$(echo "$socks_inbound" | jq -r '.port')
    local username=$(echo "$socks_inbound" | jq -r '.username // ""')
    local password=$(echo "$socks_inbound" | jq -r '.password // ""')
    local auth_mode=$(echo "$socks_inbound" | jq -r '.auth_mode // "password"')
    
    local proxy_opt=""
    if [[ "$auth_mode" == "password" && -n "$username" ]]; then
        proxy_opt="socks5://${username}:${password}@127.0.0.1:${port}"
    else
        proxy_opt="socks5://127.0.0.1:${port}"
    fi
    
    local sites=("https://api.ipify.org" "https://chatgpt.com" "https://www.netflix.com" "https://www.youtube.com" "https://www.google.com")
    local names=("出口IP" "ChatGPT" "Netflix" "YouTube" "Google")
    
    for i in "${!sites[@]}"; do
        local result=$(curl -s --max-time 5 -x "$proxy_opt" "${sites[$i]}" 2>/dev/null)
        local code=$?
        if [[ $code -eq 0 && -n "$result" ]]; then
            if [[ "${names[$i]}" == "出口IP" ]]; then
                echo -e "  ${GREEN}✓${PLAIN} ${names[$i]}: ${CYAN}${result}${PLAIN}"
            else
                echo -e "  ${GREEN}✓${PLAIN} ${names[$i]}: 可访问"
            fi
        else
            echo -e "  ${RED}✗${PLAIN} ${names[$i]}: 不可访问"
        fi
    done
    print_line
}

# 重载配置
_reload_config() {
    local socks_inbound=$(db_get_socks_inbound)
    if [[ -z "$socks_inbound" || "$socks_inbound" == "null" ]]; then
        return
    fi
    generate_xray_config
    if svc_status; then
        svc_restart
    fi
}

# --- 查看节点 ---
show_nodes() {
    echo ""
    print_dline
    echo -e "${BOLD}  📋 链式代理节点${PLAIN}"
    print_dline
    
    local nodes=$(db_get_nodes)
    local count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    
    if [[ "$count" -eq 0 ]]; then
        echo -e "  ${GRAY}暂无节点${PLAIN}"
        return
    fi
    
    local idx=1
    while IFS=$'\t' read -r name type server port; do
        echo -e "  ${GREEN}${idx}.${PLAIN} ${name} ${GRAY}(${type} @ ${server}:${port})${PLAIN}"
        ((idx++))
    done < <(echo "$nodes" | jq -r '.[] | [.name,.type,.server,(.port|tostring)] | @tsv')
    
    # 负载均衡组
    local groups=$(db_get_balancer_groups)
    local gcount=$(echo "$groups" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$gcount" -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}负载均衡组${PLAIN}"
        print_line
        while IFS=$'\t' read -r name strategy ncnt; do
            echo -e "  ${CYAN}⚖${PLAIN} ${name} ${GRAY}(${strategy}, ${ncnt}节点)${PLAIN}"
        done < <(echo "$groups" | jq -r '.[] | [.name, .strategy, (.nodes|length|tostring)] | @tsv')
    fi
    
    print_line
}

# --- 删除节点 ---
delete_node() {
    local nodes=$(db_get_nodes)
    local count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -eq 0 ]] && { print_warn "暂无节点"; return; }
    
    show_nodes
    echo -e "  ${GRAY}输入 all 删除全部${PLAIN}"
    read -rp "  删除第几个 [1-${count}]: " idx
    
    if [[ "$idx" == "all" ]]; then
        db_clear_nodes
        print_ok "已删除所有节点"
        _reload_config
    elif [[ "$idx" =~ ^[0-9]+$ && "$idx" -ge 1 && "$idx" -le "$count" ]]; then
        local name=$(echo "$nodes" | jq -r ".[$((idx-1))].name")
        db_del_node "$name"
        # 同时清理引用该节点的分流规则
        local tmp=$(mktemp)
        jq --arg out "chain:$name" '.routing_rules = [.routing_rules[]? | select(.outbound != $out)]' \
            "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
        print_ok "已删除: ${name}"
        _reload_config
    fi
}

# --- 查看状态 ---
show_status() {
    echo ""
    print_dline
    echo -e "${BOLD}  📊 服务状态${PLAIN}"
    print_dline
    
    # SOCKS5 入站
    local socks=$(db_get_socks_inbound)
    if [[ -n "$socks" && "$socks" != "null" ]]; then
        local port=$(echo "$socks" | jq -r '.port')
        local auth=$(echo "$socks" | jq -r '.auth_mode // "password"')
        if svc_status; then
            echo -e "  SOCKS5 入站: ${GREEN}● 运行中${PLAIN} (端口 ${port}, 认证: ${auth})"
        else
            echo -e "  SOCKS5 入站: ${YELLOW}⏸ 已停止${PLAIN} (端口 ${port})"
        fi
    else
        echo -e "  SOCKS5 入站: ${GRAY}○ 未配置${PLAIN}"
    fi
    
    # 节点
    local nodes=$(db_get_nodes)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    echo -e "  代理节点:    ${CYAN}${node_count} 个${PLAIN}"
    
    # 规则
    local rules=$(db_get_rules)
    local rule_count=$(echo "$rules" | jq 'length' 2>/dev/null || echo 0)
    echo -e "  分流规则:    ${CYAN}${rule_count} 条${PLAIN}"
    
    # 连接信息
    if [[ -n "$socks" && "$socks" != "null" ]]; then
        local port=$(echo "$socks" | jq -r '.port')
        local username=$(echo "$socks" | jq -r '.username // ""')
        local password=$(echo "$socks" | jq -r '.password // ""')
        local auth_mode=$(echo "$socks" | jq -r '.auth_mode // "password"')
        local ipv4=$(get_ipv4)
        echo ""
        echo -e "  ${CYAN}连接信息:${PLAIN}"
        if [[ "$auth_mode" == "password" ]]; then
            echo -e "  socks5://${username}:${password}@${ipv4}:${port}#SOCKS5"
        else
            echo -e "  SOCKS5 ${ipv4}:${port} (无认证)"
        fi
    fi
    
    print_dline
}

# --- 完全卸载 ---
do_uninstall() {
    echo ""
    read -rp "  确认完全卸载 SOCKS5 分流服务? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    
    svc_stop
    rm -f /etc/systemd/system/${SOCKS_SERVICE}.service
    systemctl daemon-reload
    rm -f "$XRAY_CONFIG" "$SOCKS_DB"
    
    print_ok "已完全卸载"
}

# ============================================================
# 主菜单
# ============================================================

show_menu() {
    clear
    print_dline
    echo -e "${BOLD}    🏠 SOCKS5 家宽出口 + 分流管理 v${VERSION}${PLAIN}"
    echo -e "${GRAY}       github.com/10000ge10000/own-rules${PLAIN}"
    print_dline
    
    # 状态摘要
    local socks=$(db_get_socks_inbound)
    local socks_status="${GRAY}○ 未配置${PLAIN}"
    if [[ -n "$socks" && "$socks" != "null" ]]; then
        local port=$(echo "$socks" | jq -r '.port')
        if svc_status; then
            socks_status="${GREEN}● 运行中 :${port}${PLAIN}"
        else
            socks_status="${YELLOW}⏸ 已停止 :${port}${PLAIN}"
        fi
    fi
    
    local node_count=$(db_get_nodes | jq 'length' 2>/dev/null || echo 0)
    local rule_count=$(db_get_rules | jq 'length' 2>/dev/null || echo 0)
    
    echo -e "  SOCKS5: ${socks_status}  节点: ${CYAN}${node_count}${PLAIN}  规则: ${CYAN}${rule_count}${PLAIN}"
    print_line
    echo ""
    
    echo -e " ${BOLD}📡 入站管理${PLAIN}"
    print_line
    echo -e "  ${GREEN}1.${PLAIN} 安装/配置 SOCKS5 入站"
    echo -e "  ${GREEN}2.${PLAIN} 查看服务状态"
    echo ""
    
    echo -e " ${BOLD}🔗 出口节点${PLAIN}"
    print_line
    echo -e "  ${GREEN}3.${PLAIN} 添加节点 (分享链接)"
    echo -e "  ${GREEN}4.${PLAIN} 一键导入 Alice 家宽 (8节点)"
    echo -e "  ${GREEN}5.${PLAIN} 查看节点"
    echo -e "  ${GREEN}6.${PLAIN} 删除节点"
    echo ""
    
    echo -e " ${BOLD}🔀 分流管理${PLAIN}"
    print_line
    echo -e "  ${GREEN}7.${PLAIN} 配置分流规则"
    echo -e "  ${GREEN}8.${PLAIN} 测试分流效果"
    echo ""
    
    echo -e " ${BOLD}⚙️  系统${PLAIN}"
    print_line
    if svc_status 2>/dev/null; then
        echo -e "  ${GREEN}9.${PLAIN} 重启服务"
        echo -e "  ${YELLOW}10.${PLAIN} 停止服务"
    else
        echo -e "  ${GREEN}9.${PLAIN} 启动服务"
    fi
    echo -e "  ${RED}11.${PLAIN} 完全卸载"
    echo ""
    echo -e "  ${GRAY}0.${PLAIN}  返回/退出"
    
    print_dline
    echo ""
    read -rp " 请选择 [0-11]: " choice
    
    case "$choice" in
        1) setup_socks_inbound ;;
        2) show_status ;;
        3) add_chain_node ;;
        4) import_alice_nodes ;;
        5) show_nodes ;;
        6) delete_node ;;
        7) setup_routing_rules ;;
        8) _test_routing ;;
        9)
            if svc_status 2>/dev/null; then
                svc_restart
            else
                generate_xray_config && svc_start
            fi
            ;;
        10) svc_stop ;;
        11) do_uninstall ;;
        0) return 1 ;;
        *) print_warn "无效选项"; sleep 1 ;;
    esac
    
    echo ""
    read -rp "按回车键继续..."
    return 0
}

# ============================================================
# 主入口
# ============================================================

main() {
    check_root
    check_jq
    db_init
    
    # 如果从 onekey.sh 调用 (无参数)，显示菜单循环
    while show_menu; do
        :
    done
}

main "$@"
