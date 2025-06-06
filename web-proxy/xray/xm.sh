#!/bin/bash

# =================================================================
# Xray Interactive Management Script
# Author: AI Assistant for Network Engineers
# Version: 2.0
#
# Manages Xray configs, subscriptions, and Nginx blocks.
# Features: Initial setup, config modification, service reloads.
# =================================================================

# --- Color Definitions ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

# --- Script Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROFILE_FILE="${SCRIPT_DIR}/.xray_manager_profile"
OUTPUTDIR_NAME="xray_generated_configs"
OUTPUT_DIR="${SCRIPT_DIR}/${OUTPUTDIR_NAME}"
CONFIG_FILE="${SCRIPT_DIR}/xray_config.json"

# --- Helper Functions ---
print_success() { echo -e "${C_GREEN}$1${C_RESET}"; }
print_error() { echo -e "${C_RED}$1${C_RESET}"; }
print_warning() { echo -e "${C_YELLOW}$1${C_RESET}"; }
print_info() { echo -e "${C_CYAN}$1${C_RESET}"; }

# 检查依赖
check_deps() {
  if ! command -v jq &>/dev/null; then
    print_error "错误: 'jq' 没有安装, 请安装后再运行脚本"
    echo "Debian/Ubuntu: sudo apt install jq"
    echo "CentOS/RHEL:   sudo yum install jq"
    exit 1
  fi

  if ! command -v openssl &>/dev/null; then
    print_error "错误: 'openssl' 没有安装, 请安装后再运行脚本"
    echo "Debian/Ubuntu: sudo apt install openssl"
    echo "CentOS/RHEL:   sudo yum install openssl"
    exit 1
  fi
}

# 检查是否有root权限
check_root() {
  if [ "$EUID" -ne 0 ]; then
    print_warning "警告: 非 root 用户运行"
    return 1
  fi
  return 0
}

# --- Core Logic Functions ---
# 加载配置文件
load_profile() {
  if [ -f "$PROFILE_FILE" ]; then
    source "$PROFILE_FILE"
    return 0
  else
    return 1
  fi
}

# 保存配置
save_profile() {
  echo "DOMAIN=\"$DOMAIN\"" >"$PROFILE_FILE"
  echo "SUBSCRIPTION_TOKEN=\"$SUBSCRIPTION_TOKEN\"" >>"$PROFILE_FILE"
  echo "FUCK_SITE=\"$FUCK_SITE\"" >>"${PROFILE_FILE}"
  print_success "配置文件已保存 -> '$PROFILE_FILE'"
}

# 函数：使用 openssl 或 xray 生成密钥对
generate_x25519_keys() {
  if command -v openssl &>/dev/null; then
    print_info "使用 OpenSSL 生成密钥对..."
    local private_key_pem
    private_key_pem=$(openssl genpkey -algorithm x25519 2>/dev/null)
    if [ -z "$private_key_pem" ]; then
      print_error "OpenSSL 生成密钥失败，请检查 openssl 版本或环境。"
      return 1
    fi
    NEW_PRIVATE_KEY=$(echo "$private_key_pem" | openssl pkey -outform DER 2>/dev/null | tail -c 32 | base64 | tr '/+' '_-' | tr -d '=')
    NEW_PUBLIC_KEY=$(echo "$private_key_pem" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr '/+' '_-' | tr -d '=')
  elif command -v xray &>/dev/null; then
    print_info "使用 xray 生成密钥对..."
    local KEY_PAIR
    KEY_PAIR=$(xray x25519)
    NEW_PRIVATE_KEY=$(echo "$KEY_PAIR" | grep 'Private key' | awk '{print $3}')
    NEW_PUBLIC_KEY=$(echo "$KEY_PAIR" | grep 'Public key' | awk '{print $3}')
  else
    print_error "无法生成密钥对，请安装 openssl 或 xray。"
    return 1
  fi

  if [ -z "$NEW_PRIVATE_KEY" ] || [ -z "$NEW_PUBLIC_KEY" ]; then
    print_error "生成密钥对失败，未获取到密钥值。"
    return 1
  fi
  return 0
}

