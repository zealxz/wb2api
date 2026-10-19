#!/usr/bin/env python3
"""国际版(global)账号激活：提交注册地区 → register 激活 Trial → 领一次性加油包。

供 activate-global-accounts.sh 调用，也可单独执行：

    # 原生模式（在仓库根目录）
    WB2API_AUTHS_DIR="$PWD/data/auths" WB2API_SCRIPTS="$PWD/gateway/scripts" \
        python3 scripts/activate_global.py SG

    # 容器内
    docker exec -i -e WB2API_AUTHS_DIR=/app/auths -e WB2API_SCRIPTS=/app/scripts \
        wb2api python3 - SG < scripts/activate_global.py

幂等：已激活账号显示 already，重复执行无副作用。
"""
import glob
import json
import os
import sys

AUTHS = os.environ.get("WB2API_AUTHS_DIR", "/app/auths")
SCRIPTS = os.environ.get("WB2API_SCRIPTS", "/app/scripts")

sys.path.insert(0, SCRIPTS)
try:
    import global_region as gr
except ImportError as exc:  # noqa: BLE001
    print("无法加载 global_region（期望位于 %s）: %s" % (SCRIPTS, exc))
    sys.exit(1)

want = (sys.argv[1] if len(sys.argv) > 1 else "SG").upper()


def is_global(auth):
    """判定 realm：凭证文件里的 realm 字段时有时无。

    面板写的文件只有 domain（其 Account 结构体没有 realm 字段），
    网关 BackfillRealm() 之后才会补上。因此以 domain 为准，realm 存在时作交叉校验。
    """
    realm = (auth.get("realm") or "").strip().lower()
    if realm:
        return realm == "global"
    domain = (auth.get("domain") or "").strip().lower()
    return "workbuddy.ai" in domain


ok, countries, msg = gr.fetch_countries()
if not ok:
    print("拉取地区列表失败:", msg)
    sys.exit(1)

country = next((c for c in countries if c["IOS2"] == want), None)
if country is None:
    print("无效地区 %s；可选: %s" % (want, ", ".join(c["IOS2"] for c in countries)))
    sys.exit(1)

print("目标注册地区: %s / %s\n" % (country["IOS2"], country["Name"]))
print("%-30s %-16s %s" % ("账号", "register", "trial"))
print("-" * 72)

total = done = skipped = failed = 0
for path in sorted(glob.glob(os.path.join(AUTHS, "*.json"))):
    with open(path) as fh:
        doc = json.load(fh)
    auth = doc.get("auth", {})
    if not is_global(auth):
        continue

    total += 1
    token = auth.get("accessToken")
    account = doc.get("account", {})
    uid = account.get("uid") or auth.get("uid")
    nick = (account.get("nickname") or uid or "?")[:30]
    if not uid or not token:
        print("%-30s %-16s %s" % (nick, "SKIP", "缺少 uid/accessToken"))
        failed += 1
        continue

    # 先探测是否已激活：已激活则不必重复提交地区。
    already, _needs_region, _ = gr.activate_region(token, uid)
    if already:
        reg_msg = "already active"
        skipped += 1
    else:
        ok2, flow_msg = gr.complete_flow(token, uid, pick=country, call_register=False)
        reg_msg = "activated" if ok2 else "FAILED: " + str(flow_msg)
        if ok2:
            done += 1
        else:
            failed += 1

    tok_ok, tok_already, tok_msg = gr.trial(token)
    trial_msg = "ok" if (tok_ok and not tok_already) else (
        "already" if tok_already else "FAILED: " + str(tok_msg)
    )

    print("%-30s %-16s %s" % (nick, reg_msg, trial_msg))

print("-" * 72)
print("global 账号 total=%d activated=%d already=%d failed=%d" % (total, done, skipped, failed))
if total == 0:
    print("（当前凭证目录里没有 global 账号）")
