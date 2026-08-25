#!/bin/bash
# ============================================================
# 05-flink-demo.sh —— 编译并提交 Flink 跨集群演示作业（在 flink-client 容器内执行）
#   - 编译 CrossClusterDemo.java（javac 直接对 dist/lib 编译，无需 Maven）
#   - 在 ns6789 准备输入文件（JAAS keytab 登录，无需 kinit 二进制）
#   - 以 yarn-application 模式提交到 ns1234 的 YARN（test@EMR.1234.COM 租户）
#   - 验证：YARN 应用状态 / ns6789 输出目录 / ns1234 checkpoint 目录
#
# 需求映射（详见 docs/04-Flink跨集群Demo.md）：
#   1) 状态/checkpoint → hdfs://ns1234/flink/checkpoints（flink-conf.yaml）
#   2) 运行位置     → ns1234 的 YARN（resourcemanager.emr.1234.com）
#   3) 数据采集     → ns6789 输入目录（显式地址 hdfs://nn1.emr.6789.com:9000），逐行打印日志
#   4) 数据写出     → ns6789 另一个目录（FileSink part-* 文件）
#   5) 租户         → test@EMR.1234.COM（/root/test.keytab，JAAS 自登录）
#
# 用法：bash scripts/05-flink-demo.sh [ns6789输入目录] [ns6789输出目录]
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose version >/dev/null 2>&1 && DC="docker compose" || DC="docker-compose"

NS6789_NN="nn1.emr.6789.com:9000"
INPUT_DIR="${1:-hdfs://${NS6789_NN}/user/test/input}"
OUTPUT_DIR="${2:-hdfs://${NS6789_NN}/user/test/output}"
APP_NAME="${FLINK_APP_NAME:-CrossClusterDemo}"

# Flink 发行版目录：04 解压后顶层目录为 flink-<version>（如 flink-1.18.1），
# 这里在容器内动态解析，不依赖目录名假设
FLINK_DIST="$(docker exec flink-client bash -c 'ls -d /opt/flink/dist/flink-* 2>/dev/null | head -1' || true)"
JOB_SRC="/opt/flink/job/CrossClusterDemo.java"
JOB_CLASSES="/opt/flink/job/classes"
JOB_JAR="/opt/flink/job/cross-cluster-demo.jar"

# 在 flink-client 容器内以 test@EMR.1234.COM 执行 hadoop/yarn 命令：
# 用 JAAS login.conf + keytab 登录（不依赖 kinit 二进制，原理见 docs/04 与 FAQ Q13）
hdfs_cmd() {
  docker exec flink-client bash -c "
    cat > /tmp/hdfs.login <<'EOF'
Client {
  com.sun.security.auth.module.Krb5LoginModule required
  useKeyTab=true keyTab=\"/root/test.keytab\" principal=\"test@EMR.1234.COM\" useTicketCache=false;
};
EOF
    export HADOOP_OPTS=\"-Djava.security.auth.login.config=/tmp/hdfs.login -Djavax.security.auth.useSubjectCredsOnly=false\"
    export YARN_OPTS=\"\$HADOOP_OPTS\"   # yarn CLI 不继承 HADOOP_OPTS，需显式带上 JAAS 参数
    export HADOOP_CONF_DIR=/etc/hadoop
    $*
  "
}

