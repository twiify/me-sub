#!/bin/bash
###########################################
# acme自动部署ssl脚本 v1.0
###########################################
set -e # 遇到错误立即退出
set -u # 使用未声明变量时报错

# 临时文件清理
TEMP_FILES=()
cleanup_temp_files() {
    if [[ ${#TEMP_FILES[@]} -gt 0 ]]; then
        info "正在清理临时文件..."
        for temp_file in "${TEMP_FILES[@]}"; do
            if [[ -f "$temp_file" ]]; then
                rm -f "$temp_file"
            fi
        done
        TEMP_FILES=() # 清空数组以防陷阱被多次调用（尽管对于EXIT通常不会）
    fi
}
trap cleanup_temp_files EXIT INT TERM

# 全局变量
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly ACME_SERVICE="acme.sh"
readonly DEFAULT_NGINX_RELOAD_CMD="service nginx force-reload"                            # Used by acme.sh --deploy-hook docker
readonly DEFAULT_NGINX_CONTAINER_LABEL_FOR_AUTOLOAD="sh.acme.autoload.domain=example.com" # Default label for nginx in docker-compose, acme.sh might use this
readonly DEFAULT_SSL_BASE_PATH_IN_CONTAINER="/etc/nginx/ssl"

# Script mode and arguments
ACTION=""
DOMAIN_NAME_ARG=""
DNS_PROVIDER_ARG=""         # e.g., dns_cf, dns_ali
DNS_CREDENTIALS_ARG_RAW=""  # Raw string like "CF_Email=a CF_Key=b"
DNS_CREDENTIALS_ARG_EXEC="" # Formatted for docker exec like "-e CF_Email=a -e CF_Key=b"
LABEL_VALUE_ARG=""          # For deployment, e.g., "nginx" or "sh.acme.autoload.domain=nginx"
FORCE_ISSUE=false
AUTO_CONFIRM=false
NON_INTERACTIVE_MODE=false

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

    if [[ "$NON_INTERACTIVE_MODE" == true && "$AUTO_CONFIRM" == true ]]; then
        info "自动确认: $prompt"
        return 0 # Yes
    fi

    # If non-interactive and not auto-confirming, some critical questions might still need to be asked or fail.
    # For now, proceed with asking if not auto-confirmed.
    # Consider adding a specific check: if ! tty -s && ! $AUTO_CONFIRM; then error_exit "Non-interactive mode requires --yes for confirmations"; fi

    echo -n -e "${YELLOW}$prompt (y/n): ${NC}"
    read -r answer

    [[ "$answer" =~ ^[Yy]$ ]]
}

# 参数解析函数
parse_args() {
    # Detect if running in non-interactive mode (e.g. no TTY or specific flag)
    if ! tty -s || [[ "$#" -gt 0 && ("$1" == "issue" || "$1" == "deploy" || "$1" == "remove" || "$1" == "renew-all" || "$1" == "list" || "$1" == "info" || "$1" == "configure-ca" || "$1" == "set-default-dns") ]]; then
        NON_INTERACTIVE_MODE=true
        # If first arg is a known action, assume CLI mode.
    fi

    local creds_array=() # To build up -e flags

    while [[ "$#" -gt 0 ]]; do
        case $1 in
        issue | deploy | remove | renew-all | list | info | configure-ca | set-default-dns)
            ACTION=$1
            NON_INTERACTIVE_MODE=true
            ;;
        --domain)
            DOMAIN_NAME_ARG="$2"
            shift
            ;;
        --dns-provider)
            DNS_PROVIDER_ARG="$2" # e.g., dns_cf, dns_ali, dns_dp
            shift
            ;;
        --dns-creds)
            # Expects "Key1=Value1 Key2=Value2 ..."
            DNS_CREDENTIALS_ARG_RAW="$2"
            local cred_pair
            for cred_pair in $DNS_CREDENTIALS_ARG_RAW; do
                creds_array+=("-e" "$cred_pair")
            done
            DNS_CREDENTIALS_ARG_EXEC="${creds_array[@]}"
            shift
            ;;
        --label)
            LABEL_VALUE_ARG="$2" # For deploy hook, e.g., nginx or sh.acme.autoload.domain=nginx
            shift
            ;;
        --ca-server)
            CA_SERVER_ARG="$2" # letsencrypt or zerossl
            shift
            ;;
        --email) # For ZeroSSL registration
            EMAIL_ARG="$2"
            shift
            ;;
        --force)
            FORCE_ISSUE=true
            ;;
        --yes)
            AUTO_CONFIRM=true
            ;;
        --non-interactive) # Explicit flag
            NON_INTERACTIVE_MODE=true
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            # If ACTION is not set and it's not a known flag, it might be an old way of calling an action
            if [[ -z "$ACTION" && ("$1" == "issue_cert" || "$1" == "deploy_cert") ]]; then
                warning "Legacy action call '$1' detected. Please use modern CLI flags."
                ACTION=${1%_cert} # Convert issue_cert to issue
                NON_INTERACTIVE_MODE=true
            else
                warning "未知参数: $1"
            fi
            ;;
        esac
        shift
    done

    if [[ "$NON_INTERACTIVE_MODE" == true && -z "$ACTION" ]]; then
        usage
        error_exit "非交互模式下必须指定操作 (例如: issue, deploy)."
    fi
}

