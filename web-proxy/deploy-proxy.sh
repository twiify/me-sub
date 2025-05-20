#!/bin/bash

# deploy-proxy.sh - 交互式管理 Nginx 反向代理配置脚本

# --- 全局变量 ---
NGINX_CONFIG_DIR_ON_HOST="nginx/sites"           # Nginx 配置文件在宿主机上的相对路径
NGINX_SITES_DIR_IN_CONTAINER="/etc/nginx/conf.d" # Nginx 容器内站点配置目录

# Nginx 容器相关配置 (硬编码，用户可按需修改)
NGINX_CONTAINER_NAME="nginx"
NGINX_RELOAD_CMD="nginx -s reload"
NGINX_SSL_CERT_BASE_PATH_IN_CONTAINER="/etc/nginx/ssl"

TEMPLATE_FILE="proxy-template.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)" # Script's own directory

# --- 辅助函数 ---
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

check_dependencies() {
    if ! command -v sed &>/dev/null; then
        log_message "错误: sed 未安装。无法处理模板文件。"
        exit 1
    fi
}

# 函数：列出现有的反代配置文件
list_proxy_configs() {
    echo "当前已部署的反向代理站点:"
    local i=0
    # 使用 find 来查找 .conf 文件，排除空目录的情况
    find "$NGINX_CONFIG_DIR_ON_HOST" -maxdepth 1 -name "*.conf" -type f -print0 2>/dev/null | while IFS= read -r -d $'\0' file; do
        i=$((i + 1))
        echo " $i. $(basename "$file")"
    done
    if [ "$i" -eq 0 ]; then
        echo "  没有找到任何配置文件。"
        return 1
    fi
    return 0
}

# 函数：部署新的反代站点 (之前 main 函数的核心逻辑)
deploy_new_proxy_site() {
    echo "--- 部署新的 Nginx 反向代理站点 ---"
    log_message "将使用以下Nginx配置: Container Name='$NGINX_CONTAINER_NAME', Reload Command='$NGINX_RELOAD_CMD', SSL Cert Path='$NGINX_SSL_CERT_BASE_PATH_IN_CONTAINER'"

    read -p "请输入您的服务域名 (例如: app.example.com): " SERVER_NAME
    if [ -z "$SERVER_NAME" ]; then
        log_message "错误: 服务域名不能为空。"
        return
    fi

    # 检查配置文件是否已存在
    local output_config_file_on_host="$NGINX_CONFIG_DIR_ON_HOST/$SERVER_NAME.conf"
    if [ -f "$output_config_file_on_host" ]; then
        read -p "配置文件 $output_config_file_on_host 已存在。是否覆盖? (yes/no): " OVERWRITE_CHOICE
        if [[ "$OVERWRITE_CHOICE" != "yes" && "$OVERWRITE_CHOICE" != "y" ]]; then
            log_message "操作已取消。"
            return
        fi
    fi

    read -p "请输入上游服务器地址 (例如: http://localhost:3000 或 http://container_name:port): " UPSTREAM_ADDR
    if [ -z "$UPSTREAM_ADDR" ]; then
        log_message "错误: 上游服务器地址不能为空。"
        return
    fi

    read -p "是否启用 SSL? (yes/no, 默认 yes): " ENABLE_SSL_INPUT
    ENABLE_SSL=${ENABLE_SSL_INPUT:-yes}

    local current_template_file="$SCRIPT_DIR/$TEMPLATE_FILE"
    if [ ! -f "$current_template_file" ]; then
        log_message "错误: 代理模板文件 $current_template_file 未找到。"
        return
    fi
    template_content=$(cat "$current_template_file")
    local new_config_content=""

    if [[ "$ENABLE_SSL" == "yes" || "$ENABLE_SSL" == "y" ]]; then
        log_message "为 $SERVER_NAME 启用 SSL."
        new_config_content=$(
            echo "$template_content" |
                sed "s|server_name example.com;|server_name $SERVER_NAME;|g" |
                sed "s|ssl_certificate /etc/nginx/ssl/example.com/full.pem;|ssl_certificate $NGINX_SSL_CERT_BASE_PATH_IN_CONTAINER/$SERVER_NAME/full.pem;|g" |
                sed "s|ssl_certificate_key /etc/nginx/ssl/example.com/key.pem;|ssl_certificate_key $NGINX_SSL_CERT_BASE_PATH_IN_CONTAINER/$SERVER_NAME/key.pem;|g" |
                sed "s|set \$upstream_server http://example1.com:80;|set \$upstream_server $UPSTREAM_ADDR;|g"
        )
        log_message "请确保 $SERVER_NAME 的 SSL 证书已通过 autossl.sh 或其他方式签发并放置在 $NGINX_SSL_CERT_BASE_PATH_IN_CONTAINER/$SERVER_NAME/"
    else
        log_message "为 $SERVER_NAME 禁用 SSL. 将只生成 HTTP 配置。"
        new_config_content=$(
            cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAME;
    location / {
        resolver 127.0.0.11 valid=5s;
        set \$upstream_server $UPSTREAM_ADDR;
        proxy_pass \$upstream_server;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        client_body_timeout 300s;
        client_max_body_size 100m;
    }
}
EOF
        )
    fi

    if [ ! -d "$(dirname "$output_config_file_on_host")" ]; then
        log_message "创建目录: $(dirname "$output_config_file_on_host")"
        mkdir -p "$(dirname "$output_config_file_on_host")"
    fi

    echo "$new_config_content" >"$output_config_file_on_host"
    if [ $? -eq 0 ]; then
        log_message "新的 Nginx 配置文件已保存到: $output_config_file_on_host"
    else
        log_message "错误: 保存配置文件 $output_config_file_on_host 失败。"
        return
    fi

    read -p "是否立即重载 Nginx 配置 (在容器 $NGINX_CONTAINER_NAME 中)? (yes/no): " RELOAD_NGINX_CHOICE
    if [[ "$RELOAD_NGINX_CHOICE" == "yes" || "$RELOAD_NGINX_CHOICE" == "y" ]]; then
        log_message "正在重载 Nginx 配置..."
        docker exec "$NGINX_CONTAINER_NAME" $NGINX_RELOAD_CMD
        if [ $? -eq 0 ]; then
            log_message "Nginx 配置重载成功。"
        else
            log_message "错误: Nginx 配置重载失败。请检查 Nginx 日志 (docker logs $NGINX_CONTAINER_NAME) 和配置文件。"
        fi
    else
        log_message "Nginx 未重载。请稍后手动重载或重启 Nginx 容器以使更改生效。"
    fi
    echo "--- 部署完成 ---"
}

