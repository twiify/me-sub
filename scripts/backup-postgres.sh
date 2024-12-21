#!/bin/bash

# 配置
CONTAINER_NAME="postgres"  # docker-compose服务名
BACKUP_DIR="./backups"    # 备份目录
SAVENUM=4                 # 保留的备份数量

# 颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# 输出日志
log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 错误处理
error_exit() {
    log "${RED}错误: $1${NC}"
    exit 1
}

# 检查容器运行状态
docker-compose ps $CONTAINER_NAME | grep "Up" >/dev/null 2>&1 || error_exit "PostgreSQL容器未运行"

# 创建备份目录
mkdir -p $BACKUP_DIR || error_exit "无法创建备份目录"

# 生成备份文件名
BACKUP_FILE="$BACKUP_DIR/postgres_$(date +%Y%m%d_%H%M%S).sql.gz"

# 执行备份
log "开始备份数据库..."
docker-compose exec -T $CONTAINER_NAME pg_dumpall -U postgres | gzip > "$BACKUP_FILE"

# 检查备份是否成功
if [ $? -eq 0 ] && [ -f "$BACKUP_FILE" ]; then
    log "${GREEN}备份成功: $BACKUP_FILE${NC}"
else
    error_exit "备份失败"
fi

# 清理旧备份
log "清理旧备份文件..."
ls -t $BACKUP_DIR/postgres_*.sql.gz 2>/dev/null | awk -v n=$((SAVENUM + 1)) 'NR>=n' | xargs -r rm

# 显示当前备份列表
log "当前备份列表:"
ls -lh $BACKUP_DIR/postgres_*.sql.gz | awk '{print $9, "(" $5 ")"}'

log "${GREEN}备份任务完成${NC}"
