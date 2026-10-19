#!/usr/bin/env bash
# wb2api 原生运行（不需要 Docker）
#
#   ./setup-native.sh              # 生成配置 → 编译 → 后台启动 → 打印接入信息
#   ./setup-native.sh --no-build   # 跳过编译，直接重启
#   ./setup-native.sh --regen      # 重新生成 api_key 与面板口令
#   ./setup-native.sh --stop       # 停止后台进程
#
# 依赖：Go 1.22+（macOS 26 上建议 1.25+，见构建后的可执行性检测）、openssl、curl。
#       前端产物已随仓库提供，无需 Node.js。
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

DO_STOP=0
BUILD=1
REGEN=0
for arg in "$@"; do
    case "$arg" in
        --stop)     DO_STOP=1 ;;
        --no-build) BUILD=0 ;;
        --regen)    REGEN=1 ;;
        -h|--help)  sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "未知参数: $arg（可用 --stop / --no-build / --regen / -h）" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
fail() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }

RUN_DIR="data/run"
LOG_DIR="data/logs"

# ── 进程控制 ───────────────────────────────────────────────────────────────
stop_one() {                       # $1 = 名称（gateway / panel）
    local name="$1" pidfile="$RUN_DIR/$1.pid"
    [ -f "$pidfile" ] || return 0
    local pid; pid=$(cat "$pidfile" 2>/dev/null || true)
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for _ in $(seq 1 20); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        kill -9 "$pid" 2>/dev/null || true
        say "==> 已停止 $name (pid $pid)"
    fi
    rm -f "$pidfile"
}

if [ "$DO_STOP" = "1" ]; then
    stop_one panel
    stop_one gateway
    say "已全部停止。"
    exit 0
fi

# ── 1. 依赖检查 ────────────────────────────────────────────────────────────
command -v go >/dev/null 2>&1 || fail "未找到 go。请安装 Go 1.22+：https://go.dev/dl/ （macOS：brew install go）"
command -v openssl >/dev/null 2>&1 || fail "未找到 openssl（生成随机密钥用）。"
command -v curl >/dev/null 2>&1 || fail "未找到 curl。"

GO_V=$(go env GOVERSION 2>/dev/null | sed 's/^go//')
awk -v v="$GO_V" 'BEGIN{split(v,a,"."); exit !(a[1]>1 || (a[1]==1 && a[2]>=22))}' \
    || fail "Go 版本为 $GO_V，需要 1.22 或更高。"
say "==> Go $GO_V / $(uname -s) $(uname -m)"

# ── 2. 端口与目录 ──────────────────────────────────────────────────────────
[ -f .env ] || cp .env.example .env
mkdir -p config data/auths data/state data/panel data/panel/backups "$RUN_DIR" "$LOG_DIR"

envget() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" .env | tail -1; }
GW_PORT=$(envget WB2API_PORT);          GW_PORT=${GW_PORT:-7863}
PANEL_PORT=$(envget WB2API_PANEL_PORT); PANEL_PORT=${PANEL_PORT:-8787}

port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# ── 3. 生成配置 ────────────────────────────────────────────────────────────
if [ "$REGEN" = "1" ]; then
    for f in config/gateway.native.json config/panel.native.json; do
        [ -f "$f" ] && cp "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
    done
    rm -f config/gateway.native.json config/panel.native.json
    say "==> 已备份旧配置，重新生成密钥"
fi

if [ ! -f config/gateway.native.json ]; then
    API_KEY="wb2api-$(openssl rand -hex 20)"
    sed -e "s|\"test_key\"|\"$API_KEY\"|" \
        -e "s|\"listen\": \":7863\"|\"listen\": \":$GW_PORT\"|" \
        -e "s|\"auth_dir\": \"./auths\"|\"auth_dir\": \"$ROOT/data/auths\"|" \
        -e "s|\"state_file\": \"./data/state.json\"|\"state_file\": \"$ROOT/data/state/state.json\"|" \
        config/gateway.example.json > config/gateway.native.json
    say "==> 已生成 config/gateway.native.json"
else
    API_KEY=$(sed -n 's/.*"api_key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' config/gateway.native.json | head -1)
    [ -n "$API_KEY" ] || fail "config/gateway.native.json 中读不到 api_key，请加 --regen 重建。"
fi

if [ ! -f config/panel.native.json ]; then
    PANEL_PASS="$(openssl rand -hex 9)"
    sed -e "s|__ROOT__|$ROOT|g" \
        -e "s|__GATEWAY_API_KEY__|$API_KEY|" \
        -e "s|__PANEL_PASSWORD__|$PANEL_PASS|" \
        -e "s|\"listen\": \":8787\"|\"listen\": \":$PANEL_PORT\"|" \
        config/panel.native.example.json > config/panel.native.json
    say "==> 已生成 config/panel.native.json"
else
    PANEL_PASS=$(sed -n 's/.*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' config/panel.native.json | head -1)
fi

