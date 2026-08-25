#!/bin/bash
# ============================================================
# 03-verify.sh —— 自动验证双集群 HDFS HA + Kerberos 跨域互信
#
# 验证点：
#   [HA] 每集群双 NameNode：nn1 active / nn2 standby（ZKFC 自动故障转移）
#   [HA] 故障转移演练：停止 active NN → standby 自动接管 → 代理访问/数据读取仍可用
#   [域] 本域访问走 nameservice（hdfs://ns1234 / hdfs://ns6789，故障转移代理）
#   [域] 跨域访问（test@EMR.1234.COM 访问集群 B，test1@EMR.6789.COM 访问集群 A）
#   [域] 跨域铁证：A 在 B 创建标记、B 本域可见；B 在 A 创建标记、A 本域可见
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

# nn_state <容器> <nameservice> <nnid> <用户> -> active|standby|""
nn_state() {
  docker exec "$1" bash -c \
    "kinit -kt /root/$4.keytab $4 >/dev/null 2>&1; \
     hdfs haadmin -ns $2 -getServiceState $3 2>/dev/null" | tr -d ' \n'
}

# check_state <容器> <nameservice> <nnid> <用户> <期望状态> <描述>
check_state() {
  local st
  st="$(nn_state "$1" "$2" "$3" "$4")"
  if [ "$st" = "$5" ]; then
    ok "${6}（实际: ${st}）"
  else
    bad "$6（期望: $5，实际: ${st:-空}）"
  fi
}

# wait_state <容器> <nameservice> <nnid> <用户> <期望状态> <描述> [轮数x5s]
wait_state() {
  local i st
  for i in $(seq 1 "${7:-24}"); do
    st="$(nn_state "$1" "$2" "$3" "$4")"
    if [ "$st" = "$5" ]; then
      ok "$6"
      return 0
    fi
    sleep 5
  done
  bad "$5（超时，最后状态: ${st:-空}）"
  return 1
}

# ---------- 0) 容器存活检查 ----------
echo "==> 检查容器状态 =="
for c in kdc1 kdc2 zk1 jn1 jn2 jn3 \
         namenode-a1 namenode-a2 namenode-b1 namenode-b2 \
         datanode datanode1 resourcemanager nodemanager flink-client; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
    echo "容器 $c 未运行，请先执行: bash scripts/01-init-kdc.sh 和 bash scripts/02-start-hdfs.sh" >&2
    exit 1
  fi
done
echo "  15 个关键容器均在运行"

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
ensure_kinit namenode-a1 ha/kerberos/krb5.conf
ensure_kinit namenode-b1 ha/kerberos1/krb5.conf

# ---------- 2) 等待 4 台 NameNode 就绪 ----------
wait_nn() {
  local c="$1"
  echo "  等待 $c (NameNode RPC) 就绪 ..."
  for i in $(seq 1 96); do   # 最长 480 秒
    if docker logs "$c" 2>&1 | grep -qE "NameNode RPC (up at|server is running)"; then
      echo "  $c RPC 已就绪"
      for j in $(seq 1 24); do
        if docker logs "$c" 2>&1 | grep -qE "Safe mode is OFF|Leaving safe mode"; then
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
  echo "  $c 未在 480 秒内就绪，最近日志：" >&2
  docker logs "$c" 2>&1 | tail -30 >&2
  return 1
}
wait_nn namenode-a1 || exit 1
wait_nn namenode-a2 || exit 1
wait_nn namenode-b1 || exit 1
wait_nn namenode-b2 || exit 1

# ---------- 3) 集群 A 视角（用户 test@EMR.1234.COM） ----------
echo
echo "=============================================="
echo " 集群 A 视角（namenode-a1，用户 test@EMR.1234.COM / ns1234）"
echo "=============================================="
run namenode-a1 "kinit test 获取本域 TGT"                 kinit -kt /root/test.keytab test
check_state namenode-a1 ns1234 nn1 test active  "HA: nn1 为 active"
check_state namenode-a1 ns1234 nn2 test standby "HA: nn2 为 standby"
run namenode-a1 "本域访问: 经代理在集群A创建 /user/test"  hdfs dfs -mkdir -p hdfs://ns1234/user/test
run namenode-a1 "本域访问: 经代理列出集群A /user"         hdfs dfs -ls hdfs://ns1234/user
run namenode-a1 "写入数据文件（供故障转移后读取验证）"    bash -c 'echo "ha-test-data-1234" | hdfs dfs -put - hdfs://ns1234/user/test/ha-file.txt'
run namenode-a1 "跨域访问: 在集群B创建 /user/test1"       hdfs dfs -mkdir -p hdfs://nn1.emr.6789.com:9000/user/test1
run namenode-a1 "跨域访问: 列出集群B /user"              hdfs dfs -ls hdfs://nn1.emr.6789.com:9000/user
run namenode-a1 "跨域写入: test 在集群B创建标记 A2B"      hdfs dfs -mkdir -p hdfs://nn1.emr.6789.com:9000/user/cross-check-A2B

