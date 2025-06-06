#!/bin/bash

# manage-xray.sh - 为 Xray 前置架构管理 Xray 配置和订阅的脚本 (V2 - 带订阅服务)

# --- 全局变量 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
XRAY_DIR="${SCRIPT_DIR}/xray"
NGINX_SITES_DIR="${SCRIPT_DIR}/nginx/sites"

CONFIG_TEMPLATE_FILE="${XRAY_DIR}/xray_config_template.json"
CONFIG_FILE="${XRAY_DIR}/xray_config.json"
CLASH_TEMPLATE_FILE="${XRAY_DIR}/clash_template.yaml"
OUTPUT_DIR="${XRAY_DIR}/xray_generated_configs"
PROFILE_FILE="${XRAY_DIR}/.xray_profile" # 用于存储域名和Token

XRAY_CONTAINER_NAME="xray"
NGINX_CONTAINER_NAME="nginx"

# --- 辅助函数 ---
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

check_dependencies() {
    if ! command -v jq &>/dev/null; then log_message "错误: jq 未安装。"; exit 1; fi
    if ! command -v openssl &>/dev/null; then log_message "错误: openssl 未安装。"; exit 1; fi
}

reload_services() {
    read -p "是否立即重载 Nginx 和 Xray 服务? (yes/no): " RELOAD_CHOICE
    if [[ "$RELOAD_CHOICE" != "yes" && "$RELOAD_CHOICE" != "y" ]]; then
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
        if [ ! -f "$CONFIG_TEMPLATE_FILE" ]; then log_message "错误: Xray 模板文件 '$CONFIG_TEMPLATE_FILE' 不存在。"; return 1; fi
        read -p "请输入您的代理主域名 (例如: proxy.example.com): " PROXY_DOMAIN
        if [ -z "$PROXY_DOMAIN" ]; then log_message "错误: 代理主域名不能为空。"; return 1; fi
        SUBSCRIPTION_TOKEN=$(openssl rand -hex 16)
        echo "PROXY_DOMAIN=\"$PROXY_DOMAIN\"" > "$PROFILE_FILE"
        echo "SUBSCRIPTION_TOKEN=\"$SUBSCRIPTION_TOKEN\"" >> "$PROFILE_FILE"
    else
        echo "--- 更新 Xray 凭证 ---"
        if [ ! -f "$PROFILE_FILE" ]; then log_message "错误: 配置文件 '$PROFILE_FILE' 不存在，请先初始化。"; return 1; fi
        source "$PROFILE_FILE"
    fi

    log_message "正在生成新的凭证..."
    if ! generate_x25519_keys; then return 1; fi
    local new_uuid
    new_uuid=$(openssl rand -hex 16)
    local new_short_id
    new_short_id=$(openssl rand -hex 8)
    local new_xhttp_path
    new_xhttp_path="/$(openssl rand -hex 8)"

    log_message "正在从模板创建新的 xray_config.json (使用 jq)..."
    jq \
      --arg ruuid "$new_uuid" \
      --arg rflow "xtls-rprx-vision" \
      --arg domain "$PROXY_DOMAIN" \
      --arg pvk "$PRIVATE_KEY" \
      --arg pbk "$PUBLIC_KEY" \
      --arg sid "$new_short_id" \
      --arg rpath "$new_xhttp_path" \
      '
      (.inbounds[0].settings.clients[0].id) = $ruuid |
      (.inbounds[0].settings.clients[0].flow) = $rflow |
      (.inbounds[0].streamSettings.realitySettings.serverNames) = [$domain] |
      (.inbounds[0].streamSettings.realitySettings.privateKey) = $pvk |
      (.inbounds[0].streamSettings.realitySettings.publicKey) = $pbk |
      (.inbounds[0].streamSettings.realitySettings.shortIds) = [$sid]
      ' \
      "$CONFIG_TEMPLATE_FILE" > "$CONFIG_FILE"

    log_message "Xray 配置文件 '$CONFIG_FILE' 创建/更新成功。"
    generate_subscription_service
    reload_services
}