usage() {
    echo "用法: $0 [action] [options]"
    echo
    echo "脚本模式:"
    echo "  $0                            启动交互式菜单"
    echo "  $0 <action> [options]         以非交互模式执行特定操作"
    echo
    echo "操作 (Actions):"
    echo "  issue                         签发新证书"
    echo "  deploy                        部署证书到容器"
    echo "  remove                        删除证书"
    echo "  renew-all                     更新所有证书"
    echo "  list                          列出已签发的证书"
    echo "  info                          查看证书详细信息 (需要 --domain)"
    echo "  configure-ca                  配置默认CA (需要 --ca-server [letsencrypt|zerossl] [--email <email_for_zerossl>])"
    echo "  set-default-dns               设置默认DNS提供商凭证 (需要 --dns-provider 和 --dns-creds)"
    echo
    echo "选项 (Options for non-interactive mode):"
    echo "  --domain <domain_name>        域名"
    echo "  --dns-provider <provider>     DNS提供商 (例如: dns_cf, dns_ali, dns_dp)"
    echo "  --dns-creds \"K1=V1 K2=V2\"   DNS凭证 (例如: \"CF_Email=user@example.com CF_Key=your_api_key\")"
    echo "  --label <label_value>         部署证书时Nginx容器的label (例如: nginx, sh.acme.autoload.domain=nginx)"
    echo "  --ca-server <server>          CA服务器 (letsencrypt 或 zerossl)"
    echo "  --email <email>               注册ZeroSSL时使用的邮箱"
    echo "  --force                       强制执行操作 (例如: 重新签发证书)"
    echo "  --yes                         对所有确认提示自动回答 'yes'"
    echo "  --non-interactive             强制非交互模式"
    echo "  -h, --help                    显示此帮助信息"
    echo
    echo "示例:"
    echo "  $0 issue --domain my.example.com --dns-provider dns_cf --dns-creds \"CF_Email=a@b.com CF_Key=secret\" --yes"
    echo "  $0 deploy --domain my.example.com --label nginx --yes"
    echo "  $0 info --domain my.example.com"
}

# 检查容器和目录
check_environment() {
    # 检查容器运行状态
    docker-compose ps $ACME_SERVICE | grep "Up" >/dev/null 2>&1 || error_exit "acme.sh 容器未运行"
}

# 全局配置相关函数
configure_ca() {
    local ca_to_set="${CA_SERVER_ARG:-}"
    local email_for_zerossl="${EMAIL_ARG:-}"

    if [[ "$NON_INTERACTIVE_MODE" == true ]]; then
        if [[ -z "$ca_to_set" ]]; then
            error_exit "非交互模式下配置CA需要 --ca-server [letsencrypt|zerossl] 参数。"
        fi
        if [[ "$ca_to_set" == "zerossl" && -z "$email_for_zerossl" ]]; then
            # Try to find if already registered
            if ! docker exec $ACME_SERVICE --check-ca-authorization zerossl >/dev/null 2>&1; then
                error_exit "非交互模式下配置ZeroSSL需要 --email <邮箱地址> 参数 (如果尚未注册)。"
            fi
        fi
    else # Interactive mode
        echo "请选择证书颁发机构:"
        echo "1) Let's Encrypt (默认)"
        echo "2) ZeroSSL"
        local choice
        read -r -p "请选择 [1-2]: " choice
        case $choice in
        1) ca_to_set="letsencrypt" ;;
        2) ca_to_set="zerossl" ;;
        *)
            warning "无效的选择，保持当前设置"
            return
            ;;
        esac
    fi

    if [[ "$ca_to_set" == "letsencrypt" ]]; then
        docker exec $ACME_SERVICE --set-default-ca --server letsencrypt
        success "已切换到 Let's Encrypt"
    elif [[ "$ca_to_set" == "zerossl" ]]; then
        docker exec $ACME_SERVICE --set-default-ca --server zerossl
        # 检查是否需要注册ZeroSSL
        if ! docker exec $ACME_SERVICE --check-ca-authorization zerossl >/dev/null 2>&1; then
            if [[ "$NON_INTERACTIVE_MODE" == false ]]; then
                info "ZeroSSL需要注册邮箱..."
                read -r -p "请输入邮箱地址: " email_for_zerossl
            fi
            if [[ -z "$email_for_zerossl" ]]; then # Should have been caught earlier in non-interactive
                error_exit "ZeroSSL注册需要邮箱地址。"
            fi
            docker exec $ACME_SERVICE --register-account -m "$email_for_zerossl"
        fi
        success "已切换到 ZeroSSL"
    else
        warning "无效的CA服务器: $ca_to_set"
    fi
}

