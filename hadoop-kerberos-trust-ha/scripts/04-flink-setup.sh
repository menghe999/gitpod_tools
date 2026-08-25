#!/bin/bash
# ============================================================
# 04-flink-setup.sh —— Flink 1.18.1 示例环境准备
#   1) 启动 flink-client 容器（挂载 flink/、test keytab、cluster-a 配置）
#   2) 环境冒烟测试：RM 可达 + test 租户（JAAS keytab 免 kinit）跨域访问 ns1234/ns6789
#   3) 下载 flink-1.18.1-bin-scala_2.12 发行版到 flink/dist（约 330MB，幂等）
#   4) 应用 flink/conf/flink-conf.yaml（test 租户 + checkpoint 落 ns1234）
# 之后执行 bash scripts/05-flink-demo.sh 提交演示作业。
# 详细说明见 docs/04-Flink跨集群Demo.md。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

FLINK_VERSION=1.18.1
FLINK_BIN="flink-${FLINK_VERSION}-bin-scala_2.12"
DIST_DIR="flink/dist"
TGZ_URL="https://archive.apache.org/dist/flink/flink-${FLINK_VERSION}/${FLINK_BIN}.tgz"
CONNECTOR_URL="https://repo1.maven.org/maven2/org/apache/flink/flink-connector-files/${FLINK_VERSION}/flink-connector-files-${FLINK_VERSION}.jar"

docker compose version >/dev/null 2>&1 && DC="docker compose" || DC="docker-compose"

echo "==> [1/4] 启动 flink-client 容器 ..."
$DC -f ha/docker-compose.yml up -d flink-client

echo "==> [2/4] 环境冒烟测试（下载前先验证，避免白下 330MB）..."
docker exec flink-client bash -c '(exec 3<>/dev/tcp/resourcemanager.emr.1234.com/8088) 2>/dev/null' \
  || { echo "错误: ResourceManager 8088 不可达（RM/NM 是否已由 02-start-hdfs.sh 启动？）" >&2; exit 1; }
echo "  [OK] ResourceManager 8088 可达"

# JAAS keytab 登录（不依赖 kinit 二进制）同时探测本域 ns1234 与跨域 ns6789
if ! docker exec flink-client bash -c "
    cat > /tmp/hdfs.login <<'EOF'
Client {
  com.sun.security.auth.module.Krb5LoginModule required
  useKeyTab=true keyTab=\"/root/test.keytab\" principal=\"test@EMR.1234.COM\" useTicketCache=false;
};
EOF
    export HADOOP_OPTS=\"-Djava.security.auth.login.config=/tmp/hdfs.login -Djavax.security.auth.useSubjectCredsOnly=false\"
    export HADOOP_CONF_DIR=/etc/hadoop
    hadoop fs -ls hdfs://ns1234/ >/dev/null 2>&1 && hadoop fs -ls hdfs://nn1.emr.6789.com:9000/ >/dev/null 2>&1
  "; then
  echo "错误: test@EMR.1234.COM 访问 HDFS 失败（ns1234 或跨域 ns6789）" >&2
  echo "  排查: 01 互信/test.keytab 是否就绪；namenode-a1/b1 是否 active；krb5.conf" >&2
  echo "  重试冒烟: docker exec flink-client bash -c 'export HADOOP_OPTS=\"-Djava.security.auth.login.config=/tmp/hdfs.login -Djavax.security.auth.useSubjectCredsOnly=false\"; export HADOOP_CONF_DIR=/etc/hadoop; hadoop fs -ls hdfs://nn1.emr.6789.com:9000/'" >&2
  exit 1
fi
echo "  [OK] test 租户访问 ns1234 与跨域 ns6789 均成功"

echo "==> [3/4] 检查/下载 Flink 发行版 ..."
if [ -d "$DIST_DIR/$FLINK_BIN" ]; then
  echo "  已存在 $DIST_DIR/$FLINK_BIN，跳过下载"
else
  mkdir -p "$DIST_DIR"
  echo "  下载 $TGZ_URL（约 330MB，首次较慢，请耐心等待）..."
  curl -fL --retry 3 --connect-timeout 30 -o "$DIST_DIR/$FLINK_BIN.tgz" "$TGZ_URL"
  echo "  解压 ..."
  tar -xzf "$DIST_DIR/$FLINK_BIN.tgz" -C "$DIST_DIR"
  rm -f "$DIST_DIR/$FLINK_BIN.tgz"
fi

echo "==> [4/4] 应用 flink-conf.yaml，并确保 FileSource/FileSink 依赖 jar 存在 ..."
cp flink/conf/flink-conf.yaml "$DIST_DIR/$FLINK_BIN/conf/flink-conf.yaml"
if ! ls "$DIST_DIR/$FLINK_BIN"/lib/flink-connector-files-*.jar >/dev/null 2>&1; then
  echo "  dist/lib 缺少 flink-connector-files，从 Maven 中央仓库下载 ..."
  curl -fL --retry 3 -o "$DIST_DIR/$FLINK_BIN/lib/flink-connector-files-${FLINK_VERSION}.jar" "$CONNECTOR_URL"
fi
echo "  flink-conf.yaml 已应用，flink-connector-files 已就绪"

echo
echo "=============================================="
echo " Flink 环境就绪！下一步："
echo "   bash scripts/05-flink-demo.sh"
echo "=============================================="
