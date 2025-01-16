# 使用官方的Java 11镜像作为基础镜像
FROM openjdk:11-jre-slim

# 设置工作目录
WORKDIR /app

# 复制JAR文件、配置文件和keytab文件
COPY hdfs-file-sync-1.2-SNAPSHOT.jar /app/hdfs-file-sync.jar
COPY krb5.conf /etc/krb5.conf
COPY hadoop /app/hadoop
COPY hadoop1 /app/hadoop1
COPY test.keytab /app/test.keytab
COPY lib.zip /app/lib.zip

# 安装unzip工具（用于解压lib.zip）
RUN apt-get update && \
    apt-get install -y unzip && \
    rm -rf /var/lib/apt/lists/*

# 解压lib.zip到/app目录
RUN unzip /app/lib.zip -d /app && \
    rm /app/lib.zip

# 设置环境变量
# ENV JAVA_OPTS="-Djava.security.krb5.conf=/etc/krb5.conf"

# 启动命令：打印lib目录内容并启动JAR包
# Usage: HDFSTransfer <sourceConfDir> <targetConfDir> <sourcePath> <targetPath> <keytabPath> <principal> <krb5Path>
CMD ["sh", "-c", "java -cp hdfs-file-sync.jar:/app/lib/* HDFSTransfer /app/hadoop /app/hadoop1 /user/test /user/test1 /app/test.keytab test@EMR.1234.COM /etc/krb5.conf"]