# DNS配置文件处理
readonly DNS_CONFIG_DIR="$SCRIPT_DIR/dns_config"
readonly DNS_CONFIG_FILE="$DNS_CONFIG_DIR/dns_config.json"
readonly DEFAULT_DNS_KEY="_default_dns_" # Special key for default DNS settings in dns_config.json

# Global vars for selected/loaded DNS provider (populated by configure_dns_provider)
SELECTED_DNS_PROVIDER=""
SELECTED_DNS_CREDENTIALS=""

# 初始化DNS配置目录
init_dns_config() {
    mkdir -p "$DNS_CONFIG_DIR"
    if [[ ! -f "$DNS_CONFIG_FILE" ]]; then
        echo '{}' >"$DNS_CONFIG_FILE"
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
    TEMP_FILES+=("$temp_file")

    # 读取现有配置
    if [[ -f "$DNS_CONFIG_FILE" ]]; then
        cat "$DNS_CONFIG_FILE" >"$temp_file"
    else
        echo '{}' >"$temp_file"
    fi

    # 更新配置
    local jq_output_file
    jq_output_file=$(mktemp)
    TEMP_FILES+=("$jq_output_file")

    if jq --arg domain "$domain" \
        --arg provider "$provider" \
        --arg credentials "$credentials" \
        '.[$domain] = {"provider": $provider, "credentials": $credentials}' \
        "$temp_file" >"$jq_output_file"; then
        if mv "$jq_output_file" "$DNS_CONFIG_FILE"; then
            success "DNS配置已更新: $domain"
            # 成功移动后，jq_output_file 不再是临时文件，可以从TEMP_FILES中移除（可选，但更精确）
            # 不过，trap中的 rm -f 对于不存在的文件是无害的
        else
            error_exit "无法更新DNS配置文件 $DNS_CONFIG_FILE"
        fi
    else
        error_exit "使用jq更新DNS配置失败"
    fi
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

    if [[ ! -f "$DNS_CONFIG_FILE" ]]; then
        warning "DNS配置文件 $DNS_CONFIG_FILE 不存在，无需清理。"
        return
    fi

    # 创建临时文件以存储修改后的配置
    local temp_jq_output_file
    temp_jq_output_file=$(mktemp)
    TEMP_FILES+=("$temp_jq_output_file")

    # 从主配置文件读取，删除指定域名的条目，并写入临时jq输出文件
    if jq --arg domain "$domain" 'del(.[$domain])' "$DNS_CONFIG_FILE" >"$temp_jq_output_file"; then
        # 如果jq操作成功，用临时jq输出文件覆盖主配置文件
        if mv "$temp_jq_output_file" "$DNS_CONFIG_FILE"; then
            success "已从DNS配置中清理域名: $domain"
        else
            error_exit "无法更新DNS配置文件 $DNS_CONFIG_FILE"
        fi
    else
        error_exit "使用jq清理DNS配置失败: $domain"
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
    cert_list=$(get_cert_list | awk 'NR>1 {print $1}')
    echo "$cert_list"
}

