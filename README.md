# obsidian-deploy

在 **阿里云 Linux 3**（OpenAnolis / `dnf`）上，自建一个**必须登录才能看**的 Obsidian 文档站。

- 编辑：本机 Obsidian 写作，经 SSH 推送到服务器私有 Git 仓库  
- 网站：Quartz（双链、搜索、标签、图谱）  
- 登录：Nginx Basic Auth（每人独立账号密码）  
- 评论：Artalk + SQLite（读者填昵称，无需 GitHub）  
- 不公开：`private/` 目录，或文首 `draft: true`

本仓库**只放安装程序和说明**。笔记正文、网站密码、SSH 私钥不要提交到这里。

## 服务器装好后的路径

| 路径 | 内容 |
| --- | --- |
| `/root/garden-deploy` | 本仓库（`git clone`） |
| `/home/garden/vault.git` | 笔记裸仓库 |
| `/home/garden/vault` | 构建用工作副本 |
| `/opt/quartz` | Quartz |
| `/var/www/garden` | 已发布网页 |
| `/var/lib/artalk` | 评论数据 |
| `/root/garden-passwords.txt` | 安装时生成的初始密码 |

## 1. 在服务器上安装

系统：Alibaba Cloud Linux 3。域名 A 记录指向该机公网 IP。建议先加安全组放行 22 / 80 / 443。

```bash
# 以 root 登录后
dnf -y install git
git clone https://github.com/hhelibib/obsidian-deploy.git /root/garden-deploy
cd /root/garden-deploy

export DOMAIN=你的域名.example.com
export EMAIL=你的邮箱@example.com   # 可选，用于 Let's Encrypt
bash deploy/install.sh
```

安装脚本会：

1. 加 2GB 交换分区  
2. 用 `dnf` 安装 Nginx、Git、certbot 等，并安装 Node.js 22  
3. 创建 `garden` 用户与 `/home/garden/vault.git`  
4. 安装 Quartz 与 Artalk（仅监听 `127.0.0.1:23366`）  
5. 配置 Nginx Basic Auth + `/artalk/` 反代  
6. 用示例笔记做首次构建  
7. 申请证书（失败则暂时 HTTP，可稍后重试）

初始两套网站密码在 `/root/garden-passwords.txt`（权限 600）。

临时跳过证书：

```bash
SKIP_TLS=1 DOMAIN=你的域名.example.com bash deploy/install.sh
```

### 若卡在 / 失败于「安装 Artalk」

Artalk **不是 yum 包**，要从 GitHub Releases 下载。文件名必须带 **`v`**：

`artalk_v2.10.0_linux_amd64.tar.gz`（不是 `artalk_2.10.0_...`）

**方案 A — 服务器上用代理（推荐先试）：**

```bash
cd /tmp
curl -fL -o artalk.tar.gz \
  https://ghproxy.net/https://github.com/ArtalkJS/Artalk/releases/download/v2.10.0/artalk_v2.10.0_linux_amd64.tar.gz
tar -xzf artalk.tar.gz
install -m 755 artalk_v2.10.0_linux_amd64/artalk /usr/local/bin/artalk
artalk version
DOMAIN=你的域名 bash deploy/install.sh
```

**方案 B — 本机能访问 GitHub 时，下载后 scp 上去：**

```bash
# 本机
curl -fL -O https://github.com/ArtalkJS/Artalk/releases/download/v2.10.0/artalk_v2.10.0_linux_amd64.tar.gz
scp artalk_v2.10.0_linux_amd64.tar.gz root@你的服务器IP:/tmp/

# 服务器
ARTALK_TARBALL=/tmp/artalk_v2.10.0_linux_amd64.tar.gz \
  DOMAIN=你的域名 bash /root/garden-deploy/deploy/install.sh
```

阿里云/腾讯云 yum 镜像解决不了这一步。

### 若报错 `Unable to find a match: nginx`

国内 ECS 常访问不了 `nginx.org`。请优先用 **Anolis/阿里云模块源**（不依赖 nginx.org）：

```bash
dnf -y module reset nginx
dnf -y module enable nginx:1.22
dnf -y module install nginx:1.22
nginx -v
```

若模块流不可用，直接装阿里云镜像上的 RPM：

```bash
VER='1.22.1-1.0.2.module+an8.9.0+11165+32bf18ca'
BASE='https://mirrors.aliyun.com/anolis/8.9/AppStream/x86_64/os/Packages'
dnf -y install \
  "${BASE}/nginx-filesystem-${VER}.noarch.rpm" \
  "${BASE}/nginx-${VER}.x86_64.rpm"
```

装好后再重新跑 `bash deploy/install.sh`。

## 2. 两种权限

| 权限 | 能做什么 | 命令 |
| --- | --- | --- |
| 网站账号 | 只能看已发布页面和评论 | `bash deploy/add-reader.sh <用户名>` |
| Git 密钥 | 改笔记；本机可见 `private/` | `bash deploy/add-editor.sh <名称> /path/to/id_ed25519.pub` |

```bash
# 读者（浏览器登录）
bash /root/garden-deploy/deploy/add-reader.sh alice

# 编辑（把对方公钥拷到服务器后）
bash /root/garden-deploy/deploy/add-editor.sh bob /root/bob.pub
```

编辑者在 Obsidian Git 插件里添加远程，例如：

```text
garden@你的域名:/home/garden/vault.git
```

推送到 `main` 后，服务器 `post-receive` 会自动重建站点。也可手动：

```bash
bash /root/garden-deploy/deploy/rebuild.sh
```

说明：

- 编辑之间不能互相隐藏笔记  
- 收回密钥删不掉对方电脑上已克隆的副本  
- 同时改同一篇会冲突，需先拉取再解决  

## 3. 不公开的笔记

任选其一：

- 放进库根目录的 `private/`（任意层级的 `private` 文件夹也会被忽略）  
- 在 Markdown 文首写：

```yaml
---
draft: true
---
```

图片等非 Markdown 附件若不想上线，也请放在 `private/` 内。

## 4. 更新安装脚本

```bash
cd /root/garden-deploy
git pull
bash deploy/apply-quartz-overlay.sh /opt/quartz "$(cat /etc/garden/domain)"
bash deploy/rebuild.sh
```

## 5. 本地验证构建（可选）

在有 Node.js 的机器上，不装 Nginx，只验证示例库构建与过滤：

```bash
bash deploy/verify-local-build.sh
```

预期：`private/` 与 `draft: true` 的笔记不会出现在生成结果里。

## 目录说明

```text
deploy/
  install.sh              # 服务器一键安装
  rebuild.sh              # 重建站点
  add-reader.sh           # 添加网站读者
  add-editor.sh           # 添加 Git 编辑者
  setup-swap.sh           # 2GB swap
  verify-local-build.sh   # 本地构建冒烟
  apply-quartz-overlay.sh # 覆盖 Quartz 配置与评论组件
  nginx/                  # Nginx 模板
  artalk/                 # Artalk 配置模板
  systemd/artalk.service
  quartz/                 # Quartz 覆盖层（含 Artalk 评论）
  hooks/post-receive      # 推送后重建
  sample-vault/           # 示例笔记
  lib/common.sh
docs/对话摘要.md          # 方案备忘
```

## 刻意不做的事

不在这台机器上跑：CouchDB 同步、思源、数据库型维基、整套独立登录中心。笔记不推到 GitHub。
