#!/usr/bin/env bash
# wb2api 一键部署（macOS / Linux）
#
#   ./setup.sh                 # 生成配置 → 构建 → 启动 → 打印接入口令
#   ./setup.sh --regen         # 重新生成 api_key 与面板口令（旧配置备份为 .bak）
#   ./setup.sh --no-build      # 配置已生成过，只想重启
#
# 幂等：已存在的 config/*.json 不会被覆盖（除非 --regen）。
set -euo pipefail
cd "$(dirname "$0")"

REGEN=0
BUILD=1
for arg in "$@"; do
    case "$arg" in
        --regen) REGEN=1 ;;
        --no-build) BUILD=0 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "未知参数: $arg（可用 --regen / --no-build / -h）" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
fail() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }

# ── 1. 依赖检查 ────────────────────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || fail "未找到 docker。请先安装 Docker Desktop for Mac：https://www.docker.com/products/docker-desktop/"
docker info >/dev/null 2>&1 || fail "Docker 未运行。请先启动 Docker Desktop，等鲸鱼图标稳定后再执行。"
docker compose version >/dev/null 2>&1 || fail "需要 Docker Compose v2（docker compose 子命令）。请升级 Docker Desktop。"
command -v openssl >/dev/null 2>&1 || fail "未找到 openssl（用于生成随机密钥）。macOS 自带，Linux 请安装 openssl。"

ARCH=$(uname -m)
say "==> 环境：$(uname -s) / $ARCH"

# ── 2. .env 与目录 ─────────────────────────────────────────────────────────
[ -f .env ] || cp .env.example .env
mkdir -p config data/auths data/state data/panel data/panel/backups

# 读取 .env 里的端口（只取需要的两个，不 source 整个文件）
envget() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" .env | tail -1; }
GW_PORT=$(envget WB2API_PORT);        GW_PORT=${GW_PORT:-7863}
PANEL_PORT=$(envget WB2API_PANEL_PORT); PANEL_PORT=${PANEL_PORT:-8787}

# ── 3. 生成密钥与配置 ──────────────────────────────────────────────────────
# Docker 的单文件 bind mount 在源路径不存在时会把它建成**目录**，
# 之后脚本写同名文件会失败（报 "Is a directory"）。这里主动清掉这种残留。
for f in config/gateway.json config/panel.json; do
    if [ -d "$f" ]; then
        rmdir "$f" 2>/dev/null || fail "$f 是一个非空目录（Docker 单文件挂载残留）。请备份后删除再重跑。"
        say "==> 已清理被 Docker 误建为目录的 $f"
    fi
done

if [ "$REGEN" = "1" ]; then
    for f in config/gateway.json config/panel.json; do
        [ -f "$f" ] && cp "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
    done
    rm -f config/gateway.json config/panel.json
    say "==> 已备份旧配置，重新生成密钥"
fi

if [ ! -f config/gateway.json ]; then
    API_KEY="wb2api-$(openssl rand -hex 20)"
    sed "s/\"test_key\"/\"$API_KEY\"/" config/gateway.example.json > config/gateway.json
    say "==> 已生成 config/gateway.json（含随机 api_key）"
else
    API_KEY=$(sed -n 's/.*"api_key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' config/gateway.json | head -1)
    [ -n "$API_KEY" ] || fail "config/gateway.json 中读不到 api_key，请检查或加 --regen 重建。"
fi

if [ ! -f config/panel.json ]; then
    PANEL_PASS="$(openssl rand -hex 9)"
    sed -e "s|__GATEWAY_API_KEY__|$API_KEY|" \
        -e "s|__PANEL_PASSWORD__|$PANEL_PASS|" \
        config/panel.example.json > config/panel.json
    say "==> 已生成 config/panel.json（含随机面板口令）"
else
    PANEL_PASS=$(sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' config/panel.json | head -1)
    # 网关 api_key 可能被 --regen 单独换过，保持面板侧同步
    if ! grep -q "\"gateway_api_key\"[[:space:]]*:[[:space:]]*\"$API_KEY\"" config/panel.json; then
        sed -i.bak "s|\"gateway_api_key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"gateway_api_key\": \"$API_KEY\"|" config/panel.json
        rm -f config/panel.json.bak
    fi
fi

chmod 600 config/gateway.json config/panel.json 2>/dev/null || true

# 凭证目录需可被容器内 uid 10001 读写。Docker Desktop for Mac 的 virtiofs 不强制属主，
# Linux 宿主才需要显式 chown（无权限时跳过并提示）。
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" = "0" ]; then
    chown -R 10001:10001 data/auths 2>/dev/null || true
fi

# ── 4. 构建并启动 ──────────────────────────────────────────────────────────
if [ "$BUILD" = "1" ]; then
    say "==> 构建镜像并启动（首次约 1-3 分钟，取决于网络）"
    docker compose up -d --build
else
    say "==> 启动（跳过构建）"
    docker compose up -d
fi

# ── 5. 等待面板就绪 ────────────────────────────────────────────────────────
say "==> 等待面板就绪..."
READY=0
for _ in $(seq 1 40); do
    if curl -fsS --noproxy '*' "http://127.0.0.1:${PANEL_PORT}/api/session" >/dev/null 2>&1; then
        READY=1; break
    fi
    sleep 1.5
done

# ── 6. 输出接入信息 ────────────────────────────────────────────────────────
say ""
say "────────────────────────────────────────────────────────────"
if [ "$READY" = "1" ]; then
    say " wb2api 已启动"
else
    say " 容器已创建，但面板尚未响应（看日志：docker compose logs -f panel）"
fi
say "────────────────────────────────────────────────────────────"
say " 管理面板    http://127.0.0.1:${PANEL_PORT}"
say "             用户名 admin ／ 口令 ${PANEL_PASS:-（见 config/panel.json）}"
say ""
say " API 地址    http://127.0.0.1:${GW_PORT}/v1"
say " API Key     ${API_KEY}"
say ""
say " 已验证可用："
say "   curl http://127.0.0.1:${GW_PORT}/v1/models -H \"Authorization: Bearer ${API_KEY}\""
say "────────────────────────────────────────────────────────────"
say ""
say "下一步：打开面板 → 「账号」→ 添加账号（国内版 / 国际版）"
say "        国际版账号添加后必须再跑一次：./scripts/activate-global-accounts.sh SG"
say ""
say "常用：docker compose logs -f     docker compose down     ./setup.sh --regen"