# 显示证书选择菜单
show_cert_menu() {
    local title=$1
    local cert_list
    local -a certs

    # 获取证书列表
    cert_list=$(parse_cert_list) || error_exit "没有可用的证书"

    # 将证书列表转换为数组
    readarray -t certs <<<"$cert_list"

    [[ ${#certs[@]} -eq 0 ]] && error_exit "没有可用的证书"

    echo -e "\n${title}"
    local i=1
    echo "----------------------------------------"
    for cert in "${certs[@]}"; do
        if [[ -n "$cert" ]]; then # 只显示非空行
            echo "$i) $cert"
            ((i++))
        fi
    done
    echo "----------------------------------------"

    if [[ "$i" == "1" ]]; then
        SELECTED_MENU_CERT=""
        warning "没有可用证书"
        return
    fi

    local selection
    while true; do
        read -r -p "请选择证书编号 [1-$((i - 1))]: " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le "$((i - 1))" ]; then
            SELECTED_MENU_CERT="${certs[$selection - 1]}"
            break
        else
            warning "请输入有效的编号"
        fi
    done
}

# 列出已签发的证书
list_certs() {
    info "已签发的证书列表:"

    local cert_list
    local -a certs

    # 尝试获取证书列表，允许为空
    cert_list=$(parse_cert_list 2>/dev/null || true)

    if [[ -z "$cert_list" ]]; then
        warning "当前没有已签发的证书。"
        echo "----------------------------------------"
        return
    fi

    readarray -t certs <<<"$cert_list"

    if [[ ${#certs[@]} -eq 0 ]]; then
        warning "当前没有已签发的证书。"
        echo "----------------------------------------"
        return
    fi

    echo "----------------------------------------"
    local i=1
    local cert_found=false
    for cert in "${certs[@]}"; do
        if [[ -n "$cert" ]]; then
            echo "$i) $cert"
            ((i++))
            cert_found=true
        fi
    done
    echo "----------------------------------------"

    if ! $cert_found; then
        warning "当前没有已签发的证书。"
    fi
}

# 查看证书详细信息
view_cert() {
    info "查看证书详细信息..."
    show_cert_menu "请选择要查看的证书："
    [[ -z "$SELECTED_MENU_CERT" ]] && return
    echo "----------------------------------------"
    get_cert_info "$SELECTED_MENU_CERT"
    echo "----------------------------------------"
}

# Helper function to prompt for DNS provider details
# Arg1: Prefix for prompts (e.g., "Default" or "Domain specific")
# Echoes "provider_api_name credentials_string"
_prompt_dns_provider_details() {
    local prompt_prefix="$1"
    local provider_name_selected
    local credentials_string_selected

    echo "请为 ${prompt_prefix} 配置选择DNS提供商:"
    echo "1) Cloudflare"
    echo "2) Aliyun"
    echo "3) DNSPod"
    local choice
    while true; do
        read -r -p "请选择 [1-3]: " choice
        case $choice in
        1)
            provider_name_selected="dns_cf"
            read -r -p "${prompt_prefix} Cloudflare Email: " cf_email
            read -r -s -p "${prompt_prefix} Cloudflare API Key: " cf_key
            echo
            credentials_string_selected="-e CF_Email=$cf_email -e CF_Key=$cf_key"
            break
            ;;
        2)
            provider_name_selected="dns_ali"
            read -r -p "${prompt_prefix} 阿里云 Access Key: " ali_key
            read -r -s -p "${prompt_prefix} 阿里云 Secret: " ali_secret
            echo
            credentials_string_selected="-e Ali_Key=$ali_key -e Ali_Secret=$ali_secret"
            break
            ;;
        3)
            provider_name_selected="dns_dp"
            read -r -p "${prompt_prefix} DNSPod ID: " dp_id
            read -r -s -p "${prompt_prefix} DNSPod Key: " dp_key
            echo
            credentials_string_selected="-e DP_Id=$dp_id -e DP_Key=$dp_key"
            break
            ;;
        *) warning "请输入有效的选项" ;;
        esac
    done
    echo "$provider_name_selected $credentials_string_selected"
}

# Function to set default DNS provider configuration (Interactive)
set_default_dns_config() {
    info "设置默认DNS提供商..."
    local details
    details=$(_prompt_dns_provider_details "默认")
    local provider_name_selected=$(echo "$details" | awk '{print $1}')
    local credentials_string_selected=$(echo "$details" | cut -d' ' -f2-)

    if [[ -n "$provider_name_selected" && -n "$credentials_string_selected" ]]; then
        save_dns_config "$DEFAULT_DNS_KEY" "$provider_name_selected" "$credentials_string_selected"
        success "默认DNS提供商配置已保存。"
    else
        warning "未能获取DNS提供商详情，默认配置未更改。"
    fi
}

# Function to set default DNS provider configuration (Non-interactive CLI)
cli_set_default_dns_config() {
    info "非交互模式：设置默认DNS提供商..."
    if [[ -z "$DNS_PROVIDER_ARG" || -z "$DNS_CREDENTIALS_ARG_EXEC" ]]; then
        error_exit "设置默认DNS需要 --dns-provider 和 --dns-creds 参数。"
    fi
    # Note: DNS_CREDENTIALS_ARG_EXEC is already formatted with -e, but save_dns_config expects the raw creds string for consistency.
    # We need to reconstruct the raw creds string from DNS_CREDENTIALS_ARG_EXEC or use DNS_CREDENTIALS_ARG_RAW if available and preferred.
    # For simplicity, let's assume save_dns_config can handle the -e formatted string if we adjust it, or we use RAW.
    # The current save_dns_config expects a simple string like "-e K=V -e K2=V2".
    # Let's use DNS_CREDENTIALS_ARG_EXEC directly as it's what acme.sh exec needs.
    save_dns_config "$DEFAULT_DNS_KEY" "$DNS_PROVIDER_ARG" "$DNS_CREDENTIALS_ARG_EXEC"
    success "默认DNS提供商配置已通过CLI设置。"
}

# Load default DNS configuration into SELECTED_DNS_PROVIDER and SELECTED_DNS_CREDENTIALS
# Returns 0 if loaded, 1 otherwise
load_default_dns_config() {
    local default_config
    if default_config=$(load_dns_config "$DEFAULT_DNS_KEY"); then
        SELECTED_DNS_PROVIDER=$(echo "$default_config" | jq -r '.provider')
        SELECTED_DNS_CREDENTIALS=$(echo "$default_config" | jq -r '.credentials')
        if [[ -n "$SELECTED_DNS_PROVIDER" && -n "$SELECTED_DNS_CREDENTIALS" ]]; then
            info "已加载默认DNS配置 ($SELECTED_DNS_PROVIDER)。"
            return 0 # Success
        fi
    fi
    SELECTED_DNS_PROVIDER=""
    SELECTED_DNS_CREDENTIALS=""
    return 1 # Failure
}

# DNS提供商配置
# $1: domain_name
# Sets SELECTED_DNS_PROVIDER and SELECTED_DNS_CREDENTIALS
_configure_dns_provider_interactive() {
    local domain=$1
    local existing_config

    if existing_config=$(load_dns_config "$domain"); then
        local provider_name
        provider_name=$(echo "$existing_config" | jq -r '.provider')
        info "发现域名 $domain 的现有DNS配置 ($provider_name)"
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
    local choice
    while true; do
        read -r -p "请选择 [1-3]: " choice
        case $choice in
        1)
            SELECTED_DNS_PROVIDER="dns_cf"
            read -r -p "Cloudflare Email: " cf_email
            read -r -s -p "Cloudflare API Key: " cf_key
            echo
            SELECTED_DNS_CREDENTIALS="-e CF_Email=$cf_email -e CF_Key=$cf_key"
            break
            ;;
        2)
            SELECTED_DNS_PROVIDER="dns_ali"
            read -r -p "阿里云 Access Key: " ali_key
            read -r -s -p "阿里云 Secret: " ali_secret
            echo
            SELECTED_DNS_CREDENTIALS="-e Ali_Key=$ali_key -e Ali_Secret=$ali_secret"
            break
            ;;
        3)
            SELECTED_DNS_PROVIDER="dns_dp"
            read -r -p "DNSPod ID: " dp_id
            read -r -s -p "DNSPod Key: " dp_key
            echo
            SELECTED_DNS_CREDENTIALS="-e DP_Id=$dp_id -e DP_Key=$dp_key"
            break
            ;;
        *) warning "请输入有效的选项" ;;
        esac
    done

    if confirm "是否保存DNS配置以供将来使用?"; then
        save_dns_config "$domain" "$SELECTED_DNS_PROVIDER" "$SELECTED_DNS_CREDENTIALS"
    fi
}