initial_setup() {
  print_info "--- 初始化配置 ---"
  if [ ! -f "$CONFIG_FILE" ]; then
    print_error "错误: 文件不存在 -> '$CONFIG_FILE'"
    return 1
  fi

  read -p "$(echo -e ${C_YELLOW}'请输入你公开访问的域名(例如: example.com): '${C_RESET})" DOMAIN
  if [ -z "$DOMAIN" ]; then
    print_error "错误: 域名不能为空"
    return 1
  fi

  read -p "$(echo -e ${C_YELLOW}'请输入nginx反代的伪装站点(例如: https://google.com): '${C_RESET})" FUCK_SITE
  if [ -z "${FUCK_SITE}" ]; then
    print_error "错误: 伪装站点不能为空"
    return 1
  fi

  SUBSCRIPTION_TOKEN=$(cat /proc/sys/kernel/random/uuid)
  echo -e "${C_YELLOW}随机订阅路径已生成: ${C_BLUE}${SUBSCRIPTION_TOKEN}${C_RESET}"

  save_profile

  # 2. 生成所有随机凭据
  print_info "正在生成全新的随机凭据..."
  NEW_REALITY_UUID=$(openssl rand -hex 16) # 使用 openssl 生成更兼容的 UUID
  NEW_REALITY_PATH="/$(openssl rand -hex 8)"
  NEW_NGINX_UUID=$(openssl rand -hex 16)
  NEW_NGINX_PATH="/$(openssl rand -hex 12)"
  if ! generate_x25519_keys; then return 1; fi
  NEW_SHORT_ID_1=$(openssl rand -hex 8)

  print_info "正在创建并写入新的 '$CONFIG_FILE' ..."
  jq \
    --arg domain "${DOMAIN}" \
    --argjson servernames "[\"$DOMAIN\"]" \
    --arg ruuid "$NEW_REALITY_UUID" --arg rpath "$NEW_REALITY_PATH" \
    --arg nuuid "$NEW_NGINX_UUID" --arg npath "$NEW_NGINX_PATH" \
    --arg pvk "$NEW_PRIVATE_KEY" --arg pbk "$NEW_PUBLIC_KEY" \
    --argjson sids "[\"$NEW_SHORT_ID_1\"]" \
    '
        (.inbounds[] | select(.streamSettings.security == "reality") .settings.clients[0].id) = $ruuid |
        (.inbounds[] | select(.streamSettings.security == "reality") .streamSettings.xhttpSettings.path) = $rpath |
        (.inbounds[] | select(.streamSettings.security == "reality") .streamSettings.realitySettings.serverNames) = $servernames |
        (.inbounds[] | select(.streamSettings.security == "reality") .streamSettings.realitySettings.privateKey) = $pvk |
        (.inbounds[] | select(.streamSettings.security == "reality") .streamSettings.realitySettings.publicKey) = $pbk |
        (.inbounds[] | select(.streamSettings.security == "reality") .streamSettings.realitySettings.shortId) = $sids |
        (.inbounds[] | select(.streamSettings.security == "none" and .streamSettings.network == "xhttp") .settings.clients[0].id) = $nuuid |
        (.inbounds[] | select(.streamSettings.security == "none" and .streamSettings.network == "xhttp") .streamSettings.xhttpSettings.path) = $npath
        ' \
    "$CONFIG_FILE" >"${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

  if [ $? -eq 0 ]; then
    print_success "全新的 '$CONFIG_FILE' 已成功创建！"
    # 4. 生成订阅和 Nginx 配置
    parse_and_generate
  else
    rm "${CONFIG_FILE}.tmp"
    print_error "创建 '$CONFIG_FILE' 失败。"
    return 1
  fi
}

