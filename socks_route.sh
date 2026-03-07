#!/bin/bash

# ====================================================
# Alice 家宽出口 + 分流管理脚本
# 项目: github.com/10000ge10000/own-rules
# 版本: 3.1.0
# 说明: 在 Xray 上配置 SOCKS5 入站 + 链式代理出站 + 分流规则
#       适用于需要家宽 IP 出口解锁流媒体等场景
#       ⚠️ 仅支持 Alice 自家机器部署使用
# ====================================================

VERSION="3.1.0"
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
XRAY_CONFIG="${XRAY_CONFIG_DIR}/socks_route_xray.json"
SOCKS_DB="${XRAY_CONFIG_DIR}/socks_route.json"
SOCKS_SERVICE="xray-socks"

# --- SOCKS5 入站默认配置 (仅本地, 无认证) ---
SOCKS_LISTEN="127.0.0.1"
SOCKS_PORT=9530

# --- Alice 家宽节点配置 ---
ALICE_SERVER="2a14:67c0:116::1"
ALICE_USERNAME="alice"
ALICE_PASSWORD="alicefofo123..OVO"
ALICE_PORT_START=10001
ALICE_PORT_END=10008

# --- 协议联动 ---
LINKAGE_USER="socks_route"
LINKAGE_TPROXY_PORT=12345
LINKAGE_IPTABLES_CHAIN="SOCKS_ROUTE"
LINKAGE_FWMARK=0x1
LINKAGE_TABLE=100

# 联动协议定义 (名称|服务名|类型: redirect=iptables透明代理, native=原生outbound支持)
declare -A LINKAGE_PROTOCOLS
LINKAGE_PROTOCOLS=(
    ["anytls"]="AnyTLS|anytls|redirect"
    ["tuic"]="TUIC|tuic|redirect"
    ["ss2022"]="SS-2022|shadowsocks-rust|redirect"
    ["hysteria2"]="Hysteria2|hysteria-server|native"
    ["mieru"]="Mieru|mita|redirect"
    ["vless"]="VLESS|xray|redirect"
    ["sudoku"]="Sudoku|sudoku-tunnel|redirect"
)

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
  "direct_ip_version": "as_is",
  "linkage": {}
}
EOF
    else
        if ! jq -e '.linkage' "$SOCKS_DB" &>/dev/null; then
            local tmp=$(mktemp)
            jq '. + {linkage:{}}' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
        fi
    fi
}

# --- 联动状态 ---
db_get_linkage() {
    jq -c '.linkage // {}' "$SOCKS_DB" 2>/dev/null
}

db_set_linkage_protocol() {
    local proto="$1" enabled="$2"
    local tmp=$(mktemp)
    jq --arg p "$proto" --argjson e "$enabled" '.linkage[$p] = $e' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
}

