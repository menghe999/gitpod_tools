基础环境准备好

- 集群1234
 - kdc1
 - namenode
 - datanode
- 集群6789
 - kdc2
 - namenode1
 - datanode1

1、根据gitpod_tools/shell/kerberos/advance/help.md配置好互信
2、根据gitpod_tools/shell/hdfs/help.md配置两个hdfs集群

确保当前目录下有 hdfs-file-sync-1.2-SNAPSHOT.jar lib.zip

gitpod /workspace/gitpod_tools/shell/hdfs/demo (main) $ ll
total 61564
drwxr-xr-x 4 gitpod gitpod     4096 Jan 16 08:19 ./
drwxr-xr-x 8 gitpod gitpod     4096 Jan 16 06:19 ../
-rw-r--r-- 1 gitpod gitpod      640 Jan 16 08:03 docker-compose.yml
-rw-r--r-- 1 gitpod gitpod      906 Jan 16 08:05 Dockerfile
drwxr-xr-x 2 gitpod gitpod       48 Jan 16 08:18 hadoop/
drwxr-xr-x 2 gitpod gitpod       48 Jan 16 08:18 hadoop1/
-rw-r--r-- 1 gitpod gitpod     5851 Jan 16 07:53 hdfs-file-sync-1.2-SNAPSHOT.jar
-rw-r--r-- 1 gitpod gitpod       36 Jan 16 07:38 help.md
-rw-r--r-- 1 gitpod gitpod      629 Jan 16 08:09 krb5.conf
-rw-r--r-- 1 gitpod gitpod 62996848 Jan 16 07:34 lib.zip
-rw------- 1 gitpod gitpod      136 Jan 16 07:57 test.keytab
-rw-r--r-- 1 gitpod gitpod      397 Jan 16 07:01 wget-log

构建镜像
docker build -t hdfs-file-sync:1.1 .

启动容器
docker-compose up -d


2025-01-16 08:14:28.940 [main] INFO  HDFSTransfer - app start
2025-01-16 08:14:29.099 [main] WARN  org.apache.hadoop.util.NativeCodeLoader - Unable to load native-hadoop library for your platform... using builtin-java classes where applicable
2025-01-16 08:14:29.183 [main] INFO  HDFSTransfer - kerberos info, principal: test@EMR.1234.COM, keytabPath: /app/test.keytab
2025-01-16 08:14:29.255 [main] INFO  org.apache.hadoop.security.UserGroupInformation - Login successful for user test@EMR.1234.COM using keytab file test.keytab. Keytab auto renewal enabled : false
log4j:WARN No appenders could be found for logger (org.apache.htrace.core.Tracer).
log4j:WARN Please initialize the log4j system properly.
log4j:WARN See http://logging.apache.org/log4j/1.2/faq.html#noconfig for more info.
2025-01-16 08:14:29.725 [main] INFO  HDFSTransfer - Copying hdfs://namenode.emr.1234.com:9000/user/test/file1 to /user/test1/file1
2025-01-16 08:14:29.954 [main] INFO  HDFSTransfer - Copying hdfs://namenode.emr.1234.com:9000/user/test/file2 to /user/test1/file2
2025-01-16 08:15:29.999 [main] INFO  HDFSTransfer - Copying hdfs://namenode.emr.1234.com:9000/user/test/file1 to /user/test1/file1