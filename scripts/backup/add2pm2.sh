#!/bin/bash

# 设置基础变量
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config/backup.json"
DEFAULT_OUTPUT="$SCRIPT_DIR/ecosystem.config.js"

# 显示帮助信息
show_help() {
    cat << EOF
Usage: $(basename $0) [OPTIONS]

Options:
    -h, --help              显示帮助信息
    -o, --output <file>     指定输出文件路径 (默认: ./ecosystem.config.js)
    -f, --force             强制覆盖已存在的配置文件
    -p, --preview           预览配置内容而不写入文件

Example:
    $(basename $0) --output /path/to/ecosystem.config.js
    $(basename $0) --preview
EOF
}

# 检查依赖
check_dependencies() {
    if ! command -v jq &> /dev/null; then
        echo "错误: 未找到必需的程序 'jq'"
        exit 1
    fi
}

# 验证配置文件
validate_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 配置文件不存在 ($CONFIG_FILE)"
        exit 1
    fi

    # 验证JSON格式
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        echo "错误: 配置文件格式不正确"
        exit 1
    fi
}

# 格式化任务名称
format_task_name() {
    local name="$1"
    # 替换特殊字符为连字符
    echo "Backup[$name]"
}

# 生成PM2配置内容
generate_config() {
    local script_path="$SCRIPT_DIR/backup.sh"

    # 配置文件头部
    cat << EOF
module.exports = {
  apps: [
EOF

    # 读取每个备份任务并生成配置
    local first=true
    while read -r task; do
        local name=$(echo "$task" | jq -r '.name')
        local cron=$(echo "$task" | jq -r '.cron')

        # 添加逗号分隔符（除了第一个项目）
        if [ "$first" = true ]; then
            first=false
        else
            echo ","
        fi

        # 生成单个任务配置
        cat << EOF
    {
      name: '$(format_task_name "$name")',
      script: '$script_path',
      cwd: '$SCRIPT_DIR',
      cron_restart: '$cron',
      autorestart: false,
      watch: false,
      args: ['$name'],
      interpreter: 'bash'
    }
EOF
    done < <(jq -c '.[]' "$CONFIG_FILE")

    # 配置文件尾部
    cat << EOF

  ]
}
EOF
}

# 主函数
main() {
    local output_file="$DEFAULT_OUTPUT"
    local force=false
    local preview=false

    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -o|--output)
                output_file="$2"
                shift 2
                ;;
            -f|--force)
                force=true
                shift
                ;;
            -p|--preview)
                preview=true
                shift
                ;;
            *)
                echo "错误: 未知参数 '$1'"
                show_help
                exit 1
                ;;
        esac
    done

    # 检查依赖和配置
    check_dependencies
    validate_config

    # 生成配置内容
    local config_content=$(generate_config)

    # 预览模式
    if [ "$preview" = true ]; then
        echo "$config_content"
        exit 0
    fi

    # 检查输出文件是否已存在
    if [ -f "$output_file" ] && [ "$force" = false ]; then
        read -p "配置文件已存在，是否覆盖？[y/N] " confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            echo "操作已取消"
            exit 0
        fi
    fi

    # 创建输出目录（如果不存在）
    mkdir -p "$(dirname "$output_file")"

    # 写入配置文件
    echo "$config_content" > "$output_file"

    if [ $? -eq 0 ]; then
        echo "PM2配置文件已生成: $output_file"
        echo "使用以下命令启动PM2任务："
        echo "pm2 start $output_file"
    else
        echo "错误: 无法写入配置文件"
        exit 1
    fi
}

main "$@"