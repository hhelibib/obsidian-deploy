#!/usr/bin/env bash
# Build Quartz site from the vault worktree into /var/www/garden.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

need_root

DOMAIN_FILE="/etc/garden/domain"
if [[ -f "${DOMAIN_FILE}" ]]; then
  DOMAIN="$(cat "${DOMAIN_FILE}")"
else
  DOMAIN="${DOMAIN:-example.com}"
fi

[[ -d "${QUARTZ_DIR}" ]] || die "找不到 Quartz: ${QUARTZ_DIR}"
[[ -d "${VAULT_WORKTREE}" ]] || die "找不到笔记工作副本: ${VAULT_WORKTREE}"

# Keep overlay in sync (safe to re-run)
bash "${SCRIPT_DIR}/apply-quartz-overlay.sh" "${QUARTZ_DIR}" "${DOMAIN}"

# Sync notes into Quartz content/
rm -rf "${QUARTZ_DIR}/content"
mkdir -p "${QUARTZ_DIR}/content"
# Copy tracked vault files; exclude .git
rsync -a --delete \
  --exclude '.git/' \
  --exclude '.obsidian/' \
  "${VAULT_WORKTREE}/" "${QUARTZ_DIR}/content/"

mkdir -p "${WEB_ROOT}"

echo "构建 Quartz（NODE_OPTIONS=--max-old-space-size=${NODE_MAX_OLD_SPACE}）…"
cd "${QUARTZ_DIR}"
export NODE_OPTIONS="--max-old-space-size=${NODE_MAX_OLD_SPACE}"
npx quartz build -o "${WEB_ROOT}"

chown -R nginx:nginx "${WEB_ROOT}" 2>/dev/null || chown -R root:root "${WEB_ROOT}"
echo "已发布到 ${WEB_ROOT}"
