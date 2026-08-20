#!/bin/bash
# ============================================================
# start-jn.sh —— JournalNode 启动脚本（HDFS HA 共享 QJM）
#
# 一台 JN 同时服务两个 nameservice（ns1234 / ns6789），
# 编辑日志按 nameservice 子目录隔离存储（QJM 协议自动处理）。
# Kerberos 主体：jn/_HOST@EMR.1234.COM（keytab 含 jn1/jn2/jn3 三个主体）
# ============================================================
set -e

log()  { echo "[JN] $*"; }
fail() { echo "[JN] 错误: $*" >&2; exit 1; }

# ---------- 主机名修正：确保 canonical hostname = FQDN ----------
# 背景：docker 内 JVM 反向解析本容器 IP 时可能得到短主机名（jn2 而非
# jn2.emr.1234.com），导致守护进程按 jn/jn2@EMR.1234.COM 登录（keytab 里只有
# jn/jn2.emr.1234.com@EMR.1234.COM）失败：
#   KerberosAuthException: failure to login: for principal: jn/jn2@EMR.1234.COM
#     ... LoginException: Unable to obtain password from user
# 容器因此反复重启（exit 255），02 脚本 JN 就绪检查超时。
# 修复：把本容器 IP→FQDN 显式写入 /etc/hosts（NSS files 优先于 docker DNS），
# 并断言反向解析结果；不匹配立即报错，避免静默重启循环。
FQDN="$(cat /etc/hostname 2>/dev/null || hostname)"
IP="$(getent hosts "$FQDN" | awk '{print $1}' | head -1)"
[ -n "$IP" ] || IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
SHORT="$(echo "$FQDN" | cut -d. -f1)"

if [ -n "$IP" ] && [ -n "$FQDN" ]; then
  # 不能用 sed -i：/etc/hosts 是 bind mount，sed -i 的 rename 覆盖会报
  # "Device or resource busy" 失败（被 || true 吞掉），旧行删不掉。
  # 用 cat 原地重写（truncate+write，不 rename），保证该 IP 的第一条记录是 FQDN。
  {
    grep -vE "^${IP}[[:space:]]" /etc/hosts \
      | grep -vE "[[:space:]]${SHORT}([[:space:]]|\$)"
    echo "$IP $FQDN $SHORT"
  } > /etc/hosts.jnfix
  cat /etc/hosts.jnfix > /etc/hosts
  rm -f /etc/hosts.jnfix
fi

CANON="$(getent hosts "$IP" 2>/dev/null | awk '{print $2}' | head -1)"
log "hostname=$FQDN ip=$IP canonical=$CANON"
if [ -z "$CANON" ] || [ "$CANON" != "$FQDN" ]; then
  fail "canonical hostname 解析为 '${CANON:-空}'（期望 '$FQDN'），Kerberos 主体会变成 jn/$SHORT@REALM 导致登录失败"
fi

echo "=== [JN] 启动 JournalNode（hdfs journalnode）==="
exec hdfs journalnode
