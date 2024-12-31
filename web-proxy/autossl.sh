#!/bin/bash
###########################################
# acme自动部署ssl脚本 v1.0
###########################################
set -e # 遇到错误立即退出
set -u # 使用未声明变量时报错

# 全局变量  
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly ACME_SERVICE="acme.sh"

# 颜色输出
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 输出日志
log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 成功信息
success() {
    log "${GREEN}$1${NC}"
}

# 警告信息
warning() {
    log "${YELLOW}警告: $1${NC}"
}

# 错误退出
error_exit() {
    log "${RED}错误: $1${NC}"
    exit 1
}

# 提示信息
info() {
    log "${BLUE}$1${NC}"
}

# 确认操作
confirm() {
    local prompt=$1
    local answer
    
    echo -n -e "${YELLOW}$prompt (y/n): ${NC}"
    read -r answer
    
    [[ "$answer" =~ ^[Yy]$ ]]
}

# 检查容器和目录
check_environment() {
    # 检查容器运行状态
    docker-compose ps $ACME_SERVICE | grep "Up" >/dev/null 2>&1 || error_exit "acme.sh 容器未运行"
}

# 全局配置相关函数
configure_ca() {
    echo "请选择证书颁发机构:"
    echo "1) Let's Encrypt (默认)"
    echo "2) ZeroSSL"
    
    local choice
    read -r -p "请选择 [1-2]: " choice
    
    case $choice in
        1)
            docker exec $ACME_SERVICE --set-default-ca --server letsencrypt
            success "已切换到 Let's Encrypt"
            ;;
        2)
            docker exec $ACME_SERVICE --set-default-ca --server zerossl
            
            # 检查是否需要注册ZeroSSL
            if ! docker exec $ACME_SERVICE --check-ca-authorization zerossl >/dev/null 2>&1; then
                info "ZeroSSL需要注册邮箱..."
                read -r -p "请输入邮箱地址: " email
                docker exec $ACME_SERVICE --register-account -m "$email"
            fi
            
            success "已切换到 ZeroSSL"
            ;;
        *)
            warning "无效的选择，保持当前设置"
            ;;
    esac
}

# DNS配置文件处理
readonly DNS_CONFIG_DIR="$SCRIPT_DIR/dns_config"
readonly DNS_CONFIG_FILE="$DNS_CONFIG_DIR/dns_config.json"

# 初始化DNS配置目录
init_dns_config() {
    mkdir -p "$DNS_CONFIG_DIR"
    if [[ ! -f "$DNS_CONFIG_FILE" ]]; then
        echo '{}' > "$DNS_CONFIG_FILE"
    fi
}

# 保存DNS配置
save_dns_config() {
    local domain=$1
    local provider=$2
    local credentials=$3
    
    # 创建临时文件以存储新配置
    local temp_file
    temp_file=$(mktemp)
    
    # 读取现有配置
    if [[ -f "$DNS_CONFIG_FILE" ]]; then
        cat "$DNS_CONFIG_FILE" > "$temp_file"
    else
        echo '{}' > "$temp_file"
    fi
    
    # 更新配置
    jq --arg domain "$domain" \
       --arg provider "$provider" \
       --arg credentials "$credentials" \
       '.[$domain] = {"provider": $provider, "credentials": $credentials}' \
       "$temp_file" > "$DNS_CONFIG_FILE"
    
    rm -f "$temp_file"
}

# 读取DNS配置
load_dns_config() {
    local domain=$1
    
    if [[ ! -f "$DNS_CONFIG_FILE" ]]; then
        return 1
    fi
    
    local config
    config=$(jq -r --arg domain "$domain" '.[$domain] // empty' "$DNS_CONFIG_FILE")
    
    if [[ -n "$config" ]]; then
        echo "$config"
        return 0
    fi
    
    return 1
}

# 清理DNS配置
clean_dns_config() {
    local domain=$1
    
    if [[ -f "$DNS_CONFIG_FILE" ]]; then
        jq --arg domain "$domain" 'del(.[$domain])' "$DNS_CONFIG_FILE" > "$DNS_CONFIG_FILE.tmp"
        mv "$DNS_CONFIG_FILE.tmp" "$DNS_CONFIG_FILE"
    fi
}

