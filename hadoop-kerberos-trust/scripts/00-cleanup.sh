#!/bin/bash
# ============================================================
# 00-cleanup.sh [--purge] —— 清理环境
#
#   默认：停止并删除所有容器、数据卷、外部网络
#   --purge：额外删除 scripts/01-init-kdc.sh 生成的 keytab 与
#            krb5.conf（回到"全新未初始化"状态）
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PURGE="${1:-}"

# 兼容 docker compose v2 / docker-compose v1
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  DC="docker-compose"
fi

echo "==> 停止 HDFS 集群 A/B 并删除数据卷 ..."
(cd hdfs && $DC -p hdfs-a -f docker-compose.yml down -v) 2>/dev/null || true
(cd hdfs && $DC -p hdfs-b -f docker-compose-1.yml down -v) 2>/dev/null || true

echo "==> 停止双 KDC ..."
(cd kerberos && $DC down -v) 2>/dev/null || true

echo "==> 删除外部网络 hadoop-kerberos-net ..."
docker network rm hadoop-kerberos-net 2>/dev/null || true

if [ "$PURGE" = "--purge" ]; then
  echo "==> 清理生成的 keytab 与 krb5.conf ..."
  rm -f hdfs/kerberos/*.keytab hdfs/kerberos/krb5.conf
  rm -f hdfs/kerberos1/*.keytab hdfs/kerberos1/krb5.conf
fi

echo "清理完成"
