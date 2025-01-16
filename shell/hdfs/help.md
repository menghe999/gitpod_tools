cd shell/hdfs

docker-compose -f docker-compose.yml  up -d
docker exec -it namenode bash
docker exec -it datanode bash
docker-compose -f docker-compose.yml  down


docker-compose -f docker-compose-1.yml  up -d
docker exec -it namenode1 bash
docker exec -it datanode1 bash
docker-compose -f docker-compose-1.yml  down


# namenode namenode1上执行，安装基础命令
echo "deb http://archive.debian.org/debian stretch main contrib non-free" > /etc/apt/sources.list && \
echo "deb http://archive.debian.org/debian-security stretch/updates main contrib non-free" >> /etc/apt/sources.list && \
echo "Acquire::Check-Valid-Until false;" > /etc/apt/apt.conf.d/99no-check-valid-until
apt-get update && apt-get install -y krb5-user vim


# namenode上执行
kinit test
hdfs dfs -ls hdfs://namenode.emr.1234.com:9000/user
hdfs dfs -ls hdfs://namenode.emr.6789.com:9000/user

# namenode1上执行
kinit test1
hdfs dfs -ls hdfs://namenode.emr.1234.com:9000/user
hdfs dfs -ls hdfs://namenode.emr.6789.com:9000/user