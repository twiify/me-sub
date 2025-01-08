#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 特殊 IP（用于重定向非法请求）
SPECIAL_IPV4="198.51.100.1"
SPECIAL_IPV6="2001:db8::1"

# IPv6 NAT 支持标志
IPV6_NAT_SUPPORT=false

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}请使用 root 权限运行此脚本${NC}"
    exit 1
fi

# 函数：检查 IPv6 NAT 支持
check_ipv6_nat() {
    if ip6tables -t nat -L >/dev/null 2>&1; then
        IPV6_NAT_SUPPORT=true
        echo -e "${GREEN}系统支持 IPv6 NAT${NC}"
    else
        IPV6_NAT_SUPPORT=false
        echo -e "${YELLOW}系统不支持 IPv6 NAT，将使用 filter 表方案${NC}"
    fi
}

# 函数：显示菜单
show_menu() {
    clear
    echo -e "${GREEN}Docker 防火墙配置脚本${NC}"
    echo "------------------------"
    echo "1. 创建新的防火墙规则"
    echo "2. 添加允许的 IP"
    echo "3. 删除允许的 IP"
    echo "4. 添加允许的端口"
    echo "5. 删除允许的端口"
    echo "6. 查看当前规则"
    echo "7. 删除所有规则"
    echo "8. 保存规则"
    echo "0. 退出"
    echo "------------------------"
}

# 函数：清理已存在的规则
clean_existing_rules() {
    echo -e "${YELLOW}清理已存在的防火墙规则...${NC}"
    
    # 删除 IPv4 规则
    iptables -t nat -D PREROUTING -j FIREWALL 2>/dev/null
    iptables -t filter -D FORWARD -j FIREWALL 2>/dev/null
    iptables -t nat -F FIREWALL
    iptables -t filter -F FIREWALL
    iptables -t nat -X FIREWALL 2>/dev/null
    iptables -t filter -X FIREWALL 2>/dev/null
    
    # 删除 IPv6 规则
    ip6tables -t filter -D FORWARD -j FIREWALL 2>/dev/null
    ip6tables -t filter -F FIREWALL
    ip6tables -t filter -X FIREWALL 2>/dev/null
    
    if $IPV6_NAT_SUPPORT; then
        ip6tables -t nat -D PREROUTING -j FIREWALL 2>/dev/null
        ip6tables -t nat -F FIREWALL
        ip6tables -t nat -X FIREWALL 2>/dev/null
    fi
    
    echo -e "${GREEN}已清理现有规则${NC}"
}

# 函数：创建基本规则
create_rules() {
    echo -e "${YELLOW}创建基本防火墙规则...${NC}"

    # 首先清理已存在的规则
    clean_existing_rules
    
    # IPv4 规则
    iptables -t nat -N FIREWALL 2>/dev/null
    iptables -t filter -N FIREWALL 2>/dev/null
    iptables -t nat -F FIREWALL
    iptables -t filter -F FIREWALL
    iptables -t nat -D PREROUTING -j FIREWALL 2>/dev/null
    iptables -t nat -I PREROUTING 1 -j FIREWALL
    iptables -t filter -D FORWARD -j FIREWALL 2>/dev/null
    iptables -t filter -I FORWARD 1 -j FIREWALL
    iptables -t filter -A FIREWALL -d $SPECIAL_IPV4 -j DROP
    iptables -t nat -A FIREWALL -j DNAT --to-destination $SPECIAL_IPV4
    
    # IPv6 规则
    ip6tables -t filter -N FIREWALL 2>/dev/null
    ip6tables -t filter -F FIREWALL
    ip6tables -t filter -D FORWARD -j FIREWALL 2>/dev/null
    ip6tables -t filter -I FORWARD 1 -j FIREWALL
    
    if $IPV6_NAT_SUPPORT; then
        ip6tables -t nat -N FIREWALL 2>/dev/null
        ip6tables -t nat -F FIREWALL
        ip6tables -t nat -D PREROUTING -j FIREWALL 2>/dev/null
        ip6tables -t nat -I PREROUTING 1 -j FIREWALL
        ip6tables -t filter -A FIREWALL -d $SPECIAL_IPV6 -j DROP
        ip6tables -t nat -A FIREWALL -j DNAT --to-destination $SPECIAL_IPV6
    else
        # 使用 filter 表方案
        ip6tables -t filter -A FIREWALL -j DROP
    fi

    iptables -A FIREWALL -m state --state ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A FIREWALL -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    echo -e "${GREEN}基本规则创建完成${NC}"
}

