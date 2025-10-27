# 使用一个基础的 CentOS 镜像
FROM centos:7 AS server

# 维护者信息
LABEL maintainer="yourname@example.com"


# 更新 yum 源配置，使用 vault 仓库
RUN sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo && \
    sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo


# 时区
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

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


# 使用一个基础的 CentOS 镜像
FROM centos:7 AS client

# 维护者信息
LABEL maintainer="yourname@example.com"


# 更新 yum 源配置，使用 vault 仓库
RUN sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo && \
    sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo


# 时区
RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 更新包列表并安装 Kerberos 相关软件包
RUN yum -y update && \
    yum -y install krb5-workstation && \
    yum clean all

# 设置 Kerberos 配置文件
COPY krb5.conf /etc/krb5.conf


CMD ["tail", "-f","/dev/null"]