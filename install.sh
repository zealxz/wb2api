#!/usr/bin/env bash
# wb2api 一键安装（预编译版）
#
# 适合「机器上只装过 WorkBuddy，没有任何开发工具链」的情况：
# 不需要 Docker、不需要 Go、不需要 Node.js，只要求系统自带 curl / tar。
#
#   curl -fsSL https://raw.githubusercontent.com/zealxz/wb2api/main/install.sh | bash
#
# 可选环境变量：
#   WB2API_DIR      安装目录（默认 $HOME/.wb2api）
#   WB2API_VERSION  指定版本标签，如 v1.0.0（默认 latest）
#
# 安装完成后执行：
#   cd "$WB2API_DIR" && ./setup-native.sh
set -euo pipefail

REPO="zealxz/wb2api"
DIR="${WB2API_DIR:-$HOME/.wb2api}"
VER="${WB2API_VERSION:-latest}"

say()  { printf '%s\n' "$*"; }
fail() { printf '\n[失败] %s\n' "$*" >&2; exit 1; }

# ── 1. 平台识别 ────────────────────────────────────────────────────────────
os=$(uname -s)
case "$os" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *) fail "暂不支持的系统：$os（可在源码仓库用 ./setup-native.sh 自行编译）" ;;
esac

arch=$(uname -m)
case "$arch" in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64)  arch=amd64 ;;
    *) fail "暂不支持的架构：$arch" ;;
esac

command -v curl >/dev/null 2>&1 || fail "需要 curl（系统自带即可）。"
command -v tar  >/dev/null 2>&1 || fail "需要 tar（系统自带即可）。"

asset="wb2api-${os}-${arch}.tar.gz"
if [ "$VER" = "latest" ]; then
    url="https://github.com/${REPO}/releases/latest/download/${asset}"
else
    url="https://github.com/${REPO}/releases/download/${VER}/${asset}"
fi

# ── 2. 下载与解压 ──────────────────────────────────────────────────────────
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

say "==> 平台：${os} / ${arch}"
say "==> 下载 ${asset}"
if ! curl -fL --retry 2 --connect-timeout 15 -o "$tmp/$asset" "$url"; then
    fail "下载失败：$url
     可能是该版本还没有对应平台的发行包。可查看：
     https://github.com/${REPO}/releases"
fi

mkdir -p "$DIR"
say "==> 解压到 $DIR"
tar -xzf "$tmp/$asset" -C "$DIR"

# macOS 兜底：若安装包是经浏览器下载/转发而来，会被打上 quarantine 属性，
# 首次执行会被 Gatekeeper 拦截。这里主动清掉（失败不视为错误）。
if [ "$os" = "darwin" ]; then
    xattr -dr com.apple.quarantine "$DIR" 2>/dev/null || true
fi

find "$DIR" -type f \( -name '*.sh' -o -path '*/bin/*' \) -exec chmod +x {} + 2>/dev/null || true

# ── 3. 结果 ────────────────────────────────────────────────────────────────
if [ ! -x "$DIR/bin/wb2api" ] || [ ! -x "$DIR/bin/wb2api-panel" ]; then
    fail "解压后缺少 bin/wb2api 或 bin/wb2api-panel，发行包可能不完整。"
fi

say ""
say "────────────────────────────────────────────────────────────"
say " 安装完成：$DIR"
say "────────────────────────────────────────────────────────────"
say ""
say "下一步："
say "  cd \"$DIR\" && ./setup-native.sh"
say ""
say "该脚本会生成随机 api_key 与面板口令，启动后打印："
say "  · 管理面板 http://127.0.0.1:8787"
say "  · API 地址 http://127.0.0.1:7863/v1"
say "────────────────────────────────────────────────────────────"
