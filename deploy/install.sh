#!/usr/bin/env bash
# Install Garden (Quartz + Nginx Basic Auth + Artalk) on Alibaba Cloud Linux 3.
#
# Usage (on the server as root):
#   export DOMAIN=notes.example.com
#   export EMAIL=you@example.com   # optional, for Let's Encrypt
#   bash /root/garden-deploy/deploy/install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

need_root

DOMAIN="${DOMAIN:-${1:-}}"
EMAIL="${EMAIL:-}"
SKIP_TLS="${SKIP_TLS:-0}"
QUARTZ_REPO="${QUARTZ_REPO:-https://github.com/jackyzha0/quartz.git}"
ARTALK_VERSION="${ARTALK_VERSION:-latest}"

[[ -n "${DOMAIN}" ]] || die "请设置 DOMAIN，例如: DOMAIN=notes.example.com bash $0"
[[ "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] || die "DOMAIN 格式不正确: ${DOMAIN}"

echo "==> 目标域名: ${DOMAIN}"
echo "==> 仓库路径: ${REPO_ROOT}"

# Persist domain for rebuild.sh
mkdir -p /etc/garden
echo "${DOMAIN}" >/etc/garden/domain
chmod 644 /etc/garden/domain

echo "==> 配置 2GB 交换分区"
bash "${SCRIPT_DIR}/setup-swap.sh"

echo "==> 安装系统软件包（dnf）"
if ! command -v dnf >/dev/null 2>&1; then
  die "未找到 dnf。本脚本面向 Alibaba Cloud Linux 3 / OpenAnolis。"
fi

dnf -y install \
  nginx \
  git \
  rsync \
  curl \
  tar \
  gzip \
  unzip \
  python3 \
  httpd-tools \
  ca-certificates \
  firewalld \
  policycoreutils-python-utils 2>/dev/null || \
dnf -y install \
  nginx git rsync curl tar gzip unzip python3 httpd-tools ca-certificates

# Node.js 20+
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | tr -d 'v' | cut -d. -f1)" -lt 20 ]]; then
  echo "==> 安装 Node.js 22（NodeSource）"
  curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
  dnf -y install nodejs
fi
echo "Node: $(node -v)  npm: $(npm -v)"

# Certbot (best effort)
if [[ "${SKIP_TLS}" != "1" ]]; then
  dnf -y install certbot python3-certbot-nginx 2>/dev/null || \
    echo "警告: 未能通过 dnf 安装 certbot，稍后将尝试跳过或手动签发。"
fi

echo "==> 创建 garden 用户与私有 Git 仓库"
ensure_garden_user
mkdir -p "${VAULT_BARE}" "${VAULT_WORKTREE}" "${WEB_ROOT}" /var/www/certbot
if [[ ! -d "${VAULT_BARE}/refs" ]]; then
  git init --bare "${VAULT_BARE}"
  git -C "${VAULT_BARE}" symbolic-ref HEAD refs/heads/main
fi
chown -R "${GARDEN_USER}:${GARDEN_USER}" "${GARDEN_HOME}"

# Seed sample vault BEFORE installing post-receive (avoid rebuild-before-ready).
# Use a temp clone so the build worktree has no nested .git (bare + work-tree only).
if [[ ! -f "${VAULT_WORKTREE}/index.md" ]]; then
  echo "==> 写入示例笔记"
  seed_tmp="$(mktemp -d)"
  rsync -a "${SCRIPT_DIR}/sample-vault/" "${seed_tmp}/"
  chown -R "${GARDEN_USER}:${GARDEN_USER}" "${seed_tmp}"
  sudo -u "${GARDEN_USER}" bash -c "
    set -e
    cd '${seed_tmp}'
    git init -b main
    git config user.email 'garden@localhost'
    git config user.name 'Garden'
    git add -A
    git commit -m 'Initial sample vault'
    git remote add origin '${VAULT_BARE}'
    git push -u origin main
  "
  rm -rf "${seed_tmp}"
  mkdir -p "${VAULT_WORKTREE}"
  # Drop any accidental nested repo metadata
  rm -rf "${VAULT_WORKTREE}/.git"
  git --git-dir="${VAULT_BARE}" --work-tree="${VAULT_WORKTREE}" checkout -f main
  chown -R "${GARDEN_USER}:${GARDEN_USER}" "${VAULT_WORKTREE}"
fi

# Hook runs as the pushing user (garden); allow passwordless rebuild via sudoers
cat >/etc/sudoers.d/garden-rebuild <<EOF
${GARDEN_USER} ALL=(root) NOPASSWD: ${SCRIPT_DIR}/rebuild.sh
EOF
chmod 440 /etc/sudoers.d/garden-rebuild

cat >"${VAULT_BARE}/hooks/post-receive" <<EOF
#!/usr/bin/env bash
set -euo pipefail
VAULT_BARE="${VAULT_BARE}"
VAULT_WORKTREE="${VAULT_WORKTREE}"
REBUILD_SCRIPT="${SCRIPT_DIR}/rebuild.sh"
LOCK_FILE="/tmp/garden-rebuild.lock"

mkdir -p "\${VAULT_WORKTREE}"
rm -rf "\${VAULT_WORKTREE}/.git"
git --git-dir="\${VAULT_BARE}" --work-tree="\${VAULT_WORKTREE}" checkout -f main 2>/dev/null \\
  || git --git-dir="\${VAULT_BARE}" --work-tree="\${VAULT_WORKTREE}" checkout -f master

(
  flock -n 9 || { echo "已有构建在进行，跳过本次。"; exit 0; }
  echo "开始重建网站…"
  sudo "\${REBUILD_SCRIPT}"
  echo "重建完成。"
) 9>"\${LOCK_FILE}"
EOF
chmod 755 "${VAULT_BARE}/hooks/post-receive"
chown -R "${GARDEN_USER}:${GARDEN_USER}" "${VAULT_BARE}"

echo "==> 安装 Quartz 到 ${QUARTZ_DIR}"
if [[ ! -d "${QUARTZ_DIR}/.git" ]]; then
  rm -rf "${QUARTZ_DIR}"
  git clone --depth 1 -b v4 "${QUARTZ_REPO}" "${QUARTZ_DIR}"
fi
bash "${SCRIPT_DIR}/apply-quartz-overlay.sh" "${QUARTZ_DIR}" "${DOMAIN}"
cd "${QUARTZ_DIR}"
npm install --no-fund --no-audit

echo "==> 安装 Artalk"
install_artalk() {
  local arch raw_arch asset tmpdir url version
  raw_arch="$(uname -m)"
  case "${raw_arch}" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "不支持的架构: ${raw_arch}" ;;
  esac

  if [[ "${ARTALK_VERSION}" == "latest" ]]; then
    url="$(curl -fsSL https://api.github.com/repos/ArtalkJS/Artalk/releases/latest \
      | python3 -c "import sys,json,re; d=json.load(sys.stdin); arch='${arch}';
pat=re.compile(rf'artalk_.*_linux_{arch}\\.tar\\.gz\$');
print(next(a['browser_download_url'] for a in d['assets'] if pat.search(a['name'])))")"
  else
    url="https://github.com/ArtalkJS/Artalk/releases/download/${ARTALK_VERSION}/artalk_${ARTALK_VERSION#v}_linux_${arch}.tar.gz"
  fi

  tmpdir="$(mktemp -d)"
  curl -fsSL "${url}" -o "${tmpdir}/artalk.tar.gz"
  tar -xzf "${tmpdir}/artalk.tar.gz" -C "${tmpdir}"
  install -m 755 "${tmpdir}/artalk" /usr/local/bin/artalk
  rm -rf "${tmpdir}"
  /usr/local/bin/artalk version || true
}
install_artalk

if ! id artalk >/dev/null 2>&1; then
  useradd --system --home "${ARTALK_DIR}" --shell /sbin/nologin artalk
fi
mkdir -p "${ARTALK_DIR}/data/artalk-img" /etc/artalk
ARTALK_APP_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
sed -e "s/__DOMAIN__/${DOMAIN}/g" \
    -e "s/__ARTALK_APP_KEY__/${ARTALK_APP_KEY}/g" \
    "${SCRIPT_DIR}/artalk/artalk.yml.template" >"${ARTALK_CONF}"
chown -R artalk:artalk "${ARTALK_DIR}"
chmod 640 "${ARTALK_CONF}"
chown root:artalk "${ARTALK_CONF}"

install -m 644 "${SCRIPT_DIR}/systemd/artalk.service" /etc/systemd/system/artalk.service
systemctl daemon-reload
systemctl enable --now artalk

echo "==> 配置 Nginx Basic Auth 初始用户"
ADMIN_USER="admin"
ADMIN_PASS="$(random_password)"
EDITOR_WEB_USER="editor"
EDITOR_WEB_PASS="$(random_password)"
umask 077
: >"${PASSWORD_FILE}"
touch "${HTPASSWD_FILE}"
htpasswd -bB -c "${HTPASSWD_FILE}" "${ADMIN_USER}" "${ADMIN_PASS}"
htpasswd -bB "${HTPASSWD_FILE}" "${EDITOR_WEB_USER}" "${EDITOR_WEB_PASS}"
chmod 640 "${HTPASSWD_FILE}"
chown root:nginx "${HTPASSWD_FILE}" 2>/dev/null || chown root:root "${HTPASSWD_FILE}"
append_password_record "website admin (initial)" "${ADMIN_USER}" "${ADMIN_PASS}"
append_password_record "website editor (initial)" "${EDITOR_WEB_USER}" "${EDITOR_WEB_PASS}"

echo "==> 写入 Nginx 配置"
if [[ "${SKIP_TLS}" == "1" ]] || [[ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]]; then
  sed "s/__DOMAIN__/${DOMAIN}/g" \
    "${SCRIPT_DIR}/nginx/garden-http-bootstrap.conf.template" \
    >/etc/nginx/conf.d/garden.conf
else
  sed "s/__DOMAIN__/${DOMAIN}/g" \
    "${SCRIPT_DIR}/nginx/garden.conf.template" \
    >/etc/nginx/conf.d/garden.conf
fi
# Remove default welcome if it conflicts
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

echo "==> 首次构建网站"
bash "${SCRIPT_DIR}/rebuild.sh"

nginx -t
systemctl enable nginx
systemctl restart nginx

# Firewall
if systemctl is-active --quiet firewalld 2>/dev/null || systemctl enable --now firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-service=http || true
  firewall-cmd --permanent --add-service=https || true
  firewall-cmd --reload || true
fi

echo "==> 申请 TLS 证书"
if [[ "${SKIP_TLS}" != "1" ]] && command -v certbot >/dev/null 2>&1; then
  CERTBOT_ARGS=(certbot certonly --webroot -w /var/www/certbot -d "${DOMAIN}" --agree-tos --non-interactive)
  if [[ -n "${EMAIL}" ]]; then
    CERTBOT_ARGS+=(--email "${EMAIL}")
  else
    CERTBOT_ARGS+=(--register-unsafely-without-email)
  fi
  if "${CERTBOT_ARGS[@]}"; then
    sed "s/__DOMAIN__/${DOMAIN}/g" \
      "${SCRIPT_DIR}/nginx/garden.conf.template" \
      >/etc/nginx/conf.d/garden.conf
    nginx -t && systemctl reload nginx
    # Renew cron
    cat >/etc/cron.d/garden-certbot <<'CRON'
0 3 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
CRON
  else
    echo "警告: 证书申请失败。站点仍以 HTTP + Basic Auth 运行。检查域名解析与 80 端口后执行:"
    echo "  certbot certonly --webroot -w /var/www/certbot -d ${DOMAIN}"
    echo "  然后把 deploy/nginx/garden.conf.template 安装为 /etc/nginx/conf.d/garden.conf 并 reload"
  fi
else
  echo "跳过 TLS（SKIP_TLS=${SKIP_TLS} 或未安装 certbot）。"
fi

cat <<EOF

========================================
Garden 安装完成
========================================

域名: https://${DOMAIN}  （若证书失败则先用 http://${DOMAIN}）
网站密码文件: ${PASSWORD_FILE}
  - ${ADMIN_USER} / （见密码文件）
  - ${EDITOR_WEB_USER} / （见密码文件）

笔记裸仓库: ${VAULT_BARE}
工作副本:   ${VAULT_WORKTREE}
Quartz:     ${QUARTZ_DIR}
站点目录:   ${WEB_ROOT}
评论数据:   ${ARTALK_DIR}

添加读者（只能看）:
  bash ${SCRIPT_DIR}/add-reader.sh <username>

添加编辑（SSH 密钥，可改笔记）:
  bash ${SCRIPT_DIR}/add-editor.sh <name> /path/to/id_ed25519.pub

手动重建:
  bash ${SCRIPT_DIR}/rebuild.sh

编辑者远程地址示例:
  ${GARDEN_USER}@${DOMAIN}:${VAULT_BARE}

请立即阅读 ${PASSWORD_FILE}，把密码发给对应的人，并考虑删除该文件中的明文备份。
EOF
