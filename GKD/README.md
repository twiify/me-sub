# GKD 自定义订阅规则

本项目包含 [GKD](https://github.com/gkd-kit/gkd) 的自定义订阅规则，用于跳过应用启动广告。

## 项目结构

- `src/apps/`: 存放各个应用的规则定义。
- `src/categories.ts`: 定义规则的分类。
- `src/globalGroups.ts`: 定义全局规则组。
- `src/subscription.ts`: 订阅的主文件，整合所有规则。
- `scripts/build.ts`: 用于构建订阅文件的脚本。
- `scripts/check.ts`: 用于检查规则格式的脚本。

## 如何使用

1.  Fork 本项目。
2.  根据你的需求在 `src/apps/` 目录下添加或修改规则。
3.  运行 `pnpm install` 安装依赖。
4.  运行 `pnpm build` 来生成订阅文件。
5.  将生成的订阅链接添加到你的 GKD 应用中。

## 订阅链接

你可以直接使用由本项目生成的订阅链接：

[https://raw.githubusercontent.com/your-username/me-sub/main/GKD/dist/gkd.json5](https://raw.githubusercontent.com/your-username/me-sub/main/GKD/dist/gkd.json5)

**注意:** 请将 `your-username` 替换为你的 GitHub 用户名。