# 函数：生成订阅服务和文件
generate_subscription_service() {
    echo "--- 生成订阅文件和 Nginx 服务 ---"
    if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$PROFILE_FILE" ]; then
        log_message "错误: 配置文件不存在。请先初始化。"
        return 1
    fi
    source "$PROFILE_FILE"

    local reality_inbound
    reality_inbound=$(jq '.inbounds[0]' "$CONFIG_FILE")
    local uuid
    uuid=$(echo "$reality_inbound" | jq -r '.settings.clients[0].id')
    local pbk
    pbk=$(echo "$reality_inbound" | jq -r '.streamSettings.realitySettings.publicKey')
    local sid
    sid=$(echo "$reality_inbound" | jq -r '.streamSettings.realitySettings.shortIds[0]')
    local flow
    flow=$(echo "$reality_inbound" | jq -r '.settings.clients[0].flow')
    # 在新架构中，xhttp path 仅用于生成客户端链接，不由服务端配置
    # 我们从 profile 文件中读取它，如果不存在则生成一个新的
    if grep -q "XHTTP_PATH" "$PROFILE_FILE"; then
        source "$PROFILE_FILE"
    else
        XHTTP_PATH="/$(openssl rand -hex 8)"
        echo "XHTTP_PATH=\"$XHTTP_PATH\"" >> "$PROFILE_FILE"
    fi
    local path_encoded
    path_encoded=$(printf '%s' "$XHTTP_PATH" | jq -s -R -r @uri)
    local node_name="Xray-REALITY-${PROXY_DOMAIN}"
    local vless_link="vless://${uuid}@${PROXY_DOMAIN}:443?security=reality&sni=${PROXY_DOMAIN}&fp=chrome&pbk=${pbk}&sid=${sid}&type=xhttp&path=${path_encoded}&flow=${flow}#${node_name}"

    mkdir -p "$OUTPUT_DIR"
    echo "$vless_link" > "${OUTPUT_DIR}/vless.txt"
    
    if [ -f "$CLASH_TEMPLATE_FILE" ]; then
        local clash_content
        clash_content=$(sed -e "s/{{NODE_NAME_REALITY}}/${node_name}/g" \
            -e "s|{{DOMAIN}}|${PROXY_DOMAIN}|g" \
            -e "s|{{REALITY_UUID}}|${uuid}|g" \
            -e "s|{{REALITY_FLOW}}|${flow}|g" \
            -e "s|{{REALITY_SNI}}|${PROXY_DOMAIN}|g" \
            -e "s|{{REALITY_PBK}}|${pbk}|g" \
            -e "s|{{REALITY_SID}}|${sid}|g" \
            -e "s|{{REALITY_PATH}}|${XHTTP_PATH}|g" \
            "$CLASH_TEMPLATE_FILE")
        echo "$clash_content" > "${OUTPUT_DIR}/clash.yaml"
    fi

    # 生成 Nginx 订阅服务器配置
    local sub_config_file="${NGINX_SITES_DIR}/subscription.conf"
    log_message "正在生成 Nginx 订阅配置文件: $sub_config_file"
    cat > "$sub_config_file" << EOF
server {
    listen unix:/dev/shm/nginx.sock ssl http2;
    server_name $PROXY_DOMAIN;

    ssl_certificate /etc/nginx/ssl/$PROXY_DOMAIN/full.pem;
    ssl_certificate_key /etc/nginx/ssl/$PROXY_DOMAIN/key.pem;

    location /$SUBSCRIPTION_TOKEN/vless {
        alias /var/www/subs/vless.txt;
        default_type text/plain;
    }

    location /$SUBSCRIPTION_TOKEN/clash {
        alias /var/www/subs/clash.yaml;
        default_type application/x-yaml;
    }

    location / {
        return 404; # 根目录返回404以增加安全性
    }
}
EOF
    echo "--- 订阅信息 ---"
    echo "VLESS 订阅 URL: https://${PROXY_DOMAIN}/${SUBSCRIPTION_TOKEN}/vless"
    echo "Clash 订阅 URL: https://${PROXY_DOMAIN}/${SUBSCRIPTION_TOKEN}/clash"
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
                echo "VLESS 订阅 URL: https://${PROXY_DOMAIN}/${SUBSCRIPTION_TOKEN}/vless"
                echo "Clash 订阅 URL: https://${PROXY_DOMAIN}/${SUBSCRIPTION_TOKEN}/clash"
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
