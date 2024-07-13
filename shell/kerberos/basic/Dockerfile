# 使用一个基础的 CentOS 镜像
FROM centos:latest

# 维护者信息
LABEL maintainer="yourname@example.com"

# 设置阿里云的 CentOS 镜像源
RUN sed -e 's|^mirrorlist=|#mirrorlist=|g' \
        -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' \
        -i.bak \
        /etc/yum.repos.d/CentOS-*

# 更新包列表并安装 Kerberos 相关软件包
RUN yum -y update && \
    yum -y install krb5-server krb5-libs krb5-workstation && \
    yum clean all

# 设置 Kerberos 配置文件
COPY krb5.conf /etc/krb5.conf
COPY kdc.conf /var/kerberos/krb5kdc/kdc.conf
COPY kadm5.acl /var/kerberos/krb5kdc/kadm5.acl

# 初始化 Kerberos 数据库
RUN /usr/sbin/kdb5_util create -s -P password

# 暴露 Kerberos 端口
EXPOSE 88 749

# 启动 Kerberos 服务
CMD ["/usr/sbin/krb5kdc", "-n"]
