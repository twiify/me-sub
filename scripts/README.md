# Shell 脚本集合

此目录包含一系列用于服务器管理和自动化的 Shell 脚本。

## 脚本说明

-   `backup-postgres.sh`: 备份 PostgreSQL 数据库。
-   `firewall.sh`: 防火墙配置脚本。
-   `ufw-manager.sh`: UFW 防火墙管理工具。
-   `vps-init.sh`: VPS 服务器初始化脚本。
-   `backup/`: 包含一个更复杂的备份解决方案。
    -   `add2cron.sh`: 将备份脚本添加到 cron 定时任务。
    -   `add2pm2.sh`: 使用 PM2 管理备份脚本。
    -   `backup.sh`: 主要的备份执行脚本。
    -   `config/backup.json`: 备份配置。

## 使用方法

每个脚本的具体用法请参考其文件内的注释。在使用前，请确保你了解脚本的功能，并根据你的环境进行必要的修改。

例如，要运行一个脚本：

```bash
bash a.sh
```
