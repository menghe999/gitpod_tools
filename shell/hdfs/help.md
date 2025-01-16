cd shell/hdfs
# 构建cluster A (namenode、datanode、resourcemanager、nodemanager)
docker-compose -f docker-compose.yml  up -d
docker exec -it namenode bash
docker exec -it datanode bash
docker exec -it resourcemanager bash
docker exec -it nodemanager bash
docker-compose -f docker-compose.yml  down


docker-compose -f docker-compose-1.yml  up -d
docker exec -it namenode1 bash
docker exec -it datanode1 bash
docker-compose -f docker-compose-1.yml  down


# 容器内安装基础命令
echo "deb http://archive.debian.org/debian stretch main contrib non-free" > /etc/apt/sources.list && \
echo "deb http://archive.debian.org/debian-security stretch/updates main contrib non-free" >> /etc/apt/sources.list && \
echo "Acquire::Check-Valid-Until false;" > /etc/apt/apt.conf.d/99no-check-valid-until
apt-get update && apt-get install -y krb5-user vim wget


# namenode上执行
kinit test
hdfs dfs -ls hdfs://namenode.emr.1234.com:9000/user
hdfs dfs -ls hdfs://namenode.emr.6789.com:9000/user

# namenode1上执行
kinit test1
hdfs dfs -ls hdfs://namenode.emr.1234.com:9000/user
hdfs dfs -ls hdfs://namenode.emr.6789.com:9000/user



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

