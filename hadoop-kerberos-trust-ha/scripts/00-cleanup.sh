#!/bin/bash
# ============================================================
# 00-cleanup.sh [--purge] —— 清理 HA 环境
#
#   默认：停止并删除所有 HA 容器、数据卷、外部网络
#   --purge：额外删除 scripts/01-init-kdc.sh 生成的 keytab 与
#            krb5.conf（回到"全新未初始化"状态）
#
# 注意：HA 版数据卷含 NameNode 元数据（namenode-a1-data 等）与
#       JournalNode 编辑日志（jn1-data 等），默认即删除（down -v），
#       下次启动会重新初始化（nn1 重新格式化）。
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

echo "==> 停止 HA 集群（ZK/JN/双 NN/DN/YARN）并删除数据卷 ..."
(cd ha && $DC -f docker-compose.yml down -v) 2>/dev/null || true

echo "==> 停止双 KDC ..."
(cd kerberos && $DC down -v) 2>/dev/null || true

echo "==> 删除外部网络 hadoop-kerberos-net ..."
docker network rm hadoop-kerberos-net 2>/dev/null || true

if [ "$PURGE" = "--purge" ]; then
  echo "==> 清理生成的 keytab 与 krb5.conf ..."
  rm -f ha/kerberos/*.keytab ha/kerberos/krb5.conf
  rm -f ha/kerberos1/*.keytab ha/kerberos1/krb5.conf
fi

echo "清理完成"
