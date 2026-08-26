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
NAME_DIR=/hadoop/dfs/name

log()  { echo "[NN:$NNID] $*"; }
# 本环境实测：容器日志对 stderr 不保证落盘（此前 format/kinit 的报错全部"静默"），
# 因此所有诊断统一走 stdout（log()）；异常退出用 EXIT trap 留痕。
fail() { echo "[NN:$NNID] 错误: $*"; exit 1; }
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "[NN:${NNID:-?}] 脚本异常退出 rc=$rc"' EXIT

# ---------- 确保 kinit 可用（启动时后台补装 krb5-user，不阻塞 NN 启动） ----------
# bde2020 镜像未预装 krb5-user（FAQ Q13）。install-krb5.sh 幂等（已装秒退），
# best-effort：失败仅告警不影响 NN 启动（离线时属正常），日志在容器内
# /tmp/install-krb5.log，可手动补装：docker exec <容器> bash /root/install-krb5.sh。
if [ -x /root/install-krb5.sh ]; then
  /root/install-krb5.sh >/tmp/install-krb5.log 2>&1 &
  log "krb5-user 后台安装中（容器内日志: /tmp/install-krb5.log）"
fi

# ---------- 说明：脚本不依赖 kinit 二进制（防御性设计，与补装互不冲突） ----------
# bde2020 镜像默认未预装 krb5-user（kinit 缺失），容器内 apt 安装也可能因
# archive.debian.org 不可达而失败（见 FAQ Q13）。因此本脚本对 kinit **零依赖**，
# 即使补装失败 NN 也照常工作（补装只是方便手工验证）：
#   - format / zkfc / bootstrapStandby / NN 守护进程均由 JVM 用 keytab 自登录
#     （SecurityUtil.login，内部完成，不调用 kinit）；
#   - 主备状态查询改用 NN Web UI 的 JMX（HTTP_ONLY 匿名访问），见 nn_state()；
#   - 启动时 install-krb5.sh 后台补装 krb5-user 属于"锦上添花"，两套机制并存。

# ---------- 主机名修正：确保 canonical hostname = FQDN ----------
# 服务端方向（与 start-jn.sh 同一问题）：JVM 反向解析本容器 IP 可能得到短主机名
# （nn1 而非 nn1.emr.1234.com），NN 守护进程（及 nn1 format 初始化 QJM）按
# nn/nn1@REALM（keytab 中没有）登录失败 → 9000 永不监听 → 02 脚本一直等待。
# 客户端方向（FAQ Q12）：NN 连接 JN 时按 JN 地址的 canonical hostname（反向解析
# 结果）推导 jn/_HOST 服务主体。若 /etc/hosts 里 JN 的短名（jn3）排在 FQDN
# （jn3.emr.1234.com）之前，反解 JN 的 IP 会得到 jn3 → 期望主体 jn/jn3@REALM，
# 与 keytab 的 FQDN 主体不匹配 → format/连 JN 静默失败（QuorumException）。
# 修复：把本容器 IP 与每台 JN 的 IP 都重写为 FQDN 打头（NSS files 优先于
# docker DNS），并断言反向解析结果。
FQDN="$(cat /etc/hostname 2>/dev/null || hostname)"
IP="$(getent hosts "$FQDN" | awk '{print $1}' | head -1)"
[ -n "$IP" ] || IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
SHORT="$(echo "$FQDN" | cut -d. -f1)"

# 从 hdfs-site.xml 的 qjournal URI 解析 JN 主机名（3 台 JN 共享，固定 FQDN）
JN_FQDNs="$(sed -n 's#.*qjournal://\([^/]*\)/.*#\1#p' /etc/hadoop/hdfs-site.xml \
  | tr ';' '\n' | cut -d: -f1)"
FIX_IPS="$IP"
for jh in $JN_FQDNs; do
  jip="$(getent hosts "$jh" | awk '{print $1}' | head -1)"
  [ -n "$jip" ] && FIX_IPS="$FIX_IPS $jip"
done

