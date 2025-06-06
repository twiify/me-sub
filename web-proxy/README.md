# Web 代理配置

此目录包含使用 Nginx 和 Xray 实现反向代理和 Web 代理的配置。

## 主要功能

-   使用 Docker Compose 快速部署。
-   通过 Nginx 实现网站的反向代理。
-   集成 Xray 提供代理服务。
-   使用 acme.sh 自动申请和续签 SSL 证书。

## 目录结构

-   `docker-compose.yml`: Docker Compose 配置文件，定义了 Nginx 和 Xray 服务。
-   `nginx/`: Nginx 相关配置。
    -   `nginx.conf`: Nginx 主配置文件。
    -   `sites/`: 存放站点配置文件。
    -   `ssl/`: 存放 SSL 证书。
-   `xray/`: Xray 相关配置。
    -   `xray_config.json`: Xray 配置文件。
-   `autossl.sh`: 自动配置 SSL 的脚本。
-   `deploy-proxy.sh`: 部署代理服务的脚本。

## 快速开始

1.  克隆本项目到你的服务器。
2.  根据你的域名和需求修改 `docker-compose.yml` 和相关的配置文件。
3.  运行 `./deploy-proxy.sh` 脚本来启动服务。
4.  运行 `./autossl.sh` 脚本来申请 SSL 证书。

详细的使用说明请参考各个脚本和配置文件中的注释。