# DNS提供商配置
configure_dns_provider() {
    local domain=$1
    local existing_config
    
    # 检查是否存在现有配置
    if existing_config=$(load_dns_config "$domain"); then
        local provider
        provider=$(echo "$existing_config" | jq -r '.provider')
        info "发现域名 $domain 的现有DNS配置 ($provider)"
        
        if confirm "是否使用现有配置?"; then
            SELECTED_DNS_PROVIDER=$(echo "$existing_config" | jq -r '.provider')
            SELECTED_DNS_CREDENTIALS=$(echo "$existing_config" | jq -r '.credentials')
            return
        fi
    fi
    
    echo "请选择DNS提供商:"
    echo "1) Cloudflare"
    echo "2) Aliyun"
    echo "3) DNSPod"
    
    local dns_provider dns_credentials choice
    while true; do
        read -r -p "请选择 [1-3]: " choice
        case $choice in
            1)
                dns_provider="dns_cf"
                read -r -p "Cloudflare Email: " cf_email
                read -r -s -p "Cloudflare API Key: " cf_key
                echo
                dns_credentials="-e CF_Email=$cf_email -e CF_Key=$cf_key"
                break
                ;;
            2)
                dns_provider="dns_ali"
                read -r -p "阿里云 Access Key: " ali_key
                read -r -s -p "阿里云 Secret: " ali_secret
                echo
                dns_credentials="-e Ali_Key=$ali_key -e Ali_Secret=$ali_secret"
                break
                ;;
            3)
                dns_provider="dns_dp"
                read -r -p "DNSPod ID: " dp_id
                read -r -s -p "DNSPod Key: " dp_key
                echo
                dns_credentials="-e DP_Id=$dp_id -e DP_Key=$dp_key"
                break
                ;;
            *)
                warning "请输入有效的选项"
                ;;
        esac
    done

    SELECTED_DNS_PROVIDER="$dns_provider"
    SELECTED_DNS_CREDENTIALS="$dns_credentials"
    
    # 保存配置
    if confirm "是否保存DNS配置以供将来使用?"; then
        save_dns_config "$domain" "$dns_provider" "$dns_credentials"
        success "DNS配置已保存"
    fi
}

# 获取证书列表信息 
get_cert_list() {
    docker exec $ACME_SERVICE --list
}

# 获取证书状态信息
get_cert_info() {
    local domain=$1
    docker exec $ACME_SERVICE --info -d "$domain"
}

# 解析证书列表到数组
parse_cert_list() {
    local cert_list
    cert_list=$(get_cert_list | grep "Main_Domain" | awk '{print $2}')
    echo "$cert_list"
}

