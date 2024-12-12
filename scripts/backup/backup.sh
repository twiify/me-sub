#!/bin/bash

# 设置基础变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/backup.json"
LOG_DIR="$SCRIPT_DIR/logs"
TEMP_DIR="/tmp/backup-system"
DATE=$(date +%Y%m%d)

# 确保日志目录存在
mkdir -p "$LOG_DIR"
mkdir -p "$TEMP_DIR"

# 显示帮助信息
show_help() {
    cat << EOF
Usage: $(basename $0) [OPTIONS] [TASK_NAME]

Options:
    -h, --help          显示帮助信息
    -l, --list          列出所有可用的备份任务
    -s, --status        显示上次备份状态

Arguments:
    TASK_NAME           要执行的备份任务名称

Examples:
    $(basename $0) --list
    $(basename $0) documents
    $(basename $0) -f photos
EOF
}

# 列出所有任务
list_tasks() {
    echo "可用的备份任务:"
    jq -r '.[] | "\(.name): \(.description) (Cron: \(.cron))"' "$CONFIG_FILE"
}

# 显示任务状态
show_status() {
    local task_name="$1"
    local log_pattern="backup-*.log"

    if [ -n "$task_name" ]; then
        echo "任务 '$task_name' 的备份状态:"
        grep -h "$task_name" "$LOG_DIR"/$log_pattern | tail -n 5
    else
        echo "所有任务的最近备份状态:"
        for name in $(jq -r '.[].name' "$CONFIG_FILE"); do
            echo -e "\n=== $name ==="
            grep -h "$name" "$LOG_DIR"/$log_pattern | tail -n 3
        done
    fi
}

# 获取任务配置
get_task_config() {
    local task_name="$1"
    jq -c ".[] | select(.name == \"$task_name\")" "$CONFIG_FILE"
}

# 清理函数
cleanup() {
    local exit_code=$?
    local name=$1

    # 清理临时目录
    if [ -d "$TEMP_DIR/$name" ]; then
        log "清理临时目录: $TEMP_DIR/$name"
        rm -rf "$TEMP_DIR/$name"
    fi

    # 清理排除规则文件
    if [ -f "$SCRIPT_DIR/config/exclude/$name.exclude" ]; then
        log "清理排除规则文件: $SCRIPT_DIR/config/exclude/$name.exclude"
        rm -f "$SCRIPT_DIR/config/exclude/$name.exclude"
    fi

    exit $exit_code
}

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_DIR/backup-$DATE.log"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 检查源路径是否存在
check_sources() {
    local sources=("$@")
    local all_exist=true

    for source in "${sources[@]}"; do
        if [ ! -e "$source" ]; then
            log "错误: 源路径不存在: $source"
            all_exist=false
        fi
    done

    $all_exist
}

# 检查依赖
check_dependencies() {
    local deps=(jq zip rclone)
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log "错误: 未找到必需的程序 $dep"
            exit 1
        fi
    done
}

# 创建排除文件
create_exclude_file() {
    local name="$1"
    local exclude_list="$2"
    local exclude_file="$SCRIPT_DIR/config/exclude/$name.exclude"

    mkdir -p "$(dirname "$exclude_file")"
    echo "$exclude_list" | jq -r '.[]' > "$exclude_file"
    echo "$exclude_file"
}