# 函数：添加允许的 IP
add_allowed_ip() {
    echo -e "${YELLOW}请输入要允许的 IP 地址（支持 IPv4/IPv6 CIDR 格式）：${NC}"
    read -r ip_addr
    
    if [[ $ip_addr =~ .*:.* ]]; then
        # IPv6
        if $IPV6_NAT_SUPPORT; then
            ip6tables -t nat -I FIREWALL -s "$ip_addr" -j RETURN
        fi
        ip6tables -t filter -I FIREWALL -s "$ip_addr" -j ACCEPT
        echo -e "${GREEN}已添加 IPv6: $ip_addr${NC}"
    elif [[ $ip_addr =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        # IPv4
        iptables -t nat -I FIREWALL -s "$ip_addr" -j RETURN
        iptables -t filter -I FIREWALL -s "$ip_addr" -j ACCEPT
        echo -e "${GREEN}已添加 IPv4: $ip_addr${NC}"
    else
        echo -e "${RED}无效的 IP 地址格式${NC}"
    fi
}

# 函数：删除允许的 IP
delete_allowed_ip() {
    echo -e "${YELLOW}请输入要删除的 IP 地址：${NC}"
    read -r ip_addr
    
    if [[ $ip_addr =~ .*:.* ]]; then
        # IPv6
        if $IPV6_NAT_SUPPORT; then
            ip6tables -t nat -D FIREWALL -s "$ip_addr" -j RETURN
        fi
        ip6tables -t filter -D FIREWALL -s "$ip_addr" -j ACCEPT
        echo -e "${GREEN}已删除 IPv6: $ip_addr${NC}"
    elif [[ $ip_addr =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        # IPv4
        iptables -t nat -D FIREWALL -s "$ip_addr" -j RETURN
        iptables -t filter -D FIREWALL -s "$ip_addr" -j ACCEPT
        echo -e "${GREEN}已删除 IPv4: $ip_addr${NC}"
    else
        echo -e "${RED}无效的 IP 地址格式${NC}"
    fi
}

# 函数：添加允许的端口
add_allowed_port() {
    echo -e "${YELLOW}请输入要允许的端口号：${NC}"
    read -r port
    
    if ! [[ $port =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}无效的端口号${NC}"
        return
    fi
    
    echo -e "${YELLOW}请选择协议：${NC}"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. 全部"
    read -r proto_choice
    
    case $proto_choice in
        1) proto="tcp" ;;
        2) proto="udp" ;;
        3) proto="all" ;;
        *) 
            echo -e "${RED}无效的选项${NC}"
            return
            ;;
    esac
    
    if [ "$proto" = "all" ]; then
        # IPv4
        iptables -t nat -I FIREWALL -p tcp --dport "$port" -j RETURN
        iptables -t nat -I FIREWALL -p udp --dport "$port" -j RETURN
        # IPv6
        if $IPV6_NAT_SUPPORT; then
            ip6tables -t nat -I FIREWALL -p tcp --dport "$port" -j RETURN
            ip6tables -t nat -I FIREWALL -p udp --dport "$port" -j RETURN
        fi
        ip6tables -t filter -I FIREWALL -p tcp --dport "$port" -j ACCEPT
        ip6tables -t filter -I FIREWALL -p udp --dport "$port" -j ACCEPT
    else
        # IPv4
        iptables -t nat -I FIREWALL -p "$proto" --dport "$port" -j RETURN
        # IPv6
        if $IPV6_NAT_SUPPORT; then
            ip6tables -t nat -I FIREWALL -p "$proto" --dport "$port" -j RETURN
        fi
        ip6tables -t filter -I FIREWALL -p "$proto" --dport "$port" -j ACCEPT
    fi
    
    echo -e "${GREEN}已添加端口: $port ($proto)${NC}"
}

# 函数：删除允许的端口
delete_allowed_port() {
    echo -e "${YELLOW}请输入要删除的端口号：${NC}"
    read -r port
    
    if ! [[ $port =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${RED}无效的端口号${NC}"
        return
    fi
    
    echo -e "${YELLOW}请选择协议：${NC}"
    echo "1. TCP"
    echo "2. UDP"
    echo "3. 全部"
    read -r proto_choice
    
    case $proto_choice in
        1) proto="tcp" ;;
        2) proto="udp" ;;
        3) proto="all" ;;
        *) 
            echo -e "${RED}无效的选项${NC}"
            return
            ;;
    esac
    
    if [ "$proto" = "all" ]; then
        # IPv4
        iptables -t nat -D FIREWALL -p tcp --dport "$port" -j RETURN
        iptables -t nat -D FIREWALL -p udp --dport "$port" -j RETURN
        # IPv6
        if $IPV6_NAT_SUPPORT; then
            ip6tables -t nat -D FIREWALL -p tcp --dport "$port" -j RETURN
            ip6tables -t nat -D FIREWALL -p udp --dport "$port" -j RETURN
        fi
        ip6tables -t filter -D FIREWALL -p tcp --dport "$port" -j ACCEPT
        ip6tables -t filter -D FIREWALL -p udp --dport "$port" -j ACCEPT
    else
        # IPv4
        iptables -t nat -D FIREWALL -p "$proto" --dport "$port" -j RETURN
        # IPv6
        if $IPV6_NAT_SUPPORT; then
            ip6tables -t nat -D FIREWALL -p "$proto" --dport "$port" -j RETURN
        fi
        ip6tables -t filter -D FIREWALL -p "$proto" --dport "$port" -j ACCEPT
    fi
    
    echo -e "${GREEN}已删除端口: $port ($proto)${NC}"
}

