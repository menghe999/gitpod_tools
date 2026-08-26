#!/bin/bash
# ============================================================
# install-krb5.sh —— 容器内确保 krb5-client（kinit/klist/kdestroy）可用
#
# 背景：bde2020/hadoop-*（Debian stretch 系）与 zookeeper:3.8 等镜像默认
# 未预装 krb5-user，容器里没有 kinit 命令（见 FAQ Q13）。本脚本在容器
# 启动时由 start-nn.sh / start-jn.sh / container-entry.sh 调用（后台、幂等），
# 也供 scripts/03-verify.sh 的 ensure_kinit() 前台兜底使用。
#
# 特性：
#   - 幂等：kinit 已存在则立即返回（重启秒过，不会重复 apt）；
#   - 多发行版：Debian/Ubuntu 用 apt 装 krb5-user；RHEL/CentOS 用 yum 装
#     krb5-workstation（kdc1/kdc2 的 centos:7 已内置，无需再装）；
#   - EOL 发行版（Debian stretch 等）自动把 apt 源改写为 archive.debian.org
#     并关闭 valid-until 校验（与 03-verify.sh 原 ensure_kinit 同款做法）；
#   - 防并发：mkdir 原子锁 + pid 残留检测（容器重启时不会叠加 apt 进程）；
#   - 安装前备份 /etc/krb5.conf（本仓库是 bind mount，apt 的 postinst 可能
#     改写它），安装后恢复；
#   - best-effort：失败仅返回非 0 并输出日志，绝不阻塞容器主进程启动。
#
# 用法：
#   /root/install-krb5.sh                          # 前台（03-verify.sh 兜底用）
#   /root/install-krb5.sh >/tmp/install-krb5.log 2>&1 &   # 后台（容器启动时用）
# ============================================================
set -uo pipefail

log() { echo "[install-krb5] $*"; }

# ---------- 幂等：已有 kinit 直接返回 ----------
if command -v kinit >/dev/null 2>&1; then
  exit 0
fi

# ---------- 防并发锁（mkdir 原子性；pid 残留检测防容器重启后的死锁） ----------
LOCK=/tmp/install-krb5.lock
LOCK_TAKEN=0
if mkdir "$LOCK" 2>/dev/null; then
  echo $$ > "$LOCK/pid"
  LOCK_TAKEN=1
else
  oldpid="$(cat "$LOCK/pid" 2>/dev/null || echo 0)"
  if [ "$oldpid" -gt 1 ] 2>/dev/null && kill -0 "$oldpid" 2>/dev/null; then
    log "另一个 install-krb5 实例正在运行（pid=$oldpid），跳过"
    exit 0
  fi
  # 残留锁：持有进程已不存在（如容器重启被 SIGKILL），清理后重试
  rm -rf "$LOCK"
  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    LOCK_TAKEN=1
  else
    log "获取锁失败，跳过"
    exit 0
  fi
fi

# ---------- 备份 /etc/krb5.conf（apt 的 krb5-user postinst 可能改写） ----------
KRB5_BAK=""
if [ -f /etc/krb5.conf ]; then
  KRB5_BAK="$(mktemp /tmp/krb5.conf.bak.XXXXXX)"
  cp -p /etc/krb5.conf "$KRB5_BAK"
fi

cleanup() {
  if [ -n "$KRB5_BAK" ] && [ -f "$KRB5_BAK" ]; then
    cp -p "$KRB5_BAK" /etc/krb5.conf 2>/dev/null || true
    rm -f "$KRB5_BAK"
  fi
  [ "$LOCK_TAKEN" = "1" ] && rm -rf "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT

# ---------- 探测发行版 ----------
ID=""
VERSION_CODENAME=""
[ -r /etc/os-release ] && . /etc/os-release
ID="${ID:-unknown}"
CODENAME="${VERSION_CODENAME:-}"
log "发行版: ID=${ID} CODENAME=${CODENAME:-（未知）}"

# ---------- Debian/Ubuntu：apt 装 krb5-user ----------
install_apt() {
  # EOL 发行版（stretch/buster 等）官方源已下线，改写为 archive.debian.org
  case "${ID}:${CODENAME}" in
    debian:stretch|debian:buster)
      log "检测到 EOL 发行版 ${CODENAME}，apt 源改写为 archive.debian.org"
      cat > /etc/apt/sources.list <<EOF
deb http://archive.debian.org/debian ${CODENAME} main contrib non-free
deb http://archive.debian.org/debian-security ${CODENAME}/updates main contrib non-free
EOF
      echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until
      ;;
    *)
      # Ubuntu / 新 Debian：保持镜像自带源，不做改动
      ;;
  esac

  # 网络不佳时快速失败，避免长时间挂起
  cat > /etc/apt/apt.conf.d/99krb5-timeout <<'EOF'
Acquire::http::Timeout "15";
Acquire::Retries "2";
EOF

  APT_LOG=/tmp/install-krb5-apt.log
  log "apt-get update ..."
  if ! DEBIAN_FRONTEND=noninteractive timeout 180 apt-get update >"$APT_LOG" 2>&1; then
    log "apt-get update 失败（网络不可达？详见容器内 $APT_LOG），仍尝试 install"
  fi

  log "apt-get install krb5-user ..."
  if ! DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y --no-install-recommends krb5-user >>"$APT_LOG" 2>&1; then
    log "apt-get install krb5-user 失败（详见容器内 $APT_LOG）："
    tail -20 "$APT_LOG" | sed 's/^/    /'
    return 1
  fi
  command -v kinit >/dev/null 2>&1
}

# ---------- RHEL/CentOS：yum 装 krb5-workstation ----------
install_yum() {
  log "yum install krb5-workstation ..."
  if ! timeout 300 yum install -y krb5-workstation >/dev/null 2>&1; then
    log "yum install krb5-workstation 失败"
    return 1
  fi
  command -v kinit >/dev/null 2>&1
}

if command -v apt-get >/dev/null 2>&1; then
  install_apt || { log "安装失败（best-effort，不阻塞容器启动）"; exit 1; }
elif command -v yum >/dev/null 2>&1; then
  install_yum || { log "安装失败（best-effort，不阻塞容器启动）"; exit 1; }
else
  log "未识别的包管理器（无 apt-get/yum），跳过"
  exit 1
fi

if command -v kinit >/dev/null 2>&1; then
  log "krb5-user 就绪: $(command -v kinit)"
  exit 0
fi
log "安装完成后仍未找到 kinit"
exit 1
