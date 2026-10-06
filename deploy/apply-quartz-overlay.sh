#!/usr/bin/env bash
# Copy Garden overlays into a Quartz checkout.
# Usage: bash apply-quartz-overlay.sh <quartz-dir> <domain>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARTZ_DIR="${1:-}"
DOMAIN="${2:-}"

[[ -n "${QUARTZ_DIR}" && -n "${DOMAIN}" ]] || {
  echo "用法: $0 <quartz-dir> <domain>" >&2
  exit 1
}
[[ -d "${QUARTZ_DIR}" ]] || {
  echo "找不到 Quartz 目录: ${QUARTZ_DIR}" >&2
  exit 1
}

cp -f "${SCRIPT_DIR}/quartz/quartz.config.ts" "${QUARTZ_DIR}/quartz.config.ts"
cp -f "${SCRIPT_DIR}/quartz/quartz.layout.ts" "${QUARTZ_DIR}/quartz.layout.ts"

mkdir -p \
  "${QUARTZ_DIR}/quartz/components/scripts" \
  "${QUARTZ_DIR}/quartz/components/styles"

cp -f "${SCRIPT_DIR}/quartz/components/ArtalkComments.tsx" \
  "${QUARTZ_DIR}/quartz/components/ArtalkComments.tsx"
cp -f "${SCRIPT_DIR}/quartz/components/scripts/artalk.inline.ts" \
  "${QUARTZ_DIR}/quartz/components/scripts/artalk.inline.ts"
cp -f "${SCRIPT_DIR}/quartz/components/styles/artalk.scss" \
  "${QUARTZ_DIR}/quartz/components/styles/artalk.scss"

# Patch baseUrl in config
python3 - "${QUARTZ_DIR}/quartz.config.ts" "${DOMAIN}" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
domain = sys.argv[2]
text = path.read_text(encoding="utf-8")
old = 'baseUrl: "example.com"'
new = f'baseUrl: "{domain}"'
if old not in text:
    raise SystemExit(f"baseUrl placeholder missing in {path}")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY

echo "已应用 Quartz 覆盖层到 ${QUARTZ_DIR}（baseUrl=${DOMAIN}）"
