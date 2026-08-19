#!/bin/bash
# ============================================================
# 03-verify.sh —— 自动验证双集群 Kerberos 跨域互信
#
# 验证点（双向）：
#   - 集群 A 用户 test@EMR.1234.COM  访问本域(集群 A) ✓
#   - 集群 A 用户 test@EMR.1234.COM  跨域访问集群 B   ✓
#   - 集群 B 用户 test1@EMR.6789.COM 访问本域(集群 B) ✓
#   - 集群 B 用户 test1@EMR.6789.COM 跨域访问集群 A   ✓
#
# 退出码：全部通过返回 0，任一失败返回 1。
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# run <容器> <描述> <命令...>
run() {
  local c="$1" desc="$2"
  shift 2
  if docker exec "$c" bash -c "$*" >"$TMP" 2>&1; then
    ok "$desc"
    return 0
  else
    bad "$desc"
    sed 's/^/          | /' "$TMP" | tail -15
    return 1
  fi
}

# ---------- 0) 容器存活检查 ----------
echo "==> 检查容器状态 =="
for c in kdc1 kdc2 namenode namenode1; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
    echo "容器 $c 未运行，请先执行: bash scripts/01-init-kdc.sh 和 bash scripts/02-start-hdfs.sh" >&2
    exit 1
  fi
done
echo "  4 个关键容器均在运行"

# ---------- 1) 确保 kinit/klist 可用（缺少则安装 krb5-user） ----------
ensure_kinit() {
  local c="$1" host_conf="$2"
  if docker exec "$c" bash -c 'command -v kinit >/dev/null 2>&1'; then
    return 0
  fi
  echo "  [$c] 缺少 krb5-user，从 stretch 归档源安装（可能较慢）..."
  # 备份宿主机上挂载的 krb5.conf，防止 apt 安装时改写
  cp "$host_conf" "${host_conf}.bak"
  docker exec "$c" bash -c '
    echo "deb http://archive.debian.org/debian stretch main contrib non-free" > /etc/apt/sources.list
    echo "deb http://archive.debian.org/debian-security stretch/updates main contrib non-free" >> /etc/apt/sources.list
    echo "Acquire::Check-Valid-Until false;" > /etc/apt/apt.conf.d/99no-check-valid-until
    DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y krb5-user >/dev/null 2>&1
  '
  cp "${host_conf}.bak" "$host_conf" && rm -f "${host_conf}.bak"
  if ! docker exec "$c" bash -c 'command -v kinit >/dev/null 2>&1'; then
    echo "  [$c] krb5-user 安装失败，请检查网络（archive.debian.org 可达性）" >&2
    exit 1
  fi
  echo "  [$c] krb5-user 就绪"
}
ensure_kinit namenode  hdfs/kerberos/krb5.conf
ensure_kinit namenode1 hdfs/kerberos1/krb5.conf

# ---------- 2) 等待 NameNode 就绪 ----------
wait_nn() {
  local c="$1"
  echo "  等待 $c (NameNode RPC) 就绪 ..."
  # 兼容 Hadoop 2.x("server is running") 与 3.x("RPC up at") 两种日志格式
  for i in $(seq 1 72); do
    if docker logs "$c" 2>&1 | grep -qE "NameNode RPC (up at|server is running)"; then
      echo "  $c RPC 已就绪"
      # 等待安全模式关闭（否则 mkdir 会被 SafeModeException 拒绝）
      for j in $(seq 1 24); do
        if docker logs "$c" 2>&1 | grep -q "Safe mode is OFF"; then
          echo "  $c 安全模式已关闭"
          return 0
        fi
        sleep 5
      done
      echo "  $c RPC 已就绪，但安全模式在 120 秒内未关闭（继续执行，若后续 mkdir 失败请检查）"
      return 0
    fi
    sleep 5
  done
  echo "  $c 未在 360 秒内就绪，最近日志：" >&2
  docker logs "$c" 2>&1 | tail -25 >&2
  return 1
}
wait_nn namenode  || exit 1
wait_nn namenode1 || exit 1

# ---------- 3) 双向验证 ----------
echo
echo "=============================================="
echo " 集群 A 视角（namenode 容器，用户 test@EMR.1234.COM）"
echo "=============================================="
run namenode "kinit test 获取本域 TGT"                    kinit -kt /root/test.keytab test
run namenode "本域访问: 在集群A创建 /user/test"           hdfs dfs -mkdir -p hdfs://namenode.emr.1234.com:9000/user/test
run namenode "本域访问: 列出集群A /user"                  hdfs dfs -ls hdfs://namenode.emr.1234.com:9000/user
run namenode "跨域访问: 在集群B创建 /user/test1"          hdfs dfs -mkdir -p hdfs://namenode.emr.6789.com:9000/user/test1
run namenode "跨域访问: 列出集群B /user"                  hdfs dfs -ls hdfs://namenode.emr.6789.com:9000/user

echo
echo "=============================================="
echo " 集群 B 视角（namenode1 容器，用户 test1@EMR.6789.COM）"
echo "=============================================="
run namenode1 "kinit test1 获取本域 TGT"                  kinit -kt /root/test1.keytab test1
run namenode1 "本域访问: 在集群B创建 /user/test1"         hdfs dfs -mkdir -p hdfs://namenode.emr.6789.com:9000/user/test1
run namenode1 "本域访问: 列出集群B /user"                 hdfs dfs -ls hdfs://namenode.emr.6789.com:9000/user
run namenode1 "跨域访问: 在集群A创建 /user/test"          hdfs dfs -mkdir -p hdfs://namenode.emr.1234.com:9000/user/test
run namenode1 "跨域访问: 列出集群A /user"                 hdfs dfs -ls hdfs://namenode.emr.1234.com:9000/user

# ---------- 4) 票据信息（展示跨域 TGT） ----------
echo
echo "=============================================="
echo " 票据信息（klist）"
echo "=============================================="
echo "--- namenode (test@EMR.1234.COM) ---"
docker exec namenode bash -c 'klist -e' 2>&1 || true
echo "--- namenode1 (test1@EMR.6789.COM) ---"
docker exec namenode1 bash -c 'klist -e' 2>&1 || true

# ---------- 5) 汇总 ----------
echo
echo "=============================================="
echo " 验证结果: PASS=$PASS  FAIL=$FAIL"
echo "=============================================="
if [ "$FAIL" -eq 0 ]; then
  echo " ✅ 双 KDC 跨域互信验证全部通过！"
  echo "    test@EMR.1234.COM 与 test1@EMR.6789.COM 均能互访对方集群。"
else
  echo " ❌ 存在失败项，请查看上方 [FAIL] 输出，参考 docs/03-常见问题.md"
fi
exit "$FAIL"
