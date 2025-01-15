# 使用 CentOS 作为基础镜像
FROM centos:7

# 复制自定义仓库配置
COPY custom-repo/CentOS-Base.repo /etc/yum.repos.d/
COPY custom-repo/resolv.conf /etc/resolv.conf

# 安装必要的软件包
RUN yum install -y krb5-server krb5-libs krb5-workstation

# 创建 Kerberos 配置文件目录
RUN mkdir -p /var/kerberos/krb5kdc

# 暴露 Kerberos 端口
EXPOSE 88 749

# 设置启动脚本
COPY kdc2/start-kdc.sh /usr/local/bin/start-kdc.sh
RUN chmod +x /usr/local/bin/start-kdc.sh

# 设置入口点
ENTRYPOINT ["/usr/local/bin/start-kdc.sh"]