configure_dns_provider() {
    local domain_to_configure=$1
    # Reset global vars
    SELECTED_DNS_PROVIDER=""
    SELECTED_DNS_CREDENTIALS=""

    if [[ "$NON_INTERACTIVE_MODE" == true ]]; then
        if [[ -n "$DNS_PROVIDER_ARG" && -n "$DNS_CREDENTIALS_ARG_EXEC" ]]; then
            info "非交互模式：使用通过 --dns-provider 和 --dns-creds 提供的DNS配置。"
            SELECTED_DNS_PROVIDER="$DNS_PROVIDER_ARG"
            SELECTED_DNS_CREDENTIALS="$DNS_CREDENTIALS_ARG_EXEC"
            return 0
        fi

        local existing_config
        if existing_config=$(load_dns_config "$domain_to_configure"); then
            info "非交互模式：为 $domain_to_configure 加载已保存的特定于域名的DNS配置。"
            SELECTED_DNS_PROVIDER=$(echo "$existing_config" | jq -r '.provider')
            SELECTED_DNS_CREDENTIALS=$(echo "$existing_config" | jq -r '.credentials')
            if [[ -n "$SELECTED_DNS_PROVIDER" && -n "$SELECTED_DNS_CREDENTIALS" ]]; then
                return 0
            else
                warning "为 $domain_to_configure 加载的特定于域名的DNS配置无效。"
            fi
        fi

        if load_default_dns_config; then
            info "非交互模式：使用已保存的默认DNS配置。"
            # SELECTED_DNS_PROVIDER and SELECTED_DNS_CREDENTIALS are set by load_default_dns_config
            return 0
        fi

        error_exit "非交互模式：DNS配置未找到。请提供 --dns-provider 和 --dns-creds, 或为域名 '$domain_to_configure' 保存配置, 或设置默认DNS配置。"

    else # Interactive mode
        local existing_domain_config
        if existing_domain_config=$(load_dns_config "$domain_to_configure"); then
            local provider_name=$(echo "$existing_domain_config" | jq -r '.provider')
            info "发现域名 $domain_to_configure 的现有DNS配置 ($provider_name)。"
            if confirm "是否使用此已保存的域名特定配置?"; then
                SELECTED_DNS_PROVIDER=$(echo "$existing_domain_config" | jq -r '.provider')
                SELECTED_DNS_CREDENTIALS=$(echo "$existing_domain_config" | jq -r '.credentials')
                return 0
            fi
        fi

        if load_default_dns_config; then # Sets SELECTED_DNS_PROVIDER and SELECTED_DNS_CREDENTIALS if found
            info "发现已保存的默认DNS配置 ($SELECTED_DNS_PROVIDER)。"
            if confirm "是否使用此默认DNS配置?"; then
                # Already set by load_default_dns_config
                return 0
            fi
        fi

        # If neither domain-specific nor default is used, prompt for new details for the domain
        info "为域名 $domain_to_configure 配置新的DNS提供商："
        local details
        details=$(_prompt_dns_provider_details "域名 $domain_to_configure 的")
        SELECTED_DNS_PROVIDER=$(echo "$details" | awk '{print $1}')
        SELECTED_DNS_CREDENTIALS=$(echo "$details" | cut -d' ' -f2-)

        if [[ -n "$SELECTED_DNS_PROVIDER" && -n "$SELECTED_DNS_CREDENTIALS" ]]; then
            if confirm "是否为域名 $domain_to_configure 保存此DNS配置以供将来使用?"; then
                save_dns_config "$domain_to_configure" "$SELECTED_DNS_PROVIDER" "$SELECTED_DNS_CREDENTIALS"
            fi
        else
            error_exit "未能获取 $domain_to_configure 的DNS提供商详情。"
        fi
    fi
}

