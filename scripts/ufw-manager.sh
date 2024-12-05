#!/bin/bash

# 检查root权限
if [ $UID -ne 0 ]; then
    echo "请使用root权限运行此脚本"
    exit 1
fi

# 检查必要命令
for cmd in ufw ss; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "未找到命令: $cmd"
        exit 1
    fi
done

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# 表格样式
TOP_LEFT="┌"
TOP_RIGHT="┐"
BOTTOM_LEFT="└"
BOTTOM_RIGHT="┘"
HORIZONTAL="─"
VERTICAL="│"
LEFT_T="├"
RIGHT_T="┤"
TOP_T="┬"
BOTTOM_T="┴"
CROSS="┼"

# 清屏函数
clear_screen() {
    printf "\033c"
}

# 绘制水平线
draw_line() {
    local width=$1
    local start=$2
    local end=$3
    printf "%s%${width}s%s\n" "$start" | sed "s/ /$HORIZONTAL/g" "$end"
}

# 打印带颜色的表格行
print_row() {
    local width=$1
    shift
    printf "$VERTICAL %b%-$((width-3))s$NC $VERTICAL\n" "$*"
}

# 获取防火墙状态
get_ufw_status() {
    if ! status=$(ufw status 2>/dev/null); then
        echo -e "${RED}错误${NC}"
        return 1
    fi

    if echo "$status" | grep -q "Status: active"; then
        echo -e "${GREEN}启用${NC}"
    else
        echo -e "${RED}禁用${NC}"
    fi
}

# 检查端口使用状态
check_port_usage() {
    local port=$1
    if ss -tunlp4 | grep -q ":$port " || ss -tunlp6 | grep -q ":$port "; then
        return 0
    fi
    return 1
}

# 获取开放端口列表
get_open_ports() {
    ufw status | grep "^[0-9]" | awk '{print $1}' | cut -d'/' -f1 | sort -un | \
    while read -r port; do
        if [ -n "$port" ]; then
            if check_port_usage "$port"; then
                echo -e "${GREEN}端口 $port [使用中]${NC}"
            else
                echo -e "${YELLOW}端口 $port [未使用]${NC}"
            fi
        fi
    done
}

# 显示主界面
show_main_menu() {
    clear_screen
    local width=50

    echo -e "\n$WHITE UFW 防火墙管理工具 $NC\n"
    echo -e "$CYAN=====================================$NC"
    echo -e "$WHITE 防火墙状态: $(get_ufw_status)$NC"
    echo -e "$CYAN=====================================$NC"
    echo -e "$WHITE 已开放端口列表:$NC"
    get_open_ports
    echo -e "$CYAN=====================================$NC"
    echo -e "${WHITE}1. 开启/关闭防火墙"
    echo -e "2. 添加端口规则"
    echo -e "3. 删除端口规则"
    echo -e "4. 查看详细信息"
    echo -e "5. 退出${NC}"
    echo -e "$CYAN=====================================$NC"
}

