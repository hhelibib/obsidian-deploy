#!/usr/bin/env bash
# Add a website reader (HTTP Basic Auth). Cannot edit notes.
# Usage: sudo bash add-reader.sh <username> [password]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

need_root
require_cmd htpasswd

username="${1:-}"
password="${2:-}"

[[ -n "${username}" ]] || die "用法: $0 <username> [password]"
[[ "${username}" =~ ^[A-Za-z0-9._-]+$ ]] || die "用户名只能包含字母、数字、. _ -"

if [[ -z "${password}" ]]; then
  password="$(random_password)"
fi

touch "${HTPASSWD_FILE}"
chmod 640 "${HTPASSWD_FILE}"
chown root:nginx "${HTPASSWD_FILE}" 2>/dev/null || chown root:root "${HTPASSWD_FILE}"

htpasswd -bB "${HTPASSWD_FILE}" "${username}" "${password}"
append_password_record "website reader" "${username}" "${password}"

echo
echo "已添加网站读者: ${username}"
echo "密码已写入: ${PASSWORD_FILE}"
echo "请把用户名和密码私下发给对方。对方只能浏览已发布页面与评论，不能改笔记。"