# ---------- 4) 集群 B 视角（用户 test1@EMR.6789.COM） ----------
echo
echo "=============================================="
echo " 集群 B 视角（namenode-b1，用户 test1@EMR.6789.COM / ns6789）"
echo "=============================================="
run namenode-b1 "kinit test1 获取本域 TGT"                kinit -kt /root/test1.keytab test1
check_state namenode-b1 ns6789 nn1 test1 active  "HA: nn1 为 active"
check_state namenode-b1 ns6789 nn2 test1 standby "HA: nn2 为 standby"
run namenode-b1 "本域访问: 经代理在集群B创建 /user/test1" hdfs dfs -mkdir -p hdfs://ns6789/user/test1
run namenode-b1 "本域访问: 经代理列出集群B /user"         hdfs dfs -ls hdfs://ns6789/user
run namenode-b1 "对端可见: 集群B存在 A 创建的标记 A2B"    hdfs dfs -test -d hdfs://ns6789/user/cross-check-A2B
run namenode-b1 "跨域访问: 在集群A创建 /user/test"        hdfs dfs -mkdir -p hdfs://nn1.emr.1234.com:9000/user/test
run namenode-b1 "跨域访问: 列出集群A /user"               hdfs dfs -ls hdfs://nn1.emr.1234.com:9000/user
run namenode-b1 "跨域写入: test1 在集群A创建标记 B2A"     hdfs dfs -mkdir -p hdfs://nn1.emr.1234.com:9000/user/cross-check-B2A

# ---------- 5) 跨域标记回查 ----------
echo
echo "=============================================="
echo " 跨域标记回查（铁证：数据确实落在对方集群）"
echo "=============================================="
run namenode-a1 "对端可见: 集群A存在 B 创建的标记 B2A"    hdfs dfs -test -d hdfs://ns1234/user/cross-check-B2A

# ---------- 6) 故障转移演练（集群 A / ns1234） ----------
echo
echo "=============================================="
echo " 故障转移演练（集群 A / ns1234）"
echo "=============================================="
ACT="$(nn_state namenode-a1 ns1234 nn1 test)"
if [ "$ACT" = "active" ]; then
  STOP=namenode-a1; STOP_NN=nn1; SURV=namenode-a2; SURV_NN=nn2
else
  STOP=namenode-a2; STOP_NN=nn2; SURV=namenode-a1; SURV_NN=nn1
fi
echo "  当前 active = ${STOP_NN}，模拟故障：停止 ${STOP} 容器"
docker stop "$STOP"
wait_state "$SURV" ns1234 "$SURV_NN" test active "故障转移: $SURV_NN 自动接管成为 active" 24
run "$SURV" "故障转移后: 经 nameservice 代理访问仍可用"    hdfs dfs -ls hdfs://ns1234/user
run "$SURV" "故障转移后: 可读取故障前写入的数据文件"        bash -c 'hdfs dfs -cat hdfs://ns1234/user/test/ha-file.txt | grep -q "ha-test-data-1234"'
run "$SURV" "故障转移后: 跨域访问集群B仍可用"              hdfs dfs -ls hdfs://nn1.emr.6789.com:9000/user
echo "  恢复故障：重新启动 $STOP"
docker start "$STOP"
wait_state "$SURV" ns1234 "$STOP_NN" test standby "故障恢复: $STOP_NN 重启后回归 standby" 36

# ---------- 7) 票据信息 ----------
echo
echo "=============================================="
echo " 票据信息（klist）"
echo "=============================================="
echo "--- namenode-a1 (test@EMR.1234.COM) ---"
docker exec namenode-a1 bash -c 'klist -e' 2>&1 || true
echo "--- namenode-b1 (test1@EMR.6789.COM) ---"
docker exec namenode-b1 bash -c 'klist -e' 2>&1 || true

# ---------- 8) 汇总 ----------
echo
echo "=============================================="
echo " 验证结果: PASS=$PASS  FAIL=$FAIL"
echo "=============================================="
if [ "$FAIL" -eq 0 ]; then
  echo " ✅ 双集群 HDFS HA + 跨域互信验证全部通过！"
  echo "    双 NameNode 自动故障转移正常，test 与 test1 可互访对方集群。"
else
  echo " ❌ 存在失败项，请查看上方 [FAIL] 输出，参考 docs/03-常见问题-HA.md"
fi
exit "$FAIL"
