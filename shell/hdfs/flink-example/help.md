
# resourcemanager上执行

# test.keytab拷贝到resourcemanager

docker cp test.keytab resourcemanager:/root/test.keytab

wget https://dlcdn.apache.org/flink/flink-1.18.1/flink-1.18.1-bin-scala_2.12.tgz

# 下载到flink/lib 后续example依赖
wget https://repo1.maven.org/maven2/org/apache/flink/flink-connector-files/1.18.1/flink-connector-files-1.18.1.jar

# 解压配置

export HADOOP_CLASSPATH=`hadoop classpath`


# 官方example
./bin/flink run-application \
  -t yarn-application \
  -Dexecution.checkpointing.interval=10000 \
  -Dexecution.checkpointing.mode=EXACTLY_ONCE \
  -Dexecution.checkpointing.timeout=60000 \
  -Dexecution.checkpointing.max-concurrent-checkpoints=1 \
  -Dexecution.checkpointing.min-pause-between-checkpoints=5000 \
  -Dstate.backend=filesystem \
  -Dstate.checkpoints.dir=hdfs://namenode.emr.1234.com:9000/user/test/flink/checkpoints \
  -Dstate.savepoints.dir=hdfs://namenode.emr.1234.com:9000/user/test/flink/savepoints \
  -Dexecution.checkpointing.externalized-checkpoint-retention=RETAIN_ON_CANCELLATION \
  -Dsecurity.kerberos.krb5-conf.path=/etc/krb5.conf \
  -Dsecurity.kerberos.login.keytab=/root/test.keytab \
  -Dsecurity.kerberos.login.principal=test@EMR.1234.COM \
  -Dsecurity.kerberos.login.use-ticket-cache=false \
  ./examples/streaming/TopSpeedWindowing.jar


# 我的example 随机造数，写入另一个hdfs集群（kerberos）
./bin/flink run-application \
  -t yarn-application \
  -Dyarn.application.name="Flink HDFS Example Job" \
  -Dexecution.checkpointing.interval=10000 \
  -Dexecution.checkpointing.mode=EXACTLY_ONCE \
  -Dexecution.checkpointing.timeout=60000 \
  -Dexecution.checkpointing.max-concurrent-checkpoints=1 \
  -Dexecution.checkpointing.min-pause-between-checkpoints=5000 \
  -Dstate.backend=filesystem \
  -Dstate.checkpoints.dir=hdfs://namenode.emr.1234.com:9000/user/test/flink/checkpoints \
  -Dstate.savepoints.dir=hdfs://namenode.emr.1234.com:9000/user/test/flink/savepoints \
  -Dexecution.checkpointing.externalized-checkpoint-retention=RETAIN_ON_CANCELLATION \
  -Dsecurity.kerberos.krb5-conf.path=/etc/krb5.conf \
  -Dsecurity.kerberos.login.keytab=/root/test.keytab \
  -Dsecurity.kerberos.login.principal=test@EMR.1234.COM \
  -Dsecurity.kerberos.login.use-ticket-cache=false \
  -c FlinkHDFSKerberosExample \
  flink-random2hdfs-1.1-SNAPSHOT.jar

