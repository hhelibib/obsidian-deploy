#!/usr/bin/env bash
# Local smoke test: clone Quartz, apply overlay, build sample vault, assert private/draft excluded.
# Does NOT install Nginx/Artalk. Safe to run on a workstation or CI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/garden-verify-$$}"
DOMAIN="${DOMAIN:-example.com}"
NODE_MAX_OLD_SPACE="${NODE_MAX_OLD_SPACE:-768}"
QUARTZ_REPO="${QUARTZ_REPO:-https://github.com/jackyzha0/quartz.git}"

cleanup() {
  if [[ "${KEEP_WORK_DIR:-0}" != "1" ]]; then
    rm -rf "${WORK_DIR}"
  else
    echo "保留工作目录: ${WORK_DIR}"
  fi
}
trap cleanup EXIT

command -v node >/dev/null || { echo "需要 Node.js"; exit 1; }
command -v npm >/dev/null || { echo "需要 npm"; exit 1; }
command -v git >/dev/null || { echo "需要 git"; exit 1; }
command -v rsync >/dev/null || { echo "需要 rsync"; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3"; exit 1; }

echo "==> 工作目录: ${WORK_DIR}"
mkdir -p "${WORK_DIR}"
git clone --depth 1 -b v4 "${QUARTZ_REPO}" "${WORK_DIR}/quartz"
bash "${SCRIPT_DIR}/apply-quartz-overlay.sh" "${WORK_DIR}/quartz" "${DOMAIN}"

rm -rf "${WORK_DIR}/quartz/content"
mkdir -p "${WORK_DIR}/quartz/content"
rsync -a "${SCRIPT_DIR}/sample-vault/" "${WORK_DIR}/quartz/content/"

echo "==> npm install"
cd "${WORK_DIR}/quartz"
npm install --no-fund --no-audit

OUT="${WORK_DIR}/public"
echo "==> quartz build (max-old-space-size=${NODE_MAX_OLD_SPACE})"
export NODE_OPTIONS="--max-old-space-size=${NODE_MAX_OLD_SPACE}"
npx quartz build -o "${OUT}"

echo "==> 断言输出"
[[ -f "${OUT}/index.html" ]] || { echo "缺少 index.html"; exit 1; }
[[ -f "${OUT}/欢迎.html" || -d "${OUT}/欢迎" || -f "${OUT}/欢迎/index.html" ]] || \
  find "${OUT}" -iname '*欢迎*' | grep -q . || { echo "缺少公开笔记「欢迎」"; exit 1; }

if find "${OUT}" -iname '*机密*' | grep -q .; then
  echo "失败: private/ 下的「机密备忘」出现在构建产物中"
  find "${OUT}" -iname '*机密*'
  exit 1
fi

if find "${OUT}" -iname '*草稿*' | grep -q .; then
  echo "失败: draft: true 的「草稿示例」出现在构建产物中"
  find "${OUT}" -iname '*草稿*'
  exit 1
fi

# Also check content index / static listings if present
if grep -R -l "机密备忘" "${OUT}" >/dev/null 2>&1; then
  echo "失败: 构建产物中出现「机密备忘」文本"
  exit 1
fi
if grep -R -l "草稿示例" "${OUT}" >/dev/null 2>&1; then
  echo "失败: 构建产物中出现「草稿示例」文本"
  exit 1
fi

echo
echo "本地构建验证通过。"
echo "  - 公开页已生成"
echo "  - private/ 与 draft: true 未进入站点"
