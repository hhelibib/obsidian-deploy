#!/usr/bin/env bash
# 下载并安装 Artalk 二进制，支持断点续传、多镜像、SHA256 校验。
#
# 用法:
#   bash deploy/download-artalk.sh              # 下载到缓存并安装到 /usr/local/bin/artalk
#   bash deploy/download-artalk.sh --download-only
#   ARTALK_VERSION=v2.9.1 bash deploy/download-artalk.sh
#   ARTALK_TARBALL=/path/to.tgz bash deploy/download-artalk.sh
#
# 环境变量:
#   ARTALK_VERSION     默认 v2.10.0（勿用 latest，避免卡在 api.github.com）
#   ARTALK_CACHE_DIR   默认 /var/cache/garden
#   ARTALK_INSTALL_DIR 默认 /usr/local/bin
#   FORCE_ARTALK_REINSTALL=1  强制重装
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DOWNLOAD_ONLY=0
for arg in "$@"; do
  case "${arg}" in
    --download-only) DOWNLOAD_ONLY=1 ;;
    -h|--help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
  esac
done

VER_RAW="${ARTALK_VERSION:-v2.10.0}"
CACHE_DIR="${ARTALK_CACHE_DIR:-/var/cache/garden}"
INSTALL_DIR="${ARTALK_INSTALL_DIR:-/usr/local/bin}"

# 已知版本的 sha256（GitHub release digest）。未知版本则跳过强校验，只做 gzip 完整性检查。
declare -A KNOWN_SHA256=(
  ["v2.10.0/amd64"]="8ef3dcb322207ea76038a32d8e137604eba9313259c3423683d80efbcf18aed1"
  ["v2.10.0/arm64"]="98a97778798864dd7fd036cd7ace3c0524cc409213024673fb11924498bc0b92"
  ["v2.10.0/arm7"]="fd172e6fe15bbc03134dbbb4d70ba316941cc6693effb9302f6b1a4391306deb"
)

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armhf) echo "arm7" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

normalize_tag() {
  local v="$1"
  [[ "${v}" == "latest" ]] && die "请使用具体版本号（如 v2.10.0），不要用 latest"
  [[ "${v}" == v* ]] || v="v${v}"
  echo "${v}"
}

mirror_urls() {
  local github_url="$1"
  cat <<EOF
https://ghproxy.net/${github_url}
https://gh.llkk.cc/${github_url}
https://mirror.ghproxy.com/${github_url}
https://ghproxy.com/${github_url}
${github_url}
EOF
}

file_sha256() {
  sha256sum "$1" | awk '{print $1}'
}

verify_tarball() {
  local path="$1"
  local expect_sha="${2:-}"

  [[ -f "${path}" ]] || return 1
  [[ -s "${path}" ]] || return 1

  # 必须是 gzip
  if ! gzip -t "${path}" 2>/dev/null; then
    echo "==> 压缩包损坏（gzip 检查失败）: ${path}"
    return 1
  fi

  if [[ -n "${expect_sha}" ]]; then
    local got
    got="$(file_sha256 "${path}")"
    if [[ "${got}" != "${expect_sha}" ]]; then
      echo "==> SHA256 不匹配"
      echo "    期望: ${expect_sha}"
      echo "    实际: ${got}"
      return 1
    fi
    echo "==> SHA256 校验通过"
  else
    echo "==> 无内置校验和，已通过 gzip 完整性检查"
  fi
  return 0
}

# 组装兼容旧版 curl 的参数（Alibaba Cloud Linux 3 自带 curl 可能没有 --retry-all-errors）
curl_download() {
  # usage: curl_download <resume:0|1> <output> <url>
  local resume="$1"
  local output="$2"
  local url="$3"
  local -a args

  args=(-fL --connect-timeout 20 --retry 8 --retry-delay 3)
  # curl >= 7.71
  if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
    args+=(--retry-all-errors)
  fi
  if [[ "${resume}" == "1" ]]; then
    args+=(-C -)
  fi
  # 旧 curl 可能没有 --progress-bar 的稳定行为；有则用
  if curl --help 2>/dev/null | grep -q -- '--progress-bar'; then
    args+=(--progress-bar)
  fi
  args+=(-o "${output}" "${url}")
  curl "${args[@]}"
}

# 断点续传到 dest_part，成功后校验并原子移动到 dest_final
resume_download() {
  local url="$1"
  local dest_part="$2"
  local dest_final="$3"
  local expect_sha="${4:-}"
  local ec=0
  local existing=0

  mkdir -p "$(dirname "${dest_part}")"

  # 已有完整且校验通过的成品，直接成功
  if [[ -f "${dest_final}" ]] && verify_tarball "${dest_final}" "${expect_sha}"; then
    echo "==> 缓存已存在且有效: ${dest_final}"
    return 0
  fi

  if [[ -f "${dest_part}" ]]; then
    existing="$(wc -c <"${dest_part}" | tr -d ' ')"
    echo "==> 发现未完成下载 ${existing} 字节，尝试续传…"
  fi

  echo "==> 下载: ${url}"
  echo "    临时文件: ${dest_part}"

  set +e
  curl_download 1 "${dest_part}" "${url}"
  ec=$?
  set -e

  if [[ "${ec}" -eq 0 ]]; then
    if verify_tarball "${dest_part}" "${expect_sha}"; then
      mv -f "${dest_part}" "${dest_final}"
      echo "==> 下载完成: ${dest_final} ($(wc -c <"${dest_final}" | tr -d ' ') 字节)"
      return 0
    fi
    echo "==> 下载完成但校验失败，删除后换源重试"
    rm -f "${dest_part}" "${dest_final}"
    return 1
  fi

  # curl 33 = HTTP range not satisfiable（本地残片与远端不一致）→ 清掉重下
  if [[ "${ec}" -eq 33 ]]; then
    echo "==> 续传区间无效 (curl 33)，清除残片后整文件重下"
    rm -f "${dest_part}"
    set +e
    curl_download 0 "${dest_part}" "${url}"
    ec=$?
    set -e
    if [[ "${ec}" -eq 0 ]] && verify_tarball "${dest_part}" "${expect_sha}"; then
      mv -f "${dest_part}" "${dest_final}"
      echo "==> 下载完成: ${dest_final}"
      return 0
    fi
  fi

  existing=0
  [[ -f "${dest_part}" ]] && existing="$(wc -c <"${dest_part}" | tr -d ' ')"
  echo "==> 本源失败 (curl exit ${ec})，已下载 ${existing} 字节，换源时将继续续传"
  return 1
}

