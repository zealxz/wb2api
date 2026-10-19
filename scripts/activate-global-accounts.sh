#!/usr/bin/env bash
# activate-global-accounts.sh
#
# 补齐国际版(global)账号的激活三步：
#     提交注册地区 → register 激活 Trial → 领一次性 trial 加油包
#
# 为什么需要这个脚本
# ------------------
# 面板的「网页版 OAuth 登录」只做 OAuth 换 token + 落盘，不跑国际版必需的
# 注册地区完善与 register 激活。结果是：通过面板加进来的 global 账号，
# chat 一律返回上游 429 / code 14017
#   "The trial version is not yet activated..."
# 而国内版账号不受影响 —— 表现为「国际版不能用、国内版才行」。
#
# 幂等：已激活的账号会显示 already，重复执行无副作用。
#
# 用法（Docker / 原生两种部署都支持，自动识别）：
#     ./scripts/activate-global-accounts.sh          # 默认地区 SG(新加坡)
#     ./scripts/activate-global-accounts.sh HK       # 可选 HK MO SG TH PH MY ID
#
# 依赖：Docker 模式需容器在运行；原生模式需 python3。
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${WB2API_CONTAINER:-wb2api}"
REGION="${1:-SG}"

fail() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }

if command -v docker >/dev/null 2>&1 && docker inspect "$CONTAINER" >/dev/null 2>&1; then
    # ── Docker 模式：在容器内执行（复用镜像里的 /app/scripts 与 /app/auths）
    MODE="Docker 容器 $CONTAINER"
    docker exec -i \
        -e WB2API_AUTHS_DIR=/app/auths \
        -e WB2API_SCRIPTS=/app/scripts \
        "$CONTAINER" python3 - "$REGION" < scripts/activate_global.py
else
    # ── 原生模式：直接跑仓库里的脚本与 data/auths
    MODE="原生进程"
    command -v python3 >/dev/null 2>&1 || fail "原生模式需要 python3（Docker 模式不需要）。"
    [ -d gateway/scripts ] || fail "找不到 gateway/scripts（请在仓库根目录运行）。"
    [ -d data/auths ] || fail "找不到 data/auths；先启动一次 ./setup-native.sh 让目录就位。"
    WB2API_AUTHS_DIR="$PWD/data/auths" \
    WB2API_SCRIPTS="$PWD/gateway/scripts" \
        python3 scripts/activate_global.py "$REGION"
fi

echo
echo "执行方式：$MODE"
echo "提示：修复前那批 14017 失败会给账号留下软冷却（cool_kind:1），到期自动清除，无需重启。"
