#!/bin/bash

# ================= 路径配置 =================
CONFIG_FILE="/etc/autodns/config.env"
BACKOFF_FILE="/tmp/dns_monitor_backoff"
# ===========================================

# 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    echo "未找到配置文件，请先运行安装脚本"
    exit 1
fi

source "$CONFIG_FILE"

# 基础 DNS 池
BASE_DNS_LIST=("8.8.4.4" "1.0.0.1" "8.8.8.8" "1.1.1.1")
# 合并用户自定义 DNS
FULL_DNS_LIST=("${BASE_DNS_LIST[@]}" $EXTRA_DNS_LIST)

# --- 函数: 获取延迟 (强化版) ---
get_latency() {
    # 逻辑说明：
    # 1. ping 4次 (提高样本准确度)
    # 2. 只有当 ping 成功退出 (exit code 0) 才分析数据
    # 3. 提取 avg 值，并去掉小数点，只取整数部分
    
    output=$(ping -c 4 -w 5 $TARGET_DOMAIN 2>&1)
    if [ $? -eq 0 ]; then
        # 提取 rtt 行的 avg 值 (兼容不同 ping 版本输出)
        # 常见格式: rtt min/avg/max/mdev = 2.790/2.824/2.862/0.029 ms
        latency=$(echo "$output" | grep -E 'rtt|round-trip' | awk -F '/' '{print $5}' | awk -F. '{print $1}')
        
        # 二次检查: 确保提取到的是数字
        if [[ "$latency" =~ ^[0-9]+$ ]]; then
            echo "$latency"
        else
            echo 9999 # 解析格式错误
        fi
    else
        echo 9999 # Ping 不通或域名解析失败
    fi
}

# --- 函数: 发送TG通知 ---
send_tg_msg() {
    local msg="$1"
    if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        local header="🖥 *服务器*: ${SERVER_REMARK}%0A🌐 *IP*: ${SERVER_IP}%0A--------------------------------%0A"
        local final_msg="${header}${msg}"
        curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
            -d chat_id="$TG_CHAT_ID" \
            -d parse_mode="Markdown" \
            -d text="$final_msg" > /dev/null
    fi
}

# --- 主逻辑 ---

# 1. 冷却期检查
if [ -f "$BACKOFF_FILE" ]; then
    last_fail_time=$(stat -c %Y "$BACKOFF_FILE")
    current_time=$(date +%s)
    if [ $((current_time - last_fail_time)) -lt 1800 ]; then
        exit 0
    else
        rm -f "$BACKOFF_FILE"
    fi
fi

# 2. 初始检测
current_latency=$(get_latency)
# 如果当前已经在 10ms 以内，直接收工
if [ "$current_latency" -le "$LATENCY_THRESHOLD" ]; then
    exit 0
fi

# 3. 开始循环寻找新 DNS
success_flag=0
log_details="" # 用于记录失败详情

for dns in "${FULL_DNS_LIST[@]}"; do
    # A. 修改 DNS
    echo "nameserver $dns" > /etc/resolv.conf
    
    # B. 【关键】强制等待 2 秒，让网络栈刷新，防止 Ping 太快报错
    sleep 2 
    
    # C. 测试延迟
    new_latency=$(get_latency)
    
    # 记录日志 (用于失败时汇报)
    if [ "$new_latency" -eq 9999 ]; then
        log_details="${log_details}\`${dns}\`: ❌超时/阻断%0A"
    else
        log_details="${log_details}\`${dns}\`: ${new_latency}ms%0A"
    fi
    
    # D. 判断是否达标
    if [ "$new_latency" -le "$LATENCY_THRESHOLD" ]; then
        success_flag=1
        msg="✅ *网络优化成功！*%0A👉 新 DNS: \`$dns\`%0A🚀 延迟: ${new_latency}ms%0A%0A(原延迟: ${current_latency}ms)"
        send_tg_msg "$msg"
        break
    fi
done

# 4. 全部失败处理
if [ $success_flag -eq 0 ]; then
    # 恢复到列表第一个 DNS (保底措施)，防止停留在最后那个可能不通的 DNS 上
    first_dns="${FULL_DNS_LIST[0]}"
    echo "nameserver $first_dns" > /etc/resolv.conf
    
    # 发送详细的失败报告
    msg="⚠️ *网络优化失败*%0A已尝试所有 DNS，延迟均不达标。%0A%0A*测试详情:*%0A${log_details}%0A💤 脚本暂停 30 分钟，DNS 已重置为: \`$first_dns\`"
    send_tg_msg "$msg"
    
    touch "$BACKOFF_FILE"
fi