install_from_tarball() {
  local tarball="$1"
  local tmpdir bin

  need_root
  tmpdir="$(mktemp -d)"
  tar -xzf "${tarball}" -C "${tmpdir}"
  bin="$(find "${tmpdir}" -type f -name artalk | head -n 1 || true)"
  [[ -n "${bin}" && -f "${bin}" ]] || die "压缩包内找不到 artalk 可执行文件"
  install -d "${INSTALL_DIR}"
  install -m 755 "${bin}" "${INSTALL_DIR}/artalk"
  rm -rf "${tmpdir}"

  echo "==> 已安装 ${INSTALL_DIR}/artalk"
  if ! "${INSTALL_DIR}/artalk" version; then
    die "安装后运行 artalk version 失败（可能是架构不匹配或文件损坏）。
请检查: uname -m 与 file ${INSTALL_DIR}/artalk"
  fi
}

main() {
  local arch tag asset github_url expect_sha cache_final cache_part url ok

  arch="$(detect_arch)"
  echo "==> 架构: $(uname -m) → ${arch}"

  # 已安装且能跑，除非强制重装
  if [[ "${DOWNLOAD_ONLY}" -eq 0 \
      && -x "${INSTALL_DIR}/artalk" \
      && "${FORCE_ARTALK_REINSTALL:-0}" != "1" ]]; then
    if "${INSTALL_DIR}/artalk" version 2>/dev/null; then
      echo "==> 已存在可用的 ${INSTALL_DIR}/artalk，跳过下载（FORCE_ARTALK_REINSTALL=1 可强制重装）"
      return 0
    fi
    echo "==> 已有二进制无法运行（可能 SEGV），将重新下载"
  fi

  # 离线包
  if [[ -n "${ARTALK_TARBALL:-}" ]]; then
    [[ -f "${ARTALK_TARBALL}" ]] || die "ARTALK_TARBALL 不存在: ${ARTALK_TARBALL}"
    echo "==> 使用本地包: ${ARTALK_TARBALL}"
    if [[ "${DOWNLOAD_ONLY}" -eq 1 ]]; then
      echo "${ARTALK_TARBALL}"
      return 0
    fi
    install_from_tarball "${ARTALK_TARBALL}"
    return 0
  fi

  tag="$(normalize_tag "${VER_RAW}")"
  asset="artalk_${tag}_linux_${arch}.tar.gz"
  github_url="https://github.com/ArtalkJS/Artalk/releases/download/${tag}/${asset}"
  # key 形如 v2.10.0/amd64
  expect_sha="${KNOWN_SHA256[${tag}/${arch}]:-}"

  if ! mkdir -p "${CACHE_DIR}" 2>/dev/null; then
    CACHE_DIR="${TMPDIR:-/tmp}/garden-cache"
    mkdir -p "${CACHE_DIR}"
    echo "==> 无法写 ${ARTALK_CACHE_DIR:-/var/cache/garden}，改用 ${CACHE_DIR}"
  fi
  cache_final="${CACHE_DIR}/${asset}"
  cache_part="${CACHE_DIR}/${asset}.part"

  echo "==> 版本: ${tag}"
  echo "==> 文件: ${asset}"
  echo "==> 缓存目录: ${CACHE_DIR}"
  [[ -n "${expect_sha}" ]] && echo "==> 期望 SHA256: ${expect_sha}"

  if [[ -f "${cache_final}" ]] && verify_tarball "${cache_final}" "${expect_sha}"; then
    echo "==> 使用已缓存文件"
  else
    ok=0
    while IFS= read -r url; do
      [[ -n "${url}" ]] || continue
      if resume_download "${url}" "${cache_part}" "${cache_final}" "${expect_sha}"; then
        ok=1
        break
      fi
    done < <(mirror_urls "${github_url}")

    if [[ "${ok}" -ne 1 ]]; then
      die "所有镜像均失败。可稍后重跑本脚本（会从 ${cache_part} 续传）。
或在可访问 GitHub 的电脑下载后:
  scp ${asset} root@服务器:${CACHE_DIR}/
  ARTALK_TARBALL=${CACHE_DIR}/${asset} bash ${SCRIPT_DIR}/download-artalk.sh"
    fi
  fi

  if [[ "${DOWNLOAD_ONLY}" -eq 1 ]]; then
    echo "${cache_final}"
    return 0
  fi

  install_from_tarball "${cache_final}"
}

main "$@"
