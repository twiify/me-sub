#!/bin/bash

# autossl.sh - 自动管理 acme.sh 证书的脚本
# 支持文本 TUI 和 CLI 模式

# --- 全局变量 ---
CONFIG_FILE="ssl.json"
ACME_SH_CONTAINER_NAME="acme.sh"
NGINX_CONTAINER_NAME="nginx"
NGINX_CERT_PATH="/etc/nginx/ssl"
NGINX_RELOAD_CMD="nginx -s reload"
DEFAULT_DNS_PROVIDER="cloudflare"
DEFAULT_CA_KEY="zerossl"    # 存储默认CA的键名，如 lets_encrypt
DEFAULT_CA_SERVER="zerossl" # 存储默认CA的服务器名，如 letsencrypt

# --- 辅助函数 ---

# 函数：记录日志
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2 # 输出到 stderr
}

# 函数：检查依赖项
check_dependencies() {
    if ! command -v jq &>/dev/null; then
        log_message "错误: jq 未安装。请先安装 jq。"
        exit 1
    fi
}

# 函数：加载配置文件
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_message "错误: 配置文件 $CONFIG_FILE 未找到。"
        exit 1
    fi

    ACME_SH_CONTAINER_NAME=$(jq -r '.acme_sh_container_name' "$CONFIG_FILE")
    NGINX_CONTAINER_NAME=$(jq -r '.nginx_container_name' "$CONFIG_FILE")
    NGINX_CERT_PATH=$(jq -r '.nginx_cert_path_in_container' "$CONFIG_FILE")
    NGINX_RELOAD_CMD=$(jq -r '.nginx_reload_command' "$CONFIG_FILE")
    DEFAULT_DNS_PROVIDER=$(jq -r '.default_dns_provider' "$CONFIG_FILE")
    DEFAULT_CA_KEY=$(jq -r '.default_ca' "$CONFIG_FILE")
    DEFAULT_CA_SERVER=$(jq -r ".certificate_authorities.\"$DEFAULT_CA_KEY\".server_name" "$CONFIG_FILE")

    if [ "$ACME_SH_CONTAINER_NAME" == "null" ] || [ -z "$ACME_SH_CONTAINER_NAME" ]; then
        log_message "错误: 配置文件中 acme_sh_container_name 未设置。"
        exit 1
    fi
    if [ "$DEFAULT_CA_KEY" == "null" ] || [ -z "$DEFAULT_CA_KEY" ] || [ "$DEFAULT_CA_SERVER" == "null" ] || [ -z "$DEFAULT_CA_SERVER" ]; then
        log_message "错误: 配置文件中 default_ca 或其对应的 server_name 未正确设置。"
        exit 1
    fi
    log_message "配置加载成功。默认DNS: $DEFAULT_DNS_PROVIDER, 默认CA: $DEFAULT_CA_KEY ($DEFAULT_CA_SERVER)"
}

# 函数：执行 acme.sh 命令 (在 acme.sh 容器内)
run_acme_sh_command() {
    log_message "在容器 '$ACME_SH_CONTAINER_NAME' 中执行: acme.sh $@"
    docker exec "$ACME_SH_CONTAINER_NAME" acme.sh "$@"
    return $? # 返回 acme.sh 命令的退出状态
}