# 显示详细信息
show_details() {
    clear_screen
    echo -e "\n$WHITE                详细端口使用情况$NC\n"

    # IPv4 端口信息
    echo -e "$CYAN═══════════════════════════════════════════════════════════════════════$NC"
    echo -e "$GREEN◆ IPv4 端口使用情况:$NC"
    echo -e "$CYAN───────────────────────────────────────────────────────────────────────$NC"
    printf "${WHITE}%-15s %-10s %-15s %-25s${NC}\n" "协议" "端口" "状态" "程序(PID)"
    echo -e "$CYAN───────────────────────────────────────────────────────────────────────$NC"

    ss -tunlp4 | grep LISTEN | while read -r line; do
        proto=$(echo "$line" | awk '{print $1}')
        addr=$(echo "$line" | awk '{print $4}')
        pid_prog=$(echo "$line" | awk '{print $NF}' | sed 's/users:((//' | sed 's/))//')
        port=$(echo "$addr" | cut -d: -f2)
        printf "${GREEN}%-15s %-10s %-15s %-25s${NC}\n" "$proto" "$port" "LISTEN" "$pid_prog"
    done

    # IPv6 端口信息
    echo -e "$CYAN═══════════════════════════════════════════════════════════════════════$NC"
    echo -e "$BLUE◆ IPv6 端口使用情况:$NC"
    echo -e "$CYAN───────────────────────────────────────────────────────────────────────$NC"
    printf "${WHITE}%-15s %-10s %-15s %-25s${NC}\n" "协议" "端口" "状态" "程序(PID)"
    echo -e "$CYAN───────────────────────────────────────────────────────────────────────$NC"

    ss -tunlp6 | grep LISTEN | while read -r line; do
        proto=$(echo "$line" | awk '{print $1}')
        addr=$(echo "$line" | awk '{print $4}')
        pid_prog=$(echo "$line" | awk '{print $NF}' | sed 's/users:((//' | sed 's/))//')
        port=$(echo "$addr" | cut -d: -f2)
        printf "${BLUE}%-15s %-10s %-15s %-25s${NC}\n" "$proto" "$port" "LISTEN" "$pid_prog"
    done

    # UFW 规则列表
    echo -e "$CYAN═══════════════════════════════════════════════════════════════════════$NC"
    echo -e "$YELLOW◆ UFW 规则列表:$NC"
    echo -e "$CYAN───────────────────────────────────────────────────────────────────────$NC"
    printf "${WHITE}%-10s %-15s %-15s %-25s${NC}\n" "规则号" "端口/协议" "动作" "来源"
    echo -e "$CYAN───────────────────────────────────────────────────────────────────────$NC"

    ufw status numbered | grep "\[.*\]" | sed 's/\[//g;s/\]//g' | \
    while read -r num rule action from; do
        printf "${YELLOW}%-10s %-15s %-15s %-25s${NC}\n" "$num" "$rule" "$action" "$from"
    done

    echo -e "$CYAN═══════════════════════════════════════════════════════════════════════$NC"
    echo -e "${WHITE}按回车返回主菜单...${NC}"
    read
}

# 添加端口规则
add_port() {
    echo -e "\n${WHITE}添加端口规则${NC}"
    echo -e "$CYAN─────────────────────────────$NC"
    read -p "请输入要开放的端口号: " port

    if [[ ! $port =~ ^[0-9]+$ ]] || [ $port -lt 1 ] || [ $port -gt 65535 ]; then
        echo -e "${RED}无效的端口号!${NC}"
        read -p "按回车继续..."
        return 1
    fi

    # 添加IPv4和IPv6的TCP/UDP规则
    for proto in tcp udp; do
        yes | ufw allow $port/$proto >/dev/null 2>&1
        yes | ufw allow $port/$proto from any to any >/dev/null 2>&1
    done

    echo -e "${GREEN}端口规则添加成功!${NC}"
    read -p "按回车继续..."
}

# 删除端口规则
delete_port() {
    echo -e "\n${WHITE}删除端口规则${NC}"
    echo -e "$CYAN─────────────────────────────$NC"
    read -p "请输入要删除的端口号: " port

    if [[ ! $port =~ ^[0-9]+$ ]] || [ $port -lt 1 ] || [ $port -gt 65535 ]; then
        echo -e "${RED}无效的端口号!${NC}"
        read -p "按回车继续..."
        return 1
    fi

    # 获取包含该端口的所有规则号
    rules=$(ufw status numbered | grep "$port/" | sed 's/\[\([0-9]*\)\].*/\1/')

    if [ -z "$rules" ]; then
        echo -e "${RED}未找到该端口的规则!${NC}"
        read -p "按回车继续..."
        return 1
    fi

    # 从最大规则号开始删除
    for rule in $(echo "$rules" | sort -nr); do
        yes | ufw delete $rule >/dev/null 2>&1
    done

    echo -e "${GREEN}端口规则删除成功!${NC}"
    read -p "按回车继续..."
}

# 主循环
while true; do
    show_main_menu
    read -p "请选择操作[1-5]: " choice

    case $choice in
        1)
            status=$(ufw status | grep Status | awk '{print $2}')
            if [ "$status" == "active" ]; then
                yes | ufw disable >/dev/null 2>&1
            else
                yes | ufw enable >/dev/null 2>&1
            fi
            ;;
        2)
            add_port
            ;;
        3)
            delete_port
            ;;
        4)
            show_details
            ;;
        5)
            echo -e "${WHITE}退出程序...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择!${NC}"
            read -p "按回车继续..."
            ;;
    esac
done