# 函数：查看当前规则
show_rules() {
    echo -e "${GREEN}IPv4 NAT 表 FIREWALL 链规则：${NC}"
    iptables -t nat -L FIREWALL -n -v
    echo
    echo -e "${GREEN}IPv4 Filter 表 FIREWALL 链规则：${NC}"
    iptables -t filter -L FIREWALL -n -v
    echo
    echo -e "${GREEN}IPv6 Filter 表 FIREWALL 链规则：${NC}"
    ip6tables -t filter -L FIREWALL -n -v
    
    if $IPV6_NAT_SUPPORT; then
        echo
        echo -e "${GREEN}IPv6 NAT 表 FIREWALL 链规则：${NC}"
        ip6tables -t nat -L FIREWALL -n -v
    fi
    
    echo -e "${YELLOW}按回车键继续...${NC}"
    read -r
}

# 函数：删除所有规则
delete_rules() {
    echo -e "${YELLOW}确定要删除所有规则吗？(y/n)${NC}"
    read -r confirm
    
    if [ "$confirm" = "y" ]; then
        # 删除 IPv4 规则
        iptables -t nat -D PREROUTING -j FIREWALL 2>/dev/null
        iptables -t filter -D FORWARD -j FIREWALL 2>/dev/null
        iptables -t nat -F FIREWALL
        iptables -t filter -F FIREWALL
        iptables -t nat -X FIREWALL 2>/dev/null
        iptables -t filter -X FIREWALL 2>/dev/null
        
        # 删除 IPv6 规则
        ip6tables -t filter -D FORWARD -j FIREWALL 2>/dev/null
        ip6tables -t filter -F FIREWALL
        ip6tables -t filter -X FIREWALL 2>/dev/null
        
        if $IPV6_NAT_SUPPORT; then
            ip6tables -t nat -D PREROUTING -j FIREWALL 2>/dev/null
            ip6tables -t nat -F FIREWALL
            ip6tables -t nat -X FIREWALL 2>/dev/null
        fi
        
        echo -e "${GREEN}所有规则已删除${NC}"
    fi
}

# 函数：保存规则
save_rules() {
    mkdir -p /etc/iptables/
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6

    chmod 600 /etc/iptables/rules.v*

    netfilter-persistent save

    echo -e "${GREEN}规则已保存到 /etc/iptables/rules.v4 和 rules.v6${NC}"
}

# 主程序开始
check_ipv6_nat

# 主循环
while true; do
    show_menu
    echo -e "${YELLOW}请选择操作 [0-8]:${NC}"
    read -r opt
    
    case $opt in
        1) create_rules ;;
        2) add_allowed_ip ;;
        3) delete_allowed_ip ;;
        4) add_allowed_port ;;
        5) delete_allowed_port ;;
        6) show_rules ;;
        7) delete_rules ;;
        8) save_rules ;;
        0) 
            echo -e "${GREEN}退出程序${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选项${NC}"
            ;;
    esac
    
    if [ "$opt" != "6" ]; then
        echo -e "${YELLOW}按回车键继续...${NC}"
        read -r
    fi
done