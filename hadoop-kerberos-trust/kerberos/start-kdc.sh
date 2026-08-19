#!/bin/bash
set -e

# ============================================================
# KDC 容器启动脚本（kdc1 / kdc2 共用）
# 通过环境变量生成 krb5.conf：
#   REALM / DOMAIN     本 realm 及其域名
#   KDC_HOST           本 KDC 主机名
#   REALM2 / DOMAIN2   对端 realm 及其域名（用于跨域互信）
#   KDC_HOST2          对端 KDC 主机名
#   MASTER_PASSWORD    本 KDC 数据库 master 密码
# ============================================================

# 1) 生成 krb5.conf：同时声明两个 realm，并用 [capaths] 声明
#    两个 realm 直接互信（"." 表示直连，无需中间 realm 转发）
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

# 2) 初始化 KDC 数据库（仅首次；容器被删除重建时会自动重建）
if [ ! -f /var/kerberos/krb5kdc/principal ]; then
  kdb5_util create -s -P ${MASTER_PASSWORD}
fi

# 3) 启动 KDC 与管理服务器
krb5kdc
kadmind || true

# 4) 保持容器前台运行
tail -f /dev/null
