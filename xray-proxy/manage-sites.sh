#!/bin/bash

# manage-sites.sh - 为 Xray 前置架构管理 Nginx 反向代理站点的脚本

# --- 全局变量 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SITES_CONFIG_DIR="${SCRIPT_DIR}/nginx/sites"
XRAY_CONFIG_FILE="${SCRIPT_DIR}/xray/xray_config.json"
NGINX_CONTAINER_NAME="nginx"
XRAY_CONTAINER_NAME="xray"
NGINX_RELOAD_CMD="nginx -s reload"

# --- 辅助函数 ---
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

check_dependencies() {
    if ! command -v jq &>/dev/null; then
        log_message "错误: jq 未安装。请先安装 jq。"
        exit 1
    fi
}

reload_services() {
    read -p "是否立即重载 Nginx 和 Xray 服务? (yes/no): " RELOAD_CHOICE
    if [[ "$RELOAD_CHOICE" != "yes" && "$RELOAD_CHOICE" != "y" ]]; then
        log_message "操作已取消。请稍后手动重载服务以使更改生效。"
        return
    fi

    log_message "正在重载 Nginx..."
    cd $SCRIPT_DIR && docker compose exec "$NGINX_CONTAINER_NAME" $NGINX_RELOAD_CMD
    if [ $? -eq 0 ]; then
        log_message "Nginx 重载成功。"
    else
        log_message "错误: Nginx 重载失败。请检查日志。"
    fi

    log_message "正在重载 Xray..."
    cd $SCRIPT_DIR && docker compose restart "$XRAY_CONTAINER_NAME"
    if [ $? -eq 0 ]; then
        log_message "Xray 重载成功。"
    else
        log_message "错误: Xray 重载失败。请检查日志。"
    fi
}

# --- 核心功能 ---

