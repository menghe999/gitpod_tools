# 使用官方的Java 11镜像作为基础镜像
FROM openjdk:11-jre-slim

# 设置工作目录
WORKDIR /app

# 复制JAR文件、配置文件和keytab文件
COPY hdfs-file-sync-1.3-SNAPSHOT.jar /app/hdfs-file-sync.jar
COPY lib.zip /app/lib.zip

# 安装unzip工具（用于解压lib.zip）
RUN apt-get update && \
    apt-get install -y unzip && \
    rm -rf /var/lib/apt/lists/*

# 解压lib.zip到/app目录
RUN unzip /app/lib.zip -d /app && \
    rm /app/lib.zip

# 启动命令：通过环境变量传递参数
CMD ["sh", "-c", "java -cp hdfs-file-sync.jar:/app/lib/* HDFSTransfer ${SOURCE_CONF_DIR} ${TARGET_CONF_DIR} ${SOURCE_PATH} ${TARGET_PATH} ${KEYTAB_PATH} ${PRINCIPAL} ${KRB5_PATH}"]