db_get_linkage_protocol() {
    local proto="$1"
    jq -r --arg p "$proto" '.linkage[$p] // false' "$SOCKS_DB" 2>/dev/null
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
    local tmp=$(mktemp)
    jq --arg n "$name" '.chain_nodes = [.chain_nodes[]? | select(.name != $n)]' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
    tmp=$(mktemp)
    jq --argjson node "$node_json" '.chain_nodes += [$node]' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
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
# Xray 配置生成
# ============================================================

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
    local listen_addr=$(echo "$socks_inbound" | jq -r '.listen // "127.0.0.1"')
    
    # === 入站列表 ===
    local inbounds='[]'
    
    # SOCKS5 入站 (仅本地, 无认证)
    local socks_in=$(jq -n --argjson port "$port" --arg listen "$listen_addr" \
        '{port:$port, listen:$listen, protocol:"socks", settings:{auth:"noauth",udp:true}, tag:"socks-in"}')
    inbounds=$(echo "$inbounds" | jq --argjson ib "$socks_in" '. += [$ib]')
    
    # 透明代理入站 (dokodemo-door) — 用于协议联动 iptables REDIRECT
    local linkage=$(db_get_linkage)
    local has_redirect=false
    if [[ -n "$linkage" && "$linkage" != "{}" ]]; then
        while IFS='=' read -r key val; do
            if [[ "$val" == "true" ]]; then
                local proto_info="${LINKAGE_PROTOCOLS[$key]:-}"
                local proto_type=$(echo "$proto_info" | cut -d'|' -f3)
                if [[ "$proto_type" == "redirect" ]]; then
                    has_redirect=true
                    break
                fi
            fi
        done < <(echo "$linkage" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
    fi
    
    if [[ "$has_redirect" == "true" ]]; then
        local tproxy_in=$(jq -n --argjson port "$LINKAGE_TPROXY_PORT" \
            '{port:$port, listen:"127.0.0.1", protocol:"dokodemo-door", settings:{network:"tcp,udp",followRedirect:true}, sniffing:{enabled:true,destOverride:["http","tls","quic"]}, tag:"tproxy-in"}')
        inbounds=$(echo "$inbounds" | jq --argjson ib "$tproxy_in" '. += [$ib]')
    fi
    
    # === 出站 ===
    local outbounds='[{"tag":"direct","protocol":"freedom","settings":{}}]'
    local nodes=$(db_get_nodes)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    
    if [[ "$node_count" -gt 0 ]]; then
        while IFS= read -r node; do
            local name=$(echo "$node" | jq -r '.name')
            local tag="chain-${name}"
            local out=$(gen_xray_outbound "$node" "$tag")
            if [[ -n "$out" ]]; then
                outbounds=$(echo "$outbounds" | jq --argjson o "$out" '. += [$o]')
            fi
            
            local tag_v4="chain-${name}-prefer-ipv4"
            local out_v4=$(gen_xray_outbound "$node" "$tag_v4")
            if [[ -n "$out_v4" ]]; then
                out_v4=$(echo "$out_v4" | jq '.settings.domainStrategy = "UseIPv4"')
                outbounds=$(echo "$outbounds" | jq --argjson o "$out_v4" '. += [$o]')
            fi
        done < <(echo "$nodes" | jq -c '.[]')
    fi
    
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
            
            local out_tag="direct"
            if [[ "$outbound" == "direct" ]]; then
                out_tag="direct"
            elif [[ "$outbound" == chain:* ]]; then
                local node_name="${outbound#chain:}"
                out_tag="chain-${node_name}-prefer-ipv4"
            elif [[ "$outbound" == balancer:* ]]; then
                local group_name="${outbound#balancer:}"
                out_tag="balancer-${group_name}"
            fi
            
            local domain_list=""
            if [[ "$rule_type" == "custom" && -n "$domains" ]]; then
                domain_list="$domains"
            elif [[ "$rule_type" == "all" ]]; then
                :
            elif [[ -n "${ROUTING_DOMAINS[$rule_type]}" ]]; then
                domain_list="${ROUTING_DOMAINS[$rule_type]}"
            fi
            
            if [[ "$rule_type" == "all" ]]; then
                routing_rules=$(echo "$routing_rules" | jq --arg tag "$out_tag" \
                    '. += [{"type":"field","network":"tcp,udp","outboundTag":$tag}]')
            elif [[ -n "$domain_list" ]]; then
                local domains_json=$(echo "$domain_list" | tr ',' '\n' | jq -R . | jq -s .)
                local geosite_arr=$(echo "$domains_json" | jq '[.[] | select(startswith("geosite:"))]')
                local geoip_arr=$(echo "$domains_json" | jq '[.[] | select(startswith("geoip:"))]')
                local domain_arr=$(echo "$domains_json" | jq '[.[] | select((startswith("geosite:") or startswith("geoip:")) | not)]')
                
                local combined=$(echo "$domain_arr" | jq --argjson gs "$geosite_arr" '. + $gs')
                if [[ $(echo "$combined" | jq 'length') -gt 0 ]]; then
                    routing_rules=$(echo "$routing_rules" | jq --arg tag "$out_tag" --argjson domains "$combined" \
                        '. += [{"type":"field","domain":$domains,"outboundTag":$tag}]')
                fi
                
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
            
            local selectors='[]'
            while IFS= read -r n; do
                selectors=$(echo "$selectors" | jq --arg s "chain-${n}" '. += [$s]')
            done < <(echo "$group_nodes" | jq -r '.[]')
            
            balancers=$(echo "$balancers" | jq --arg tag "balancer-${group_name}" \
                --arg strategy "$strategy" --argjson sel "$selectors" \
                '. += [{"tag":$tag,"selector":$sel,"strategy":{"type":$strategy}}]')
        done < <(echo "$balancer_groups" | jq -c '.[]')
        
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
            --argjson inbounds "$inbounds" \
            --argjson outbounds "$outbounds" \
            --argjson rules "$routing_rules" \
            --argjson balancers "$balancers" \
            '{
                log: {loglevel:"warning"},
                inbounds: $inbounds,
                outbounds: $outbounds,
                routing: {domainStrategy:"AsIs", rules: $rules, balancers: $balancers}
            }')
    else
        config=$(jq -n \
            --argjson inbounds "$inbounds" \
            --argjson outbounds "$outbounds" \
            --argjson rules "$routing_rules" \
            '{
                log: {loglevel:"warning"},
                inbounds: $inbounds,
                outbounds: $outbounds,
                routing: {domainStrategy:"AsIs", rules: $rules}
            }')
    fi
    
    echo "$config" | jq . > "$XRAY_CONFIG"
    
    # 检查是否使用了 leastPing 或 leastLoad 策略，需要添加 burstObservatory 配置
    local needs_observatory=false
    if [[ "$balancer_count" -gt 0 ]]; then
        while IFS= read -r group; do
            local strategy=$(echo "$group" | jq -r '.strategy // "random"')
            if [[ "$strategy" == "leastPing" || "$strategy" == "leastLoad" ]]; then
                needs_observatory=true
                break
            fi
        done < <(echo "$balancer_groups" | jq -c '.[]')
    fi
    
    if [[ "$needs_observatory" == "true" ]]; then
        # 构建 subjectSelector: 使用通配符匹配所有链式代理出站
        local subject_selectors="[]"
        while IFS= read -r group; do
            local strategy=$(echo "$group" | jq -r '.strategy // "random"')
            if [[ "$strategy" == "leastPing" || "$strategy" == "leastLoad" ]]; then
                local first_node=$(echo "$group" | jq -r '.nodes[0] // ""')
                if [[ -n "$first_node" ]]; then
                    # 提取公共前缀 (例如 Alice-TW-SOCKS5-01 -> Alice-TW-SOCKS5)
                    local prefix=$(echo "$first_node" | sed 's/-[0-9][0-9]*$//')
                    local tag_prefix="chain-${prefix}-"
                    if ! echo "$subject_selectors" | jq -e --arg p "$tag_prefix" '.[] | select(. == $p)' >/dev/null 2>&1; then
                        subject_selectors=$(echo "$subject_selectors" | jq --arg p "$tag_prefix" '. + [$p]')
                    fi
                fi
            fi
        done < <(echo "$balancer_groups" | jq -c '.[]')
        
        local tmp=$(mktemp)
        jq --argjson selectors "$subject_selectors" '
            .burstObservatory = {
                subjectSelector: $selectors,
                pingConfig: {
                    destination: "https://www.gstatic.com/generate_204",
                    interval: "10s",
                    sampling: 2,
                    timeout: "5s"
                }
            }
        ' "$XRAY_CONFIG" > "$tmp" && mv "$tmp" "$XRAY_CONFIG"
        print_info "已添加 burstObservatory 探测配置 (leastPing/leastLoad 需要)"
    fi
    
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
# 自动初始化 (安装 SOCKS5 入站 + 导入 Alice 节点)
# ============================================================

_auto_setup_socks_inbound() {
    local existing=$(db_get_socks_inbound)
    if [[ -n "$existing" && "$existing" != "null" ]]; then
        return 0
    fi
    
    print_info "自动配置 SOCKS5 入站 (${SOCKS_LISTEN}:${SOCKS_PORT}, 无认证, 仅本地)..."
    
    local inbound_json=$(jq -n --argjson port "$SOCKS_PORT" \
        --arg user "" --arg pass "" --arg auth "noauth" --arg listen "$SOCKS_LISTEN" \
        '{port:$port, username:$user, password:$pass, auth_mode:$auth, listen:$listen}')
    
    db_set_socks_inbound "$inbound_json"
    print_ok "SOCKS5 入站已配置"
}

_auto_import_alice_nodes() {
    local nodes=$(db_get_nodes)
    local existing_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    
    local alice_count=0
    if [[ "$existing_count" -gt 0 ]]; then
        alice_count=$(echo "$nodes" | jq '[.[] | select(.name | startswith("Alice-TW-SOCKS5-"))] | length' 2>/dev/null || echo 0)
    fi
    
    if [[ "$alice_count" -ge 8 ]]; then
        return 0
    fi
    
    print_info "自动导入 Alice 家宽节点 (8节点)..."
    
    if [[ "$alice_count" -gt 0 ]]; then
        local tmp=$(mktemp)
        jq '.chain_nodes = [.chain_nodes[]? | select(.name | startswith("Alice-TW-SOCKS5-") | not)]' "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
    fi
    
    local imported=0
    for i in $(seq 1 8); do
        local port=$((ALICE_PORT_START + i - 1))
        local name=$(printf "Alice-TW-SOCKS5-%02d" "$i")
        local node=$(jq -n --arg name "$name" --arg server "$ALICE_SERVER" \
            --argjson port "$port" --arg user "$ALICE_USERNAME" --arg pass "$ALICE_PASSWORD" \
            '{name:$name,type:"socks",server:$server,port:$port,username:$user,password:$pass}')
        db_add_node "$node"
        ((imported++))
    done
    
    print_ok "已导入 ${imported} 个 Alice 节点"
    
    # 自动创建负载均衡组
    local group_nodes='[]'
    for i in $(seq 1 8); do
        local name=$(printf "Alice-TW-SOCKS5-%02d" "$i")
        group_nodes=$(echo "$group_nodes" | jq --arg n "$name" '. += [$n]')
    done
    local group=$(jq -n --arg name "Alice-TW-LB" --arg strategy "random" \
        --argjson nodes "$group_nodes" \
        '{name:$name, strategy:$strategy, nodes:$nodes}')
    db_add_balancer_group "$group"
    print_ok "负载均衡组 'Alice-TW-LB' 已创建 (随机策略, 可在菜单中切换)"
}

auto_init() {
    local need_reload=false
    
    install_xray || { print_err "Xray 安装失败，无法继续"; return 1; }
    
    local old_socks=$(db_get_socks_inbound)
    _auto_setup_socks_inbound
    local new_socks=$(db_get_socks_inbound)
    [[ "$old_socks" != "$new_socks" ]] && need_reload=true
    
    local old_nodes=$(db_get_nodes | jq 'length' 2>/dev/null || echo 0)
    _auto_import_alice_nodes
    local new_nodes=$(db_get_nodes | jq 'length' 2>/dev/null || echo 0)
    [[ "$old_nodes" != "$new_nodes" ]] && need_reload=true
    
    if [[ "$need_reload" == "true" ]] || ! svc_status; then
        generate_xray_config
        svc_start
    fi
}

# ============================================================
# 分流规则菜单
# ============================================================

setup_routing_rules() {
    while true; do
        echo ""
        print_dline
        echo -e "${BOLD}  🔀 分流规则管理${PLAIN}"
        print_dline
        
        _show_current_rules
        
        echo ""
        echo -e "  ${GREEN}1.${PLAIN} 添加分流规则"
        echo -e "  ${GREEN}2.${PLAIN} 删除分流规则"
        echo -e "  ${GREEN}3.${PLAIN} 清空所有规则"
        echo -e "  ${GREEN}4.${PLAIN} 测试分流效果"
        echo -e "  ${GREEN}5.${PLAIN} 检测节点活性"
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
            5) echo ""; _check_nodes_health; echo ""; read -rp "按回车键继续..." ;;
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
        [[ "$rule_type" == "custom" && -n "$domains" ]] && name="自定义(${domains:0:30}...)"
        
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
    local out_display="直连"
    [[ "$outbound" == chain:* ]] && out_display="${outbound#chain:}"
    [[ "$outbound" == balancer:* ]] && out_display="${outbound#balancer:} (负载均衡)"
    print_ok "已添加: ${name} → ${out_display}"
    
    _reload_config
}

