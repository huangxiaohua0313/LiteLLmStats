# LiteLLmStats

macOS 菜单栏上的 LiteLLM 用量监控小部件。实时显示**当天** token 消耗，点击展开各模型明细。

当前版本：**0.1.0**

## 功能

- 菜单栏实时显示「今日 x.xxM」
- 按模型展示请求数、输入/输出 token、缓存命中率
- 网关地址（IP）与端口可配置
- 刷新间隔可配置（2–3600 秒）
- 访问密钥可配置；留空时自动读取 `~/.litellm/config.yaml` 中的 `master_key`
- 支持开机自动启动（LaunchAgent）
- 当日统计：跨零点自动归零；litellm 重启、计数器归零后仍继续累计当天用量

## 前置条件：LiteLLM 必须启用 Prometheus

本应用完全依赖 LiteLLM 的 Prometheus 指标。**被监控的 LiteLLM 必须安装 prometheus 依赖并启用 prometheus 回调**，否则 `/metrics/` 会返回 404（或指标为空），应用显示不出任何数据。

安装依赖（`proxy` extra 已包含 `prometheus_client`）：

```bash
pip install 'litellm[proxy]'
# 或 pipx install 'litellm[proxy]'
```

在 LiteLLM 配置（`config.yaml`）中确认存在：

```yaml
litellm_settings:
  callbacks: ["prometheus"]
```

修改后重启 LiteLLM 服务。验证（需使用 `master_key`，虚拟 key 无权限访问 `/metrics/`）：

```bash
curl -H "Authorization: Bearer <master_key>" http://<host>:<port>/metrics/
```

返回 200 且包含 `litellm_*` 指标即表示就绪。

> 用 Docker 运行时，prometheus 指标同样来自上面的配置项，无需额外安装 Prometheus 服务——指标由 LiteLLM 自己以文本格式暴露在 `/metrics/`。

## 数据来源与统计口径

应用读取 LiteLLM 的 Prometheus 指标接口：

```text
GET http://<host>:<port>/metrics/
Authorization: Bearer <master_key>
```

Prometheus 计数器是进程启动以来的累计值。为了显示“当天”，应用：

1. 读取每类计数的 `litellm_*_metric_created`（计数器序列创建时间）；
2. 若计数器是当天创建的，直接把当前值计为今日用量；
3. 若计数器跨天，则按两次采样之间的增量累加；
4. 若检测到计数器重建（litellm 重启），把新序列的当前值全部计入当天，同时保留重启前已累计的部分；
5. 本地跨过零点时自动清空。
6. 当日状态持久化在 `~/.litellmStats/daily.json`，应用重启不会丢失。

已知边界：如果 LiteLLM 进程跨天运行，而本应用在当天零点之后才首次启动，那么“零点到应用启动前、且来自跨天旧计数器”的用量无法从纯计数器反推。

## 构建

要求：macOS 13+，已安装 Xcode Command Line Tools（提供 `swiftc`）。

```bash
./build.sh
open dist/LiteLLmStats.app
```

产物：`dist/LiteLLmStats.app`（ad-hoc 签名，可直接本地运行）。

## 打包 pkg

```bash
./packaging/build-pkg.sh
```

产物：`dist/LiteLLmStats-0.1.0.pkg`，版本号取自 `Resources/Info.plist` 的 `CFBundleShortVersionString`。

安装包会：

- 安装 `LiteLLmStats.app` 到 `/Applications/LiteLLmStats.app`
- 安装 LaunchAgent 到 `/Library/LaunchAgents/local.llm.litellm-stats.plist`
- 安装后自动为当前登录用户加载开机自启服务
- 清理旧版本 `/Applications/LLMStats.app` 和冲突的用户级 LaunchAgent

双击安装即可。未签名安装包如被 Gatekeeper 拦截，可在「系统设置 → 隐私与安全性」中点击「仍要打开」。

卸载（需要管理员密码）：

```bash
./packaging/uninstall.sh
```

## 配置

点击菜单栏图标 → **设置…**，可修改：

| 项目 | 说明 |
|---|---|
| 网关地址 / IP | LiteLLM 所在主机，默认 `127.0.0.1` |
| 端口 | 默认 `4000` |
| 刷新间隔(秒) | 2–3600，默认 `10` |
| 访问密钥 | 留空则读取 `~/.litellm/config.yaml` 的 `master_key` |
| 开机自动启动 | 写入/启用 LaunchAgent |

数据目录：`~/.litellmStats/`（权限 0700）。

| 文件 | 说明 |
|---|---|
| `~/.litellmStats/config.json` | 配置（权限 0600），参考 `config.example.json` |
| `~/.litellmStats/daily.json` | 当日累计状态 |

旧版本使用的 `~/.litellm/menubar/` 数据会在首次启动时自动迁移到新目录。

## 安装与卸载

本仓库只负责构建；可自行将 `dist/LiteLLmStats.app` 复制到 `/Applications`，并在设置中勾选“开机自动启动”。

卸载：

```bash
launchctl bootout gui/$(id -u)/local.llm.litellm-stats 2>/dev/null
sudo rm -rf /Applications/LiteLLmStats.app
sudo rm -f /Library/LaunchAgents/local.llm.litellm-stats.plist
rm -rf ~/.litellmStats ~/.litellm/menubar
```

> 应用使用 `LSUIElement`，只驻留菜单栏，不显示在 Dock 和启动台。

## 开发流程

`main` 分支受保护：**禁止直接提交，必须从特性分支通过 Pull Request 合并**。

```bash
git checkout main
git pull
git checkout -b feat/your-feature

# 修改代码并提交
git add -A
git commit -m "feat: your feature"

git push -u origin feat/your-feature
# 在 GitHub 创建 Pull Request，合并到 main
```

## 发布

1. 修改 `Resources/Info.plist` 中的版本号（`CFBundleShortVersionString` / `CFBundleVersion`）
2. 执行 `./packaging/build-pkg.sh`
3. 在 GitHub Releases 新建 `v<版本号>` tag，上传 `dist/LiteLLmStats-<版本号>.pkg`

当前版本 `0.1.0` 的安装包：`LiteLLmStats-0.1.0.pkg`。

## 版本

- `0.1.0` — 首个对外版本：菜单栏今日用量、按模型明细、可配置网关/刷新/密钥、开机自启
