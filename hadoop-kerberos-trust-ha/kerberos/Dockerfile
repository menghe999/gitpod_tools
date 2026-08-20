# ============================================================
# 双 KDC 共用同一镜像模板：kdc1 / kdc2 由 start-kdc.sh 通过
# 环境变量（REALM / REALM2 / KDC_HOST / KDC_HOST2 /
# MASTER_PASSWORD）在容器启动时动态生成 krb5.conf。
# ============================================================
FROM centos:7

# centos:7 官方 yum 源已失效，替换为 vault.centos.org 镜像
COPY custom-repo/CentOS-Base.repo /etc/yum.repos.d/
COPY custom-repo/resolv.conf /etc/resolv.conf

# 安装 Kerberos 服务端
RUN yum install -y krb5-server krb5-libs krb5-workstation && \
    mkdir -p /var/kerberos/krb5kdc && \
    yum clean all

# KDC / kadmin 端口
EXPOSE 88 749

COPY start-kdc.sh /usr/local/bin/start-kdc.sh
RUN chmod +x /usr/local/bin/start-kdc.sh

ENTRYPOINT ["/usr/local/bin/start-kdc.sh"]