# 清理旧备份
cleanup_old_backups() {
    local name="$1"
    local dest="$2"
    local savenum="$3"
    local pattern="$name-[0-9]*-[0-9]*.zip"

    if [[ $dest == local:* ]]; then
        local dest_path="${dest#local:}"
        # 列出所有备份文件并按时间排序
        local files=( $(ls -t "$dest_path"/$pattern 2>/dev/null) )
        # 删除超出保留数量的旧文件
        if [ ${#files[@]} -gt $savenum ]; then
            for ((i=$savenum; i<${#files[@]}; i++)); do
                log "删除旧备份文件: ${files[i]}"
                rm "${files[i]}"
            done
        fi
    else
        # 使用rclone处理远程文件
        local remote_path="${dest#*:}"
        # 获取文件列表
        local files=( $(rclone lsf "$remote_path" --include "$pattern" | sort -r) )
        if [ ${#files[@]} -gt $savenum ]; then
            for ((i=$savenum; i<${#files[@]}; i++)); do
                log "删除远程旧备份: $dest/${files[i]}"
                rclone delete "$remote_path/${files[i]}"
            done
        fi
    fi
}

# 传输备份文件到目标位置
transfer_backup() {
    local name="$1"
    local backup_file="$2"
    local dest="$3"
    local savenum="$4"
    local success=true

    if [[ $dest == local:* ]]; then
        local dest_path="${dest#local:}"
        mkdir -p "$dest_path"
        if cp "$TEMP_DIR/$name/$backup_file" "$dest_path/"; then
            log "备份文件已保存到本地: $dest_path/$backup_file"
        else
            log "错误: 无法保存到本地: $dest_path/$backup_file"
            success=false
        fi
    else
        local dest_path="${dest#rclone:}"
        if rclone copy "$TEMP_DIR/$name/$backup_file" "$dest_path"; then
            log "备份文件已上传到远程: $dest/$backup_file"
        else
            log "错误: 无法上传到远程: $dest/$backup_file"
            success=false
        fi
    fi

    if $success; then
        cleanup_old_backups "$name" "$dest" "$savenum"
    fi

    $success
}

# 执行备份
do_backup() {
    local item="$1"
    local name=$(echo "$item" | jq -r '.name')
    local description=$(echo "$item" | jq -r '.description')
    local sources=($(echo "$item" | jq -r '.source[]'))
    local dests=($(echo "$item" | jq -r '.dest[]'))
    local pwd=$(echo "$item" | jq -r '.pwd')
    local savenum=$(echo "$item" | jq -r '.savenum')
    local exclude=$(echo "$item" | jq -r '.exclude')

    # 设置清理trap
    trap 'cleanup "$name"' EXIT INT TERM

    log "开始备份: $description ($name)"

    # 检查源路径
    if ! check_sources "${sources[@]}"; then
        log "错误: 源路径检查失败，跳过备份: $name"
        return 1
    fi

    # 创建任务专用临时目录
    mkdir -p "$TEMP_DIR/$name"

    # 创建排除文件
    local exclude_file=""
    if [ "$exclude" != "null" ]; then
        exclude_file=$(create_exclude_file "$name" "$exclude")
    fi

    # 生成备份文件名
    local number=1
    local backup_file
    while true; do
        backup_file="$name-$DATE-$(printf "%03d" $number).zip"
        local file_exists=false

        # 检查所有目标位置
        for dest in "${dests[@]}"; do
            if [[ $dest == local:* ]]; then
                local dest_path="${dest#local:}"
                [ -f "$dest_path/$backup_file" ] && file_exists=true
            else
                local dest_path="${dest#rclone:}"
                rclone lsf "$dest_path/$backup_file" &>/dev/null && file_exists=true
            fi
        done

        $file_exists || break
        ((number++))
    done

    # 执行压缩
    log "正在压缩源文件..."
    local zip_opts="-r -7"
    if [ "$pwd" != "null" ]; then
        zip_opts="$zip_opts -P $pwd"
    fi
    if [ "$exclude_file" != "" ]; then
        zip $zip_opts "$TEMP_DIR/$name/$backup_file" ${sources[@]} -x@${exclude_file}
    else
        zip $zip_opts "$TEMP_DIR/$name/$backup_file" ${sources[@]}
    fi

    if [ ! -f "$TEMP_DIR/$name/$backup_file" ]; then
        log "错误: 压缩失败: $name"
        return 1
    fi

    # 传输到所有目标位置
    local transfer_success=true
    for dest in "${dests[@]}"; do
        if ! transfer_backup "$name" "$backup_file" "$dest" "$savenum"; then
            transfer_success=false
            log "警告: 传输失败到目标: $dest"
        fi
    done

    if $transfer_success; then
        log "备份完成: $name (所有目标)"
    else
        log "备份部分完成: $name (部分目标失败)"
        return 1
    fi
}

# 主函数
main() {
    check_dependencies

    # 检查配置文件
    if [ ! -f "$CONFIG_FILE" ]; then
        log "错误: 配置文件不存在 ($CONFIG_FILE)"
        exit 1
    fi

    # 解析命令行参数
    local TASK_NAME=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -l|--list)
                list_tasks
                exit 0
                ;;
            -s|--status)
                shift
                show_status "$1"
                exit 0
                ;;
            *)
                if [ -z "$TASK_NAME" ]; then
                    TASK_NAME="$1"
                else
                    echo "错误: 未知参数 '$1'"
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # 如果没有指定任务名称，显示帮助信息
    if [ -z "$TASK_NAME" ]; then
        show_help
        exit 1
    fi

    # 获取任务配置
    local task_config=$(get_task_config "$TASK_NAME")
    if [ -z "$task_config" ]; then
        echo "错误: 未找到任务 '$TASK_NAME'"
        echo "使用 --list 查看可用任务"
        exit 1
    fi

    # 执行备份任务
    if ! do_backup "$task_config"; then
        exit 1
    fi
}

main "$@"