# 函数：执行 acme.sh 命令并传递 DNS API 环境变量
run_acme_sh_command_with_dns_env() {
    local dns_provider_key=$1
    shift
    local acme_args=("$@")
    local env_vars=()
    local api_creds_json=$(jq -r ".dns_providers.\"$dns_provider_key\".api_credentials" "$CONFIG_FILE")

    if [ "$api_creds_json" == "null" ] || [ -z "$api_creds_json" ]; then
        log_message "错误: 未找到 DNS 提供商 '$dns_provider_key' 的 API 凭证配置。"
        return 1
    fi

    for key in $(echo "$api_creds_json" | jq -r 'keys[]'); do
        local value=$(echo "$api_creds_json" | jq -r ".$key")
        if [ -n "$value" ] && [ "$value" != "null" ] && [ "$value" != "" ]; then
            env_vars+=("-e" "$key=$value")
        else
            log_message "警告: DNS提供商 '$dns_provider_key' 的 API凭证 '$key' 未在配置文件中设置或为空。"
        fi
    done

    if [ ${#env_vars[@]} -eq 0 ]; then
        log_message "错误: DNS提供商 '$dns_provider_key' 的所有API凭证均未设置。无法继续。"
        return 1
    fi

    log_message "在容器 '$ACME_SH_CONTAINER_NAME' 中执行 (带DNS环境变量 for $dns_provider_key): acme.sh ${acme_args[*]}"
    docker exec "${env_vars[@]}" "$ACME_SH_CONTAINER_NAME" acme.sh "${acme_args[@]}"
    return $? # 返回 acme.sh 命令的退出状态
}

# 函数：获取已存在的域名列表 (每行一个域名输出)
get_existing_domains_array() {
    local list_output
    list_output=$(run_acme_sh_command --list)

    # 检查 list_output 是否为空或仅包含标题行 (通常 acme.sh --list 在没有证书时可能输出空或只有标题)
    # 计算行数，如果小于等于1（即空或只有标题），则不进行处理
    local line_count=$(echo "$list_output" | wc -l)
    if [ -z "$list_output" ] || [ "$line_count" -le 1 ]; then
        # 没有域名或只有标题行，则输出空，调用者 mapfile 会得到空数组
        return
    fi

    # 使用 awk 跳过第一行 (NR>1)，并打印第一个字段 ($1)
    # 同时确保第一个字段不为空
    echo "$list_output" | awk 'NR>1 && $1!="" {print $1}'
}

# --- 核心功能函数 ---

list_certificates() {
    log_message "正在获取证书列表..."
    run_acme_sh_command --list
}

view_certificate_details() {
    local domain=$1
    if [ -z "$domain" ]; then
        log_message "错误: 请提供域名以查看详情。"
        return 1
    fi
    log_message "正在获取域名 '$domain' 的证书详情..."
    run_acme_sh_command --info -d "$domain"
}

delete_certificate() {
    local domain=$1
    if [ -z "$domain" ]; then
        log_message "错误: 请提供域名以删除证书。"
        return 1
    fi
    log_message "准备删除域名 '$domain' 的证书..."
    run_acme_sh_command --remove -d "$domain"
}

# 函数：签发或续签证书
# 参数: $1 - 域名 (例如: example.com 或 *.example.com,sub.example.com)
#       $2 - DNS 提供商 (可选, 默认为配置文件中的 default_dns_provider)
#       $3 - CA (可选, 默认为配置文件中的 default_ca_key)
#       $4 - 是否强制续签 (可选, "true" 表示续签，否则为新签发)
issue_or_renew_certificate() {
    local domains=$1
    local dns_provider_key=${2:-$DEFAULT_DNS_PROVIDER}
    local ca_issue_key=${3:-$DEFAULT_CA_KEY}
    local force_renew=${4:-"false"}

    if [ -z "$domains" ]; then
        log_message "错误: 请提供需要操作的域名。"
        return 1
    fi

    local primary_domain=$(echo "$domains" | cut -d, -f1) # 取第一个域名作为主域名判断
    local existing_domains_string=$(get_existing_domains_array)
    local domain_exists=false
    while IFS= read -r ex_dom; do
        if [ "$ex_dom" == "$primary_domain" ]; then
            domain_exists=true
            break
        fi
    done <<<"$existing_domains_string"

    local cmd_to_run
    local action_desc

    if [ "$domain_exists" == "true" ] || [ "$force_renew" == "true" ]; then
        log_message "域名 '$primary_domain' 已存在或被指定续签，准备执行续签操作..."
        action_desc="续签"
        # 对于续签，acme.sh 会使用其配置文件中该域名的现有设置（包括DNS提供商）
        # 如果希望在续签时能更改CA或DNS，需要更复杂的逻辑，或先移除再签发
        # --force 确保即使证书未到期也尝试续签
        # --server 可以用来指定CA，但续签时通常会沿用旧的
        local renew_args=("--renew" "-d" "$primary_domain") # 续签通常针对主域名
        # 如果 domains 包含多个，acme.sh renew -d main.com 会自动处理SANs
        if [ "$ca_issue_key" != "$DEFAULT_CA_KEY" ]; then # 如果用户指定了非默认CA
            local ca_server_for_renew=$(jq -r ".certificate_authorities.\"$ca_issue_key\".server_name" "$CONFIG_FILE")
            if [ "$ca_server_for_renew" != "null" ] && [ -n "$ca_server_for_renew" ]; then
                renew_args+=("--server" "$ca_server_for_renew")
            fi
        fi
        renew_args+=("--force")
        run_acme_sh_command "${renew_args[@]}"
        cmd_status=$?
    else
        log_message "准备为域名 '$domains' 使用 DNS 提供商 '$dns_provider_key' 和 CA '$ca_issue_key' 签发新证书..."
        action_desc="签发"
        local acme_dns_api_name=$(jq -r ".dns_providers.\"$dns_provider_key\".acme_dns_api_name" "$CONFIG_FILE")
        local ca_server_to_use=$(jq -r ".certificate_authorities.\"$ca_issue_key\".server_name" "$CONFIG_FILE")

        if [ "$acme_dns_api_name" == "null" ] || [ -z "$acme_dns_api_name" ]; then
            log_message "错误: 未找到 DNS 提供商 '$dns_provider_key' 的 acme_dns_api_name。"
            return 1
        fi
        if [ "$ca_server_to_use" == "null" ] || [ -z "$ca_server_to_use" ]; then
            log_message "错误: 未找到证书颁发机构 '$ca_issue_key' 的 server_name。"
            return 1
        fi

        local domain_args=()
        IFS=',' read -ra DOMAIN_ARRAY <<<"$domains"
        for d_issue in "${DOMAIN_ARRAY[@]}"; do
            domain_args+=("-d" "$d_issue")
        done

        run_acme_sh_command_with_dns_env "$dns_provider_key" --issue --dns "$acme_dns_api_name" "${domain_args[@]}" --server "$ca_server_to_use"
        cmd_status=$?
    fi

    if [ $cmd_status -eq 0 ]; then
        log_message "证书 $action_desc 成功: $domains"
        read -p "是否立即部署证书到 Nginx? (yes/no): " deploy_now_choice
        if [ "$deploy_now_choice" == "yes" ]; then
            deploy_certificate_to_nginx "$primary_domain" # 部署通常用主域名
        else
            log_message "证书未部署。"
        fi
    else
        log_message "证书 $action_desc 失败: $domains (退出码: $cmd_status)"
    fi
    return $cmd_status
}

deploy_certificate_to_nginx() {
    local domain=$1
    if [ -z "$domain" ]; then
        log_message "错误: 请提供域名以部署证书。"
        return 1
    fi

    log_message "准备将域名 '$domain' 的证书部署到 Nginx 容器 '$NGINX_CONTAINER_NAME'..."
    local cert_dir_in_container="$NGINX_CERT_PATH/$domain"
    local key_file="$cert_dir_in_container/key.pem"
    local fullchain_file="$cert_dir_in_container/full.pem"

    log_message "在 acme.sh 容器内创建证书目录: $cert_dir_in_container"
    docker exec "$ACME_SH_CONTAINER_NAME" mkdir -p "$cert_dir_in_container"
    if [ $? -ne 0 ]; then
        log_message "错误: 在容器内创建目录失败。"
        return 1
    fi

    log_message "部署证书 '$domain' 到 Nginx..."
    run_acme_sh_command \
        --install-cert -d "$domain" \
        --key-file "$key_file" \
        --fullchain-file "$fullchain_file" \
        --reloadcmd "docker exec $NGINX_CONTAINER_NAME $NGINX_RELOAD_CMD"
}

switch_default_ca() {
    local target_ca_key=$1
    local registration_email=$2

    if [ -z "$target_ca_key" ]; then
        log_message "错误: 请提供要切换到的 CA (例如 lets_encrypt 或 zerossl)。"
        return 1
    fi
    if [ -z "$registration_email" ]; then
        log_message "错误: 请提供用于 CA 账户注册的邮箱地址。"
        return 1
    fi

    local target_ca_server_name=$(jq -r ".certificate_authorities.\"$target_ca_key\".server_name" "$CONFIG_FILE")
    if [ "$target_ca_server_name" == "null" ] || [ -z "$target_ca_server_name" ]; then
        log_message "错误: 未找到 CA '$target_ca_key' 的配置。"
        return 1
    fi

    log_message "正在尝试为邮箱 '$registration_email' 在 CA '$target_ca_key' ($target_ca_server_name) 注册账户..."
    run_acme_sh_command --register-account -m "$registration_email" --server "$target_ca_server_name"
    if [ $? -ne 0 ]; then
        log_message "警告: 账户注册可能失败或已存在。继续尝试设置默认CA。"
    else
        log_message "账户注册/检查成功。"
    fi

    log_message "正在切换默认 CA 为 '$target_ca_key' ($target_ca_server_name)..."
    run_acme_sh_command --set-default-ca --server "$target_ca_server_name"
    if [ $? -eq 0 ]; then
        jq ".default_ca = \"$target_ca_key\"" "$CONFIG_FILE" >"${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        log_message "配置文件 $CONFIG_FILE 已更新，默认 CA 设置为 $target_ca_key。"
        DEFAULT_CA_KEY=$target_ca_key
        DEFAULT_CA_SERVER=$target_ca_server_name
    else
        log_message "错误: 切换默认 CA 失败。"
    fi
}

configure_dns_provider_text_tui() {
    local provider_key=$1
    local provider_name=$(jq -r ".dns_providers.\"$provider_key\".name" "$CONFIG_FILE")

    echo "--- 配置 DNS 提供商: $provider_name ---"
    local creds_template=$(jq -r ".dns_providers.\"$provider_key\".api_credentials" "$CONFIG_FILE")
    local updated_creds="{}"

    for cred_key in $(echo "$creds_template" | jq -r 'keys[]'); do
        local current_value=$(jq -r ".dns_providers.\"$provider_key\".api_credentials.\"$cred_key\"" "$CONFIG_FILE")
        read -p "请输入 $provider_name 的 $cred_key (当前: $current_value, 直接回车保留): " new_value
        if [ -z "$new_value" ] && [ "$new_value" != "\"\"" ]; then # 保留当前值，除非用户明确输入空字符串 ""
            updated_creds=$(echo "$updated_creds" | jq ". + {\"$cred_key\": \"$current_value\"}")
        else
            # 如果用户输入 "" (带引号的空字符串)，则视为空字符串，否则为输入值
            [ "$new_value" == "\"\"" ] && new_value=""
            updated_creds=$(echo "$updated_creds" | jq ". + {\"$cred_key\": \"$new_value\"}")
        fi
    done

    jq ".dns_providers.\"$provider_key\".api_credentials = $updated_creds" "$CONFIG_FILE" >"${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    log_message "DNS 提供商 '$provider_name' 的凭证已更新到 $CONFIG_FILE。"
    echo "-------------------------------------"
}

# --- 文本 TUI 函数 ---
show_text_tui_menu() {
    while true; do
        echo ""
        echo "====================================="
        echo " AutoSSL 管理脚本 - 请选择操作:"
        echo "====================================="
        echo " 1. 查看证书列表"
        echo " 2. 查看证书详情"
        echo " 3. 签发/续签证书"
        echo " 4. 删除证书"
        echo " 5. 部署证书到Nginx"
        echo " 6. 切换默认CA (当前: $DEFAULT_CA_KEY)"
        echo " 7. 配置DNS提供商凭证"
        echo " 0. 退出"
        echo "-------------------------------------"
        read -p "请输入选项 [1-8]: " choice

        case $choice in
        1)
            list_certificates
            ;;
        2)
            # 查看证书详情
            mapfile -t existing_domains_arr < <(get_existing_domains_array)
            if [ ${#existing_domains_arr[@]} -eq 0 ]; then
                log_message "没有找到已存在的证书。"
            else
                echo "请选择要查看详情的域名:"
                for i in "${!existing_domains_arr[@]}"; do
                    echo " $((i + 1)). ${existing_domains_arr[$i]}"
                done
                read -p "请输入域名序号: " domain_idx
                if [[ "$domain_idx" =~ ^[0-9]+$ ]] && [ "$domain_idx" -gt 0 ] && [ "$domain_idx" -le "${#existing_domains_arr[@]}" ]; then
                    view_certificate_details "${existing_domains_arr[$((domain_idx - 1))]}"
                else
                    log_message "无效的域名序号。"
                fi
            fi
            ;;
        3)
            # 签发/续签证书
            read -p "请输入要签发/续签的域名 (多个域名用逗号分隔, e.g., example.com,*.example.com): " domains_input
            if [ -z "$domains_input" ]; then
                log_message "未输入域名。"
                continue
            fi

            echo "可用DNS提供商:"
            local i_dns=1
            local dns_keys_array=($(jq -r '.dns_providers | keys[]' "$CONFIG_FILE"))
            for key_dns in "${dns_keys_array[@]}"; do
                local name_dns=$(jq -r ".dns_providers.\"$key_dns\".name" "$CONFIG_FILE")
                echo " $i_dns. $name_dns ($key_dns)"
                i_dns=$((i_dns + 1))
            done
            echo " $i_dns. 使用默认 ($DEFAULT_DNS_PROVIDER)"
            read -p "请选择DNS提供商 [1-$i_dns] (默认为 $i_dns): " dns_choice_num

            local dns_provider_to_use
            if [ -z "$dns_choice_num" ] || [ "$dns_choice_num" -eq "$i_dns" ]; then
                dns_provider_to_use=$DEFAULT_DNS_PROVIDER
            elif [ "$dns_choice_num" -gt 0 ] && [ "$dns_choice_num" -lt "$i_dns" ]; then
                dns_provider_to_use=${dns_keys_array[$((dns_choice_num - 1))]}
            else
                log_message "无效的DNS提供商选择。"
                continue
            fi

            echo "可用证书颁发机构 (CA):"
            local j_ca=1
            local ca_keys_array=($(jq -r '.certificate_authorities | keys[]' "$CONFIG_FILE"))
            for key_ca in "${ca_keys_array[@]}"; do
                local name_ca=$(jq -r ".certificate_authorities.\"$key_ca\".name" "$CONFIG_FILE")
                echo " $j_ca. $name_ca ($key_ca)"
                j_ca=$((j_ca + 1))
            done
            echo " $j_ca. 使用默认 ($DEFAULT_CA_KEY)"
            read -p "请选择CA [1-$j_ca] (默认为 $j_ca): " ca_choice_num

            local ca_key_to_use
            if [ -z "$ca_choice_num" ] || [ "$ca_choice_num" -eq "$j_ca" ]; then
                ca_key_to_use=$DEFAULT_CA_KEY
            elif [ "$ca_choice_num" -gt 0 ] && [ "$ca_choice_num" -lt "$j_ca" ]; then
                ca_key_to_use=${ca_keys_array[$((ca_choice_num - 1))]}
            else
                log_message "无效的CA选择。"
                continue
            fi

            issue_or_renew_certificate "$domains_input" "$dns_provider_to_use" "$ca_key_to_use"
            ;;
        4)
            # 删除证书
            mapfile -t existing_domains_arr_del < <(get_existing_domains_array)
            if [ ${#existing_domains_arr_del[@]} -eq 0 ]; then
                log_message "没有找到已存在的证书可以删除。"
            else
                echo "请选择要删除的域名:"
                for i_del in "${!existing_domains_arr_del[@]}"; do
                    echo " $((i_del + 1)). ${existing_domains_arr_del[$i_del]}"
                done
                read -p "请输入域名序号: " domain_idx_del
                if [[ "$domain_idx_del" =~ ^[0-9]+$ ]] && [ "$domain_idx_del" -gt 0 ] && [ "$domain_idx_del" -le "${#existing_domains_arr_del[@]}" ]; then
                    local domain_to_delete_selected="${existing_domains_arr_del[$((domain_idx_del - 1))]}"
                    read -p "确定要删除域名 '$domain_to_delete_selected' 的证书吗? (yes/no): " confirm_delete
                    if [ "$confirm_delete" == "yes" ]; then
                        delete_certificate "$domain_to_delete_selected"
                    else
                        log_message "删除操作已取消。"
                    fi
                else
                    log_message "无效的域名序号。"
                fi
            fi
            ;;
        5)
            # 部署证书
            mapfile -t existing_domains_arr_dep < <(get_existing_domains_array)
            if [ ${#existing_domains_arr_dep[@]} -eq 0 ]; then
                log_message "没有找到已存在的证书可以部署。"
            else
                echo "请选择要部署到Nginx的域名:"
                for i_dep in "${!existing_domains_arr_dep[@]}"; do
                    echo " $((i_dep + 1)). ${existing_domains_arr_dep[$i_dep]}"
                done
                read -p "请输入域名序号: " domain_idx_dep
                if [[ "$domain_idx_dep" =~ ^[0-9]+$ ]] && [ "$domain_idx_dep" -gt 0 ] && [ "$domain_idx_dep" -le "${#existing_domains_arr_dep[@]}" ]; then
                    deploy_certificate_to_nginx "${existing_domains_arr_dep[$((domain_idx_dep - 1))]}"
                else
                    log_message "无效的域名序号。"
                fi
            fi
            ;;
        6)
            # 切换默认CA
            echo "可用证书颁发机构 (CA):"
            local k_ca_sw=1
            local ca_switch_keys_array=($(jq -r '.certificate_authorities | keys[]' "$CONFIG_FILE"))
            for key_ca_switch in "${ca_switch_keys_array[@]}"; do
                local name_ca_switch=$(jq -r ".certificate_authorities.\"$key_ca_switch\".name" "$CONFIG_FILE")
                echo " $k_ca_sw. $name_ca_switch ($key_ca_switch)"
                k_ca_sw=$((k_ca_sw + 1))
            done
            read -p "请选择要切换到的默认CA [1-$(($k_ca_sw - 1))]: " ca_switch_choice_num

            if [[ "$ca_switch_choice_num" =~ ^[0-9]+$ ]] && [ "$ca_switch_choice_num" -gt 0 ] && [ "$ca_switch_choice_num" -lt "$k_ca_sw" ]; then
                local selected_ca_key_switch=${ca_switch_keys_array[$((ca_switch_choice_num - 1))]}
                read -p "请输入用于CA账户注册/关联的邮箱地址: " reg_email
                if [ -n "$reg_email" ]; then
                    switch_default_ca "$selected_ca_key_switch" "$reg_email"
                else
                    log_message "未输入邮箱地址，操作取消。"
                fi
            else
                log_message "无效的CA选择。"
            fi
            ;;
        7)
            # 配置DNS提供商
            echo "可用DNS提供商进行配置:"
            local l_dns_cfg=1
            local dns_config_keys_array=($(jq -r '.dns_providers | keys[]' "$CONFIG_FILE"))
            for key_dns_conf in "${dns_config_keys_array[@]}"; do
                local name_dns_conf=$(jq -r ".dns_providers.\"$key_dns_conf\".name" "$CONFIG_FILE")
                echo " $l_dns_cfg. $name_dns_conf ($key_dns_conf)"
                l_dns_cfg=$((l_dns_cfg + 1))
            done
            read -p "请选择要配置凭证的DNS提供商 [1-$(($l_dns_cfg - 1))]: " dns_config_choice_num

            if [[ "$dns_config_choice_num" =~ ^[0-9]+$ ]] && [ "$dns_config_choice_num" -gt 0 ] && [ "$dns_config_choice_num" -lt "$l_dns_cfg" ]; then
                local selected_dns_key_config=${dns_config_keys_array[$((dns_config_choice_num - 1))]}
                configure_dns_provider_text_tui "$selected_dns_key_config"
            else
                log_message "无效的DNS提供商选择。"
            fi
            ;;
        0)
            log_message "已退出。"
            break
            ;;
        *)
            log_message "无效选项: $choice"
            ;;
        esac
        read -n 1 -s -r -p "按任意键继续..."
        echo ""
    done
}

