#!/bin/bash
# ============================================================
# start-nn.sh —— NameNode 启动脚本（HDFS HA：双 NN + QJM + ZKFC 自动故障转移）
#
# 通过环境变量参数化（compose 中注入）：
#   NAMESERVICE  nameservice id（ns1234 / ns6789）
#   NN_ID        本节点 namenode id（nn1 / nn2）
#   REALM        Kerberos realm（EMR.1234.COM / EMR.6789.COM）
#   DOMAIN       主机域（emr.1234.com / emr.6789.com）
#
# 首次部署流程：
#   nn1：格式化（同时初始化 QJM 共享日志）→ 启动 NN → formatZK → 启动 ZKFC → active
#   nn2：等 nn1 成为 active → bootstrapStandby 同步 fsimage → 启动 NN → ZKFC → standby
# 重启（name dir 已存在）时跳过初始化，直接启动 NN + ZKFC（幂等）。
#
# 注意：容器主机名必须是 nn1.<domain> / nn2.<domain>，
#       NN 守护进程据此自动识别自己的 nameservice 与 namenode-id。
# ============================================================
set -e

NS="${NAMESERVICE:?需要环境变量 NAMESERVICE}"
NNID="${NN_ID:?需要环境变量 NN_ID}"
REALM="${REALM:?需要环境变量 REALM}"
DOMAIN="${DOMAIN:?需要环境变量 DOMAIN}"
HOST="$(hostname -f)"
NAME_DIR=/hadoop/dfs/name

log()  { echo "[NN:$NNID] $*"; }
fail() { echo "[NN:$NNID] 错误: $*" >&2; exit 1; }

# ---------- 工具：TCP 端口等待 ----------
wait_tcp() {
  local host="$1" port="$2" what="$3" tries="${4:-120}" i
  log "等待 $what ($host:$port) ..."
  for i in $(seq 1 "$tries"); do
    if (exec 3<>/dev/tcp/"$host"/"$port") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      log "$what 就绪"
      return 0
    fi
    sleep 2
  done
  fail "等待 $what 超时（$((tries*2)) 秒），请检查依赖容器日志"
}

# ---------- 工具：haadmin 状态查询（需已 kinit） ----------
nn_state() {
  hdfs haadmin -ns "$NS" -getServiceState "$1" 2>/dev/null | tr -d ' \n'
}

# ---------- 工具：等待本 NN 的 ZKFC 状态落定（active 或 standby 均可） ----------
wait_zkfc_settled() {
  local tries="${1:-90}" i st
  log "等待 ZKFC 状态落定（active/standby）..."
  for i in $(seq 1 "$tries"); do
    st="$(nn_state "$NNID")"
    if [ "$st" = "active" ] || [ "$st" = "standby" ]; then
      log "ZKFC 状态落定: $st"
      return 0
    fi
    sleep 5
  done
  fail "ZKFC 未在限时内落定（最后状态: ${st:-未知}），请查看 docker logs"
}

# 容器退出时尽量优雅地停掉子进程（QJM 编辑日志是同步落盘的）
trap 'log "收到终止信号，停止 NameNode/ZKFC"; kill $NN_PID $ZKFC_PID 2>/dev/null || true' TERM INT

# ---------- 1) 等待依赖：ZK + 3 台 JN + 对端 NN ----------
wait_tcp zk1 2181 "ZooKeeper"
wait_tcp jn1 8485 "JournalNode-1"
wait_tcp jn2 8485 "JournalNode-2"
wait_tcp jn3 8485 "JournalNode-3"

if [ "$NNID" = "nn1" ]; then OTHER=nn2; else OTHER=nn1; fi

# ---------- 2) 首次初始化 ----------
if [ ! -d "$NAME_DIR/current" ]; then
  if [ "$NNID" = "nn1" ]; then
    log "首次启动：格式化 NameNode（同时初始化 QJM 共享编辑日志）"
    hdfs namenode -format -force -nonInteractive
  else
    log "首次启动：等待对端 $OTHER.$DOMAIN 成为 active ..."
    kinit -kt /etc/hadoop/nn.keytab "nn/$HOST@$REALM" || fail "kinit 失败"
    st=""
    for i in $(seq 1 90); do
      st="$(nn_state "$OTHER")"
      [ "$st" = "active" ] && break
      sleep 5
    done
    [ "$st" = "active" ] || fail "对端 $OTHER 未在限时内成为 active（最后状态: ${st:-未知}）"
    log "对端 $OTHER 已是 active，执行 bootstrapStandby 同步 fsimage"
    hdfs namenode -bootstrapStandby -force
    kdestroy 2>/dev/null || true
  fi
fi

# ---------- 3) 启动 NameNode（后台；日志直接进 docker logs） ----------
if ! (exec 3<>/dev/tcp/"$HOST"/9000) 2>/dev/null; then
  log "启动 NameNode 守护进程"
  hdfs namenode &
  NN_PID=$!
  exec 3>&- 3<&- 2>/dev/null || true
fi
wait_tcp "$HOST" 9000 "NameNode RPC" 240

# ---------- 4) kinit（供 haadmin 状态查询） + nn1 初始化 ZK ----------
kinit -kt /etc/hadoop/nn.keytab "nn/$HOST@$REALM" || fail "kinit 失败"
if [ "$NNID" = "nn1" ]; then
  log "初始化 ZooKeeper 故障转移元数据（hdfs zkfc -formatZK）"
  hdfs zkfc -formatZK -ns "$NS" || log "formatZK 返回非零（znode 可能已存在，忽略）"
fi

# ---------- 5) 启动 ZKFC（自动故障转移控制器）并保持前台 ----------
log "启动 ZKFC"
hdfs zkfc -ns "$NS" &
ZKFC_PID=$!

wait_zkfc_settled 90
kdestroy 2>/dev/null || true

# 前台等待 ZKFC；异常退出时容器由 restart 策略自动拉起
wait "$ZKFC_PID"