# 签发新证书
issue_cert() {
    local domain_to_issue="${DOMAIN_NAME_ARG:-}"
    local issue_cmd_force_flag=""

    if [[ "$NON_INTERACTIVE_MODE" == false ]]; then
        info "开始签发新证书..."
        read -r -p "请输入域名: " domain_to_issue
        if [[ -z "$domain_to_issue" ]]; then error_exit "域名不能为空"; fi
    else
        if [[ -z "$domain_to_issue" ]]; then error_exit "非交互模式签发证书需要 --domain 参数。"; fi
        info "非交互模式：开始为 $domain_to_issue 签发新证书..."
    fi

    if [[ "$FORCE_ISSUE" == true ]]; then
        issue_cmd_force_flag="--force"
        info "将使用 --force 标志进行签发。"
    elif docker exec $ACME_SERVICE --list | grep -qw "$domain_to_issue"; then
        if ! confirm "证书 '$domain_to_issue' 已存在，是否重新签发 (使用 --force)?"; then
            info "取消签发。"
            return
        fi
        issue_cmd_force_flag="--force" # User confirmed re-issue
    fi

    configure_dns_provider "$domain_to_issue"

    if [[ -z "${SELECTED_DNS_PROVIDER:-}" || -z "${SELECTED_DNS_CREDENTIALS:-}" ]]; then
        error_exit "DNS配置无效，无法签发证书。"
    fi

    info "正在使用 $SELECTED_DNS_PROVIDER 为 $domain_to_issue 签发证书..."
    # Note: $SELECTED_DNS_CREDENTIALS is already an array of -e flags if set by parse_args,
    # or a string if set by interactive mode. Docker exec handles both.
    if docker exec $SELECTED_DNS_CREDENTIALS $ACME_SERVICE --issue $issue_cmd_force_flag -d "$domain_to_issue" --dns "$SELECTED_DNS_PROVIDER"; then
        success "证书 '$domain_to_issue' 签发成功!"
        get_cert_info "$domain_to_issue"
    else
        error_exit "证书 '$domain_to_issue' 签发失败。"
        # No automatic cleanup of DNS config on failure in non-interactive mode unless explicitly requested.
        if [[ "$NON_INTERACTIVE_MODE" == false ]]; then
            if confirm "是否清理此域名的DNS配置?"; then
                clean_dns_config "$domain_to_issue"
            fi
        fi
    fi
}

