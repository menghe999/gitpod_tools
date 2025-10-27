```shell
# 构建镜像
docker build -t kerberos-server:v1.0 --target server .
docker build -t mycentos:v1.0 --target client .
# 启动容器
docker-compose up -d
```

```shell
# 进入kerberos-server容器
docker exec -it kerberos-server /bin/bash

# kerberos-server容器内执行，创建一个租户flink
sh /root/help/init_k_user.sh
su - flink
kinit -kt flink.keytab flink
exit
exit
```

```shell
# 宿主机执行（将flink keytab拷贝到kerberos-client）
docker cp kerberos-server:/home/flink/flink.keytab .
docker cp flink.keytab kerberos-client:/root/
docker exec -it kerberos-client /bin/bash
```

```shell
# kerberos-client容器内部执行
cd ~ && chown root:root flink.keytab
kinit -kt flink.keytab flink && klist
```