parse_and_generate() {
  print_info "解析xray配置文件并生成订阅 ..."

  # REALITY Inbound (identified by security: "reality")
  REALITY_INBOUND=$(jq '.inbounds[] | select(.streamSettings.security == "reality")' "$CONFIG_FILE")
  # Nginx-proxied Inbound (identified by listen: "127.0.0.1" and network: "xhttp")
  NGINX_INBOUND=$(jq '.inbounds[] | select(.streamSettings.security == "none" and .streamSettings.network == "xhttp")' "$CONFIG_FILE")

  if [ -z "$REALITY_INBOUND" ] || [ -z "$NGINX_INBOUND" ]; then
    print_error "Error: Could not find one or both required inbounds in the config file."
    return 1
  fi

  # Extract REALITY parameters
  REALITY_PORT=$(echo "$REALITY_INBOUND" | jq -r '.port')
  REALITY_UUID=$(echo "$REALITY_INBOUND" | jq -r '.settings.clients[0].id')
  REALITY_FLOW=$(echo "$REALITY_INBOUND" | jq -r '.settings.clients[0].flow')
  REALITY_PATH=$(echo "$REALITY_INBOUND" | jq -r '.streamSettings.xhttpSettings.path')
  REALITY_PBK=$(echo "$REALITY_INBOUND" | jq -r '.streamSettings.realitySettings.publicKey')
  REALITY_SID=$(echo "$REALITY_INBOUND" | jq -r '.streamSettings.realitySettings.shortId[0]')
  REALITY_SNI=$(echo "$REALITY_INBOUND" | jq -r '.streamSettings.realitySettings.serverNames[0]')

  # Extract Nginx-proxied parameters
  NGINX_LOCAL_PORT=$(echo "$NGINX_INBOUND" | jq -r '.port')
  NGINX_UUID=$(echo "$NGINX_INBOUND" | jq -r '.settings.clients[0].id')
  NGINX_PATH=$(echo "$NGINX_INBOUND" | jq -r '.streamSettings.xhttpSettings.path')

  # URL-encode paths
  REALITY_PATH_ENCODED=$(printf '%s' "$REALITY_PATH" | jq -s -R -r @uri)
  NGINX_PATH_ENCODED=$(printf '%s' "$NGINX_PATH" | jq -s -R -r @uri)

  NODE_NAME_REALITY="REALITY-XHTTP-${DOMAIN}"
  NODE_NAME_NGINX="Nginx-XHTTP-${DOMAIN}"

  VLESS_REALITY_LINK="vless://${REALITY_UUID}@${DOMAIN}:${REALITY_PORT}?security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PBK}&sid=${REALITY_SID}&type=xhttp&path=${REALITY_PATH_ENCODED}&flow=${REALITY_FLOW}#${NODE_NAME_REALITY}"
  VLESS_NGINX_LINK="vless://${NGINX_UUID}@${DOMAIN}:443?security=tls&sni=${DOMAIN}&alpn=h2&type=xhttp&path=${NGINX_PATH_ENCODED}#${NODE_NAME_NGINX}"

  mkdir -p "$OUTPUT_DIR"

  # Create VLESS subscription
  echo -e "${VLESS_REALITY_LINK}\n${VLESS_NGINX_LINK}" >"${OUTPUT_DIR}/links.tmp"
  SUB_BASE64=$(base64 -w 0 "${OUTPUT_DIR}/links.tmp")
  echo "$SUB_BASE64" >"${OUTPUT_DIR}/vless_sub.txt"
  rm "${OUTPUT_DIR}/links.tmp"

  # Fill in the templates
  # Clash
  sed -e "s|{{NODE_NAME_REALITY}}|${NODE_NAME_REALITY}|g" \
    -e "s|{{DOMAIN}}|${DOMAIN}|g" \
    -e "s|{{REALITY_PORT}}|${REALITY_PORT}|g" \
    -e "s|{{REALITY_UUID}}|${REALITY_UUID}|g" \
    -e "s|{{REALITY_FLOW}}|${REALITY_FLOW}|g" \
    -e "s|{{REALITY_SNI}}|${REALITY_SNI}|g" \
    -e "s|{{REALITY_PBK}}|${REALITY_PBK}|g" \
    -e "s|{{REALITY_SID}}|${REALITY_SID}|g" \
    -e "s|{{REALITY_PATH}}|${REALITY_PATH}|g" \
    -e "s|{{NODE_NAME_NGINX}}|${NODE_NAME_NGINX}|g" \
    -e "s|{{NGINX_UUID}}|${NGINX_UUID}|g" \
    -e "s|{{NGINX_PATH}}|${NGINX_PATH}|g" \
    clash_template.yaml >"${OUTPUT_DIR}/clash_config.yaml"

  # Nginx
  sed -e "s|{{DOMAIN}}|${DOMAIN}|g" \
    -e "s|{{NGINX_PATH}}|${NGINX_PATH}|g" \
    -e "s|{{NGINX_LOCAL_PORT}}|${NGINX_LOCAL_PORT}|g" \
    -e "s|{{SUBSCRIPTION_TOKEN}}|${SUBSCRIPTION_TOKEN}|g" \
    -e "s|{{FUCK_SITE}}|${FUCK_SITE}|g" \
    -e "s|{{OUTPUT_DIR}}|/etc/xray/${OUTPUTDIR_NAME}|g" \
    nginx_template.conf >"${OUTPUT_DIR}/xray_nginx.conf"

  print_success "所有配置文件已生成"
  view_configs
}