# 部署证书
deploy_cert() {
    local domain_to_deploy="${DOMAIN_NAME_ARG:-}"
    local label_for_deploy="${LABEL_VALUE_ARG:-}"

    if [[ "$NON_INTERACTIVE_MODE" == false ]]; then
        info "部署证书..."
        show_cert_menu "请选择要部署的证书："
        domain_to_deploy="$SELECTED_MENU_CERT"
        [[ -z "$domain_to_deploy" ]] && warning "未选择证书，取消部署。" && return

        # Try to guess label from docker-compose.yml for nginx service
        local nginx_label_from_compose
        nginx_label_from_compose=$(grep -A 5 "services:" "$SCRIPT_DIR/docker-compose.yml" | grep -A 3 "nginx:" | grep "sh.acme.autoload.domain" | sed -n 's/.*sh\.acme\.autoload\.domain=\(.*\)/\1/p' | head -n 1 | tr -d '"' | tr -d "'")

        local suggested_label="nginx" # Default suggestion
        if [[ -n "$nginx_label_from_compose" ]]; then
            suggested_label="$nginx_label_from_compose"
        fi
        read -r -p "请输入目标容器的label值 (例如: nginx, sh.acme.autoload.domain=nginx) [默认: $suggested_label]: " label_for_deploy
        label_for_deploy="${label_for_deploy:-$suggested_label}"

    else
        if [[ -z "$domain_to_deploy" ]]; then error_exit "非交互模式部署证书需要 --domain 参数。"; fi
        if [[ -z "$label_for_deploy" ]]; then
            # Try to guess label from docker-compose.yml for nginx service
            label_for_deploy=$(grep -A 5 "services:" "$SCRIPT_DIR/docker-compose.yml" | grep -A 3 "nginx:" | grep "sh.acme.autoload.domain" | sed -n 's/.*sh\.acme\.autoload\.domain=\(.*\)/\1/p' | head -n 1 | tr -d '"' | tr -d "'")
            if [[ -z "$label_for_deploy" ]]; then
                label_for_deploy="nginx" # Fallback default
                warning "无法从docker-compose.yml猜测label，使用默认值 'nginx'. 可通过 --label 指定."
            else
                info "从docker-compose.yml中自动检测到label '$label_for_deploy' 用于部署。"
            fi
        fi
        info "非交互模式：开始为 $domain_to_deploy 部署证书到label '$label_for_deploy'..."
    fi

    if ! docker exec $ACME_SERVICE --list | grep -qw "$domain_to_deploy"; then
        error_exit "证书 '$domain_to_deploy' 不存在，无法部署。"
    fi

    if ! confirm "是否确认部署证书 '$domain_to_deploy' 到具有label 'sh.acme.autoload.domain=$label_for_deploy' 的容器?"; then
        info "取消部署。"
        return
    fi

    info "正在部署证书 $domain_to_deploy..."
    local key_file_path="$DEFAULT_SSL_BASE_PATH_IN_CONTAINER/$domain_to_deploy/key.pem"
    local cert_file_path="$DEFAULT_SSL_BASE_PATH_IN_CONTAINER/$domain_to_deploy/cert.pem"
    local ca_file_path="$DEFAULT_SSL_BASE_PATH_IN_CONTAINER/$domain_to_deploy/ca.pem"
    local fullchain_file_path="$DEFAULT_SSL_BASE_PATH_IN_CONTAINER/$domain_to_deploy/full.pem"

    # The DEPLOY_DOCKER_CONTAINER_LABEL should be the *value* of the label, not the full "key=value"
    # acme.sh's docker hook searches for containers with label "sh.acme.autoload.domain" having the specified value.
    if docker exec \
        -e DEPLOY_DOCKER_CONTAINER_LABEL="sh.acme.autoload.domain=$label_for_deploy" \
        -e DEPLOY_DOCKER_CONTAINER_KEY_FILE="$key_file_path" \
        -e DEPLOY_DOCKER_CONTAINER_CERT_FILE="$cert_file_path" \
        -e DEPLOY_DOCKER_CONTAINER_CA_FILE="$ca_file_path" \
        -e DEPLOY_DOCKER_CONTAINER_FULLCHAIN_FILE="$fullchain_file_path" \
        -e DEPLOY_DOCKER_CONTAINER_RELOAD_CMD="$DEFAULT_NGINX_RELOAD_CMD" \
        $ACME_SERVICE --deploy -d "$domain_to_deploy" --deploy-hook docker; then
        success "证书 '$domain_to_deploy' 部署成功!"
    else
        error_exit "证书 '$domain_to_deploy' 部署失败。"
    fi
}

# 删除证书
remove_cert() {
    local domain_to_remove="${DOMAIN_NAME_ARG:-}"

    if [[ "$NON_INTERACTIVE_MODE" == false ]]; then
        info "删除证书..."
        show_cert_menu "请选择要删除的证书："
        domain_to_remove="$SELECTED_MENU_CERT"
        [[ -z "$domain_to_remove" ]] && warning "未选择证书，取消删除。" && return
    else
        if [[ -z "$domain_to_remove" ]]; then error_exit "非交互模式删除证书需要 --domain 参数。"; fi
        info "非交互模式：准备删除证书 $domain_to_remove..."
    fi

    if ! docker exec $ACME_SERVICE --list | grep -qw "$domain_to_remove"; then
        warning "证书 '$domain_to_remove' 本身未找到，可能已被删除。"
        # Still proceed to check DNS config
    fi

    if ! confirm "确定要删除证书 '$domain_to_remove' 吗?"; then
        info "取消删除。"
        return
    fi

    info "正在删除证书 '$domain_to_remove'..."
    local removed_cert_ok=true
    if docker exec $ACME_SERVICE --list | grep -qw "$domain_to_remove"; then # Check again before actual removal
        if ! docker exec $ACME_SERVICE --remove -d "$domain_to_remove"; then
            error_exit "证书 '$domain_to_remove' 删除失败。"
            removed_cert_ok=false # Should not reach here due to error_exit
        fi
    else
        info "证书 '$domain_to_remove' 在acme.sh列表中未找到，无需从acme.sh中删除。"
    fi

    if [[ "$removed_cert_ok" == true ]]; then
        success "证书 '$domain_to_remove' 已成功从acme.sh处理（或本就无需处理）。"
        if [[ -f "$DNS_CONFIG_FILE" ]] && jq -e --arg domain "$domain_to_remove" '.[$domain_to_remove]' "$DNS_CONFIG_FILE" >/dev/null; then
            if confirm "是否同时删除此域名的DNS配置?"; then
                clean_dns_config "$domain_to_remove"
            fi
        fi
    fi
}

# 更新所有证书
renew_all_certs() {
    info "更新所有证书..."
    local renew_force_flag=""
    if [[ "$FORCE_ISSUE" == true ]]; then # Re-use FORCE_ISSUE for renew --force
        renew_force_flag="--force"
        info "将使用 --force 标志进行更新。"
    fi

    if docker exec $ACME_SERVICE --renew-all $renew_force_flag; then
        success "所有证书更新成功!"
    else
        error_exit "证书更新失败。"
    fi
}