chmod 600 config/gateway.native.json config/panel.native.json 2>/dev/null || true

# 端口以 .env 为准：配置无论是新建还是沿用，都同步一次。
# 否则改过 WB2API_PORT 之后，面板仍会把请求发往旧的 gateway_url。
sed -i.bak "s|\"listen\": \"[0-9:]*\"|\"listen\": \":$GW_PORT\"|" config/gateway.native.json
rm -f config/gateway.native.json.bak
sed -i.bak -e "s|\"listen\": \"[0-9:]*\"|\"listen\": \":$PANEL_PORT\"|" \
           -e "s|\"gateway_url\": \"[^\"]*\"|\"gateway_url\": \"http://127.0.0.1:$GW_PORT\"|" \
    config/panel.native.json
rm -f config/panel.native.json.bak

# ── 4. 编译 ────────────────────────────────────────────────────────────────
if [ "$BUILD" = "1" ]; then
    mkdir -p bin
    say "==> 编译网关（首次需联网拉取 Go 依赖）"
    ( cd gateway && go build -trimpath -ldflags="-s -w" -o "$ROOT/bin/wb2api" ./cmd/server )
    say "==> 编译面板（前端产物已内嵌，无需 Node.js）"
    ( cd panel && go build -trimpath -ldflags="-s -w" -o "$ROOT/bin/wb2api-panel" ./cmd/server )

    # macOS 26 的 dyld 会拒绝缺少 LC_UUID 的 Mach-O。Go 1.22~1.24 在 darwin 上
    # 不生成该 load command（1.25+ 已修复），表现为「编译成功但一执行就 Abort trap 6」。
    # 这里直接实测产物能否启动，把版本问题的报错提前到部署阶段。
    smoke() {
        local bin="$1" out
        out=$("$bin" -h 2>&1 || true)
        if printf '%s' "$out" | grep -q 'missing LC_UUID'; then
            fail "$(basename "$bin") 无法在本机运行：Mach-O 缺少 LC_UUID。
     当前 Go $GO_V 在 $(uname -s) 上产出的二进制不被 dyld 接受。
     处理：升级到 Go 1.25+（实测 1.25.14 / 1.26.9 正常），或改用 Docker 方式（./setup.sh）。"
        fi
    }
    smoke "$ROOT/bin/wb2api"
    smoke "$ROOT/bin/wb2api-panel"

    say "==> 编译完成：bin/wb2api  bin/wb2api-panel"
else
    [ -x bin/wb2api ] && [ -x bin/wb2api-panel ] || fail "bin/ 下没有可执行文件，请先不带 --no-build 运行一次。"
fi

# ── 5. 重启进程 ────────────────────────────────────────────────────────────
stop_one panel
stop_one gateway

if port_busy "$GW_PORT"; then
    fail "端口 $GW_PORT 已被占用（可能是旧的 Docker 栈）。先停掉它，或改 .env 里的 WB2API_PORT。"
fi
if port_busy "$PANEL_PORT"; then
    fail "端口 $PANEL_PORT 已被占用（可能是旧的 Docker 栈）。先停掉它，或改 .env 里的 WB2API_PANEL_PORT。"
fi

say "==> 启动网关与面板"
nohup ./bin/wb2api      -config config/gateway.native.json >> "$LOG_DIR/gateway.log" 2>&1 &
echo $! > "$RUN_DIR/gateway.pid"
nohup ./bin/wb2api-panel -config config/panel.native.json  >> "$LOG_DIR/panel.log"   2>&1 &
echo $! > "$RUN_DIR/panel.pid"

# ── 6. 等待就绪 ────────────────────────────────────────────────────────────
READY=0
for _ in $(seq 1 40); do
    if curl -fsS --noproxy '*' "http://127.0.0.1:${PANEL_PORT}/api/session" >/dev/null 2>&1; then
        READY=1; break
    fi
    sleep 0.5
done

# ── 7. 输出 ────────────────────────────────────────────────────────────────
say ""
say "────────────────────────────────────────────────────────────"
if [ "$READY" = "1" ]; then
    say " wb2api 已启动（原生进程，无 Docker）"
else
    say " 进程已拉起，但面板尚未响应。排查：tail -50 $LOG_DIR/panel.log"
fi
say "────────────────────────────────────────────────────────────"
say " 管理面板    http://127.0.0.1:${PANEL_PORT}"
say "             用户名 admin ／ 口令 ${PANEL_PASS:-（见 config/panel.native.json）}"
say ""
say " API 地址    http://127.0.0.1:${GW_PORT}/v1"
say " API Key     ${API_KEY}"
say ""
say " 日志        $LOG_DIR/gateway.log  $LOG_DIR/panel.log"
say " 停止        ./setup-native.sh --stop"
say "────────────────────────────────────────────────────────────"
say ""
say "注意：原生模式下面板的「重启网关」按钮不可用（该功能依赖容器）；"
say "      改完网关配置后请执行 ./setup-native.sh --no-build 重载。"