# --- CLI 处理 ---
handle_cli_args() {
    if [ "$#" -eq 0 ]; then
        show_text_tui_menu
        exit 0
    fi

    local command=$1
    shift

    case $command in
    list)
        list_certificates
        ;;
    info)
        view_certificate_details "$1"
        ;;
    delete)
        delete_certificate "$1"
        ;;
    issue)
        # issue <domains> [dns_provider_key] [ca_key] [force_renew_true_false]
        issue_or_renew_certificate "$1" "$2" "$3" "$4"
        ;;
    deploy)
        deploy_certificate_to_nginx "$1"
        ;;
    switch-ca)
        # switch-ca <ca_key> <email>
        if [ -z "$1" ] || [ -z "$2" ]; then
            log_message "错误: switch-ca 需要 <ca_key> 和 <email> 参数。"
            display_help
            exit 1
        fi
        switch_default_ca "$1" "$2"
        ;;
    config-dns)
        # config-dns <provider_key>
        log_message "CLI模式下的DNS配置建议直接修改 autossl.json 文件或使用TUI模式。"
        log_message "如果仍要继续，请确保已备份 autossl.json。"
        read -p "是否继续通过CLI配置DNS for '$1'? (yes/no): " confirm_cli_dns_config
        if [ "$confirm_cli_dns_config" == "yes" ]; then
            configure_dns_provider_text_tui "$1"
        else
            log_message "DNS配置已取消。"
        fi
        ;;
    help | --help | -h)
        display_help
        ;;
    *)
        log_message "错误: 未知命令 '$command'"
        display_help
        exit 1
        ;;
    esac
}