# 函数：添加新站点
add_site() {
    echo "--- 添加新的反向代理站点 ---"
    read -p "请输入您的服务域名 (例如: app.example.com): " SERVER_NAME
    if [ -z "$SERVER_NAME" ]; then
        log_message "错误: 服务域名不能为空。"
        return
    fi

    local site_config_file="$SITES_CONFIG_DIR/$SERVER_NAME.conf"
    if [ -f "$site_config_file" ]; then
        read -p "配置文件 $site_config_file 已存在。是否覆盖? (yes/no): " OVERWRITE_CHOICE
        if [[ "$OVERWRITE_CHOICE" != "yes" && "$OVERWRITE_CHOICE" != "y" ]]; then
            log_message "操作已取消。"
            return
        fi
    fi

    read -p "请输入上游服务地址 (例如: http://container_name:port): " UPSTREAM_ADDR
    if [ -z "$UPSTREAM_ADDR" ]; then
        log_message "错误: 上游服务地址不能为空。"
        return
    fi

    log_message "正在为 $SERVER_NAME 生成 Nginx 配置文件..."
    # 创建 Nginx 配置文件
    cat > "$site_config_file" << EOF
server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;
    server_name $SERVER_NAME;

    ssl_certificate /etc/nginx/ssl/$SERVER_NAME/full.pem;
    ssl_certificate_key /etc/nginx/ssl/$SERVER_NAME/key.pem;

    access_log /var/log/nginx/$SERVER_NAME.access.log;
    error_log /var/log/nginx/$SERVER_NAME.error.log;

    location / {
        resolver 127.0.0.11 valid=5s;
        set \$upstream_service $UPSTREAM_ADDR;
        proxy_pass \$upstream_service;

        proxy_set_header Host \$host;

        set \$client_ip \$proxy_protocol_addr;
        if (\$client_ip = "") {
            set \$client_ip \$remote_addr;
        }
        proxy_set_header X-Real-IP \$client_ip;
        proxy_set_header X-Forwarded-For \$client_ip;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
    log_message "Nginx 配置文件已创建: $site_config_file"
    log_message "请确保 $SERVER_NAME 的 SSL 证书已通过 autossl.sh 签发。"

    log_message "正在将 $SERVER_NAME 添加到 Xray 配置中..."
    # 使用 jq 将新域名添加到 serverNames 数组
    local temp_xray_config=$(mktemp)
    jq "(.inbounds[0].streamSettings.realitySettings.serverNames += [\"$SERVER_NAME\"]) | .inbounds[0].streamSettings.realitySettings.serverNames |= unique" "$XRAY_CONFIG_FILE" > "$temp_xray_config"
    
    if [ $? -eq 0 ]; then
        mv "$temp_xray_config" "$XRAY_CONFIG_FILE"
        log_message "Xray 配置文件更新成功。"
        reload_services
    else
        log_message "错误: 更新 Xray 配置文件失败。"
        rm "$temp_xray_config"
    fi
}

# 函数：删除站点
delete_site() {
    echo "--- 删除反向代理站点 ---"
    mapfile -t config_files < <(find "$SITES_CONFIG_DIR" -maxdepth 1 -name "*.conf" -type f 2>/dev/null | sort)

    if [ ${#config_files[@]} -eq 0 ]; then
        log_message "没有找到任何站点配置文件可以删除。"
        return
    fi

    echo "请选择要删除的站点配置文件:"
    for i in "${!config_files[@]}"; do
        echo " $((i + 1)). $(basename "${config_files[$i]}")"
    done
    read -p "请输入文件序号: " file_idx

    if ! [[ "$file_idx" =~ ^[0-9]+$ ]] || [ "$file_idx" -le 0 ] || [ "$file_idx" -gt "${#config_files[@]}" ]; then
        log_message "无效的文件序号。"
        return
    fi

    local file_to_delete="${config_files[$((file_idx - 1))]}"
    local domain_to_delete=$(basename "$file_to_delete" .conf)

    read -p "确定要删除站点 '$domain_to_delete' 吗? (yes/no): " confirm_delete
    if [[ "$confirm_delete" != "yes" && "$confirm_delete" != "y" ]]; then
        log_message "删除操作已取消。"
        return
    fi

    # 从 Xray 配置中移除域名
    log_message "正在从 Xray 配置中移除 $domain_to_delete..."
    local temp_xray_config=$(mktemp)
    jq "(.inbounds[0].streamSettings.realitySettings.serverNames) |= map(select(. != \"$domain_to_delete\"))" "$XRAY_CONFIG_FILE" > "$temp_xray_config"

    if [ $? -ne 0 ]; then
        log_message "错误: 更新 Xray 配置文件失败。"
        rm "$temp_xray_config"
        return
    fi
    mv "$temp_xray_config" "$XRAY_CONFIG_FILE"
    log_message "Xray 配置更新成功。"

    # 删除 Nginx 配置文件
    rm -f "$file_to_delete"
    if [ $? -eq 0 ]; then
        log_message "Nginx 配置文件 '$file_to_delete' 已删除。"
        reload_services
    else
        log_message "错误: 删除 Nginx 配置文件 '$file_to_delete' 失败。"
    fi
}

# 函数：查看站点列表
list_sites() {
    echo "--- 当前已部署的站点 ---"
    local i=0
    find "$SITES_CONFIG_DIR" -maxdepth 1 -name "*.conf" -type f -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        i=$((i + 1))
        local domain=$(basename "$file" .conf)
        local upstream=$(grep -oP 'upstream_service\s+\K\S+;' "$file" | sed 's/;//')
        echo " $i. $domain -> $upstream"
    done
    if [ "$i" == "0" ]; then
        echo "  没有找到任何站点。"
    fi
    echo "------------------------"
}


# --- 主菜单 ---
show_main_menu() {
    while true; do
        echo ""
        echo "=========================================="
        echo " Nginx 站点管理脚本 (for Xray-Fronted)"
        echo "=========================================="
        echo " 1. 添加新的站点"
        echo " 2. 删除已部署站点"
        echo " 3. 查看已部署站点列表"
        echo " 0. 退出"
        echo "------------------------------------------"
        read -p "请输入选项 [0-3]: " choice

        case $choice in
        1) add_site ;;
        2) delete_site ;;
        3) list_sites ;;
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
