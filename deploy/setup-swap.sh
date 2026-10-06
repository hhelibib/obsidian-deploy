#!/usr/bin/env bash
# Create a 2GB swap file if swap is missing or too small.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

need_root

current_swap_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
needed_kb=$((SWAP_SIZE_MB * 1024))

if [[ "${current_swap_kb}" -ge "${needed_kb}" ]]; then
  echo "已有足够交换分区（${current_swap_kb} KB），跳过。"
  exit 0
fi

if [[ -f "${SWAP_FILE}" ]]; then
  echo "发现已有 ${SWAP_FILE}，尝试启用…"
  swapon "${SWAP_FILE}" 2>/dev/null || true
  current_swap_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
  if [[ "${current_swap_kb}" -ge "${needed_kb}" ]]; then
    echo "交换分区已启用。"
    exit 0
  fi
fi

echo "创建 ${SWAP_SIZE_MB}MB 交换文件: ${SWAP_FILE}"
dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${SWAP_SIZE_MB}" status=progress
chmod 600 "${SWAP_FILE}"
mkswap "${SWAP_FILE}"
swapon "${SWAP_FILE}"

if ! grep -qE "^${SWAP_FILE}\\s" /etc/fstab; then
  echo "${SWAP_FILE} none swap sw 0 0" >>/etc/fstab
fi

echo "交换分区就绪："
swapon --show
free -h