_select_outbound() {
    print_line >&2
    echo -e "  ${BOLD}选择出口${PLAIN}" >&2
    print_line >&2
    
    local outbounds=()
    local display=()
    
    # 直连
    outbounds+=("direct")
    display+=("DIRECT (直连)")
    
    # 负载均衡组 (优先显示)
    local groups=$(db_get_balancer_groups)
    local gcount=$(echo "$groups" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$gcount" -gt 0 ]]; then
        while IFS=$'\t' read -r name strategy node_cnt; do
            local strategy_display="${BALANCER_STRATEGY_NAMES[$strategy]:-$strategy}"
            outbounds+=("balancer:${name}")
            display+=("⚖ ${name} (${strategy_display}/${node_cnt}节点) ${YELLOW}← 推荐${PLAIN}")
        done < <(echo "$groups" | jq -r '.[] | [.name, .strategy, (.nodes|length|tostring)] | @tsv')
    fi
    
    # 单个节点
    local nodes=$(db_get_nodes)
    local count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$count" -gt 0 ]]; then
        while IFS=$'\t' read -r name type server; do
            outbounds+=("chain:${name}")
            display+=("${name} (${type} @ ${server})")
        done < <(echo "$nodes" | jq -r '.[] | [.name,.type,.server] | @tsv')
    fi
    
    local idx=1
    for d in "${display[@]}"; do
        echo -e "  ${GREEN}${idx}.${PLAIN} ${d}" >&2
        ((idx++))
    done
    echo -e "  ${GRAY}0.${PLAIN} 取消" >&2
    print_line >&2
    
    read -rp "  选择: " sel
    if [[ "$sel" == "0" || -z "$sel" ]]; then
        return
    fi
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
        print_warn "SOCKS5 入站未就绪"
        return
    fi
    
    if ! svc_status; then
        print_warn "服务未运行，正在启动..."
        generate_xray_config && svc_start
        if ! svc_status; then
            print_err "服务启动失败"
            return
        fi
    fi
    
    local port=$(echo "$socks_inbound" | jq -r '.port')
    local proxy_opt="socks5://127.0.0.1:${port}"
    
    echo ""
    echo -e "  ${GRAY}通过 SOCKS5 127.0.0.1:${port} 测试...${PLAIN}"
    echo ""
    
    # 测试出口 IP
    echo -ne "  出口 IP ............. "
    local exit_ip=$(curl -s --max-time 8 -x "$proxy_opt" https://api.ipify.org 2>/dev/null)
    if [[ -n "$exit_ip" ]]; then
        echo -e "${GREEN}${exit_ip}${PLAIN}"
    else
        echo -e "${RED}无法获取${PLAIN}"
    fi
    
    # 测试各预设站点
    local sites=("https://chatgpt.com" "https://www.netflix.com" "https://www.youtube.com" "https://www.google.com" "https://t.me")
    local names=("ChatGPT      " "Netflix      " "YouTube      " "Google       " "Telegram     ")
    
    local fail_count=0
    local total_count=${#sites[@]}
    
    for i in "${!sites[@]}"; do
        echo -ne "  ${names[$i]} ... "
        local http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 8 -x "$proxy_opt" "${sites[$i]}" 2>/dev/null)
        if [[ "$http_code" =~ ^[23] ]]; then
            echo -e "${GREEN}可访问 (${http_code})${PLAIN}"
        elif [[ "$http_code" == "000" ]]; then
            echo -e "${RED}连接失败${PLAIN}"
            ((fail_count++))
        else
            echo -e "${YELLOW}HTTP ${http_code}${PLAIN}"
        fi
    done
    
    echo ""
    
    # 如果有连接失败，自动触发节点活性检测
    if [[ "$fail_count" -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠ 检测到 ${fail_count}/${total_count} 个站点连接失败，正在检测节点活性...${PLAIN}"
        echo ""
        _check_nodes_health
        echo ""
    fi
    
    # 最近路由日志
    echo -e "  ${GRAY}最近路由日志:${PLAIN}"
    journalctl -u "$SOCKS_SERVICE" --no-pager -n 30 2>/dev/null | \
        grep -oP '\[.*?>>.*?\].*' | tail -5 | while read -r line; do
        echo -e "  ${GRAY}  ${line}${PLAIN}"
    done
    
    print_line
}

# ============================================================
# 节点活性检测
# ============================================================

_check_nodes_health() {
    local nodes=$(db_get_nodes)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    
    if [[ "$node_count" -eq 0 ]]; then
        print_warn "没有节点可供检测"
        return
    fi
    
    echo -e "  ${CYAN}节点活性检测 (${node_count} 个节点)${PLAIN}"
    print_line
    
    local alive_count=0
    local dead_count=0
    local dead_nodes=()
    
    while IFS= read -r node; do
        local name=$(echo "$node" | jq -r '.name')
        local server=$(echo "$node" | jq -r '.server')
        local port=$(echo "$node" | jq -r '.port')
        local username=$(echo "$node" | jq -r '.username // ""')
        local password=$(echo "$node" | jq -r '.password // ""')
        
        echo -ne "  ${name} (${server}:${port}) ... "
        
        # 方法1: 尝试通过节点的 SOCKS5 获取 IP (验证完整链路)
        local node_alive=false
        local socks_url=""
        if [[ -n "$username" && -n "$password" ]]; then
            socks_url="socks5://${username}:${password}@${server}:${port}"
        else
            socks_url="socks5://${server}:${port}"
        fi
        
        # TCP 连接测试 (先快速检测端口可达性)
        local tcp_ok=false
        if timeout 5 bash -c "echo > /dev/tcp/${server}/${port}" 2>/dev/null; then
            tcp_ok=true
        fi
        
        if [[ "$tcp_ok" == "true" ]]; then
            # 端口可达，进一步验证 SOCKS5 协议
            local test_ip=$(curl -s --max-time 6 -x "$socks_url" https://api.ipify.org 2>/dev/null)
            if [[ -n "$test_ip" && "$test_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                node_alive=true
                echo -e "${GREEN}在线 (出口: ${test_ip})${PLAIN}"
                ((alive_count++))
            else
                # SOCKS5 认证通过但无法访问外网
                local test_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -x "$socks_url" https://www.gstatic.com/generate_204 2>/dev/null)
                if [[ "$test_code" == "204" || "$test_code" =~ ^[23] ]]; then
                    node_alive=true
                    echo -e "${GREEN}在线 (端口可达)${PLAIN}"
                    ((alive_count++))
                else
                    echo -e "${RED}异常 (端口开放但链路不通)${PLAIN}"
                    ((dead_count++))
                    dead_nodes+=("$name")
                fi
            fi
        else
            echo -e "${RED}离线 (端口不可达)${PLAIN}"
            ((dead_count++))
            dead_nodes+=("$name")
        fi
    done < <(echo "$nodes" | jq -c '.[]')
    
    echo ""
    echo -e "  ${CYAN}检测结果: ${GREEN}${alive_count} 在线${PLAIN} / ${RED}${dead_count} 离线${PLAIN} / 共 ${node_count} 个${PLAIN}"
    
    if [[ "$dead_count" -gt 0 ]]; then
        echo -e "  ${RED}离线节点: ${dead_nodes[*]}${PLAIN}"
        echo ""
        echo -e "  ${YELLOW}提示: 离线节点可能导致分流连接失败${PLAIN}"
        echo -e "  ${YELLOW}      建议使用 leastPing 或 leastLoad 策略自动规避故障节点${PLAIN}"
        echo -e "  ${YELLOW}      可在主菜单 → 负载均衡策略 中切换${PLAIN}"
    fi
    
    print_line
}

# ============================================================
# 负载均衡策略管理
# ============================================================

# 策略说明
declare -A BALANCER_STRATEGY_NAMES
BALANCER_STRATEGY_NAMES=(
    ["random"]="随机 (Random)"
    ["roundRobin"]="轮询 (Round Robin)"
    ["leastPing"]="最低延迟 (Least Ping)"
    ["leastLoad"]="最低负载 (Least Load)"
)

declare -A BALANCER_STRATEGY_DESC
BALANCER_STRATEGY_DESC=(
    ["random"]="每次请求随机选择一个节点，简单高效"
    ["roundRobin"]="按顺序轮流使用每个节点，流量均匀分配"
    ["leastPing"]="自动探测延迟，优先使用延迟最低的节点 (推荐)"
    ["leastLoad"]="综合评估节点负载和延迟，选择最优节点"
)

manage_balancer_strategy() {
    while true; do
        echo ""
        print_dline
        echo -e "${BOLD}  ⚖ 负载均衡策略管理${PLAIN}"
        print_dline
        
        local groups=$(db_get_balancer_groups)
        local gcount=$(echo "$groups" | jq 'length' 2>/dev/null || echo 0)
        
        if [[ "$gcount" -eq 0 ]]; then
            echo ""
            print_warn "没有负载均衡组"
            echo ""
            read -rp "按回车键返回..."
            return
        fi
        
        # 显示当前组
        echo ""
        echo -e "  ${CYAN}当前负载均衡组:${PLAIN}"
        print_line
        
        local idx=1
        local group_names=()
        while IFS= read -r group; do
            local gname=$(echo "$group" | jq -r '.name')
            local gstrategy=$(echo "$group" | jq -r '.strategy // "random"')
            local gnode_cnt=$(echo "$group" | jq '.nodes | length')
            local strategy_display="${BALANCER_STRATEGY_NAMES[$gstrategy]:-$gstrategy}"
            
            echo -e "  ${GREEN}${idx}.${PLAIN} ${gname} — ${CYAN}${strategy_display}${PLAIN} (${gnode_cnt} 节点)"
            echo -e "      ${GRAY}${BALANCER_STRATEGY_DESC[$gstrategy]:-}${PLAIN}"
            group_names+=("$gname")
            ((idx++))
        done < <(echo "$groups" | jq -c '.[]')
        
        echo ""
        print_line
        echo -e "  ${GRAY}0.${PLAIN} 返回"
        print_line
        
        read -rp "  选择要修改策略的组 [0-${#group_names[@]}]: " choice
        [[ "$choice" == "0" || -z "$choice" ]] && return
        
        if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#group_names[@]} ]]; then
            local sel_name="${group_names[$((choice-1))]}"
            _change_balancer_strategy "$sel_name"
        fi
    done
}

_change_balancer_strategy() {
    local group_name="$1"
    
    echo ""
    print_line
    echo -e "  ${BOLD}选择负载均衡策略 — ${group_name}${PLAIN}"
    print_line
    echo ""
    echo -e "  ${GREEN}1.${PLAIN} ${BALANCER_STRATEGY_NAMES[random]}"
    echo -e "     ${GRAY}${BALANCER_STRATEGY_DESC[random]}${PLAIN}"
    echo ""
    echo -e "  ${GREEN}2.${PLAIN} ${BALANCER_STRATEGY_NAMES[roundRobin]}"
    echo -e "     ${GRAY}${BALANCER_STRATEGY_DESC[roundRobin]}${PLAIN}"
    echo ""
    echo -e "  ${GREEN}3.${PLAIN} ${BALANCER_STRATEGY_NAMES[leastPing]}  ${YELLOW}← 推荐${PLAIN}"
    echo -e "     ${GRAY}${BALANCER_STRATEGY_DESC[leastPing]}${PLAIN}"
    echo ""
    echo -e "  ${GREEN}4.${PLAIN} ${BALANCER_STRATEGY_NAMES[leastLoad]}"
    echo -e "     ${GRAY}${BALANCER_STRATEGY_DESC[leastLoad]}${PLAIN}"
    echo ""
    echo -e "  ${GRAY}0.${PLAIN} 取消"
    print_line
    
    read -rp "  选择: " sel
    
    local new_strategy=""
    case "$sel" in
        1) new_strategy="random" ;;
        2) new_strategy="roundRobin" ;;
        3) new_strategy="leastPing" ;;
        4) new_strategy="leastLoad" ;;
        0|"") return ;;
        *) print_warn "无效选项"; return ;;
    esac
    
    # 更新策略
    local tmp=$(mktemp)
    jq --arg name "$group_name" --arg strategy "$new_strategy" \
        '.balancer_groups = [.balancer_groups[]? | if .name == $name then .strategy = $strategy else . end]' \
        "$SOCKS_DB" > "$tmp" && mv "$tmp" "$SOCKS_DB"
    
    local strategy_display="${BALANCER_STRATEGY_NAMES[$new_strategy]}"
    print_ok "${group_name} 策略已切换为: ${strategy_display}"
    
    _reload_config
}

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

# --- 查看状态 ---
show_status() {
    echo ""
    print_dline
    echo -e "${BOLD}  📊 服务状态${PLAIN}"
    print_dline
    
    local socks=$(db_get_socks_inbound)
    if [[ -n "$socks" && "$socks" != "null" ]]; then
        local port=$(echo "$socks" | jq -r '.port')
        local listen=$(echo "$socks" | jq -r '.listen // "127.0.0.1"')
        if svc_status; then
            echo -e "  SOCKS5 入站: ${GREEN}● 运行中${PLAIN} (${listen}:${port}, 仅本地)"
        else
            echo -e "  SOCKS5 入站: ${YELLOW}⏸ 已停止${PLAIN} (${listen}:${port})"
        fi
    else
        echo -e "  SOCKS5 入站: ${GRAY}○ 未配置${PLAIN}"
    fi
    
    local nodes=$(db_get_nodes)
    local node_count=$(echo "$nodes" | jq 'length' 2>/dev/null || echo 0)
    echo -e "  Alice 节点:  ${CYAN}${node_count} 个${PLAIN}"
    
    local groups=$(db_get_balancer_groups)
    local gcount=$(echo "$groups" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$gcount" -gt 0 ]]; then
        while IFS=$'\t' read -r name strategy ncnt; do
            local strategy_display="${BALANCER_STRATEGY_NAMES[$strategy]:-$strategy}"
            echo -e "  负载均衡:    ${CYAN}⚖ ${name} (${strategy_display}, ${ncnt}节点)${PLAIN}"
        done < <(echo "$groups" | jq -r '.[] | [.name, .strategy, (.nodes|length|tostring)] | @tsv')
    fi
    
    local rules=$(db_get_rules)
    local rule_count=$(echo "$rules" | jq 'length' 2>/dev/null || echo 0)
    echo -e "  分流规则:    ${CYAN}${rule_count} 条${PLAIN}"
    
    if [[ "$rule_count" -gt 0 ]]; then
        local idx=1
        while IFS= read -r rule; do
            local rule_type=$(echo "$rule" | jq -r '.type')
            local outbound=$(echo "$rule" | jq -r '.outbound')
            local name="${ROUTING_NAMES[$rule_type]:-$rule_type}"
            local out_name="直连"
            [[ "$outbound" == chain:* ]] && out_name="${outbound#chain:}"
            [[ "$outbound" == balancer:* ]] && out_name="${outbound#balancer:} (LB)"
            echo -e "    ${GREEN}${idx}.${PLAIN} ${name} → ${CYAN}${out_name}${PLAIN}"
            ((idx++))
        done < <(echo "$rules" | jq -c '.[]')
    fi
    
    echo ""
    echo -e "  ${BOLD}协议联动:${PLAIN}"
    local sorted_keys=(anytls tuic ss2022 hysteria2 mieru vless sudoku)
    local has_any=false
    for key in "${sorted_keys[@]}"; do
        local info="${LINKAGE_PROTOCOLS[$key]}"
        local name=$(echo "$info" | cut -d'|' -f1)
        local svc=$(echo "$info" | cut -d'|' -f2)
        local enabled=$(db_get_linkage_protocol "$key")
        
        if ! systemctl cat "$svc" &>/dev/null 2>&1; then
            continue
        fi
        has_any=true
        
        if [[ "$enabled" == "true" ]]; then
            echo -e "    ${GREEN}●${PLAIN} ${name} — 已联动"
        else
            echo -e "    ${GRAY}○${PLAIN} ${name} — 未联动"
        fi
    done
    [[ "$has_any" == "false" ]] && echo -e "    ${GRAY}(未安装任何可联动的协议)${PLAIN}"
    
    print_dline
}

# --- 完全卸载 ---
do_uninstall() {
    echo ""
    read -rp "  确认完全卸载 Alice 分流服务? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return
    
    _linkage_disable_all_quiet
    
    svc_stop
    rm -f /etc/systemd/system/${SOCKS_SERVICE}.service
    systemctl daemon-reload
    rm -f "$XRAY_CONFIG" "$SOCKS_DB"
    
    print_ok "已完全卸载"
}

# ============================================================
# 协议联动模块
# ============================================================

_linkage_ensure_user() {
    if ! id "$LINKAGE_USER" &>/dev/null; then
        useradd -r -s /usr/sbin/nologin -M "$LINKAGE_USER" 2>/dev/null
        print_ok "创建系统用户: $LINKAGE_USER"
    fi
}

_linkage_get_uid() {
    id -u "$LINKAGE_USER" 2>/dev/null
}

_linkage_setup_iptables() {
    local uid=$(_linkage_get_uid)
    [[ -z "$uid" ]] && { print_err "联动用户不存在"; return 1; }
    
    _linkage_cleanup_iptables 2>/dev/null
    
    iptables -t nat -N "$LINKAGE_IPTABLES_CHAIN" 2>/dev/null
    
    iptables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d 100.64.0.0/10 -j RETURN
    iptables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d 240.0.0.0/4 -j RETURN
    
    iptables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -p tcp -j REDIRECT --to-ports "$LINKAGE_TPROXY_PORT"
    iptables -t nat -A OUTPUT -m owner --uid-owner "$uid" -j "$LINKAGE_IPTABLES_CHAIN"
    
    ip6tables -t nat -N "$LINKAGE_IPTABLES_CHAIN" 2>/dev/null
    ip6tables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d ::1/128 -j RETURN
    ip6tables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d fe80::/10 -j RETURN
    ip6tables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -d fc00::/7 -j RETURN
    ip6tables -t nat -A "$LINKAGE_IPTABLES_CHAIN" -p tcp -j REDIRECT --to-ports "$LINKAGE_TPROXY_PORT"
    ip6tables -t nat -A OUTPUT -m owner --uid-owner "$uid" -j "$LINKAGE_IPTABLES_CHAIN"
    
    print_ok "iptables REDIRECT 规则已设置 (UID=$uid → :$LINKAGE_TPROXY_PORT)"
}

_linkage_cleanup_iptables() {
    local uid=$(_linkage_get_uid)
    
    iptables -t nat -D OUTPUT -m owner --uid-owner "$uid" -j "$LINKAGE_IPTABLES_CHAIN" 2>/dev/null
    iptables -t nat -F "$LINKAGE_IPTABLES_CHAIN" 2>/dev/null
    iptables -t nat -X "$LINKAGE_IPTABLES_CHAIN" 2>/dev/null
    
    ip6tables -t nat -D OUTPUT -m owner --uid-owner "$uid" -j "$LINKAGE_IPTABLES_CHAIN" 2>/dev/null
    ip6tables -t nat -F "$LINKAGE_IPTABLES_CHAIN" 2>/dev/null
    ip6tables -t nat -X "$LINKAGE_IPTABLES_CHAIN" 2>/dev/null
}

_linkage_persist_iptables() {
    cat > /etc/systemd/system/socks-route-iptables.service <<EOF
[Unit]
Description=SOCKS Route iptables REDIRECT rules
After=network.target xray-socks.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'SCRIPT="${XRAY_CONFIG_DIR}/linkage_iptables.sh"; [ -f "\$SCRIPT" ] && bash "\$SCRIPT" up'
ExecStop=/bin/bash -c 'SCRIPT="${XRAY_CONFIG_DIR}/linkage_iptables.sh"; [ -f "\$SCRIPT" ] && bash "\$SCRIPT" down'

[Install]
WantedBy=multi-user.target
EOF
    
    local uid=$(_linkage_get_uid)
    cat > "${XRAY_CONFIG_DIR}/linkage_iptables.sh" <<EOFSCRIPT
#!/bin/bash
CHAIN="$LINKAGE_IPTABLES_CHAIN"
PORT="$LINKAGE_TPROXY_PORT"
UID_VAL="$uid"

do_up() {
    for cmd in iptables ip6tables; do
        \$cmd -t nat -N "\$CHAIN" 2>/dev/null
        if [[ "\$cmd" == "iptables" ]]; then
            for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
                \$cmd -t nat -A "\$CHAIN" -d "\$cidr" -j RETURN
            done
        else
            for cidr in ::1/128 fe80::/10 fc00::/7; do
                \$cmd -t nat -A "\$CHAIN" -d "\$cidr" -j RETURN
            done
        fi
        \$cmd -t nat -A "\$CHAIN" -p tcp -j REDIRECT --to-ports "\$PORT"
        \$cmd -t nat -A OUTPUT -m owner --uid-owner "\$UID_VAL" -j "\$CHAIN"
    done
}

do_down() {
    for cmd in iptables ip6tables; do
        \$cmd -t nat -D OUTPUT -m owner --uid-owner "\$UID_VAL" -j "\$CHAIN" 2>/dev/null
        \$cmd -t nat -F "\$CHAIN" 2>/dev/null
        \$cmd -t nat -X "\$CHAIN" 2>/dev/null
    done
}

case "\$1" in
    up) do_up ;;
    down) do_down ;;
    *) echo "Usage: \$0 {up|down}" ;;
