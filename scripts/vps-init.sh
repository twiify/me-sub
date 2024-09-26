#!/bin/bash

# 检查是否以root用户执行脚本
if [ "$(id -u)" -ne 0 ]; then
  echo "请使用root用户执行该脚本。"
  exit 1
fi

# 函数：创建新用户
create_user() {
  read -p "请输入新建用户名: " USERNAME
  if id "$USERNAME" &>/dev/null; then
    echo "用户 $USERNAME 已存在。"
  else
    read -s -p "请输入新建用户的密码: " PASSWORD
    echo
    useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd
    echo "用户 $USERNAME 已创建。"
  fi
}

# 函数：备份 SSH 配置文件
backup_ssh_config() {
  SSH_CONFIG="/etc/ssh/sshd_config"
  if [ -f "$SSH_CONFIG" ]; then
    cp "$SSH_CONFIG" "${SSH_CONFIG}.bak"
    echo "SSH 配置文件已备份至 ${SSH_CONFIG}.bak。"
  else
    echo "SSH 配置文件不存在，退出。"
    exit 1
  fi
}

# 函数：检查并替换 Match User 配置
modify_match_user() {
  SSH_CONFIG="/etc/ssh/sshd_config"
  
  # 查找并替换已有的 Match User 块
  if grep -q "^Match User" "$SSH_CONFIG"; then
    if grep -q "^Match User $USERNAME" "$SSH_CONFIG"; then
      echo "Match User $USERNAME 已存在，不做修改。"
    else
      # 替换已有的 Match User 块为新用户
      sed -i "/^Match User /,/^$/c\Match User $USERNAME\n    PasswordAuthentication yes" "$SSH_CONFIG"
      echo "已替换为新用户 $USERNAME 的 Match User 块。"
    fi
  else
    # 如果没有找到 Match User 块，则在文件末尾追加
    echo "Match User $USERNAME" >> "$SSH_CONFIG"
    echo "    PasswordAuthentication yes" >> "$SSH_CONFIG"
    echo "已为 $USERNAME 追加 Match User 块。"
  fi
}

# 函数：修改 SSH 配置
modify_ssh_config() {
  read -p "是否要修改 SSH 配置？(y/n): " MODIFY_SSH
  if [ "$MODIFY_SSH" == "y" ]; then
    backup_ssh_config

    SSH_CONFIG="/etc/ssh/sshd_config"

    # 确保禁用 root 用户的密码登录
    if grep -q "^PermitRootLogin" "$SSH_CONFIG"; then
      sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSH_CONFIG"
    else
      echo "PermitRootLogin prohibit-password" >> "$SSH_CONFIG"
    fi

    # 全局禁用密码登录（适用于所有用户）
    if grep -q "^PasswordAuthentication" "$SSH_CONFIG"; then
      sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    else
      echo "PasswordAuthentication no" >> "$SSH_CONFIG"
    fi

    # 启用公钥认证
    if grep -q "^PubkeyAuthentication" "$SSH_CONFIG"; then
      sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSH_CONFIG"
    else
      echo "PubkeyAuthentication yes" >> "$SSH_CONFIG"
    fi

    # 修改 SSH 登录端口
    read -p "请输入新的 SSH 端口 (默认22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    if grep -q "^Port" "$SSH_CONFIG"; then
      sed -i "s/^Port.*/Port $SSH_PORT/" "$SSH_CONFIG"
    else
      echo "Port $SSH_PORT" >> "$SSH_CONFIG"
    fi
    echo "SSH 配置已修改为禁用 root 密码登录，启用公钥认证，使用端口 $SSH_PORT。"

    # 调用函数处理 Match User 块
    modify_match_user

    # 测试 SSH 配置文件是否正确
    sshd -t
    if [ $? -eq 0 ]; then
      echo "SSH 配置正确，重启 SSH 服务..."
      systemctl restart ssh
    else
      echo "SSH 配置文件有误，恢复备份..."
      cp "${SSH_CONFIG}.bak" "$SSH_CONFIG"
      systemctl restart ssh
      echo "已恢复原 SSH 配置。"
    fi
  else
    echo "SSH 配置未做修改。"
  fi
}

# 函数：安装和配置 UFW
configure_ufw() {
  if ! command -v ufw &>/dev/null; then
    echo "UFW 未安装，正在安装..."
    apt update
    apt install -y ufw
    echo "UFW 已安装。"
  else
    echo "UFW 已存在，跳过安装步骤。"
  fi

  # 允许SSH访问
  ufw allow "$SSH_PORT"
  echo "已允许 SSH 端口 $SSH_PORT 访问。"

  # 允许用户指定的端口访问
  read -p "请输入要开放的端口（可选，多个端口用逗号分隔）: " ALLOWED_PORTS
  if [ -n "$ALLOWED_PORTS" ]; then
    # 去除前后空格并分割端口列表
    ALLOWED_PORTS=$(echo "$ALLOWED_PORTS" | sed 's/, */,/g' | sed 's/ *, */,/g')
    IFS=',' read -ra PORTS <<< "$ALLOWED_PORTS"
    for PORT in "${PORTS[@]}"; do
      ufw allow "$PORT"
      echo "已允许端口 $PORT 访问。"
    done
  fi

  # 启用 UFW 并设置开机自启
  ufw enable
  ufw status
  systemctl enable ufw
  echo "UFW 已启用，并设置为开机自启。"
}

# 函数：检查并安装 Docker
install_docker() {
  read -p "是否要安装 Docker？(y/n): " INSTALL_DOCKER
  if [ "$INSTALL_DOCKER" == "y" ]; then
    if ! command -v docker &>/dev/null; then
      echo "Docker 未安装，正在安装..."
      curl -fsSL https://get.docker.com | bash
      systemctl start docker
      systemctl enable docker
      echo "Docker 已安装并启动。"
    else
      echo "Docker 已安装，跳过安装步骤。"
    fi
  else
    echo "跳过 Docker 安装步骤。"
  fi
}

# 主流程
create_user
modify_ssh_config
configure_ufw
install_docker

echo "所有操作已完成。"
