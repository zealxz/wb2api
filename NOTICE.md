# NOTICE

本仓库（`wb2api`）是以下两个开源项目的**打包发行版**，而非原创实现。
两个上游均以 MIT 许可发布，其原始版权声明保留在各自目录下的 `LICENSE` 中。

## 内置组件与版本锚点

| 组件 | 目录 | 上游仓库 | Vendored commit | 日期 | 许可 |
|---|---|---|---|---|---|
| 网关 | `gateway/` | https://github.com/Sliverkiss/workbuddy2api | `160c553fcd4386ad42f514b0fb596bcb71caffa0` | 2026-09-17 | MIT © 2026 Sliverkiss |
| 面板 | `panel/` | https://github.com/287775856/workbuddy2api-gui | `209d111cfd41a570058b04f4b71038dcde9495a6` | 2026-09-14 | MIT © 2026 Sliverkiss |

```
MIT License

Copyright (c) 2026 Sliverkiss

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 本仓库对上游所做的改动

### 1. 剔除文件（不含功能改动）

从 vendored 源码中移除了：

- `.git/`（版本历史，避免嵌套仓库）
- `auths/`、`data/`、`config.json`（本地账号凭证与运行时状态，**含明文 token，绝不入库**）
- `.github/`（指向原仓库 CI，在本仓库无意义）
- 上游各自的 `docker-compose.yml`（由本仓库根目录的统一编排替代）

### 2. 提交前端构建产物（打包差异，非上游代码改动）

上游 `panel/.gitignore` 忽略 `internal/webui/dist/assets/`，前端由 Dockerfile 的 Node 阶段生成。
本发行版**把 `panel/internal/webui/dist/` 的构建产物（约 272KB）一并入库**，原因是：
只装 Go、不用 Node 的用户执行 `go build ./cmd/server` 时，若 dist 只有占位 `index.html`，
打出来的面板会白屏（占位 HTML 引用的 `assets/index-*.js` 不存在）。

产物来自上游 `web/` 的 `npm ci && npm run build`（Node 20 + Vite），未做任何二次修改。
Docker 构建流程不变，仍会在镜像内重新构建并覆盖该目录。

### 3. 面板的代码修复（2 个文件）

| 文件 | 改动 |
|---|---|
| `panel/internal/upstream/client.go` | 新增导出函数 `IsGlobalAccount()`，复用 `regionOfAccount()` 按 `domain` 后缀识别国际版账号 |
| `panel/internal/ops/ops.go` | 新增常量 `globalCheckinSkipped`；`Checkin()` 与 `checkinOne()` 在调用 `DailyCheckin()` 前对国际版账号短路，返回成功并照常刷新余额 |

**技术依据**：国际版（`workbuddy.ai`）不存在签到活动，其 `daily-checkin` 端点对任意全球账号
恒定返回 HTTP 400 / `{"code":10001,"msg":"签到活动未开启或已过期"}`。上游网关的调度器
（`gateway/internal/scheduler/scheduler.go`）本就对 `IsGlobal()` 账号跳过签到、不发起上游调用；
面板此前未同步这一门控，导致该响应被当作硬失败呈现给用户。此修复使面板与网关口径一致。

**未改动**：国内版签到路径、余额查询、token 刷新、登录流程、号池逻辑、Web 前端。

## 商标

CodeBuddy、WorkBuddy 及相关标识归其权利人所有。本项目与上述公司无任何关联，
未获其背书或授权。
