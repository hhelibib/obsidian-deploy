#!/usr/bin/env bash
# Shared helpers for garden deploy scripts.
set -euo pipefail

GARDEN_USER="${GARDEN_USER:-garden}"
GARDEN_HOME="${GARDEN_HOME:-/home/${GARDEN_USER}}"
VAULT_BARE="${VAULT_BARE:-${GARDEN_HOME}/vault.git}"
VAULT_WORKTREE="${VAULT_WORKTREE:-${GARDEN_HOME}/vault}"
QUARTZ_DIR="${QUARTZ_DIR:-/opt/quartz}"
WEB_ROOT="${WEB_ROOT:-/var/www/garden}"
ARTALK_DIR="${ARTALK_DIR:-/var/lib/artalk}"
ARTALK_CONF="${ARTALK_CONF:-/etc/artalk/artalk.yml}"
HTPASSWD_FILE="${HTPASSWD_FILE:-/etc/nginx/garden.htpasswd}"
PASSWORD_FILE="${PASSWORD_FILE:-/root/garden-passwords.txt}"
NODE_MAX_OLD_SPACE="${NODE_MAX_OLD_SPACE:-768}"
SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-2048}"

die() {
  echo "错误: $*" >&2
  exit 1
}

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "请用 root 运行（例如: sudo bash $0）"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

random_password() {
  # URL-safe-ish password without ambiguous characters
  tr -dc 'A-Za-z2-9' </dev/urandom | head -c 16
}

ensure_garden_user() {
  if ! id "${GARDEN_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${GARDEN_USER}"
  fi
  mkdir -p "${GARDEN_HOME}/.ssh"
  chmod 700 "${GARDEN_HOME}/.ssh"
  touch "${GARDEN_HOME}/.ssh/authorized_keys"
  chmod 600 "${GARDEN_HOME}/.ssh/authorized_keys"
  chown -R "${GARDEN_USER}:${GARDEN_USER}" "${GARDEN_HOME}/.ssh"
}

append_password_record() {
  local label="$1"
  local username="$2"
  local password="$3"
  umask 077
  {
    echo "----- $(date '+%Y-%m-%d %H:%M:%S') -----"
    echo "${label}"
    echo "username: ${username}"
    echo "password: ${password}"
    echo
  } >>"${PASSWORD_FILE}"
  chmod 600 "${PASSWORD_FILE}"
}
