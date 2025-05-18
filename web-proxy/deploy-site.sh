#!/bin/bash

# 脚本：快速部署反代网站
# 版本：1.0
# 功能：通过交互式提问，快速生成Nginx反向代理配置并协助申请SSL证书。

set -e # 遇到错误立即退出
set -u # 使用未声明变量时报错

# 全局变量
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly NGINX_SITES_DIR="$SCRIPT_DIR/nginx/sites"
readonly NGINX_SSL_DIR_HOST="$SCRIPT_DIR/nginx/ssl" # 主机上的SSL目录
readonly NGINX_SSL_DIR_CONTAINER="/etc/nginx/ssl"   # Nginx容器内的SSL目录
readonly PROXY_TEMPLATE_FILE="$SCRIPT_DIR/proxy-template.conf"
readonly AUTOSSL_SCRIPT="$SCRIPT_DIR/autossl.sh"
readonly DOCKER_COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
readonly NGINX_CONTAINER_NAME="nginx" # 从 docker-compose.yml 获取或硬编码

# 颜色输出
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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
    local prompt="$1"
    local answer
    while true; do
        echo -n -e "${YELLOW}${prompt} (y/n): ${NC}"
        read -r answer
        case "$answer" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        *) echo "请输入 y 或 n." ;;
        esac
    done
}

# 检查依赖
check_dependencies() {
    info "正在检查依赖..."
    command -v docker &>/dev/null || error_exit "未找到 docker 命令，请先安装 Docker。"
    command -v docker-compose &>/dev/null || error_exit "未找到 docker-compose 命令，请先安装 Docker Compose。"
    [[ -f "$PROXY_TEMPLATE_FILE" ]] || error_exit "代理模板文件 '$PROXY_TEMPLATE_FILE' 未找到。"
    [[ -f "$AUTOSSL_SCRIPT" ]] || warning "自动SSL脚本 '$AUTOSSL_SCRIPT' 未找到。SSL功能可能受限。"
    [[ -d "$NGINX_SITES_DIR" ]] || mkdir -p "$NGINX_SITES_DIR" || error_exit "无法创建Nginx站点配置目录 '$NGINX_SITES_DIR'。"
    # 检查 Nginx 和 acme.sh 容器是否正在运行
    if ! docker-compose -f "$DOCKER_COMPOSE_FILE" ps nginx | grep -q "Up"; then
        error_exit "Nginx 容器 (nginx) 未运行。请先启动: docker-compose -f \"$DOCKER_COMPOSE_FILE\" up -d nginx"
    fi
    if ! docker-compose -f "$DOCKER_COMPOSE_FILE" ps acme.sh | grep -q "Up"; then
        warning "acme.sh 容器 (acme.sh) 未运行。SSL证书自动申请和部署可能失败。"
    fi
    success "依赖检查通过。"
}

