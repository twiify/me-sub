#!/bin/bash

# manage-xray.sh - 为 Xray 前置架构管理 Xray 配置和订阅的脚本 (V2 - 带订阅服务)

# --- 全局变量 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
XRAY_DIR="${SCRIPT_DIR}/xray"
NGINX_SITES_DIR="${SCRIPT_DIR}/nginx/sites"

XRAY_TEMPLATE_FILE="${XRAY_DIR}/xray_config_template.json"
XRAY_CONFIG_FILE="${XRAY_DIR}/xray_config.json"
CLASH_TEMPLATE_FILE="${XRAY_DIR}/clash_template.yaml"
XRAY_CLIENT_TEMPLATE_FILE="${XRAY_DIR}/xray_client_template.json"
OUTPUT_DIR="${XRAY_DIR}/xray_generated_configs"
PROFILE_FILE="${XRAY_DIR}/.xray_profile"

XRAY_CONTAINER_NAME="xray"
NGINX_CONTAINER_NAME="nginx"

# --- 辅助函数 ---
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

check_yes() {
    case $1 in
    y | Y | Yes | yes | YES)
        echo 1
        ;;
    *)
        echo 0
        ;;
    esac
}

check_dependencies() {
    if ! command -v jq &>/dev/null; then
        log_message "错误: jq 未安装。"
        exit 1
    fi
    if ! command -v openssl &>/dev/null; then
        log_message "错误: openssl 未安装。"
        exit 1
    fi
}

reload_services() {
    read -p "是否立即重载 Nginx 和 Xray 服务? (yes/no): " RELOAD_CHOICE
    if [[ "$(check_yes $RELOAD_CHOICE)" != "1" ]]; then
        log_message "操作已取消。请稍后手动重载服务以使更改生效。"
        return
    fi

    log_message "正在重载 Nginx..."
    docker exec "$NGINX_CONTAINER_NAME" nginx -s reload
    if [ $? -eq 0 ]; then log_message "Nginx 重载成功。"; else log_message "错误: Nginx 重载失败。"; fi

    log_message "正在重载 Xray..."
    docker exec "$XRAY_CONTAINER_NAME" sh -c 'kill -SIGUSR1 $(pidof xray)'
    if [ $? -eq 0 ]; then log_message "Xray 重载成功。"; else log_message "错误: Xray 重载失败。"; fi
}

# --- 核心功能 ---

generate_x25519_keys() {
    log_message "正在使用 OpenSSL 生成 X25519 密钥对..."
    # 使用 openssl 生成 PEM 格式的私钥
    local private_key_pem
    private_key_pem=$(openssl genpkey -algorithm x25519 2>/dev/null)
    if [ -z "$private_key_pem" ]; then
        log_message "错误: OpenSSL 生成密钥失败，请检查 openssl 版本或环境。"
        return 1
    fi
    # 从 PEM 中提取 base64url 编码的私钥和公钥
    PRIVATE_KEY=$(echo "$private_key_pem" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '/+' '_-' | tr -d '=')
    PUBLIC_KEY=$(echo "$private_key_pem" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '/+' '_-' | tr -d '=')

    if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
        log_message "错误: 从 OpenSSL 输出中提取密钥失败。"
        return 1
    fi
    return 0
}