# 函数：删除已部署的反代站点
delete_proxy_site() {
    echo "--- 删除 Nginx 反向代理站点 ---"
    mapfile -t config_files < <(find "$NGINX_CONFIG_DIR_ON_HOST" -maxdepth 1 -name "*.conf" -type f 2>/dev/null | sort)

    if [ ${#config_files[@]} -eq 0 ]; then
        log_message "没有找到任何配置文件可以删除。"
        return
    fi

    echo "请选择要删除的配置文件:"
    for i in "${!config_files[@]}"; do
        echo " $((i + 1)). $(basename "${config_files[$i]}")"
    done
    read -p "请输入文件序号: " file_idx

    if [[ "$file_idx" =~ ^[0-9]+$ ]] && [ "$file_idx" -gt 0 ] && [ "$file_idx" -le "${#config_files[@]}" ]; then
        local file_to_delete="${config_files[$((file_idx - 1))]}"
        read -p "确定要删除配置文件 '$file_to_delete' 吗? (yes/no): " confirm_delete
        if [[ "$confirm_delete" == "yes" || "$confirm_delete" == "y" ]]; then
            rm -f "$file_to_delete"
            if [ $? -eq 0 ]; then
                log_message "配置文件 '$file_to_delete' 已删除。"
                read -p "是否立即重载 Nginx 配置? (yes/no): " RELOAD_AFTER_DELETE
                if [[ "$RELOAD_AFTER_DELETE" == "yes" || "$RELOAD_AFTER_DELETE" == "y" ]]; then
                    docker exec "$NGINX_CONTAINER_NAME" $NGINX_RELOAD_CMD
                    log_message "Nginx 配置已尝试重载。"
                fi
            else
                log_message "错误: 删除配置文件 '$file_to_delete' 失败。"
            fi
        else
            log_message "删除操作已取消。"
        fi
    else
        log_message "无效的文件序号。"
    fi
    echo "--- 删除操作完成 ---"
}

# 函数：查看反代站点详情
view_proxy_site_details() {
    echo "--- 查看 Nginx 反向代理站点详情 ---"
    mapfile -t config_files < <(find "$NGINX_CONFIG_DIR_ON_HOST" -maxdepth 1 -name "*.conf" -type f 2>/dev/null | sort)

    if [ ${#config_files[@]} -eq 0 ]; then
        log_message "没有找到任何配置文件可以查看。"
        return
    fi

    echo "请选择要查看详情的配置文件:"
    for i in "${!config_files[@]}"; do
        echo " $((i + 1)). $(basename "${config_files[$i]}")"
    done
    read -p "请输入文件序号: " file_idx

    if [[ "$file_idx" =~ ^[0-9]+$ ]] && [ "$file_idx" -gt 0 ] && [ "$file_idx" -le "${#config_files[@]}" ]; then
        local file_to_view="${config_files[$((file_idx - 1))]}"
        echo "--- 内容: $file_to_view ---"
        cat "$file_to_view"
        echo "--- 内容结束 ---"
    else
        log_message "无效的文件序号。"
    fi
    echo "--- 查看操作完成 ---"
}

# --- 主 TUI 菜单 ---
show_main_menu() {
    while true; do
        echo ""
        echo "=========================================="
        echo " Nginx 反向代理管理脚本"
        echo "=========================================="
        echo " 1. 部署新的反向代理站点"
        echo " 2. 查看已部署站点详情"
        echo " 3. 删除已部署站点"
        echo " 0. 退出"
        echo "------------------------------------------"
        read -p "请输入选项 [1-4]: " choice

        case $choice in
        1) deploy_new_proxy_site ;;
        2) view_proxy_site_details ;;
        3) delete_proxy_site ;;
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
main() {
    check_dependencies
    # 确保 NGINX_CONFIG_DIR_ON_HOST 存在，如果脚本在 web-proxy 目录外执行，这个相对路径可能需要调整
    # 或者在脚本开头让用户确认/输入项目根目录
    if [ ! -d "$NGINX_CONFIG_DIR_ON_HOST" ]; then
        log_message "警告: Nginx 配置目录 '$NGINX_CONFIG_DIR_ON_HOST' 不存在。将尝试创建。"
        mkdir -p "$NGINX_CONFIG_DIR_ON_HOST"
        if [ $? -ne 0 ]; then
            log_message "错误: 创建目录 '$NGINX_CONFIG_DIR_ON_HOST' 失败。请检查权限或路径。"
            exit 1
        fi
    fi
    show_main_menu
}

# 执行主函数
main
