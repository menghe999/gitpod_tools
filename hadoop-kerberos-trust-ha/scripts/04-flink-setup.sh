#!/bin/bash
# ============================================================
# 04-flink-setup.sh —— Flink 1.18.1 示例环境准备
#   1) 下载 flink-1.18.1-bin-scala_2.12 发行版到 flink/dist（约 330MB，幂等）
#   2) 应用 flink/conf/flink-conf.yaml（test 租户 + checkpoint 落 ns1234）
#   3) 启动 flink-client 容器（挂载 flink/、test keytab、cluster-a 配置）
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

echo "==> [1/3] 检查/下载 Flink 发行版 ..."
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

echo "==> [2/3] 应用 flink-conf.yaml，并确保 FileSource/FileSink 依赖 jar 存在 ..."
cp flink/conf/flink-conf.yaml "$DIST_DIR/$FLINK_BIN/conf/flink-conf.yaml"
if ! ls "$DIST_DIR/$FLINK_BIN"/lib/flink-connector-files-*.jar >/dev/null 2>&1; then
  echo "  dist/lib 缺少 flink-connector-files，从 Maven 中央仓库下载 ..."
  curl -fL --retry 3 -o "$DIST_DIR/$FLINK_BIN/lib/flink-connector-files-${FLINK_VERSION}.jar" "$CONNECTOR_URL"
fi
echo "  flink-conf.yaml 已应用，flink-connector-files 已就绪"

echo "==> [3/3] 启动 flink-client 容器 ..."
$DC -f ha/docker-compose.yml up -d flink-client

echo
echo "=============================================="
echo " Flink 环境就绪！下一步："
echo "   bash scripts/05-flink-demo.sh"
echo "=============================================="