# 获取用户输入
get_user_input() {
    info "请输入新站点的配置信息："

    while true; do
        read -r -p "请输入您的域名 (例如: my.example.com): " DOMAIN_NAME
        if [[ -z "$DOMAIN_NAME" ]]; then
            warning "域名不能为空。"
        else
            # 简单验证域名格式
            if [[ "$DOMAIN_NAME" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                break
            else
                warning "域名格式不正确，请重新输入。"
            fi
        fi
    done

    while true; do
        read -r -p "请输入上游服务器地址 (例如: http://localhost:3000 或 http://container_name:port): " UPSTREAM_SERVER
        if [[ -z "$UPSTREAM_SERVER" ]]; then
            warning "上游服务器地址不能为空。"
        elif [[ "$UPSTREAM_SERVER" =~ ^https?://.+ ]]; then
            break
        else
            warning "上游服务器地址格式不正确，应以 http:// 或 https:// 开头。"
        fi
    done

    if [[ -f "$AUTOSSL_SCRIPT" ]] && docker-compose -f "$DOCKER_COMPOSE_FILE" ps acme.sh | grep -q "Up"; then
        if confirm "是否为此域名启用SSL (通过acme.sh申请证书)?"; then
            ENABLE_SSL=true
        else
            ENABLE_SSL=false
        fi
    else
        warning "无法启用SSL，因为acme.sh脚本或容器未准备好。"
        ENABLE_SSL=false
    fi
}

# 生成Nginx配置文件
generate_nginx_config() {
    info "正在生成Nginx配置文件..."
    local config_file_path="$NGINX_SITES_DIR/${DOMAIN_NAME}.conf"

    if [[ -f "$config_file_path" ]]; then
        if confirm "配置文件 '$config_file_path' 已存在，是否覆盖?"; then
            info "将覆盖现有配置文件。"
        else
            error_exit "操作已取消。未作任何更改。"
        fi
    fi

    # 复制模板并替换占位符
    sed -e "s|example.com|$DOMAIN_NAME|g" \
        -e "s|http://example1.com:80|$UPSTREAM_SERVER|g" \
        "$PROXY_TEMPLATE_FILE" >"$config_file_path.tmp"

    if [[ "$ENABLE_SSL" == true ]]; then
        # SSL 配置已在模板中，只需确保路径正确
        # 模板中的SSL路径已经是 /etc/nginx/ssl/example.com/full.pem
        # 我们需要确保这里的 example.com 被替换为 $DOMAIN_NAME
        # sed 命令中第一个 -e "s|example.com|$DOMAIN_NAME|g" 已经处理了 server_name
        # 现在需要确保ssl_certificate 和 ssl_certificate_key 中的路径也正确
        # proxy-template.conf 使用 /etc/nginx/ssl/example.com/full.pem
        # 替换后会变成 /etc/nginx/ssl/$DOMAIN_NAME/full.pem
        info "SSL已启用。配置文件将包含HTTPS设置。"
    else
        # 如果不启用SSL，我们需要移除或注释掉SSL相关的配置，并修改监听端口
        info "SSL未启用。将配置HTTP站点。"
        # 创建一个简化的HTTP配置
        cat <<EOF >"$config_file_path.tmp"
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME;

    location / {
        resolver 127.0.0.11 valid=10s; # Docker内置DNS
        set \$upstream_server $UPSTREAM_SERVER;
        proxy_pass \$upstream_server;

        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;

        proxy_read_timeout 600s;
        client_body_timeout 300s;
    }

    # 可选：访问日志和错误日志
    # access_log /var/log/nginx/${DOMAIN_NAME}.access.log;
    # error_log /var/log/nginx/${DOMAIN_NAME}.error.log;
}
EOF
    fi

    mv "$config_file_path.tmp" "$config_file_path"
    success "Nginx配置文件 '$config_file_path' 生成成功。"
}

# 申请和部署SSL证书
manage_ssl_certificate() {
    if [[ "$ENABLE_SSL" == true ]]; then
        info "准备为域名 '$DOMAIN_NAME' 申请/部署SSL证书..."
        local cert_exists=false

        # 检查证书是否存在 (使用 autossl.sh info)
        info "正在检查 '$DOMAIN_NAME' 证书状态..."
        if bash "$AUTOSSL_SCRIPT" info --domain "$DOMAIN_NAME" --non-interactive &>/dev/null; then
            info "域名 '$DOMAIN_NAME' 的证书已由acme.sh管理。"
            cert_exists=true
        else
            info "域名 '$DOMAIN_NAME' 的证书尚未被acme.sh管理或查询失败。"
            cert_exists=false
        fi

        if [[ "$cert_exists" == false ]]; then
            info "尝试为 '$DOMAIN_NAME' 申请新证书..."
            # Attempt to issue. This will use autossl.sh's saved DNS creds or fail if none are configured for the domain.
            # The --yes flag will auto-confirm prompts within autossl.sh if possible.
            if bash "$AUTOSSL_SCRIPT" issue --domain "$DOMAIN_NAME" --yes --non-interactive; then
                success "证书 '$DOMAIN_NAME' 申请成功 (或已存在并跳过)。"
                cert_exists=true # Mark as existing for deployment step
            else
                error_exit "证书 '$DOMAIN_NAME' 申请失败。请检查 '$AUTOSSL_SCRIPT' 的输出。您可能需要运行 'bash $AUTOSSL_SCRIPT' 以交互方式配置DNS提供商信息。"
            fi
        fi

        # 如果证书存在 (无论是之前就有还是刚刚申请的)，则尝试部署
        if [[ "$cert_exists" == true ]]; then
            if confirm "是否部署证书 '$DOMAIN_NAME' 到Nginx?"; then
                info "尝试部署证书 '$DOMAIN_NAME'..."
                # autossl.sh deploy will try to determine the label automatically or use 'nginx'
                if bash "$AUTOSSL_SCRIPT" deploy --domain "$DOMAIN_NAME" --yes --non-interactive; then
                    success "证书 '$DOMAIN_NAME' 部署请求已发送。Nginx应该会自动重载。"
                else
                    error_exit "证书 '$DOMAIN_NAME' 部署失败。请检查 '$AUTOSSL_SCRIPT' 的输出。"
                fi
            else
                warning "证书 '$DOMAIN_NAME' 未部署。您可能需要手动运行 'bash $AUTOSSL_SCRIPT' deploy --domain $DOMAIN_NAME"
            fi
        else
            # This case should ideally not be reached if issuance failed and exited.
            warning "证书 '$DOMAIN_NAME' 不存在，无法部署。"
        fi
    fi
}

# 重载Nginx配置
reload_nginx() {
    info "准备重载Nginx配置..."
    if confirm "是否立即重载Nginx以应用更改?"; then
        info "正在测试Nginx配置..."
        if docker-compose -f "$DOCKER_COMPOSE_FILE" exec "$NGINX_CONTAINER_NAME" nginx -t; then
            success "Nginx配置测试通过。"
            info "正在重载Nginx..."
            if docker-compose -f "$DOCKER_COMPOSE_FILE" exec "$NGINX_CONTAINER_NAME" nginx -s reload; then
                success "Nginx重载成功！您的站点 '$DOMAIN_NAME'应该已生效。"
            else
                error_exit "Nginx重载失败。请检查Nginx容器日志。"
            fi
        else
            error_exit "Nginx配置测试失败。请检查 '$NGINX_SITES_DIR/${DOMAIN_NAME}.conf' 以及Nginx的错误日志。"
        fi
    else
        warning "Nginx未重载。您需要手动重载Nginx以使更改生效: docker-compose -f \"$DOCKER_COMPOSE_FILE\" exec $NGINX_CONTAINER_NAME nginx -s reload"
    fi
}

# 主函数
main() {
    clear
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}  Nginx 反向代理网站快速部署脚本 ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo

    check_dependencies
    echo

    get_user_input
    echo

    generate_nginx_config
    echo

    manage_ssl_certificate
    echo

    reload_nginx
    echo

    success "部署流程完成！"
    if [[ "$ENABLE_SSL" == true ]]; then
        echo -e "${BLUE}请确保SSL证书已正确申请并部署。如果遇到问题，请使用 '$AUTOSSL_SCRIPT' 进行检查和操作。${NC}"
        echo -e "${BLUE}您的站点应该可以通过 https://$DOMAIN_NAME 访问。${NC}"
    else
        echo -e "${BLUE}您的站点应该可以通过 http://$DOMAIN_NAME 访问。${NC}"
    fi
}

# 执行主函数
main