esac
EOFSCRIPT
    chmod +x "${XRAY_CONFIG_DIR}/linkage_iptables.sh"
    
    systemctl daemon-reload
    systemctl enable socks-route-iptables >/dev/null 2>&1
    systemctl restart socks-route-iptables
}

_linkage_unpersist_iptables() {
    systemctl stop socks-route-iptables 2>/dev/null
    systemctl disable socks-route-iptables 2>/dev/null
    rm -f /etc/systemd/system/socks-route-iptables.service
    rm -f "${XRAY_CONFIG_DIR}/linkage_iptables.sh"
    systemctl daemon-reload
}

_linkage_set_service_user() {
    local service_name="$1" user="$2"
    local svc_file="/etc/systemd/system/${service_name}.service"
    
    if [[ ! -f "$svc_file" ]]; then
        svc_file="/usr/lib/systemd/system/${service_name}.service"
        [[ ! -f "$svc_file" ]] && return 1
    fi
    
    _linkage_fix_permissions "$service_name" "$user"
    
    if grep -q "^User=" "$svc_file"; then
        sed -i "s/^User=.*/User=$user/" "$svc_file"
    else
        sed -i "/^\[Service\]/a User=$user" "$svc_file"
    fi
    
    if [[ "$user" != "root" ]]; then
        if ! grep -q "^CapabilityBoundingSet=" "$svc_file"; then
            sed -i "/^User=/a CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE" "$svc_file"
        fi
        if ! grep -q "^AmbientCapabilities=" "$svc_file"; then
            sed -i "/^CapabilityBoundingSet=/a AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE" "$svc_file"
        fi
    fi
    
    systemctl daemon-reload
}

