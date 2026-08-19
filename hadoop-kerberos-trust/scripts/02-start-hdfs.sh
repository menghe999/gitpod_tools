#!/bin/bash
# ============================================================
# 02-start-hdfs.sh —— 启动双 HDFS 集群（Kerberos 安全模式）
#
# 前置：先执行 scripts/01-init-kdc.sh（生成 krb5.conf 与 keytab）
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 兼容 docker compose v2 / docker-compose v1
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  DC="docker-compose"
fi

# ---------- 预检 ----------
echo "==> 预检：KDC 初始化产物是否齐全 =="
MISSING=0
for f in \
  hdfs/kerberos/krb5.conf hdfs/kerberos/nn.keytab hdfs/kerberos/dn.keytab \
  hdfs/kerberos/rm.keytab hdfs/kerberos/nm.keytab hdfs/kerberos/test.keytab \
  hdfs/kerberos1/krb5.conf hdfs/kerberos1/nn.keytab hdfs/kerberos1/dn.keytab \
  hdfs/kerberos1/rm.keytab hdfs/kerberos1/nm.keytab hdfs/kerberos1/test1.keytab; do
  if [ ! -f "$f" ]; then
    echo "  缺少: $f" >&2
    MISSING=1
  fi
done
if [ "$MISSING" -eq 1 ]; then
  echo "请先执行: bash scripts/01-init-kdc.sh" >&2
  exit 1
fi

if ! docker network inspect hadoop-kerberos-net >/dev/null 2>&1; then
  echo "外部网络 hadoop-kerberos-net 不存在，请先执行: bash scripts/01-init-kdc.sh" >&2
  exit 1
fi
echo "  预检通过"

# ---------- 启动集群 A（EMR.1234.COM） ----------
echo
echo "==> 启动集群 A (EMR.1234.COM) =="
(cd hdfs && $DC -p hdfs-a -f docker-compose.yml up -d)

# ---------- 启动集群 B（EMR.6789.COM） ----------
echo
echo "==> 启动集群 B (EMR.6789.COM) =="
(cd hdfs && $DC -p hdfs-b -f docker-compose-1.yml up -d)

echo
echo "=============================================="
echo " 双 HDFS 集群已启动！"
echo " 等待 NameNode 就绪后执行验证："
echo "   bash scripts/03-verify.sh"
echo "=============================================="