# 显示证书选择菜单
show_cert_menu() {
    local title=$1
    local cert_list
    local -a certs
    
    # 获取证书列表
    cert_list=$(parse_cert_list)
    mapfile -t certs <<< "$cert_list"
    
    [[ ${#certs[@]} -eq 0 ]] && error_exit "没有可用的证书"

    echo -e "\n${title}"
    echo "----------------------------------------"
    local i=1
    for cert in "${certs[@]}"; do
        echo "$i) $cert"
        ((i++))
    done
    echo "----------------------------------------"

    local selection
    while true; do
        read -r -p "请选择证书编号 [1-${#certs[@]}]: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "${#certs[@]}" ]; then
            echo "${certs[$selection-1]}"
            break
        else
            warning "请输入有效的编号"
        fi
    done
}

# 列出已签发的证书
list_certs() {
    info "已签发的证书列表:"
    echo "----------------------------------------"
    get_cert_list
    echo "----------------------------------------"
}

# 查看证书详细信息
view_cert() {
    info "查看证书详细信息..."
    
    local domain=$(show_cert_menu "请选择要查看的证书:")
    [[ -z "$domain" ]] && return
    
    echo "----------------------------------------"
    get_cert_info "$domain"
    echo "----------------------------------------"
}

# DNS提供商配置
configure_dns_provider() {
    echo "请选择DNS提供商:"
    echo "1) Cloudflare"
    echo "2) Aliyun"
    echo "3) DNSPod"

    local dns_provider dns_credentials
    local dns_provider dns_credentials choice
    while true; do
        read -r -p "请选择 [1-3]: " choice
        case $choice in
            1)
                dns_provider="dns_cf"
                read -r -p "Cloudflare Email: " cf_email
                read -r -s -p "Cloudflare API Key: " cf_key
                echo
                dns_credentials="-e CF_Email=$cf_email -e CF_Key=$cf_key"
                break
                ;;
            2)
                dns_provider="dns_ali"
                read -r -p "阿里云 Access Key: " ali_key
                read -r -s -p "阿里云 Secret: " ali_secret
                echo
                dns_credentials="-e Ali_Key=$ali_key -e Ali_Secret=$ali_secret"
                break
                ;;
            3)
                dns_provider="dns_dp"
                read -r -p "DNSPod ID: " dp_id
                read -r -s -p "DNSPod Key: " dp_key
                echo
                dns_credentials="-e DP_Id=$dp_id -e DP_Key=$dp_key"
                break
                ;;
            *)
                warning "请输入有效的选项"
                ;;
        esac
    done
    
    # 使用全局变量返回值
    SELECTED_DNS_PROVIDER="$dns_provider"
    SELECTED_DNS_CREDENTIALS="$dns_credentials"
}

# 签发新证书
issue_cert() {
    info "开始签发新证书..."
    
    read -r -p "请输入域名: " domain
    
    # 检查证书是否已存在
    if docker exec $ACME_SERVICE --list | grep -q "Main_Domain: $domain"; then
        if ! confirm "证书已存在，是否重新签发?"; then
            return
        fi
    fi
    
    # 配置DNS提供商
    configure_dns_provider "$domain"
    
    # 使用全局变量获取DNS配置
    if [[ -z "${SELECTED_DNS_PROVIDER:-}" || -z "${SELECTED_DNS_CREDENTIALS:-}" ]]; then
        error_exit "DNS配置无效"
    fi
    
    info "正在使用 $SELECTED_DNS_PROVIDER 签发证书 $domain..."
    if docker exec $SELECTED_DNS_CREDENTIALS $ACME_SERVICE --issue -d "$domain" --dns "$SELECTED_DNS_PROVIDER"; then
        success "证书签发成功!"
        get_cert_info "$domain"
    else
        error_exit "证书签发失败"
        # 如果签发失败，清理保存的配置
        if confirm "是否清理此域名的DNS配置?"; then
            clean_dns_config "$domain"
            success "DNS配置已清理"
        fi
    fi
}

# 部署证书
deploy_cert() {
    info "部署证书..."
    
    # 获取并显示可用证书列表
    local certs=($(get_available_certs))
    local domain=$(show_cert_menu "请选择要部署的证书:" "${certs[*]}")
    
    read -r -p "请输入目标容器的label值(sh.acme.autoload.domain=?): " label_value
    
    if confirm "是否确认部署证书到容器?"; then
        info "正在部署证书 $domain..."
        docker exec \
        -e DEPLOY_DOCKER_CONTAINER_LABEL="sh.acme.autoload.domain=$label_value" \
        -e DEPLOY_DOCKER_CONTAINER_KEY_FILE="/etc/nginx/ssl/$domain/key.pem" \
        -e DEPLOY_DOCKER_CONTAINER_CERT_FILE="/etc/nginx/ssl/$domain/cert.pem" \
        -e DEPLOY_DOCKER_CONTAINER_CA_FILE="/etc/nginx/ssl/$domain/ca.pem" \
        -e DEPLOY_DOCKER_CONTAINER_FULLCHAIN_FILE="/etc/nginx/ssl/$domain/full.pem" \
        -e DEPLOY_DOCKER_CONTAINER_RELOAD_CMD="service nginx force-reload" \
        $ACME_SERVICE --deploy -d "$domain" --deploy-hook docker
        
        success "证书部署成功!"
    fi
}