_linkage_fix_permissions() {
    local service_name="$1" user="$2"
    
    case "$service_name" in
        anytls)
            chown -R "$user":"$user" /etc/anytls/ 2>/dev/null
            chown -R "$user":"$user" /opt/anytls/ 2>/dev/null
            ;;
        tuic)
            chown -R "$user":"$user" /etc/tuic/ 2>/dev/null
            chown -R "$user":"$user" /opt/tuic/ 2>/dev/null
            ;;
        shadowsocks-rust)
            chown -R "$user":"$user" /etc/shadowsocks-rust/ 2>/dev/null
            chown -R "$user":"$user" /opt/shadowsocks-rust/ 2>/dev/null
            ;;
        mita)
            chown -R "$user":"$user" /etc/mieru/ 2>/dev/null
            chown -R "$user":"$user" /opt/mieru/ 2>/dev/null
            ;;
        sudoku-tunnel)
            chown -R "$user":"$user" /etc/sudoku/ 2>/dev/null
            chown -R "$user":"$user" /opt/sudoku/ 2>/dev/null
            ;;
        xray)
            chown -R "$user":"$user" /etc/xray/nodes/ 2>/dev/null
            chown "$user":"$user" /etc/xray/config.json 2>/dev/null
            chown "$user":"$user" /etc/xray/env.conf 2>/dev/null
            chown -R "$user":"$user" /etc/xray/cert/ 2>/dev/null
            chown -R "$user":"$user" /opt/xray/ 2>/dev/null
            ;;
    esac
}

