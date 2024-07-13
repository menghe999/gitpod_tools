#!/bin/bash

# file_name: init_k_user.sh
# create_time: 2024/07/13
# author：mengh
# description: 创建principal的脚本，需要在kdc节点，用root用户执行

# 配置租户名、域
K_USER=flink
# Kerberos域，由Kerberos服务初始化时决定，不可随意更改
K_REALM=EXAMPLE.COM

echo "即将创建 $K_USER@$K_REALM 租户"
# 为该租户创建家目录（建议在每个节点都执行一下，为了保证租户和linux用户能对应起来）
useradd $K_USER

# 创建一个新的租户，随机生成密码
# kadmin.local -q "addprinc -randkey $K_USER@$K_REALM"

# 创建一个新的租户，也可手动配置密码
kadmin.local -q "addprinc -pw $K_USER@pass $K_USER@$K_REALM" 

echo "$K_USER@$K_REALM 租户创建成功，密码 $K_USER@pass"

# 导出keytab文件
kadmin.local -q "xst -norandkey -k  /home/$K_USER/$K_USER.keytab $K_USER"

echo "$K_USER@$K_REALM 租户导出keytab文件成功"

# keytab文件权限修改
chmod 400  /home/$K_USER/$K_USER.keytab

chown $K_USER:$K_USER /home/$K_USER/$K_USER.keytab


# # 建议在hdfs上为该租户创建一个目录，需要hdfs用户权限

# echo "切换到hdfs用创建$K_USER 用户的家目录"
# su - hdfs <<EOF
# hdfs dfs -mkdir /user/$K_USER;
# hdfs dfs -chown -R $K_USER:$K_USER /user/$K_USER;
# exit;
# EOF
