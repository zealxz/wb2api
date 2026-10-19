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
# 用法：
#     ./scripts/activate-global-accounts.sh          # 默认地区 SG(新加坡)
#     ./scripts/activate-global-accounts.sh HK       # 可选 HK MO SG TH PH MY ID
#
# 依赖：docker；网关容器已在运行（脚本在其内部执行，复用 /app/scripts/global_region.py）
set -euo pipefail
cd "$(dirname "$0")/.."

CONTAINER="${WB2API_CONTAINER:-wb2api}"
REGION="${1:-SG}"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "找不到容器 $CONTAINER（用 WB2API_CONTAINER=<名字> 覆盖）" >&2
    exit 1
fi

docker exec -i "$CONTAINER" python3 - "$REGION" <<'PY'
import glob, json, sys

sys.path.insert(0, '/app/scripts')
try:
    import global_region as gr
except ImportError as e:
    print('无法加载 global_region（镜像里应有 /app/scripts/）:', e)
    sys.exit(1)

want = (sys.argv[1] if len(sys.argv) > 1 else 'SG').upper()

# 判定 realm：凭证文件里的 realm 字段时有时无 —— 面板写的文件只有 domain，
# 网关 BackfillRealm() 之后才会补上。因此以 domain 为准，realm 存在时作交叉校验。
def is_global(auth):
    realm = (auth.get('realm') or '').strip().lower()
    if realm:
        return realm == 'global'
    domain = (auth.get('domain') or '').strip().lower()
    return 'workbuddy.ai' in domain

ok, countries, msg = gr.fetch_countries()
if not ok:
    print('拉取地区列表失败:', msg)
    sys.exit(1)

country = next((c for c in countries if c['IOS2'] == want), None)
if country is None:
    print('无效地区 %s；可选: %s' % (want, ', '.join(c['IOS2'] for c in countries)))
    sys.exit(1)

print('目标注册地区: %s / %s\n' % (country['IOS2'], country['Name']))
print('%-30s %-16s %s' % ('账号', 'register', 'trial'))
print('-' * 72)

total = done = skipped = failed = 0
for path in sorted(glob.glob('/app/auths/*.json')):
    doc = json.load(open(path))
    auth = doc.get('auth', {})
    if not is_global(auth):
        continue

    total += 1
    token = auth['accessToken']
    account = doc.get('account', {})
    uid = account.get('uid') or auth.get('uid')
    nick = (account.get('nickname') or uid or '?')[:30]
    if not uid or not token:
        print('%-30s %-16s %s' % (nick, 'SKIP', '缺少 uid/accessToken'))
        failed += 1
        continue

    # 先探测是否已激活：已激活则不必重复提交地区。
    already, needs_region, _ = gr.activate_region(token, uid)
    if already:
        reg_msg = 'already active'
        skipped += 1
    else:
        ok2, flow_msg = gr.complete_flow(token, uid, pick=country, call_register=False)
        reg_msg = 'activated' if ok2 else 'FAILED: ' + str(flow_msg)
        if ok2:
            done += 1
        else:
            failed += 1

    tok_ok, tok_already, tok_msg = gr.trial(token)
    trial_msg = 'ok' if (tok_ok and not tok_already) else ('already' if tok_already else 'FAILED: ' + str(tok_msg))

    print('%-30s %-16s %s' % (nick, reg_msg, trial_msg))

print('-' * 72)
print('global 账号 total=%d activated=%d already=%d failed=%d' % (total, done, skipped, failed))
if total == 0:
    print('（当前 auths/ 里没有 global 账号）')
PY

echo
echo "提示：修复前那批 14017 失败会给账号留下软冷却（cool_kind:1），到期自动清除，"
echo "      无需重启网关。查看状态：curl -s \"http://127.0.0.1:\${WB2API_PORT:-7863}/status\" -H \"Authorization: Bearer <api_key>\""