# 函数：显示帮助信息
display_help() {
    echo "用法: $0 [命令] [参数...]"
    echo ""
    echo "如果未提供命令，则进入交互式文本 TUI 模式。"
    echo ""
    echo "可用命令:"
    echo "  list                      查看所有证书"
    echo "  info <domain>             查看指定域名的证书详情"
    echo "  delete <domain>           删除指定域名的证书"
    echo "  issue <domains> [dns_provider] [ca_key] [force_renew]  签发或续签证书"
    echo "                            <domains>: 逗号分隔的域名列表, e.g., 'example.com,*.example.com'"
    echo "                            [dns_provider]: cloudflare, tencent_cloud, aliyun (默认: $DEFAULT_DNS_PROVIDER)"
    echo "                            [ca_key]: lets_encrypt, zerossl (默认: $DEFAULT_CA_KEY)"
    echo "                            [force_renew]: 'true' 强制续签 (可选, 默认 'false')"
    echo "  deploy <domain>           将证书部署到 Nginx"
    echo "  switch-ca <ca_key> <email> 切换默认证书颁发机构 (ca_key: lets_encrypt/zerossl, email: 你的邮箱)"
    echo "  config-dns <provider_key> 通过交互式提示配置指定 DNS 提供商的 API 凭证"
    echo "  help, --help, -h          显示此帮助信息"
    echo ""
}

# --- 主程序 ---
main() {
    check_dependencies
    load_config

    if [ "$#" -gt 0 ]; then
        handle_cli_args "$@"
    else
        show_text_tui_menu
    fi
}

main "$@"