_linkage_setup_hysteria2() {
    local hy_config="/etc/hysteria/config.yaml"
    [[ ! -f "$hy_config" ]] && { print_err "Hysteria2 配置文件不存在"; return 1; }
    
    local socks_inbound=$(db_get_socks_inbound)
    local socks_port=$(echo "$socks_inbound" | jq -r '.port')
    
    cp -f "$hy_config" "${hy_config}.bak.linkage"
    
    local tmp_config=$(mktemp)
    sed '/^outbounds:/,/^[^ ]/{ /^outbounds:/d; /^  /d; /^$/d; }' "$hy_config" > "$tmp_config"
    sed -i '/^$/N;/^\n$/d' "$tmp_config"
    
    cat >> "$tmp_config" <<EOF

outbounds:
  - name: socks_route
    type: socks5
    socks5:
      addr: 127.0.0.1:${socks_port}
EOF
    
    mv "$tmp_config" "$hy_config"
    chmod 600 "$hy_config"
    
    systemctl restart hysteria-server 2>/dev/null
    sleep 1
    if systemctl is-active --quiet hysteria-server; then
        print_ok "Hysteria2 outbound 已设置为 socks_route (SOCKS5)"
    else
        print_err "Hysteria2 重启失败，正在回滚..."
        cp -f "${hy_config}.bak.linkage" "$hy_config"
        systemctl restart hysteria-server 2>/dev/null
        return 1
    fi
}

