#!/bin/bash
###########################################
# 系统配置脚本 v1.0
# 功能：创建用户、配置SSH、设置防火墙、安装Docker
###########################################

set -e # 遇到错误立即退出
set -u # 使用未声明变量时报错

# 全局变量
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly LOG_FILE="/var/log/system_config.log"
readonly SSH_CONFIG="/etc/ssh/sshd_config"
readonly SSH_CONFIG_BAK="${SSH_CONFIG}.bak"
readonly VERSION="1.0"

# 声明全局变量
username=""
ssh_port=22

# 日志函数
log() {
    local level=$1
    shift
    local message=$*
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# 错误处理
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# 检查命令是否存在
check_command() {
    command -v "$1" >/dev/null 2>&1 || error_exit "命令 $1 未找到,请先安装."
}

# 验证端口号
validate_port() {
    local port=$1
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error_exit "请使用root用户执行该脚本"
    fi
}

# 创建新用户
create_user() {
    log "INFO" "开始创建新用户..."
    
    while true; do
        read -p "请输入新建用户名: " username
        # 验证用户名
        if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            log "WARN" "无效的用户名格式,请重新输入"
            continue
        fi
        if id "$username" &>/dev/null; then
            log "WARN" "用户 $username 已存在"
            return
        fi
        break
    done

    # 使用更安全的密码输入方式
    while true; do
        read -s -p "请输入密码: " password
        echo
        read -s -p "请确认密码: " password2
        echo
        if [ "$password" = "$password2" ]; then
            break
        fi
        log "WARN" "密码不匹配,请重新输入"
    done

    if useradd -m -s /bin/bash "$username"; then
        echo "$username:$password" | chpasswd
        log "INFO" "用户 $username 创建成功"
    else
        error_exit "创建用户失败"
    fi
}

# 备份SSH配置
backup_ssh_config() {
    log "INFO" "备份SSH配置文件..."
    if [ -f "$SSH_CONFIG" ]; then
        cp "$SSH_CONFIG" "$SSH_CONFIG_BAK" || error_exit "备份SSH配置失败"
        log "INFO" "SSH配置已备份至 $SSH_CONFIG_BAK"
    else
        error_exit "SSH配置文件不存在"
    fi
}

# 修改Match User配置
modify_match_user() {
    local username=$1
    log "INFO" "修改Match User配置..."
    
    if ! grep -q "^Match User" "$SSH_CONFIG"; then
        echo -e "\nMatch User $username\n PasswordAuthentication yes" >> "$SSH_CONFIG"
    else
        if ! grep -q "^Match User $username" "$SSH_CONFIG"; then
            sed -i "/^Match User /a\Match User $username\n\tPasswordAuthentication yes" "$SSH_CONFIG"
        fi
    fi
    log "INFO" "Match User配置更新完成"
}

# 修改SSH配置
modify_ssh_config() {
    local username=$1
    log "INFO" "开始修改SSH配置..."
    
    read -p "是否要修改SSH配置？[y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "跳过SSH配置修改"
        return
    fi

    backup_ssh_config

    # 修改SSH配置
    local config_changes=(
        "s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/"
        "s/^#*PasswordAuthentication.*/PasswordAuthentication no/"
        "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/"
    )

    for change in "${config_changes[@]}"; do
        sed -i "$change" "$SSH_CONFIG"
    done

    # 设置SSH端口
    while true; do
        read -p "请输入新的SSH端口 [22]: " port_input
        ssh_port=${port_input:-22}
        if validate_port "$ssh_port"; then
            break
        fi
        log "WARN" "无效的端口号,请重新输入"
    done

    sed -i "s/^#*Port .*/Port $ssh_port/" "$SSH_CONFIG"

    # 修改Match User配置
    modify_match_user "$username"

    # 验证配置
    log "INFO" "验证SSH配置..."
    if ! sshd -t; then
        log "ERROR" "SSH配置验证失败,恢复备份"
        cp "$SSH_CONFIG_BAK" "$SSH_CONFIG"
        systemctl restart sshd
        error_exit "SSH配置错误"
    fi

    systemctl restart sshd
    log "INFO" "SSH配置修改完成"
}

# 配置UFW
configure_ufw() {
    local ssh_port=$1
    log "INFO" "开始配置UFW防火墙..."

    # 检查并安装UFW
    if ! command -v ufw &>/dev/null; then
        log "INFO" "安装UFW..."
        apt-get update && apt-get install -y ufw || error_exit "UFW安装失败"
    fi

    # 配置UFW规则
    ufw --force reset # 重置现有规则
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$ssh_port/tcp" comment "SSH"

    # 配置额外端口
    read -p "请输入要开放的其他端口(多个端口用逗号分隔): " ports
    if [ -n "$ports" ]; then
        IFS=',' read -ra port_array <<< "$ports"
        for port in "${port_array[@]}"; do
            port=$(echo "$port" | tr -d '[:space:]')
            if validate_port "$port"; then
                ufw allow "$port" comment "Custom port"
                log "INFO" "已开放端口 $port"
            else
                log "WARN" "跳过无效端口: $port"
            fi
        done
    fi

    # 启用UFW
    log "INFO" "启用UFW..."
    ufw --force enable
    systemctl enable ufw
    ufw status verbose | tee -a "$LOG_FILE"
    log "INFO" "UFW配置完成"
}

# 安装Docker
install_docker() {
    log "INFO" "开始安装Docker..."
    
    read -p "是否要安装Docker? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "INFO" "跳过Docker安装"
        return
    fi

    if command -v docker &>/dev/null; then
        log "INFO" "Docker已安装"
        return
    fi

    # 安装依赖
    apt-get update || error_exit "更新包列表失败"
    apt-get install -y apt-transport-https ca-certificates curl software-properties-common || error_exit "安装依赖失败"

    # 安装Docker
    curl -fsSL https://get.docker.com | bash || error_exit "Docker安装失败"

    # 启动Docker
    systemctl start docker || error_exit "启动Docker失败"
    systemctl enable docker || error_exit "设置Docker自启动失败"
    
    log "INFO" "Docker安装完成"
    docker --version | tee -a "$LOG_FILE"
}

# 清理函数
cleanup() {
    log "INFO" "开始清理..."
    if [ -f "$SSH_CONFIG_BAK" ]; then
        rm -f "$SSH_CONFIG_BAK"
    fi
    log "INFO" "清理完成"
}

# 显示帮助信息
show_help() {
    cat << EOF
用法: $(basename "$0") [选项]
选项:
    -h, --help     显示帮助信息
    -v, --version  显示版本信息
功能:
    - 创建新用户
    - 配置SSH服务 
    - 设置UFW防火墙
    - 安装Docker
EOF
}

# 显示版本信息
show_version() {
    echo "系统配置脚本 v${VERSION}"
}

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -v|--version)
            show_version
            exit 0
            ;;
        *)
            error_exit "未知参数: $1"
            ;;
    esac
    shift
done

# 主函数
main() {
    # 检查权限
    check_root

    # 创建日志文件
    touch "$LOG_FILE" || error_exit "无法创建日志文件"
    log "INFO" "开始系统配置..."

    # 注册清理函数
    trap cleanup EXIT

    # 执行配置步骤
    create_user
    modify_ssh_config "$username"
    configure_ufw "$ssh_port"
    install_docker

    log "INFO" "所有配置完成"
}

# 执行主函数
main
