#!/bin/bash
# ============================================================
# start-jn.sh —— JournalNode 启动脚本（HDFS HA 共享 QJM）
#
# 一台 JN 同时服务两个 nameservice（ns1234 / ns6789），
# 编辑日志按 nameservice 子目录隔离存储（QJM 协议自动处理）。
# Kerberos 主体：jn/_HOST@EMR.1234.COM（keytab 含 jn1/jn2/jn3 三个主体）
# ============================================================
set -e

echo "=== [JN] 启动 JournalNode（hdfs journalnode）==="
exec hdfs journalnode
