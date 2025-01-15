#!/bin/bash

# 设置 Kerberos 配置文件
cat <<EOF > /etc/krb5.conf
[logging]
 default = FILE:/var/log/krb5libs.log
 kdc = FILE:/var/log/krb5kdc.log
 admin_server = FILE:/var/log/kadmind.log

[libdefaults]
 default_realm = ${REALM}
 dns_lookup_realm = false
 dns_lookup_kdc = false
 ticket_lifetime = 24h
 renew_lifetime = 7d
 forwardable = true

[realms]
 ${REALM} = {
  kdc = ${KDC_HOST}
  admin_server = ${KDC_HOST}
 }
 ${REALM2} = {
  kdc = ${KDC_HOST2}
  admin_server = ${KDC_HOST2}
 }

[domain_realm]
 .${DOMAIN} = ${REALM}
 ${DOMAIN} = ${REALM}
 .${DOMAIN2} = ${REALM2}
 ${DOMAIN2} = ${REALM2}

[capaths]
.${REALM} = {
  ${REALM2} = .
}
.${REALM2} = {
  ${REALM} = .
}
EOF

# 创建 KDC 数据库
kdb5_util create -s -P ${MASTER_PASSWORD}

# 启动 KDC 和管理服务器
krb5kdc
kadmind

# 保持容器运行
tail -f /dev/null