# 函数：生成并更新 REALITY 密钥对和 shortId
generate_reality_keys() {
  print_info "--- 正在生成新的 REALITY 密钥对和 ShortID ---"

  if ! generate_x25519_keys; then
    return 1
  fi

  print_success "新的 Private Key: $NEW_PRIVATE_KEY"
  print_success "新的 Public Key:  $NEW_PUBLIC_KEY"

  NEW_SHORT_ID_1=$(openssl rand -hex 8)
  NEW_SHORT_ID_2=$(openssl rand -hex 4)
  print_success "新的 ShortIDs: [\"$NEW_SHORT_ID_1\", \"$NEW_SHORT_ID_2\"]"

  print_info "正在更新 '$CONFIG_FILE' ..."

  cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%s)"
  print_info "配置文件已备份: $CONFIG_FILE.bak.*"

  TEMP_FILE=$(mktemp)
  jq \
    --arg pvk "$NEW_PRIVATE_KEY" \
    --arg pbk "$NEW_PUBLIC_KEY" \
    --argjson sids "[\"$NEW_SHORT_ID_1\", \"$NEW_SHORT_ID_2\"]" \
    '
        (.inbounds[] | select(.streamSettings.security == "reality") .streamSettings.realitySettings.privateKey) = $pvk |
        (.inbounds[] | select(.streamSettings.security == "reality") .streamSettings.realitySettings.publicKey) = $pbk |
        (.inbounds[] | select(.streamSettings.security == "reality") .streamSettings.realitySettings.shortId) = $sids
        ' \
    "$CONFIG_FILE" >"$TEMP_FILE" && mv "$TEMP_FILE" "$CONFIG_FILE"

  if [ $? -eq 0 ]; then
    print_success "Xray 配置文件更新成功！"
    return 0
  else
    print_error "更新 Xray 配置文件失败。"
    return 1
  fi
}

