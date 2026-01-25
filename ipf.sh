#!/bin/bash
# ==============================================================
# 脚本名称: IPTables Port Forwarding Manager (IPF)
# 文件名称: ipf.sh
# 功能描述: 端口转发管理 (支持域名解析、备注、TCP+UDP合并显示)
# ==============================================================

# --- 全局变量与配色 ---
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 颜色定义
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[36m'
PLAIN='\033[0m'

# 配置文件定义
# 格式: 协议|本地端口|目标IP|目标端口|备注
CONF_DIR="/etc/ip-forward"
CONF_FILE="${CONF_DIR}/conf.db"
SCRIPT_PATH=$(readlink -f "$0")
CMD_NAME="ipf"

# --- 基础检查与环境准备 ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[错误] 请使用 root 权限运行此脚本！${PLAIN}"
        exit 1
    fi
}

check_sys() {
    if [[ -f /etc/redhat-release ]]; then
        RELEASE="centos"
    elif cat /etc/issue | grep -q -E -i "debian"; then
        RELEASE="debian"
    elif cat /etc/issue | grep -q -E -i "ubuntu"; then
        RELEASE="ubuntu"
    elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
        RELEASE="centos"
    elif cat /proc/version | grep -q -E -i "debian"; then
        RELEASE="debian"
    elif cat /proc/version | grep -q -E -i "ubuntu"; then
        RELEASE="ubuntu"
    elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
        RELEASE="centos"
    else
        echo -e "${RED}[错误] 不支持的操作系统！${PLAIN}"
        exit 1
    fi
}

install_dependencies() {
    echo -e "${BLUE}[信息] 正在检查并安装依赖...${PLAIN}"
    
    # 开启内核转发
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/ip_forward.conf
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.d/ip_forward.conf
    sysctl -p /etc/sysctl.d/ip_forward.conf >/dev/null 2>&1

    if [ "${RELEASE}" == "centos" ]; then
        yum install -y iptables iptables-services bind-utils
        systemctl stop firewalld
        systemctl disable firewalld
        systemctl enable iptables
        systemctl start iptables
    elif [ "${RELEASE}" == "debian" ] || [ "${RELEASE}" == "ubuntu" ]; then
        apt-get update
        apt-get install -y iptables iptables-persistent netfilter-persistent dnsutils
        systemctl enable netfilter-persistent
        systemctl start netfilter-persistent
    fi

    # 创建配置目录
    if [ ! -d "${CONF_DIR}" ]; then
        mkdir -p "${CONF_DIR}"
    fi
    if [ ! -f "${CONF_FILE}" ]; then
        touch "${CONF_FILE}"
    fi

    # 安装全局命令
    if [ ! -f "/usr/bin/${CMD_NAME}" ]; then
        ln -sf "${SCRIPT_PATH}" "/usr/bin/${CMD_NAME}"
        chmod +x "/usr/bin/${CMD_NAME}"
        echo -e "${GREEN}[成功] 安装完成！${PLAIN}"
        echo -e "${GREEN}==============================================${PLAIN}"
        echo -e "${GREEN}  请在终端输入 ${YELLOW}${CMD_NAME}${GREEN} 进入管理面板  ${PLAIN}"
        echo -e "${GREEN}==============================================${PLAIN}"
    fi
}

# --- 核心逻辑函数 ---

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

is_ipv6() {
    local ip=$1
    if [[ "$ip" =~ : ]]; then return 0; else return 1; fi
}

check_port() {
    local port=$1
    if [[ ! $port =~ ^[0-9]+(:[0-9]+)?$ ]]; then return 1; fi
    return 0
}