_linkage_restore_hysteria2() {
    local hy_config="/etc/hysteria/config.yaml"
    [[ ! -f "$hy_config" ]] && return
    
    if [[ -f "${hy_config}.bak.linkage" ]]; then
        cp -f "${hy_config}.bak.linkage" "$hy_config"
        rm -f "${hy_config}.bak.linkage"
    else
        local tmp_config=$(mktemp)
        sed '/^outbounds:/,/^[^ ]/{ /^outbounds:/d; /^  /d; /^$/d; }' "$hy_config" > "$tmp_config"
        cat >> "$tmp_config" <<EOF

outbounds:
  - name: default
    type: direct
    direct:
      mode: 46
EOF
        mv "$tmp_config" "$hy_config"
        chmod 600 "$hy_config"
    fi
    
    systemctl restart hysteria-server 2>/dev/null
    print_ok "Hysteria2 outbound 已恢复为 direct"
}

_linkage_enable_protocol() {
    local proto_key="$1"
    local proto_info="${LINKAGE_PROTOCOLS[$proto_key]:-}"
    [[ -z "$proto_info" ]] && { print_err "未知协议: $proto_key"; return 1; }
    
    local proto_name=$(echo "$proto_info" | cut -d'|' -f1)
    local service_name=$(echo "$proto_info" | cut -d'|' -f2)
    local linkage_type=$(echo "$proto_info" | cut -d'|' -f3)
    
    if ! systemctl cat "$service_name" &>/dev/null; then
        print_warn "$proto_name 服务未安装，跳过"
        return 1
    fi
    
    case "$linkage_type" in
        redirect)
            _linkage_ensure_user
            _linkage_set_service_user "$service_name" "$LINKAGE_USER"
            systemctl restart "$service_name" 2>/dev/null
            sleep 1
            if systemctl is-active --quiet "$service_name"; then
                db_set_linkage_protocol "$proto_key" "true"
                print_ok "$proto_name 联动已启用 (iptables REDIRECT)"
            else
                print_err "$proto_name 以联动用户重启失败，回滚..."
                _linkage_set_service_user "$service_name" "root"
                systemctl restart "$service_name" 2>/dev/null
                return 1
            fi
            ;;
        native)
            if [[ "$proto_key" == "hysteria2" ]]; then
                _linkage_setup_hysteria2 && db_set_linkage_protocol "$proto_key" "true"
            fi
            ;;
    esac
}

_linkage_disable_protocol() {
    local proto_key="$1"
    local proto_info="${LINKAGE_PROTOCOLS[$proto_key]:-}"
    [[ -z "$proto_info" ]] && return
    
    local proto_name=$(echo "$proto_info" | cut -d'|' -f1)
    local service_name=$(echo "$proto_info" | cut -d'|' -f2)
    local linkage_type=$(echo "$proto_info" | cut -d'|' -f3)
    
    case "$linkage_type" in
        redirect)
            if systemctl cat "$service_name" &>/dev/null; then
                _linkage_set_service_user "$service_name" "root"
                _linkage_fix_permissions "$service_name" "root"
                systemctl restart "$service_name" 2>/dev/null
            fi
            db_set_linkage_protocol "$proto_key" "false"
            print_ok "$proto_name 联动已禁用"
            ;;
        native)
            if [[ "$proto_key" == "hysteria2" ]]; then
                _linkage_restore_hysteria2
            fi
            db_set_linkage_protocol "$proto_key" "false"
            ;;
    esac
}

_linkage_disable_all_quiet() {
    for key in "${!LINKAGE_PROTOCOLS[@]}"; do
        local enabled=$(db_get_linkage_protocol "$key")
        [[ "$enabled" == "true" ]] && _linkage_disable_protocol "$key" 2>/dev/null
    done
    _linkage_cleanup_iptables 2>/dev/null
    _linkage_unpersist_iptables 2>/dev/null
}

manage_linkage() {
    while true; do
        echo ""
        print_dline
        echo -e "${BOLD}  🔗 协议联动管理${PLAIN}"
        echo -e "${GRAY}  让已安装的协议流量通过分流规则路由${PLAIN}"
        print_dline
        
        local socks=$(db_get_socks_inbound)
        if [[ -z "$socks" || "$socks" == "null" ]]; then
            echo ""
            print_err "分流服务未就绪，请等待自动初始化完成"
            echo ""
            read -rp "按回车键返回..."
            return
        fi
        
        local node_count=$(db_get_nodes | jq 'length' 2>/dev/null || echo 0)
        if [[ "$node_count" -eq 0 ]]; then
            echo ""
            print_warn "尚未添加任何出口节点，联动后所有流量将直连"
        fi
        
        local socks_port=$(echo "$socks" | jq -r '.port')
        echo ""
        echo -e "  ${CYAN}分流入口: SOCKS5 127.0.0.1:${socks_port}  |  透明代理 :${LINKAGE_TPROXY_PORT}${PLAIN}"
        print_line
        echo ""
        
        local idx=1
        local sorted_keys=(anytls tuic ss2022 hysteria2 mieru vless sudoku)
        local available_keys=()
        
        for key in "${sorted_keys[@]}"; do
            local info="${LINKAGE_PROTOCOLS[$key]}"
            local name=$(echo "$info" | cut -d'|' -f1)
            local svc=$(echo "$info" | cut -d'|' -f2)
            local type=$(echo "$info" | cut -d'|' -f3)
            local enabled=$(db_get_linkage_protocol "$key")
            
            local installed=false
            if systemctl cat "$svc" &>/dev/null 2>&1; then
                installed=true
            fi
            
            local status_str=""
            local type_str=""
            case "$type" in
                redirect) type_str="${GRAY}透明代理${PLAIN}" ;;
                native)   type_str="${GRAY}原生outbound${PLAIN}" ;;
            esac
            
            if [[ "$installed" == "false" ]]; then
                status_str="${GRAY}⬜ 未安装${PLAIN}"
            elif [[ "$enabled" == "true" ]]; then
                status_str="${GREEN}● 已联动${PLAIN}"
            else
                status_str="${YELLOW}○ 未联动${PLAIN}"
            fi
            
            echo -e "  ${GREEN}${idx}.${PLAIN} ${name} ${type_str}  ${status_str}"
            available_keys+=("$key")
            ((idx++))
        done
        
        echo ""
        print_line
        echo -e "  ${GREEN}a.${PLAIN} 一键启用全部已安装协议"
        echo -e "  ${RED}d.${PLAIN} 一键禁用全部联动"
        echo -e "  ${GRAY}0.${PLAIN} 返回"
        print_line
        echo ""
        
        read -rp "  请选择 [0-${#available_keys[@]}/a/d]: " choice
        
        case "$choice" in
            0|"") return ;;
            a|A)
                echo ""
                _linkage_enable_all
                echo ""
                read -rp "按回车键继续..."
                ;;
            d|D)
                echo ""
                _linkage_disable_all
                echo ""
                read -rp "按回车键继续..."
                ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#available_keys[@]} ]]; then
                    local sel_key="${available_keys[$((choice-1))]}"
                    local enabled=$(db_get_linkage_protocol "$sel_key")
                    echo ""
                    if [[ "$enabled" == "true" ]]; then
                        _linkage_disable_protocol "$sel_key"
                    else
                        _linkage_enable_protocol "$sel_key"
                    fi
                    _linkage_refresh
                    echo ""
                    read -rp "按回车键继续..."
                fi
                ;;
        esac
    done
}