modify_and_regenerate() {
  if ! load_profile; then
    print_error "脚本配置文件不存在, 请先运行初始化配置"
    return
  fi

  while true; do
    echo ""
    print_info "--- 修改和重新生成配置 ---"
    echo "1) 重新生成所有 UUIDs 和 Paths"
    echo "2) 重新生成订阅 Token"
    echo "3) 重新生成 Reality 密钥对和 ShortIDs"
    echo "0) 返回主菜单"
    read -p "选择 [0-2]: " mod_choice

    case $mod_choice in
    1)
      print_warning "这会修改所有 UUID 和 Paths -> '$CONFIG_FILE'."
      read -p "确认执行吗? (y/n): " confirm
      if [[ "$confirm" =~ ^[yY]$ ]]; then
        # Generate new values
        NEW_REALITY_UUID=$(cat /proc/sys/kernel/random/uuid)
        NEW_REALITY_PATH="/$(openssl rand -hex 8)"
        NEW_NGINX_UUID=$(cat /proc/sys/kernel/random/uuid)
        NEW_NGINX_PATH="/$(openssl rand -hex 12)"

        # Backup original file
        cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%s)"
        print_info "配置文件已备份: $CONFIG_FILE.bak.*"

        # Update JSON file using jq
        TEMP_FILE=$(mktemp)
        jq \
          --arg ruuid "$NEW_REALITY_UUID" \
          --arg rpath "$NEW_REALITY_PATH" \
          --arg nuuid "$NEW_NGINX_UUID" \
          --arg npath "$NEW_NGINX_PATH" \
          '
                        (.inbounds[] | select(.streamSettings.security == "reality") .settings.clients[0].id) = $ruuid |
                        (.inbounds[] | select(.streamSettings.security == "reality") .streamSettings.xhttpSettings.path) = $rpath |
                        (.inbounds[] | select(.listen == "127.0.0.1") .settings.clients[0].id) = $nuuid |
                        (.inbounds[] | select(.listen == "127.0.0.1") .streamSettings.xhttpSettings.path) = $npath
                        ' \
          "$CONFIG_FILE" >"$TEMP_FILE" && mv "$TEMP_FILE" "$CONFIG_FILE"

        if [ $? -eq 0 ]; then
          print_success "Xray 配置文件已成功修改, 请手动重启 Xray 服务"
          parse_and_generate
        else
          print_error "更新 Xray 配置文件错误"
        fi
      fi
      ;;
    2)
      SUBSCRIPTION_TOKEN=$(cat /proc/sys/kernel/random/uuid)
      print_info "重新生成订阅 Token"
      save_profile
      parse_and_generate
      ;;
    3)
      print_warning "这将替换 REALITY 的密钥对和 ShortIDs -> '$CONFIG_FILE'."
      read -p "确认执行吗? (y/n): " confirm
      if [[ "$confirm" =~ ^[yY]$ ]]; then
        if generate_reality_keys; then
          parse_and_generate
        fi
      fi
      ;;
    0)
      break
      ;;
    *)
      print_error "错误选项"
      ;;
    esac
  done
}

view_configs() {
  if ! load_profile; then
    print_error "脚本配置文件不存在, 请先运行初始化配置"
    return
  fi

  echo ""
  print_info "--- 当前配置 ---"
  echo -e "Clash 订阅 URL: ${C_GREEN}https://"$DOMAIN"/${SUBSCRIPTION_TOKEN}/clash${C_RESET}"
  echo -e "vless 订阅 URL: ${C_GREEN}https://"$DOMAIN"/${SUBSCRIPTION_TOKEN}/vless${C_RESET}"
  echo ""
  print_info "Nginx 配置块(${OUTPUT_DIR}/xray_nginx.conf):"
  echo -e "${C_BLUE}--------------------------------------------------${C_RESET}"
  cat "${OUTPUT_DIR}/xray_nginx.conf"
  echo -e "${C_BLUE}--------------------------------------------------${C_RESET}"
  echo ""
  print_info "Clash 配置预览 (${OUTPUT_DIR}/clash_config.yaml):"
  echo -e "${C_BLUE}--------------------------------------------------${C_RESET}"
  head -n 30 "${OUTPUT_DIR}/clash_config.yaml"
  echo "..."
  echo -e "${C_BLUE}--------------------------------------------------${C_RESET}"
}

# --- Main Menu Loop ---
main() {
  check_deps
  while true; do
    echo ""
    print_info "============================================="
    print_info "         Xray Interactive Manager"
    print_info "============================================="
    echo "1. 初始化配置"
    echo "2. 重新生成所有订阅和Nginx配置"
    echo "3. 修改 Xray 配置并重新生成订阅"
    echo "4. 查看当前订阅和配置"
    echo "0. 退出"
    echo "---------------------------------------------"
    read -p "选择 [0-4]: " choice

    case $choice in
    1)
      initial_setup
      ;;
    2)
      if load_profile; then
        parse_and_generate
      else
        print_error "脚本配置文件不存在, 请先运行初始化配置"
      fi
      ;;
    3)
      modify_and_regenerate
      ;;
    4)
      view_configs
      ;;
    0)
      echo "退出"
      exit 0
      ;;
    *)
      print_error "错误选项, 请重新输入"
      ;;
    esac

    echo ""
    read -n 1 -s -r -p "输入任意键返回菜单"
    clear
  done
}

# --- Script Entry Point ---
main