# 域名解析逻辑
resolve_ip() {
    local target=$1
    local resolved_ip=""

    # 1. 判断是否已经是合法 IPv4
    if [[ "$target" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$target"
        return 0
    fi

    # 2. 判断是否已经是合法 IPv6 (简单的含冒号检查)
    if [[ "$target" =~ : ]]; then
        echo "$target"
        return 0
    fi

    # 3. 尝试解析 (优先 IPv4)
    # 使用 getent ahosts 是一种标准且兼容性好的方法
    resolved_ip=$(getent ahostsv4 "$target" | head -n1 | awk '{print $1}')
    
    # 4. 如果 IPv4 解析失败，尝试 IPv6
    if [[ -z "$resolved_ip" ]]; then
        resolved_ip=$(getent ahostsv6 "$target" | head -n1 | awk '{print $1}')
    fi

    if [[ -n "$resolved_ip" ]]; then
        echo "$resolved_ip"
        return 0
    else
        return 1
    fi
}

save_iptables() {
    if [ "${RELEASE}" == "centos" ]; then
        service iptables save >/dev/null 2>&1
        service ip6tables save >/dev/null 2>&1
    else
        netfilter-persistent save >/dev/null 2>&1
    fi
}

# 统一处理规则添加/删除 (底层逻辑)
# op: add / del
manage_iptables_rule() {
    local op=$1
    local proto=$2
    local lport=$3
    local dip=$4
    local dport=$5

    # 定义动作参数
    local action=""
    if [ "$op" == "add" ]; then action="-A"; else action="-D"; fi

    # 定义具体的 iptables 命令处理函数
    run_ipt() {
        local p=$1
        if is_ipv6 "${dip}"; then
            # IPv6
            ip6tables -t nat ${action} PREROUTING -p "$p" --dport "${lport}" -j DNAT --to-destination "[${dip}]:${dport}"
            ip6tables -t nat ${action} POSTROUTING -p "$p" -d "${dip}" --dport "${dport}" -j MASQUERADE
            ip6tables ${action} FORWARD -p "$p" -d "${dip}" --dport "${dport}" -j ACCEPT
        else
            # IPv4
            iptables -t nat ${action} PREROUTING -p "$p" --dport "${lport}" -j DNAT --to-destination "${dip}:${dport}"
            iptables -t nat ${action} POSTROUTING -p "$p" -d "${dip}" --dport "${dport}" -j MASQUERADE
            iptables ${action} FORWARD -p "$p" -d "${dip}" --dport "${dport}" -j ACCEPT
        fi
    }

    # 根据协议类型执行
    if [ "$proto" == "tcp+udp" ]; then
        run_ipt "tcp"
        run_ipt "udp"
    else
        run_ipt "$proto"
    fi
}

# --- 菜单功能函数 ---

add_rule() {
    echo -e "${BLUE}=== 新增端口转发规则 ===${PLAIN}"
    
    # 1. 本地端口
    read -p "请输入本地监听端口 (如 80 或 1000:2000): " lport
    if ! check_port "$lport"; then echo -e "${RED}端口格式错误!${PLAIN}"; return; fi

    # 2. 目标 IP 或 域名
    read -p "请输入目标 IP 或 域名: " dest_input
    if [[ -z "$dest_input" ]]; then echo -e "${RED}目标不能为空!${PLAIN}"; return; fi

    # --- 解析过程 ---
    local dip=""
    dip=$(resolve_ip "$dest_input")
    
    if [[ $? -ne 0 || -z "$dip" ]]; then
        echo -e "${RED}[错误] 无法解析域名: ${dest_input}${PLAIN}"
        echo -e "${YELLOW}请检查域名拼写或 DNS 设置。${PLAIN}"
        return
    fi

    # 如果输入值和解析后的 IP 不同，说明输入的是域名
    if [[ "$dest_input" != "$dip" ]]; then
        echo -e "${GREEN}[信息] 域名解析成功: ${dest_input} -> ${dip}${PLAIN}"
    fi

    # 3. 目标端口
    read -p "请输入目标端口 (如 80 或 1000:2000): " dport
    if ! check_port "$dport"; then echo -e "${RED}端口格式错误!${PLAIN}"; return; fi

    # 4. 协议
    echo -e "请选择转发协议:"
    echo -e "1. TCP"
    echo -e "2. UDP"
    echo -e "3. TCP + UDP"
    read -p "(默认 1): " proto_idx
    local proto="tcp"
    case "${proto_idx}" in
        2) proto="udp" ;;
        3) proto="tcp+udp" ;;
        *) proto="tcp" ;;
    esac

    # 5. 备注 (自动填充逻辑)
    # 如果用户输入的是域名，且没有填备注，默认备注设为域名
    local default_remark="无"
    if [[ "$dest_input" != "$dip" ]]; then
        default_remark="$dest_input"
    fi
    
    read -p "请输入备注 (回车默认: ${default_remark}): " remark
    if [[ -z "$remark" ]]; then remark="$default_remark"; fi
    
    # 简单的输入清洗，防止破坏数据库格式
    remark=${remark//|/-}

    # 执行系统命令
    manage_iptables_rule "add" "$proto" "$lport" "$dip" "$dport"
    
    # 写入配置文件 (单行记录)
    echo "${proto}|${lport}|${dip}|${dport}|${remark}" >> "${CONF_FILE}"

    save_iptables
    echo -e "${GREEN}[成功] 规则已添加！${PLAIN}"
    
    # 友情提示 DDNS 问题
    if [[ "$dest_input" != "$dip" ]]; then
        echo -e "${YELLOW}[注意] iptables 转发使用静态 IP。如果域名 ${dest_input} 的 IP 发生变化，你需要删除规则重新添加。${PLAIN}"
    fi
}

