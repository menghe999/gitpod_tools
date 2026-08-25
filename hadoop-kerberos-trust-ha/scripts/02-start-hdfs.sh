#!/bin/bash
# ============================================================
# 02-start-hdfs.sh —— 启动双 HDFS HA 集群（ZK + QJM + 双 NN 自动故障转移）
#
# 启动顺序（分阶段，确保 HA 初始化正确）：
#   1) 共享层：zk1 + jn1/jn2/jn3（QJM 仲裁，先于 NN）
#   2) 双 NameNode：namenode-a1/a2、namenode-b1/b2
#      （nn1 格式化并初始化 QJM/ZK，nn2 bootstrapStandby 后成为 standby）
#   3) DataNode 与 YARN（RM/NM）
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
COMPOSE="ha/docker-compose.yml"

# ---------- 预检 ----------
echo "==> 预检：KDC 初始化产物是否齐全 =="
MISSING=0
for f in \
  ha/kerberos/krb5.conf ha/kerberos/nn1.keytab ha/kerberos/nn2.keytab \
  ha/kerberos/dn.keytab ha/kerberos/jn.keytab \
  ha/kerberos/rm.keytab ha/kerberos/nm.keytab ha/kerberos/test.keytab \
  ha/kerberos1/krb5.conf ha/kerberos1/nn1.keytab ha/kerberos1/nn2.keytab \
  ha/kerberos1/dn.keytab ha/kerberos1/test1.keytab; do
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

# ---------- 1) 启动共享层：ZK + JournalNode ----------
echo
echo "==> [1/3] 启动共享层 zk1 + jn1/jn2/jn3 =="
$DC -f "$COMPOSE" up -d zk1 jn1 jn2 jn3

echo "  等待 JournalNode RPC (8485) 就绪 ..."
for i in $(seq 1 60); do
  READY=1
  for jn in jn1 jn2 jn3; do
    if ! docker exec "$jn" bash -c '(exec 3<>/dev/tcp/localhost/8485) 2>/dev/null' 2>/dev/null; then
      READY=0
      break
    fi
  done
  [ "$READY" -eq 1 ] && break
  # 每 6 轮（30 秒）打印一次进度，避免容器 restarting 时静默超时
  if [ $((i % 6)) -eq 0 ]; then
    echo "  仍在等待 JN 就绪（已 $((i*5)) 秒），jn1 状态: $(docker ps -a --filter name=jn1 --format '{{.Status}}')"
  fi
  sleep 5
done
if [ "$READY" -ne 1 ]; then
  echo "错误: JournalNode 在 300 秒内未就绪，请检查: docker logs jn1 jn2 jn3" >&2
  exit 1
fi
echo "  3 台 JournalNode 已就绪"

# ---------- 2) 启动双 NameNode ----------
echo
echo "==> [2/3] 启动 4 台 NameNode（双集群 HA）=="
$DC -f "$COMPOSE" up -d namenode-a1 namenode-a2 namenode-b1 namenode-b2

wait_nn() {
  local c="$1"
  echo "  等待 $c (NameNode RPC) 就绪 ..."
  for i in $(seq 1 96); do   # 最长 480 秒（含 format + bootstrapStandby）
    if docker logs "$c" 2>&1 | grep -qE "NameNode RPC (up at|server is running|就绪)"; then
      echo "  $c RPC 已就绪"
      return 0
    fi
    sleep 5
  done
  echo "  $c 未在 480 秒内就绪，最近日志：" >&2
  docker logs "$c" 2>&1 | tail -30 >&2
  return 1
}
wait_nn namenode-a1 || exit 1
wait_nn namenode-a2 || exit 1
wait_nn namenode-b1 || exit 1
wait_nn namenode-b2 || exit 1

# ---------- 3) 启动 DataNode 与 YARN（含 flink-client 客户端容器） ----------
echo
echo "==> [3/3] 启动 DataNode 与 YARN (RM/NM) + flink-client =="
$DC -f "$COMPOSE" up -d datanode datanode1 resourcemanager nodemanager flink-client

echo
echo "=============================================="
echo " 双 HDFS HA 集群已启动！"
echo " 等 NameNode 退出安全模式并完成故障转移初始化后执行验证："
echo "   bash scripts/03-verify.sh"
echo " Flink 跨集群示例（可选）："
echo "   bash scripts/04-flink-setup.sh && bash scripts/05-flink-demo.sh"
echo "=============================================="