echo "==> [1/5] 检查 flink-client / RM / NM 与 Flink 发行版 ..."
docker ps --format '{{.Names}}' | grep -qx flink-client \
  || { echo "错误: flink-client 未运行，先执行 bash scripts/04-flink-setup.sh" >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx resourcemanager \
  || { echo "错误: resourcemanager 未运行，先执行 bash scripts/02-start-hdfs.sh" >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx nodemanager \
  || { echo "错误: nodemanager 未运行，先执行 bash scripts/02-start-hdfs.sh" >&2; exit 1; }
docker exec flink-client bash -c '(exec 3<>/dev/tcp/resourcemanager.emr.1234.com/8088) 2>/dev/null' \
  || { echo "错误: ResourceManager 8088 不可达（检查 docker logs resourcemanager）" >&2; exit 1; }
docker exec flink-client test -d "$FLINK_DIST" \
  || { echo "错误: 容器内缺少 ${FLINK_DIST}，先执行 bash scripts/04-flink-setup.sh" >&2; exit 1; }
echo "  flink-client / resourcemanager / nodemanager 均就绪"

echo "==> [2/5] 容器内编译作业（javac 对 dist/lib 编译，无需 Maven）..."
docker exec flink-client bash -c "
  rm -rf $JOB_CLASSES && mkdir -p $JOB_CLASSES
  javac -cp '$FLINK_DIST/lib/*' -d $JOB_CLASSES $JOB_SRC
  jar cf $JOB_JAR -C $JOB_CLASSES .
"
echo "  编译完成: flink/job/cross-cluster-demo.jar"

echo "==> [3/5] 在 ns6789 准备输入数据（test@EMR.1234.COM 跨域写入）..."
hdfs_cmd "hadoop fs -mkdir -p $INPUT_DIR"
if ! hdfs_cmd "hadoop fs -test -e $INPUT_DIR/sample.txt"; then
  hdfs_cmd "printf 'hello from ns6789: line-1\nhello from ns6789: line-2\n跨域采集演示 第三行\n' | hadoop fs -put - $INPUT_DIR/sample.txt"
fi
hdfs_cmd "hadoop fs -ls $INPUT_DIR"

echo "==> [4/5] 提交到 ns1234 的 YARN（yarn-application 模式，test 租户）..."
submit_out="$(docker exec flink-client bash -c "
  export HADOOP_CLASSPATH=\"\$(hadoop classpath)\"
  export HADOOP_CONF_DIR=/etc/hadoop
  cd $FLINK_DIST
  bin/flink run-application -t yarn-application \\
    -D yarn.application.name=$APP_NAME \\
    -D jobmanager.memory.process.size=1024m \\
    -D taskmanager.memory.process.size=1024m \\
    -c CrossClusterDemo $JOB_JAR $INPUT_DIR $OUTPUT_DIR
" 2>&1 | tee /tmp/flink-submit.log)"
echo "$submit_out" | tail -8

APP_ID="$(echo "$submit_out" | grep -oE 'application_[0-9]+_[0-9]+' | head -1 || true)"
if [ -z "$APP_ID" ]; then
  APP_ID="$(hdfs_cmd "yarn application -list 2>/dev/null | grep -w '$APP_NAME' | awk '{print \$1}'" | head -1 || true)"
fi
if [ -z "$APP_ID" ]; then
  echo "错误: 提交后未解析到应用 ID，提交疑似失败。完整提交输出：" >&2
  echo "$submit_out" >&2
  exit 1
fi
echo "  应用 ID: $APP_ID"

echo "==> [5/5] 等待作业结束（有界文件源，读取完即结束）并验证 ..."
JOB_DONE=0
for i in $(seq 1 60); do
  st="$(hdfs_cmd "yarn application -status $APP_ID 2>/dev/null | grep -E '^State|^Final-State' | tr -d ' \t'" || true)"
  echo "  [${i}] $st"
  if echo "$st" | grep -q "State:FINISHED"; then JOB_DONE=1; break; fi
  if echo "$st" | grep -q "State:FAILED"; then
    echo "  作业 FAILED，自动拉取日志尾部（YARN 日志聚合）..." >&2
    hdfs_cmd "yarn logs -applicationId $APP_ID 2>/dev/null | grep -iE -A3 'exception|error|caused by' | tail -40" >&2 || true
    break
  fi
  sleep 5
done
if [ "$JOB_DONE" -ne 1 ]; then
  echo "  警告: 作业未在 5 分钟内 FINISHED（最后状态如上）。" >&2
  echo "  查看: http://localhost:8088（RM Web UI，宿主映射 8088），或:" >&2
  echo "        docker exec flink-client bash -c 'yarn logs -applicationId $APP_ID | tail -50'" >&2
fi

echo "  输出目录（ns6789）:"
hdfs_cmd "hadoop fs -ls $OUTPUT_DIR" || true
echo "  输出内容（ns6789）:"
hdfs_cmd "hadoop fs -cat $OUTPUT_DIR/part-* 2>/dev/null | head -20" || true
echo "  checkpoint 目录（ns1234）:"
hdfs_cmd "hadoop fs -ls -R hdfs://ns1234/flink/checkpoints 2>/dev/null | tail -12" || true

echo
echo "=============================================="
echo " 验证完成。查看采集日志："
echo "  yarn logs -applicationId $APP_ID | grep FlinkDemo"
echo "=============================================="