# 删除证书
remove_cert() {
    info "删除证书..."
    
    local domain=$(show_cert_menu "请选择要删除的证书:")
    [[ -z "$domain" ]] && return
    
    if confirm "确定要删除证书 $domain 吗?"; then
        info "正在删除证书..."
        if docker exec $ACME_SERVICE --remove -d "$domain"; then
            # 删除DNS配置
            if [[ -f "$DNS_CONFIG_FILE" ]] && jq -e --arg domain "$domain" '.[$domain]' "$DNS_CONFIG_FILE" >/dev/null; then
                if confirm "是否同时删除此域名的DNS配置?"; then
                    clean_dns_config "$domain"
                    success "DNS配置已删除"
                fi
            fi
            success "证书删除成功!"
        else
            error_exit "证书删除失败"
        fi
    fi
}

# 查看证书详细信息
view_cert() {
    info "查看证书详细信息..."
    
    # 获取并显示可用证书列表
    local certs=($(get_available_certs))
    local domain=$(show_cert_menu "请选择要查看的证书:" "${certs[*]}")
    
    echo "----------------------------------------"
    get_cert_info "$domain"
    echo "----------------------------------------"
    
    if confirm "是否查看证书内容?"; then
        openssl x509 -in "$ACME_DATA_DIR/${domain}_ecc/$domain.cer" -text -noout
    fi
}

# 更新所有证书
renew_all_certs() {
    info "更新所有证书..."
    
    if docker exec $ACME_SERVICE --renew-all --force; then
        success "所有证书更新成功!"
    else
        error_exit "证书更新失败"
    fi
}

# 全局配置菜单
global_config_menu() {
    while true; do
        echo
        echo "全局配置"
        echo "===================="
        echo "1) 切换证书颁发机构"
        echo "2) 查看当前配置"
        echo "3) 清理所有DNS配置"
        echo "0) 返回主菜单"
        echo
        read -r -p "请选择操作 [0-3]: " choice
        echo

        case $choice in
            1) configure_ca ;;
            2)
                echo "当前配置:"
                echo "----------------------------------------"
                docker exec $ACME_SERVICE --info
                echo "----------------------------------------"
                ;;
            3)
                if confirm "确定要清理所有DNS配置吗？此操作不可恢复"; then
                    echo '{}' > "$DNS_CONFIG_FILE"
                    success "所有DNS配置已清理"
                fi
                ;;
            0) break ;;
            *) warning "无效的选择" ;;
        esac
    done
}

# 修改后的主菜单
main_menu() {
    while true; do
        echo
        echo -e "${GREEN}ACME.sh 证书管理工具${NC}"
        echo "===================="
        echo "1) 列出已签发的证书"
        echo "2) 签发新证书"
        echo "3) 部署证书"
        echo "4) 删除证书"
        echo "5) 查看证书详细信息"
        echo "6) 更新所有证书"
        echo "7) 全局配置"
        echo "0) 退出"
        echo
        read -r -p "请选择操作 [0-7]: " choice
        echo

        case $choice in
            1) list_certs ;;
            2) issue_cert ;;
            3) deploy_cert ;;
            4) remove_cert ;;
            5) view_cert ;;
            6) renew_all_certs ;;
            7) global_config_menu ;;
            0) 
                info "感谢使用，再见!"
                exit 0 
                ;;
            *) warning "无效的选择" ;;
        esac
    done
}

# 初始化脚本
init_script() {
    # 检查依赖
    command -v jq >/dev/null 2>&1 || error_exit "请先安装jq"
    command -v docker-compose >/dev/null 2>&1 || error_exit "请先安装docker-compose"
    
    # 检查容器
    check_environment
    
    # 初始化配置目录
    init_dns_config
    
    # 设置权限
    chmod 600 "$DNS_CONFIG_FILE" 2>/dev/null || true
}

# 主程序
init_script
main_menu