list_rules() {
    echo -e "${BLUE}=== 当前端口转发规则列表 ===${PLAIN}"
    if [ ! -s "${CONF_FILE}" ]; then
        echo -e "${YELLOW}暂无规则。${PLAIN}"
        return
    fi

    # 表头格式化
    printf "${YELLOW}%-4s %-8s %-12s %-25s %-15s${PLAIN}\n" "ID" "协议" "本地端口" "目标地址" "备注"
    echo "-----------------------------------------------------------------------"
    
    local i=1
    while IFS='|' read -r proto lport dip dport remark; do
        # 目标地址格式化
        local dest_display=""
        if is_ipv6 "$dip"; then
            dest_display="[${dip}]:${dport}"
        else
            dest_display="${dip}:${dport}"
        fi
        
        # 截断过长的备注以便显示
        local short_remark=${remark:0:20}
        
        printf "%-4s %-8s %-12s %-25s %-15s\n" "$i" "$proto" "$lport" "$dest_display" "$short_remark"
        ((i++))
    done < "${CONF_FILE}"
    echo "-----------------------------------------------------------------------"
}

delete_rule() {
    list_rules
    if [ ! -s "${CONF_FILE}" ]; then return; fi

    read -p "请输入要删除的规则 ID (输入 0 取消): " choice
    if [[ "$choice" == "0" || -z "$choice" ]]; then return; fi

    local rule_line=$(sed -n "${choice}p" "${CONF_FILE}")
    if [[ -z "$rule_line" ]]; then
        echo -e "${RED}ID 无效!${PLAIN}"
        return
    fi

    IFS='|' read -r proto lport dip dport remark <<< "$rule_line"

    # 删除 iptables 规则
    manage_iptables_rule "del" "$proto" "$lport" "$dip" "$dport"

    # 删除配置文件
    sed -i "${choice}d" "${CONF_FILE}"
    
    save_iptables
    echo -e "${GREEN}[成功] 规则已删除！${PLAIN}"
}

clear_rules() {
    read -p "确定要清空所有规则吗？(y/n): " confirm
    if [[ "$confirm" != "y" ]]; then return; fi

    while IFS='|' read -r proto lport dip dport remark; do
        manage_iptables_rule "del" "$proto" "$lport" "$dip" "$dport"
    done < "${CONF_FILE}"

    > "${CONF_FILE}"
    save_iptables
    echo -e "${GREEN}[成功] 所有转发规则已清空。${PLAIN}"
}

uninstall() {
    read -p "确定要卸载脚本并清除所有规则吗？(y/n): " confirm
    if [[ "$confirm" != "y" ]]; then return; fi

    echo -e "${BLUE}正在清除规则...${PLAIN}"
    if [ -f "${CONF_FILE}" ]; then
        while IFS='|' read -r proto lport dip dport remark; do
            manage_iptables_rule "del" "$proto" "$lport" "$dip" "$dport" >/dev/null 2>&1
        done < "${CONF_FILE}"
    fi
    save_iptables

    rm -rf "${CONF_DIR}"
    rm -f "/usr/bin/${CMD_NAME}"
    echo -e "${GREEN}[成功] 卸载完成。${PLAIN}"
    exit 0
}

# --- 主菜单 ---

show_menu() {
    clear
    echo -e "==========================================="
    echo -e " ${GREEN}iptables 端口转发管理脚本 (IPF)${PLAIN}"
    echo -e " ${YELLOW}系统: ${RELEASE} | 状态: 运行中${PLAIN}"
    echo -e "==========================================="
    echo -e " 1. 查看 转发规则"
    echo -e " 2. 新增 转发规则 ${YELLOW}(支持域名/TCP+UDP)${PLAIN}"
    echo -e " 3. 删除 转发规则"
    echo -e " 4. 清空 所有规则"
    echo -e " 5. 卸载 脚本工具"
    echo -e " 0. 退出"
    echo -e "==========================================="
    read -p "请输入选项 [0-5]: " num

    case "$num" in
        1) list_rules; read -p "按回车键继续..." ;;
        2) add_rule; read -p "按回车键继续..." ;;
        3) delete_rule; read -p "按回车键继续..." ;;
        4) clear_rules; read -p "按回车键继续..." ;;
        5) uninstall ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入错误，请重新输入!${PLAIN}"; sleep 1 ;;
    esac
}

# --- 入口处理 ---

check_root
check_sys

if [ ! -f "/usr/bin/${CMD_NAME}" ]; then
    install_dependencies
    # 强制让用户确认已安装
    read -p "按回车键进入面板..."
fi

while true; do
    show_menu
done
