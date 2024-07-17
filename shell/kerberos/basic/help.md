```shell
docker build -t kerberos-server:v1.0 --target server .
docker build -t mycentos:v1.0 --target client .
docker-compose up

docker exec -it kerberos-server /bin/bash
docker exec -it kerberos-client /bin/bash
```

```shell
# 创建一个租户flink
sh /root/help/init_k_user.sh 

su - flink
kinit -kt flink.keytab flink




docker cp kerberos-server:/home/flink/flink.keytab .
docker cp flink.keytab kerberos-client:/root/

docker exec -it kerberos-client /bin/bash
cd ~ && chown root:root flink.keytab  

cp /usr/share/zoneinfo/Asia/Tokyo  /etc/localtime

```