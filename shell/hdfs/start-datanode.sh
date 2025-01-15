#!/bin/bash

# 设置环境变量
export HDFS_DATANODE_SECURE_USER=hadoop
export JSVC_HOME=/usr/bin
export HADOOP_CONF_DIR=/etc/hadoop

echo "Starting DataNode with Kerberos authentication..."

# 初始化 Kerberos 票据
kinit -kt /etc/hadoop/dn.keytab dn/datanode.emr.1234.com@EMR.1234.COM

# 检查 Kerberos 票据
echo "Kerberos ticket information:"
klist

# 启动 DataNode，并将日志输出到标准输出和标准错误
set -x
exec $HADOOP_HOME/bin/hdfs --config $HADOOP_CONF_DIR datanode && tail -f /dev/null