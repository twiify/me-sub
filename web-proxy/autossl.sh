#!/bin/bash
###########################################
# acme自动部署ssl脚本 v1.0
###########################################
set -e # 遇到错误立即退出
set -u # 使用未声明变量时报错

# 全局变量  
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly ACME_SERVICE="acme.sh"
readonly ACME_DATA_DIR="$SCRIPT_DIR/acmeout"

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
    
    # 检查数据目录
    [[ -d "$ACME_DATA_DIR" ]] || error_exit "acme数据目录($ACME_DATA_DIR)不存在"
}

# 获取证书状态信息
get_cert_info() {
    local domain=$1
    local cert_dir="$ACME_DATA_DIR/$domain"
    
    if [[ -d "$cert_dir" ]]; then
        local expire_date
        expire_date=$(openssl x509 -in "$cert_dir/$domain.cer" -noout -enddate 2>/dev/null | cut -d= -f2)
        echo "证书信息:"
        echo "  域名: $domain"
        echo "  到期时间: $expire_date"
        echo "  证书路径: $cert_dir"
    else
        warning "未找到域名 $domain 的证书信息"
        return 1
    fi
}

# 获取可用证书列表
get_available_certs() {
    local -a certs=()
    for cert_dir in "$ACME_DATA_DIR"/*; do
        if [[ -d "$cert_dir" && -f "$cert_dir/$(basename "$cert_dir").cer" ]]; then
            certs+=("$(basename "$cert_dir")")
        fi
    done
    echo "${certs[@]}"
}

# 显示证书选择菜单
show_cert_menu() {
    local title=$1
    local -a certs=($2)
    local index=1

    [[ ${#certs[@]} -eq 0 ]] && error_exit "没有可用的证书"

    echo -e "\n${title}"
    echo "----------------------------------------"
    for cert in "${certs[@]}"; do
        echo "$index) $cert"
        ((index++))
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
    
    local found=false
    local certs=($(get_available_certs))
    
    if [ ${#certs[@]} -eq 0 ]; then
        warning "未找到任何已签发的证书"
        return
    fi
    
    for cert in "${certs[@]}"; do
        get_cert_info "$cert"
        echo "----------------------------------------"
    done
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
    if [[ -d "$ACME_DATA_DIR/$domain" ]]; then
        if ! confirm "证书已存在，是否重新签发?"; then
            return
        fi
    fi
    
    # 配置DNS提供商
    configure_dns_provider
    
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
    
    # 获取并显示可用证书列表
    local certs=($(get_available_certs))
    local domain=$(show_cert_menu "请选择要删除的证书:" "${certs[*]}")
    
    if confirm "确定要删除证书 $domain 吗?"; then
        info "正在删除证书..."
        if docker exec $ACME_SERVICE --remove -d "$domain"; then
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
        openssl x509 -in "$ACME_DATA_DIR/$domain/$domain.cer" -text -noout
    fi
}

# 更新所有证书
renew_all_certs() {
    info "更新所有证书..."
    
    if docker exec $ACME_SERVICE --renew-all; then
        success "所有证书更新成功!"
    else
        error_exit "证书更新失败"
    fi
}

# 主菜单
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
        echo "0) 退出"
        echo
        read -r -p "请选择操作 [0-6]: " choice
        echo

        case $choice in
            1) list_certs ;;
            2) issue_cert ;;
            3) deploy_cert ;;
            4) remove_cert ;;
            5) view_cert ;;
            6) renew_all_certs ;;
            0) 
                info "感谢使用，再见!"
                exit 0 
                ;;
            *) warning "无效的选择" ;;
        esac
    done
}

# 主程序
check_environment
main_menu