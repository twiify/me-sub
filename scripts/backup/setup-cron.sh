#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/backup.json"
BACKUP_MARKER="# MANAGED-BY-BACKUP-SYSTEM"

# 检查配置文件
if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 配置文件不存在 ($CONFIG_FILE)"
    exit 1
fi

# 创建临时文件
TEMP_CRON=$(mktemp)
trap 'rm -f "$TEMP_CRON"' EXIT

# 获取当前crontab内容，排除旧的备份任务
crontab -l 2>/dev/null | grep -v "$BACKUP_MARKER" > "$TEMP_CRON"

# 添加新的备份任务
while read -r line; do
    cron=$(echo "$line" | jq -r '.cron')
    name=$(echo "$line" | jq -r '.name')
    echo "$cron $SCRIPT_DIR/backup.sh \"$name\" $BACKUP_MARKER" >> "$TEMP_CRON"
done < <(jq -c '.[]' "$CONFIG_FILE")

# 安装新的crontab
crontab "$TEMP_CRON"

# 验证crontab是否成功更新
if [ $? -eq 0 ]; then
    echo "Cron任务已成功更新。"
    echo "当前备份任务的Cron设置:"
    crontab -l | grep "$BACKUP_MARKER"
else
    echo "错误: 更新Cron任务失败。"
    exit 1
fi