if [ -n "$IP" ] && [ -n "$FQDN" ]; then
  # 不能用 sed -i：/etc/hosts 是 bind mount，sed -i 的 rename 覆盖会报
  # "Device or resource busy" 失败（被 || true 吞掉），旧行删不掉。
  # 用 cat 原地重写（truncate+write，不 rename），保证这些 IP 的第一条记录是 FQDN。
  {
    grep -vE "^($(echo "$FIX_IPS" | tr ' ' '|'))[[:space:]]" /etc/hosts \
      | grep -vE "[[:space:]]${SHORT}([[:space:]]|\$)"
    echo "$IP $FQDN $SHORT"
    for jh in $JN_FQDNs; do
      jip="$(getent hosts "$jh" | awk '{print $1}' | head -1)"
      [ -n "$jip" ] && echo "$jip $jh"
    done
  } > /etc/hosts.jnfix
  cat /etc/hosts.jnfix > /etc/hosts
  rm -f /etc/hosts.jnfix
fi

CANON="$(getent hosts "$IP" 2>/dev/null | awk '{print $2}' | head -1)"
log "hostname=$FQDN ip=$IP canonical=$CANON"
if [ -z "$CANON" ] || [ "$CANON" != "$FQDN" ]; then
  fail "canonical hostname 解析为 '${CANON:-空}'（期望 '$FQDN'），Kerberos 主体会变成 nn/$SHORT@REALM 导致登录失败"
fi
for jh in $JN_FQDNs; do
  jip="$(getent hosts "$jh" | awk '{print $1}' | head -1)"
  jcanon="$(getent hosts "$jip" 2>/dev/null | awk '{print $2}' | head -1)"
  log "JN $jh ip=${jip:-未解析} canonical=${jcanon:-未解析}"
  if [ -z "$jip" ] || [ "$jcanon" != "$jh" ]; then
    fail "JN $jh 的 canonical hostname 解析为 '${jcanon:-空}'（期望 '$jh'），NN 客户端推导 jn/_HOST 会得到短名 → QJM 认证失败（FAQ Q12）"
  fi
done
HOST="$FQDN"

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

# ---------- 工具：NN 状态查询（JMX over HTTP，免 kinit/TGT） ----------
# 不依赖 hdfs haadmin（需要 TGT），改查 NN Web UI 的 JMX：Web 为 HTTP_ONLY
# 匿名访问。注意：主备状态在 NameNodeStatus bean 的 State 字段
# （active/standby），FSNamesystemState 只有 FSState=Operational，没有
# active/standby（曾导致误判超时）。
nn_state() {
  curl -s --max-time 5 \
    "http://${1}.${DOMAIN}:50070/jmx?qry=Hadoop:service=NameNode,name=NameNodeStatus" 2>/dev/null \
    | sed -n 's/.*"State"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
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
# JN 地址取自已解析的 qjournal URI：3 台 JN 共享且固定位于 emr.1234.com（双集群一致）
for jh in $JN_FQDNs; do
  wait_tcp "$jh" 8485 "JournalNode-${jh%%.*}"
done

if [ "$NNID" = "nn1" ]; then OTHER=nn2; else OTHER=nn1; fi

# ---------- 2) 首次初始化 ----------
if [ ! -d "$NAME_DIR/current" ]; then
  if [ "$NNID" = "nn1" ]; then
    log "首次启动：格式化 NameNode（同时初始化 QJM 共享编辑日志）"
    hdfs namenode -format -force -nonInteractive
  else
    log "首次启动：等待对端 $OTHER.$DOMAIN 成为 active ..."
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

# ---------- 4) nn1 初始化 ZK（zkfc 自 keytab 登录，无需 kinit） ----------
# 注意：3.2.1 的 zkfc 没有 -ns 参数（误传会 badArg 报错，曾导致 formatZK 失败、
# ZKFC 守护进程直接退出）；nameservice 由配置决定。加 -force -nonInteractive
# 避免交互式确认（容器内无 TTY 会失败）。
if [ "$NNID" = "nn1" ]; then
  log "初始化 ZooKeeper 故障转移元数据（hdfs zkfc -formatZK）"
  if ! fmt_out="$(hdfs zkfc -formatZK -force -nonInteractive 2>&1)"; then
    if echo "$fmt_out" | grep -qi "already exists"; then
      log "formatZK：znode 已存在（重启幂等场景），继续"
    else
      log "formatZK 失败，输出："
      echo "$fmt_out" | tail -30 | sed 's/^/  /'
      fail "formatZK 失败，请查看上方输出"
    fi
  fi
fi

# ---------- 5) 启动 ZKFC（自动故障转移控制器）并保持前台 ----------
log "启动 ZKFC"
hdfs zkfc &
ZKFC_PID=$!

wait_zkfc_settled 90
kdestroy 2>/dev/null || true

# 前台等待 ZKFC；异常退出时容器由 restart 策略自动拉起
wait "$ZKFC_PID"
