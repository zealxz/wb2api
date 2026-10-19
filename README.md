# wb2api

把 **CodeBuddy / WorkBuddy 账号** 变成 **OpenAI 兼容 API**，并自带 Web 管理面板。
一条命令在 macOS（Intel / Apple Silicon）上跑起来。

> 非官方项目。网关注册与面板均为 MIT 许可的上游开源项目，本仓库做的是**打包、编排与修复**，
> 详见 [NOTICE.md](NOTICE.md) 与 [相对上游的改动](#相对上游的改动)。

---

## 特性

- **OpenAI 兼容**：`/v1/chat/completions`、`/v1/models`、流式 SSE，现有客户端改个 Base URL 就能用。
- **自带 Web 面板**（`http://127.0.0.1:8787`）：账号增删、网页 OAuth 登录、内置聊天测试台、
  批量签到 / 刷 token / 查余额、网关配置在线编辑、一键重启。
- **号池能力**：软/硬冷却、熔断降权、会话粘性、按积分到期紧迫度优先消耗。
- **双区域**：国内版（`codebuddy.cn`）与国际版（`workbuddy.ai`）可同时纳入同一号池。
- **容器化**：网关与面板两个容器，共享一个私有网络；宿主机不需要装 Go / Node。

## 快速开始（macOS）

前置条件：安装并**启动** [Docker Desktop for Mac](https://www.docker.com/products/docker-desktop/)。

```bash
git clone https://github.com/zealxz/wb2api.git
cd wb2api
./setup.sh
```

脚本会：检查 Docker → 生成随机 `api_key` 与面板口令 → 构建镜像 → 启动 → 等待就绪 → 打印接入信息。

首次构建约 1–3 分钟（拉取 Go / Node 基础镜像）。之后 `./setup.sh --no-build` 秒起。

输出示例：

```
 管理面板    http://127.0.0.1:8787
             用户名 admin ／ 口令 <随机生成>
 API 地址    http://127.0.0.1:7863/v1
 API Key     wb2api-<随机生成>
```

> 端口占用时改 `.env`（`WB2API_PORT` / `WB2API_PANEL_PORT`）后重跑 `./setup.sh --no-build`。

## 添加账号

1. 打开面板 → 登录。
2. 「账号」→ 添加账号 → 选区域：
   - **国内版** `copilot.tencent.com` / `www.codebuddy.cn`
   - **国际版** `www.workbuddy.ai`
3. 按提示打开授权链接完成登录，回到面板点「我已完成登录」。

### ⚠️ 国际版账号：加完必须补激活

面板的网页登录只做 OAuth 换 token + 落盘，**不跑国际版必需的「注册地区 + Trial 激活」**。
不做这一步，所有 `global:*` 模型会返回上游 `429 / code 14017 The trial version is not yet activated`，
而国内版完全正常 —— 表现为「国际版不能用、国内版才行」。

```bash
./scripts/activate-global-accounts.sh SG      # 可选地区：HK MO SG TH PH MY ID
```

脚本幂等，已激活的账号显示 `already active`。**地区是账号级半永久属性，选错了不好改，请自己确认。**
执行完无需重启网关。

## 客户端接入

| 项 | 值 |
|---|---|
| Base URL | `http://127.0.0.1:7863/v1` |
| API Key | `setup.sh` 输出的 `api_key`（也在 `config/gateway.json`） |
| 模型名 | `GET /v1/models` 拉取 |

自检：

```bash
curl http://127.0.0.1:7863/v1/models -H "Authorization: Bearer <API_KEY>"
```

OpenAI SDK：

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:7863/v1", api_key="<API_KEY>")
print(client.chat.completions.create(
    model="deepseek-v4-pro",
    messages=[{"role": "user", "content": "hello"}],
).choices[0].message.content)
```

**模型名前缀**：`cn:` / `global:` 可省略。不带前缀时由任一可用账号承接；
需要指定区域时写 `global:gpt-5.4`、`cn:glm-5.3`。

**跨设备访问**：网关默认监听 `0.0.0.0:7863`，把 `127.0.0.1` 换成宿主机局域网 IP 或 Tailscale IP 即可，
API Key 不变。**管理面板始终只绑 `127.0.0.1`**，不对外暴露。

## 目录结构

```
.
├── docker-compose.yml      # 网关 + 面板统一编排
├── setup.sh                # 一键部署
├── .env.example            # 端口 / 监听地址
├── config/
│   ├── gateway.example.json   # 网关配置模板（排程、号池、冷却）
│   └── panel.example.json     # 面板配置模板
├── data/                   # 运行时生成：auths 凭证、状态、备份（不入库）
├── scripts/
│   ├── activate-global-accounts.sh   # 国际版激活
│   └── probe-checkin.py              # 签到/余额对照诊断
├── gateway/                # 网关源码（vendored）
└── panel/                  # 面板源码（vendored，含本仓库修复）
```

## 常用命令

```bash
docker compose logs -f              # 全部日志
docker compose logs -f gateway      # 只看网关
docker compose restart gateway      # 改完配置后重载
docker compose down                 # 停止（保留 data/ 与 config/）
./setup.sh --regen                  # 重新生成 api_key 与面板口令（旧配置备份）
```

查看号池状态：

```bash
curl -s http://127.0.0.1:7863/status -H "Authorization: Bearer <API_KEY>"
```

## 相对上游的改动

为透明起见，本仓库对上游源码的改动仅有两处，都在 `panel/`：

| 文件 | 改动 |
|---|---|
| `panel/internal/upstream/client.go` | 新增 `IsGlobalAccount()`（按 `domain` 后缀识别国际版账号） |
| `panel/internal/ops/ops.go` | 单账号与批量签到对国际版账号**跳过签到调用**，返回「国际版无签到活动（已跳过）」并照常刷新余额 |

**原因**：国际版根本没有签到活动 —— 上游对 `global` realm 的 `daily-checkin` 恒定返回
`code=10001「签到活动未开启或已过期」`。原有面板把它当硬失败弹出，
而网关侧调度器本身就对国际版做了跳过门控（`internal/scheduler/scheduler.go` 的 D4 门控）。
本改动是让面板与网关口径一致，不改变任何国内版行为。

指纹校验可自行对比：`diff -r gateway/ <上游 checkout>`、`diff -r panel/ <上游 checkout>`。

其余文件均为上游原样 vendored，仅去掉了 `.git`、本地 `auths/`、`data/`、`config.json` 与上游 compose。

## 已知限制

- **国际版无签到、无任务中心**：签到只会被跳过；国际版积分来自试用额度 / 对话活跃上报，
  不要期待签到涨额度。
- **签到是每日固定额度**，不是主要积分来源；本项目的价值在于把账号变成可用 API。
- **面板「系统」页显示的 Base URL 不可直接照抄**：它展示的是容器内网地址
  `http://gateway:7863/v1`。宿主机/客户端请用 `http://127.0.0.1:7863/v1`。
- 构建需联网拉取基础镜像（`golang:1.26-alpine`、`node:20-alpine`、`alpine:3.20`）。
- 仅在 macOS（Apple Silicon 实测）与 Docker Compose v2 上验证；Linux 需自行 `chown -R 10001:10001 data/auths`。

## 安全

- `data/auths/*.json` 是**明文账号凭证**；`config/*.json` 含 api_key 与面板口令。三者均已 `.gitignore`。
- 管理面板只绑 `127.0.0.1`；面板口令随机生成。
- 面板挂载了 `/var/run/docker.sock`（用于「系统」页一键重启网关）——这等同于把宿主机 Docker 控制权交给该容器。
  不需要就把 `docker-compose.yml` 里那行注释掉，面板会自动降级。
- 对外暴露网关时请保持 `api_key` 为强随机值；`setup.sh` 默认生成 40 位十六进制。

## 免责声明

仅供**本人授权账号**与**本机 / 私有环境**使用。此类网关涉及目标平台服务条款，
使用可能导致账号被限制或封禁，风险自负。请勿用于商业分发或共享账号池。

## 许可与致谢

本仓库的编排与脚本以 MIT 发布。内置的两个上游项目同样是 MIT：

- 网关：[`Sliverkiss/workbuddy2api`](https://github.com/Sliverkiss/workbuddy2api) © 2026 Sliverkiss
- 面板：[`287775856/workbuddy2api-gui`](https://github.com/287775856/workbuddy2api-gui) © 2026 Sliverkiss

版本锚点与完整声明见 [NOTICE.md](NOTICE.md)。