# 查看证书详细信息 (modified for non-interactive)
view_cert() {
    local domain_to_view="${DOMAIN_NAME_ARG:-}"
    if [[ "$NON_INTERACTIVE_MODE" == false ]]; then
        info "查看证书详细信息..."
        show_cert_menu "请选择要查看的证书："
        domain_to_view="$SELECTED_MENU_CERT"
        [[ -z "$domain_to_view" ]] && warning "未选择证书。" && return
    else
        if [[ -z "$domain_to_view" ]]; then error_exit "非交互模式查看证书信息需要 --domain 参数。"; fi
        info "非交互模式：查看证书 $domain_to_view 详细信息..."
    fi

    if ! docker exec $ACME_SERVICE --list | grep -qw "$domain_to_view"; then
        error_exit "证书 '$domain_to_view' 未找到。"
    fi
    echo "----------------------------------------"
    get_cert_info "$domain_to_view"
    echo "----------------------------------------"
}

# 全局配置菜单
global_config_menu() {
    while true; do
        echo
        echo "全局配置"
        echo "===================="
        echo "1) 切换证书颁发机构 (CA)"
        echo "2) 设置/更新默认DNS提供商"
        echo "3) 查看默认DNS提供商"
        echo "4) 清理默认DNS提供商配置"
        echo "5) 查看当前acme.sh配置"
        echo "6) 清理所有已保存的DNS配置 (包括每个域名的和默认的)"
        echo "0) 返回主菜单"
        echo
        read -r -p "请选择操作 [0-6]: " choice
        echo

        case $choice in
        1) configure_ca ;;
        2) set_default_dns_config ;;
        3)
            if load_default_dns_config; then
                info "当前默认DNS提供商: $SELECTED_DNS_PROVIDER"
                # Optionally show partial credentials if needed, but be careful with secrets
            else
                warning "未设置默认DNS提供商。"
            fi
            ;;
        4)
            if confirm "确定要清理默认DNS提供商配置吗?"; then
                clean_dns_config "$DEFAULT_DNS_KEY" # clean_dns_config handles non-existing keys gracefully
                success "默认DNS提供商配置已清理 (如果存在)。"
            fi
            ;;
        5)
            echo "当前acme.sh配置:"
            echo "----------------------------------------"
            docker exec $ACME_SERVICE --info
            echo "----------------------------------------"
            ;;
        6)
            if confirm "警告：确定要清理所有已保存的DNS配置吗？此操作不可恢复！"; then
                echo '{}' >"$DNS_CONFIG_FILE"
                success "所有已保存的DNS配置已清理。"
            fi
            ;;
        0) break ;;
        *) warning "无效的选择" ;;
        esac
    done
}

# 修改后的主菜单 (Interactive Mode Only)
main_menu_interactive() {
    # This function is only called if NON_INTERACTIVE_MODE is false
    while true; do
        echo
        echo -e "${GREEN}ACME.sh 证书管理工具 (交互模式)${NC}"
        echo "===================="
        echo "1) 列出已签发的证书"
        echo "2) 签发新证书"
        echo "3) 部署证书"
        echo "4) 删除证书"
        echo "5) 查看证书详细信息"
        echo "6) 更新所有证书"
        echo "7) 全局配置 (CA, DNS等)"
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
    command -v jq >/dev/null 2>&1 || error_exit "请先安装jq"
    command -v docker-compose >/dev/null 2>&1 || error_exit "请先安装docker-compose"
    command -v docker >/dev/null 2>&1 || error_exit "请先安装docker" # Added docker check
    command -v grep >/dev/null 2>&1 || error_exit "请先安装grep"     # Added grep check
    command -v sed >/dev/null 2>&1 || error_exit "请先安装sed"       # Added sed check
    command -v awk >/dev/null 2>&1 || error_exit "请先安装awk"       # Added awk check
    command -v mktemp >/dev/null 2>&1 || error_exit "请先安装mktemp" # Added mktemp check

    check_environment # Checks acme.sh container
    init_dns_config
    chmod 600 "$DNS_CONFIG_FILE" 2>/dev/null || true
}

# 主程序执行逻辑
main() {
    init_script
    parse_args "$@" # Pass all script arguments to parser

    if [[ "$NON_INTERACTIVE_MODE" == true ]]; then
        info "非交互模式运行: $ACTION"
        case $ACTION in
        issue) issue_cert ;;
        deploy) deploy_cert ;;
        remove) remove_cert ;;
        renew-all) renew_all_certs ;;
        list) get_cert_list ;;
        info) view_cert ;;
        configure-ca) configure_ca ;;
        set-default-dns) cli_set_default_dns_config ;;
        *)
            usage
            error_exit "无效的非交互操作: $ACTION"
            ;;
        esac
        success "非交互操作 '$ACTION' 完成。"
    else
        main_menu_interactive
    fi
}

main "$@"
