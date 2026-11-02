#!/usr/bin/env bash
# AgentRouter 签到面板 · 一键安装
# 用法：curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | bash
set -euo pipefail

# ↓↓↓ 发布前把这两行改成你自己的仓库 ↓↓↓
OWNER="${AR_OWNER:-zourjke}"
REPO="${AR_REPO:-agentrouter-signin}"
BRANCH="${AR_BRANCH:-main}"

DEST="${AR_DEST:-/root/agentrouter.sh}"
LINK="${AR_LINK:-/usr/local/bin/ck}"
RAW="https://raw.githubusercontent.com/${OWNER}/${REPO}/${BRANCH}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少依赖：$1，请先安装"; exit 1; }; }
need curl

echo "→ 下载 agentrouter.sh"
if ! curl -fsSL "$RAW/agentrouter.sh" -o "$DEST.tmp"; then
  echo "下载失败，检查 OWNER/REPO 是否填对：$RAW/agentrouter.sh"
  exit 1
fi
bash -n "$DEST.tmp" || { echo "脚本语法检查失败，放弃安装"; rm -f "$DEST.tmp"; exit 1; }
mv "$DEST.tmp" "$DEST"
chmod +x "$DEST"
echo "✔ 已安装到 $DEST"

if [ -w "$(dirname "$LINK")" ]; then
  ln -sf "$DEST" "$LINK"
  echo "✔ 快捷命令：$LINK"
else
  echo "! 无权限写 $(dirname "$LINK")，可手动：ln -sf $DEST ~/ck"
fi

echo
echo "依赖检查："
for b in curl jq python3; do
  if command -v "$b" >/dev/null 2>&1; then echo "  ✔ $b"; else echo "  ✘ $b（请先安装：apt-get install -y $b）"; fi
done

echo
echo "安装完成。运行下面的命令开始配置："
echo "  ck"
