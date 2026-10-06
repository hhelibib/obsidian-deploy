#!/usr/bin/env bash
# Grant an editor SSH push access to the private vault.
# Usage: sudo bash add-editor.sh <name> <path-to-ssh-public-key>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

need_root
ensure_garden_user

name="${1:-}"
pubkey_path="${2:-}"

[[ -n "${name}" && -n "${pubkey_path}" ]] || die "用法: $0 <name> <path-to-ssh-public-key>"
[[ -f "${pubkey_path}" ]] || die "找不到公钥文件: ${pubkey_path}"

pubkey="$(tr -d '\r\n' <"${pubkey_path}")"
[[ "${pubkey}" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp256|sk-ssh-ed25519) ]] || \
  die "看起来不是有效的 SSH 公钥"

auth_file="${GARDEN_HOME}/.ssh/authorized_keys"
mkdir -p "${GARDEN_HOME}/.ssh"
chmod 700 "${GARDEN_HOME}/.ssh"
touch "${auth_file}"

# Avoid duplicate keys
if grep -Fqx "${pubkey}" "${auth_file}" 2>/dev/null; then
  echo "该公钥已经存在，跳过写入。"
else
  # Restrict to git-shell style comment; still allow normal git over ssh for garden user
  echo "# editor:${name} $(date '+%Y-%m-%d')" >>"${auth_file}"
  echo "${pubkey}" >>"${auth_file}"
fi

chmod 600 "${auth_file}"
chown -R "${GARDEN_USER}:${GARDEN_USER}" "${GARDEN_HOME}/.ssh"

host="$(hostname -f 2>/dev/null || hostname)"
echo
echo "已添加编辑者: ${name}"
echo
echo "对方在 Obsidian Git 插件中使用的远程地址类似："
echo "  ${GARDEN_USER}@${host}:${VAULT_BARE}"
echo "或："
echo "  ssh://${GARDEN_USER}@YOUR_DOMAIN${VAULT_BARE}"
echo
echo "注意："
echo "  - 编辑者能看到并修改整个库（含 private/）"
echo "  - 编辑之间不能互相隐藏笔记"
echo "  - 收回密钥不会删除对方电脑上已克隆的副本"
echo "  - 同时改同一篇会冲突，需先拉取再解决"