# 函数：初始化或更新配置
setup_config() {
    local is_initial_setup=$1

    if [ "$is_initial_setup" = true ]; then
        echo "--- 初始化 Xray 配置 ---"
        if [ ! -f "$XRAY_TEMPLATE_FILE" ]; then
            log_message "错误: Xray 模板文件 '$XRAY_TEMPLATE_FILE' 不存在。"
            return 1
        fi
        read -p "请输入您的订阅主域名 (例如: sub.example.com): " SUB_DOMAIN
        if [ -z "$SUB_DOMAIN" ]; then
            log_message "错误: 订阅主域名不能为空。"
            return 1
        fi
        read -p "请输入您的 xhttp 路径 (例如 /my-secret-path): " XHTTP_PATH
        if [ -z "$XHTTP_PATH" ]; then
            XHTTP_PATH="/$(openssl rand -hex 8)"
            log_message "xhttp 路径为空, 使用随机路径: ${XHTTP_PATH}"
        fi
        # 确保路径以 / 开头
        if [[ ! "$XHTTP_PATH" == /* ]]; then XHTTP_PATH="/$XHTTP_PATH"; fi

        read -p "请输入伪装域名 (直接回车则使用域名 'wallhaven.cc'): " REALITY_TARGET_DOMAIN
        if [ -z "$REALITY_TARGET_DOMAIN" ]; then
            log_message "未输入伪装目标，将使用域名 'wallhaven.cc' 作为伪装目标。"
            REALITY_TARGET_DOMAIN="wallhaven.cc"
        fi

        SUB_TOKEN=$(openssl rand -hex 16)
        echo "SUB_DOMAIN=\"$SUB_DOMAIN\"" >"$PROFILE_FILE"
        echo "SUB_TOKEN=\"$SUB_TOKEN\"" >>"$PROFILE_FILE"
        echo "XHTTP_PATH=\"$XHTTP_PATH\"" >>"$PROFILE_FILE"
        echo "REALITY_TARGET_DOMAIN=\"$REALITY_TARGET_DOMAIN\"" >>"$PROFILE_FILE"
    else
        echo "--- 更新 Xray 凭证 ---"
        if [ ! -f "$PROFILE_FILE" ]; then
            log_message "错误: 配置文件 '$PROFILE_FILE' 不存在，请先初始化。"
            return 1
        fi
        source "$PROFILE_FILE"
    fi

    log_message "正在生成新的凭证..."
    if ! generate_x25519_keys; then return 1; fi
    local new_uuid
    new_uuid=$(openssl rand -hex 16)
    local new_short_id
    new_short_id=$(openssl rand -hex 8)
    # 核心：动态构建 serverNames 列表
    log_message "正在扫描 Nginx 站点目录以构建 serverNames 列表..."
    local server_names_list=()
    # 1. 添加主代理域名
    server_names_list+=("$SUB_DOMAIN")
    # 2. 扫描并从文件内容中提取域名
    if [ -d "$NGINX_SITES_DIR" ]; then
        # 使用 grep 和 awk 从 .conf 文件中提取所有 server_name
        # -R 递归搜索, -h 不显示文件名, -o 只输出匹配的部分, -E 使用扩展正则表达式
        # awk 用于处理 server_name 指令后的所有域名，并替换分号
        local extracted_domains
        extracted_domains=$(grep -rhoE '^[ \t]*server_name\s+[^;]+;' "$NGINX_SITES_DIR"/*.conf 2>/dev/null | awk '{for (i=2; i<=NF; i++) print $i}' | sed 's/;//g')

        # 将提取的域名添加到列表中
        for domain in $extracted_domains; do
            # 避免添加 subscription 域名，因为它通常与主域名相同或由脚本管理
            if [ "$domain" != "subscription" ] && [ "$domain" != "$SUB_DOMAIN" ]; then
                server_names_list+=("$domain")
            fi
        done
    fi

    # 将 bash 数组转换为 jq 可接受的 JSON 数组字符串
    local server_names_json_array
    server_names_json_array=$(printf '%s\n' "${server_names_list[@]}" | jq -R . | jq -s 'unique')
    log_message "构建的 serverNames 列表: $server_names_json_array"

    # 更新 jq 命令
    source "$PROFILE_FILE" # 确保加载了所有变量
    log_message "正在从模板创建新的 xray_config.json (使用 jq)..."
    jq \
        --arg ruuid "$new_uuid" \
        --argjson domains "$server_names_json_array" \
        --arg pvk "$PRIVATE_KEY" \
        --arg pbk "$PUBLIC_KEY" \
        --arg sid "$new_short_id" \
        --arg xpath "$XHTTP_PATH" \
        '
     # 更新 TCP-REALITY 入站 (inbounds[0])
     (.inbounds[0].settings.clients[0].id) = $ruuid |
     (.inbounds[0].streamSettings.realitySettings.serverNames) = $domains |
     (.inbounds[0].streamSettings.realitySettings.privateKey) = $pvk |
     (.inbounds[0].streamSettings.realitySettings.publicKey) = $pbk |
     (.inbounds[0].streamSettings.realitySettings.shortIds) = ["", $sid] |

     # 更新 xhttp 入站 (inbounds[1])
     (.inbounds[1].settings.clients[0].id) = $ruuid |
     (.inbounds[1].streamSettings.xhttpSettings.path) = $xpath
     ' \
        "$XRAY_TEMPLATE_FILE" >"$XRAY_CONFIG_FILE"

    log_message "Xray 配置文件 '$XRAY_CONFIG_FILE' 创建/更新成功。"
    generate_subscription_service
    reload_services
}

# 函数：生成订阅服务和文件
generate_subscription_service() {
    echo "--- 生成订阅文件和 Nginx 服务 ---"
    if [ ! -f "$XRAY_CONFIG_FILE" ] || [ ! -f "$PROFILE_FILE" ]; then
        log_message "错误: 配置文件不存在。请先初始化。"
        return 1
    fi
    source "$PROFILE_FILE"

    local reality_inbound
    local xhttp_inbound
    reality_inbound=$(jq '.inbounds[0]' "$XRAY_CONFIG_FILE")
    xhttp_inbound=$(jq '.inbounds[1]' "$XRAY_CONFIG_FILE")
    local uuid
    uuid=$(echo "$reality_inbound" | jq -r '.settings.clients[0].id')
    local flow
    flow=$(echo "$reality_inbound" | jq -r '.settings.clients[0].flow')
    local pbk
    pbk=$(echo "$reality_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
    local sid
    sid=$(echo "$reality_inbound" | jq -r '.streamSettings.realitySettings.shortIds[1]')
    local xpath
    xpath=$(echo "$xhttp_inbound" | jq -r '.streamSettings.xhttpSettings.path')

    local node_name="Xray-XTLS-Reality"
    local node_name1="Xray-XHTTP-Reality"

    local vless_link="vless://${uuid}@${SUB_DOMAIN}:443?type=tcp&security=reality&sni=${SUB_DOMAIN}&fp=chrome&pbk=${pbk}&sid=${sid}&flow=${flow}#${node_name}"
    local vless_link1="vless://${uuid}@${SUB_DOMAIN}:443?type=xhttp&security=reality&sni=${SUB_DOMAIN}&fp=chrome&pbk=${pbk}&sid=${sid}&path=${xpath}&mode=auto&host=${SUB_DOMAIN}#${node_name1}"

    mkdir -p "$OUTPUT_DIR"
    echo -e "${vless_link}\n${vless_link1}" >"${OUTPUT_DIR}/vless.txt"

    if [ -f "$CLASH_TEMPLATE_FILE" ]; then
        local clash_content
        clash_content=$(sed -e "s/{{NODE_NAME_REALITY}}/${node_name}/g" \
            -e "s|{{DOMAIN}}|${SUB_DOMAIN}|g" \
            -e "s|{{REALITY_UUID}}|${uuid}|g" \
            -e "s|{{REALITY_FLOW}}|${flow}|g" \
            -e "s|{{REALITY_SNI}}|${SUB_DOMAIN}|g" \
            -e "s|{{REALITY_PBK}}|${pbk}|g" \
            -e "s|{{REALITY_SID}}|${sid}|g" \
            "$CLASH_TEMPLATE_FILE")
        echo "$clash_content" >"${OUTPUT_DIR}/clash.yaml"
    fi

    if [ -f "$XRAY_CLIENT_TEMPLATE_FILE" ]; then
        local xray_client_content
        xray_client_content=$(sed -e "s|{{CLIENT_UUID}}|${uuid}|g" \
            -e "s|{{CLIENT_FLOW}}|${flow}|g" \
            -e "s|{{REALITY_PBK}}|${pub}|g" \
            -e "s|{{REALITY_SID}}|${sid}|g" \
            -e "s|{{XHTTP_PATH}}|${XHTTP_PATH}|g" \
        "$XRAY_CLIENT_TEMPLATE_FILE")
        echo "$xray_client_content" >"${OUTPUT_DIR}/xray_outbound_template.json"
    fi

    # 生成 Nginx 订阅服务器配置
    local sub_XRAY_CONFIG_FILE="${NGINX_SITES_DIR}/subscription.conf"
    log_message "正在生成 Nginx 订阅配置文件: $sub_XRAY_CONFIG_FILE"
    cat >"$sub_XRAY_CONFIG_FILE" <<-EOL
server {
    listen unix:/dev/shm/nginx.sock ssl;
    http2 on;
    server_name $SUB_DOMAIN;

    ssl_certificate /etc/nginx/ssl/$SUB_DOMAIN/full.pem;
    ssl_certificate_key /etc/nginx/ssl/$SUB_DOMAIN/key.pem;

    location /$SUB_TOKEN/vless {
        alias /var/www/subs/vless.txt;
        default_type text/plain;
    }

    location /$SUB_TOKEN/clash {
        alias /var/www/subs/clash.yaml;
        default_type application/x-yaml;
    }

    location /$SUB_TOKEN/xray_template {
        alias /var/www/subs/xray_outbound_template.json;
        default_type text/plain;
    }

    location $XHTTP_PATH {
        grpc_buffer_size         16k;
        grpc_socket_keepalive    on;
        grpc_read_timeout        30m;
        grpc_send_timeout        30m;
        grpc_set_header Connection         "";
        grpc_set_header X-Real-IP          \$remote_addr;
        grpc_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto  \$scheme;
        grpc_set_header X-Forwarded-Port   \$server_port;
        grpc_set_header Host               \$host;
        grpc_set_header X-Forwarded-Host   \$host;

        grpc_pass unix:/dev/shm/xhttp_upload.sock;
    }


    location / {
        resolver 127.0.0.11 valid=5s;
        set \$upstream_service https://$REALITY_TARGET_DOMAIN;

        proxy_pass \$upstream_service;

        sub_filter                            \$proxy_host \$host;
        sub_filter_once                       off;
        
        proxy_http_version                    1.1;
        proxy_cache_bypass                    \$http_upgrade;
        proxy_ssl_server_name                 on;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL
    echo "--- 订阅信息 ---"
    echo "VLESS 订阅 URL: https://${SUB_DOMAIN}/${SUB_TOKEN}/vless"
    echo "Clash 订阅 URL: https://${SUB_DOMAIN}/${SUB_TOKEN}/clash"
    echo "Xray 客户端模板: https://${SUB_DOMAIN}/${SUB_TOKEN}/xray_template"
    echo "------------------"
}

# --- 主菜单 ---
show_main_menu() {
    while true; do
        echo ""
        echo "=========================================="
        echo " Xray 配置与订阅管理脚本 (v2)"
        echo "=========================================="
        echo " 1. 初始化 Xray 配置 (会覆盖现有配置)"
        echo " 2. 更新 Xray 凭证并重新生成订阅"
        echo " 3. 查看当前订阅链接"
        echo " 0. 退出"
        echo "------------------------------------------"
        read -p "请输入选项 [0-3]: " choice

        case $choice in
        1) setup_config true ;;
        2) setup_config false ;;
        3)
            if [ -f "$PROFILE_FILE" ]; then
                source "$PROFILE_FILE"
                echo "--- 订阅信息 ---"
                echo "VLESS 订阅 URL: https://${SUB_DOMAIN}/${SUB_TOKEN}/vless"
                echo "Clash 订阅 URL: https://${SUB_DOMAIN}/${SUB_TOKEN}/clash"
                echo "Xray 客户端模板: https://${SUB_DOMAIN}/${SUB_TOKEN}/xray_template"
                echo "------------------"
            else
                log_message "尚未初始化，无订阅链接。"
            fi
            ;;
        0)
            log_message "已退出。"
            break
            ;;
        *) log_message "无效选项: $choice" ;;
        esac
        read -n 1 -s -r -p "按任意键返回主菜单..."
        echo ""
    done
}

# --- 主逻辑 ---
check_dependencies
show_main_menu