_linkage_enable_all() {
    print_info "正在启用所有已安装协议的联动..."
    echo ""
    
    for key in "${!LINKAGE_PROTOCOLS[@]}"; do
        local info="${LINKAGE_PROTOCOLS[$key]}"
        local svc=$(echo "$info" | cut -d'|' -f2)
        
        if systemctl cat "$svc" &>/dev/null 2>&1; then
            _linkage_enable_protocol "$key"
        fi
    done
    
    _linkage_refresh
    print_ok "全部联动已启用"
}

_linkage_disable_all() {
    print_info "正在禁用所有协议联动..."
    echo ""
    
    for key in "${!LINKAGE_PROTOCOLS[@]}"; do
        local enabled=$(db_get_linkage_protocol "$key")
        [[ "$enabled" == "true" ]] && _linkage_disable_protocol "$key"
    done
    
    _linkage_cleanup_iptables
    _linkage_unpersist_iptables
    
    generate_xray_config && svc_restart
    
    print_ok "全部联动已禁用"
}

_linkage_refresh() {
    local has_redirect=false
    for key in "${!LINKAGE_PROTOCOLS[@]}"; do
        local enabled=$(db_get_linkage_protocol "$key")
        local info="${LINKAGE_PROTOCOLS[$key]}"
        local type=$(echo "$info" | cut -d'|' -f3)
        if [[ "$enabled" == "true" && "$type" == "redirect" ]]; then
            has_redirect=true
            break
        fi
    done
    
    generate_xray_config
    
    if svc_status; then
        svc_restart
    else
        svc_start
    fi
    
    if [[ "$has_redirect" == "true" ]]; then
        _linkage_setup_iptables
        _linkage_persist_iptables
    else
        _linkage_cleanup_iptables
        _linkage_unpersist_iptables
    fi
}

# ============================================================
# 主菜单
# ============================================================

show_menu() {
    clear
    print_dline
    echo -e "${BOLD}    🏠 Alice 家宽分流管理 v${VERSION}${PLAIN}"
    echo -e "${GRAY}       github.com/10000ge10000/own-rules${PLAIN}"
    echo -e "${YELLOW}       ⚠ 仅支持 Alice 自家机器部署使用${PLAIN}"
    print_dline
    
    local socks=$(db_get_socks_inbound)
    local socks_status="${GRAY}○ 未就绪${PLAIN}"
    if [[ -n "$socks" && "$socks" != "null" ]]; then
        local port=$(echo "$socks" | jq -r '.port')
        if svc_status; then
            socks_status="${GREEN}● 运行中 127.0.0.1:${port}${PLAIN}"
        else
            socks_status="${YELLOW}⏸ 已停止${PLAIN}"
        fi
    fi
    
    local node_count=$(db_get_nodes | jq 'length' 2>/dev/null || echo 0)
    local rule_count=$(db_get_rules | jq 'length' 2>/dev/null || echo 0)
    
    local linkage_count=0
    for key in "${!LINKAGE_PROTOCOLS[@]}"; do
        [[ $(db_get_linkage_protocol "$key") == "true" ]] && ((linkage_count++))
    done
    
    echo -e "  分流: ${socks_status}  节点: ${CYAN}${node_count}${PLAIN}  规则: ${CYAN}${rule_count}${PLAIN}  联动: ${CYAN}${linkage_count}${PLAIN}"
    print_line
    echo ""
    
    echo -e " ${BOLD}🔗 协议联动${PLAIN}"
    print_line
    if [[ $linkage_count -gt 0 ]]; then
        echo -e "  ${GREEN}1.${PLAIN} 管理协议联动 ${GREEN}(${linkage_count}个协议已联动)${PLAIN}"
    else
        echo -e "  ${GREEN}1.${PLAIN} 管理协议联动 ${GRAY}(让其他协议流量走分流)${PLAIN}"
    fi
    echo ""
    
    echo -e " ${BOLD}🔀 分流管理${PLAIN}"
    print_line
    echo -e "  ${GREEN}2.${PLAIN} 配置分流规则"
    echo -e "  ${GREEN}3.${PLAIN} 测试分流效果"
    echo -e "  ${GREEN}8.${PLAIN} 负载均衡策略"
    echo ""
    
    echo -e " ${BOLD}📊 状态${PLAIN}"
    print_line
    echo -e "  ${GREEN}4.${PLAIN} 查看详细状态"
    echo ""
    
    echo -e " ${BOLD}⚙️  系统${PLAIN}"
    print_line
    if svc_status 2>/dev/null; then
        echo -e "  ${GREEN}5.${PLAIN} 重启服务"
        echo -e "  ${YELLOW}6.${PLAIN} 停止服务"
    else
        echo -e "  ${GREEN}5.${PLAIN} 启动服务"
    fi
    echo -e "  ${RED}7.${PLAIN} 完全卸载"
    echo ""
    echo -e "  ${GRAY}0.${PLAIN}  返回/退出"
    
    print_dline
    echo ""
    read -rp " 请选择 [0-8]: " choice
    
    case "$choice" in
        1) manage_linkage ;;
        2) setup_routing_rules ;;
        3) _test_routing ;;
        4) show_status; echo ""; read -rp "按回车键继续..." ;;
        5)
            if svc_status 2>/dev/null; then
                svc_restart
            else
                generate_xray_config && svc_start
            fi
            ;;
        6) svc_stop ;;
        7) do_uninstall ;;
        8) manage_balancer_strategy ;;
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
    
    echo ""
    print_info "正在初始化分流服务..."
    auto_init
    echo ""
    
    while show_menu; do
        :
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
