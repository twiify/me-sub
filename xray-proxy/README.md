# Web 代理与反向代理解决方案

此项目提供了一套基于 Nginx、Xray 和 acme.sh 的强大 Web 代理和反向代理解决方案，全部通过 Docker Compose 进行容器化部署。其核心特性是利用 Xray 的 VLESS-REALITY 协议作为前端，统一处理代理流量和正常的 Web 流量。

## 核心架构

1.  **入口**: 所有外部流量（通常在 443 端口）首先由 **Xray** 接收。
2.  **流量分流**:
    *   **代理流量**: 如果流量匹配 VLESS-REALITY 协议，Xray 会直接处理，提供代理服务。
    *   **Web 流量**: 如果是标准的 HTTPS 请求，Xray 会根据其 `serverNames` 配置，将流量通过 Unix Socket (`/dev/shm/nginx.sock`) 透明地转发给 **Nginx**。
3.  **反向代理**: **Nginx** 接收到流量后，根据域名查找对应的站点配置文件，并将请求反向代理到上游的 Web 服务。
4.  **证书管理**: **acme.sh** 服务在独立的容器中运行，负责自动申请、续签和部署 SSL 证书。

这种架构的优势在于，所有服务共享同一个端口（443），有效隐藏了代理服务的特征。

## 目录与文件说明

-   `docker-compose.yml`: 定义了 `nginx`, `xray`, 和 `acme.sh` 三个核心服务。
-   `ssl.json`: `acme.sh` 证书管理脚本的配置文件，用于定义 DNS 提供商、API 密钥等。
-   `autossl.sh`: 功能强大的 SSL 证书管理脚本，提供 TUI 和 CLI 两种模式。
-   `manage-xray.sh`: Xray 服务管理脚本，用于初始化配置、生成凭证和创建订阅链接。
-   `manage-sites.sh`: Nginx 反向代理站点管理脚本，用于添加/删除网站。
-   `nginx/`: Nginx 相关目录。
    -   `nginx.conf`: Nginx 主配置文件，配置了与 Xray 的 Unix Socket 通信。
    -   `sites/`: 存放由脚本生成的各个站点的反向代理配置文件。
    -   `ssl/`: 存放由 `acme.sh` 自动部署的 SSL 证书。
-   `xray/`: Xray 相关目录。
    -   `xray_config_template.json`: Xray 配置的模板文件。
    -   `xray_config.json`: 由脚本生成的最终 Xray 配置文件。
    -   `clash_template.yaml`: 生成 Clash 订阅内容的模板文件。
    -   `xray_generated_configs/`: 存放生成的订阅文件（vless.txt, clash.yaml）。

## 快速开始

### 步骤 1: 环境准备

1.  克隆本项目到你的服务器。
2.  确保服务器上已安装 `docker`, `docker-compose` 和 `jq`。
3.  创建一个名为 `self-host` 的 Docker 网络：
    ```bash
    docker network create self-host
    ```

### 步骤 2: 配置 DNS API 密钥

编辑 `ssl.json` 文件，填入你选择的 DNS 提供商的 API 凭证。这是 `acme.sh` 申请证书所必需的。

```json
{
  "dns_providers": {
    "cloudflare": {
      "name": "Cloudflare (Global API Key)",
      "api_credentials": {
        "CF_Key": "YOUR_CLOUDFLARE_API_KEY",
        "CF_Email": "YOUR_CLOUDFLARE_EMAIL"
      },
      "acme_dns_api_name": "dns_cf"
    },
    // ... 其他 DNS 提供商
  },
  "default_dns_provider": "cloudflare",
  // ... 其他配置
}
```

### 步骤 3: 启动核心服务

运行 Docker Compose 启动 `nginx`, `xray`, 和 `acme.sh` 容器。

```bash
docker-compose up -d
```

### 步骤 4: 初始化 Xray 并生成订阅

运行 `manage-xray.sh` 脚本来初始化 Xray 服务。它会引导你设置代理主域名，并自动生成密钥、UUID 和订阅链接。

```bash
./manage-xray.sh
```
选择选项 `1. 初始化 Xray 配置`，并按照提示输入你的代理主域名（例如 `proxy.yourdomain.com`）。

脚本会自动：
1.  生成 `xray_config.json`。
2.  生成一个 Nginx 配置文件 `nginx/sites/subscription.conf` 用于提供订阅服务。
3.  在 `xray_generated_configs/` 目录下生成 `vless.txt` 和 `clash.yaml`。
4.  输出 VLESS 和 Clash 的订阅链接。

### 步骤 5: 为代理主域名申请证书

运行 `autossl.sh` 脚本为刚刚设置的代理主域名申请 SSL 证书。

```bash
./autossl.sh
```
在 TUI 菜单中，选择 `3. 签发/续签证书`，输入你的代理主域名，并选择 DNS 提供商和 CA。签发成功后，选择将证书部署到 Nginx。

### 步骤 6: 添加其他反向代理站点 (可选)

如果你需要将其他网站（例如 `app.yourdomain.com`）也通过此架构进行反向代理，请执行以下操作：

1.  **添加站点**: 运行 `manage-sites.sh` 脚本。
    ```bash
    ./manage-sites.sh
    ```
    选择 `1. 添加新的站点`，并输入服务域名和上游地址（例如 `http://other_container:8080`）。脚本会自动创建 Nginx 配置文件，并将域名添加到 Xray 的 `serverNames` 列表中。

2.  **为新站点申请证书**: 再次运行 `autossl.sh`，为新的服务域名申请并部署证书。

## 脚本使用详解

### `autossl.sh`

用于管理 SSL 证书。直接运行 `./autossl.sh` 会进入交互式 TUI 菜单，你可以在其中：
-   查看、签发、删除证书。
-   将证书部署到 Nginx。
-   切换默认的 CA（Let's Encrypt / ZeroSSL）。
-   配置 DNS 提供商的 API 凭证。

### `manage-xray.sh`

用于管理 Xray 核心配置和订阅服务。
-   **初始化配置**: 首次设置时运行，创建所有必要的配置和凭证。
-   **更新凭证**: 如果需要，可以重新生成 Xray 的 UUID 和密钥，并更新订阅链接，增强安全性。
-   **查看订阅**: 显示当前的订阅链接。

### `manage-sites.sh`

用于管理通过 Nginx 反向代理的普通网站。
-   **添加站点**: 引导你输入域名和上游服务地址，自动生成 Nginx 配置并更新 Xray 配置。
-   **删除站点**: 安全地移除站点的 Nginx 配置并从 Xray 配置中解注册。
-   **查看列表**: 列出当前所有已配置的反向代理站点。
