#!/usr/bin/env python3
"""对照探针：对 CN / Global 账号分别打 daily-checkin 的两条候选路径 + 余额接口。

只读取证用：打印 HTTP 状态与响应体，不修改任何本地文件。
用法: docker exec -i wb2api python3 - < scripts/probe-checkin.py
"""
import json
import os
import ssl
import urllib.request
import urllib.error

AUTHS = "/app/auths"

CN_CHAT = "https://copilot.tencent.com"
CN_BILLING = "https://www.codebuddy.cn"
CN_ORIGIN = "https://www.codebuddy.cn"

GL_CHAT = "https://www.workbuddy.ai"
GL_BILLING = "https://www.workbuddy.ai"
GL_ORIGIN = "https://www.workbuddy.ai"

UA = "CLI/2.63.2 CodeBuddy/2.63.2"

CTX = ssl.create_default_context()


def load_accounts():
    out = []
    for name in sorted(os.listdir(AUTHS)):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(AUTHS, name)) as fh:
            doc = json.load(fh)
        # 凭证文件形如 {"account": {uid,nickname,enterpriseId}, "auth": {accessToken,...}}，
        # 两层字段都要读：realm/domain 在 auth，uid/nickname 在 account（早期版本曾在 auth 层）。
        a = doc.get("auth", doc)
        acc = doc.get("account", doc)
        realm = (a.get("realm") or "").lower()
        domain = (a.get("domain") or "").lower()
        is_global = realm == "global" or "workbuddy.ai" in domain
        out.append({
            "file": name,
            "uid": acc.get("uid") or acc.get("UID") or a.get("uid") or "?",
            "nick": acc.get("nickname") or acc.get("nickName") or a.get("nickname") or "?",
            "realm": realm or "(empty)",
            "domain": domain or "(empty)",
            "token": a.get("accessToken") or a.get("access_token") or "",
            "enterprise": (acc.get("enterpriseId") or a.get("enterpriseId")
                           or a.get("enterprise_id") or ""),
            "global": is_global,
        })
    return out


def call(url, token, uid, domain, enterprise, origin, body=b"{}"):
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/plain, */*")
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("X-Requested-With", "XMLHttpRequest")
    req.add_header("User-Agent", UA)
    req.add_header("Origin", origin)
    req.add_header("Referer", origin + "/")
    if uid:
        req.add_header("X-User-Id", uid)
    if enterprise:
        req.add_header("X-Enterprise-Id", enterprise)
        req.add_header("X-Tenant-Id", enterprise)
    if domain:
        req.add_header("X-Domain", domain)
    try:
        with urllib.request.urlopen(req, timeout=25, context=CTX) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        return -1, "transport: %r" % (e,)


def mask(tok):
    return (tok[:8] + "..." + tok[-4:]) if len(tok) > 14 else "(short)"


def main():
    accts = load_accounts()
    print("账号清单：")
    for a in accts:
        print("  %-12s uid=%-12s realm=%-8s domain=%-18s token=%s" % (
            a["nick"][:12], a["uid"][:12], a["realm"], a["domain"], mask(a["token"])))
    print()

    resource_body = json.dumps({
        "PageNumber": 1, "PageSize": 100, "ProductCode": "p_tcaca",
        "Status": [0, 3],
        "PackageEndTimeRangeBegin": "2020-01-01 00:00:00",
        "PackageEndTimeRangeEnd": "2099-01-01 00:00:00",
    }).encode()

    for a in accts:
        tag = "GLOBAL" if a["global"] else "CN    "
        print("=" * 78)
        print("[%s] %s  uid=%s  domain=%s" % (tag, a["nick"][:14], a["uid"][:12], a["domain"]))
        print("=" * 78)

        if a["global"]:
            paths = [
                (GL_BILLING + "/v2/billing/meter/daily-checkin", GL_ORIGIN, "/v2/billing/meter/daily-checkin"),
                (GL_BILLING + "/billing/meter/daily-checkin", GL_ORIGIN, "/billing/meter/daily-checkin"),
            ]
            bal = [
                (GL_BILLING + "/v2/billing/meter/get-user-resource", GL_ORIGIN, "global /v2 get-user-resource"),
                (GL_BILLING + "/billing/meter/get-user-resource", GL_ORIGIN, "global / get-user-resource"),
            ]
        else:
            paths = [
                (CN_BILLING + "/v2/billing/meter/daily-checkin", CN_ORIGIN, "cn /v2/billing/meter/daily-checkin"),
            ]
            bal = [
                (CN_BILLING + "/v2/billing/meter/get-user-resource", CN_ORIGIN, "cn /v2 get-user-resource"),
            ]

        for url, origin, label in paths:
            st, body = call(url, a["token"], a["uid"], a["domain"], a["enterprise"], origin)
            print("  checkin %-42s -> HTTP %-4s %s" % (label, st, body[:220].replace("\n", " ")))

        for url, origin, label in bal:
            st, body = call(url, a["token"], a["uid"], a["domain"], a["enterprise"], origin, resource_body)
            print("  balance %-42s -> HTTP %-4s %s" % (label, st, body[:180].replace("\n", " ")))
        print()


if __name__ == "__main__":
    main()
