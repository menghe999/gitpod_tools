### 启动两个kdc并配置双向互信，添加一些基础的principle

cd shell/kerberos/advance/
docker-compose up -d
---
> kdc1上执行

docker exec -it kdc1 bash

kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.6789.COM@EMR.1234.COM"
kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.1234.COM@EMR.6789.COM"
 

kadmin.local -q "getprinc krbtgt/EMR.6789.COM@EMR.1234.COM"
kadmin.local -q "getprinc krbtgt/EMR.1234.COM@EMR.6789.COM"

kadmin.local -q "addprinc -randkey nn/namenode.emr.1234.com@EMR.1234.COM"
kadmin.local -q "addprinc -randkey dn/datanode.emr.1234.com@EMR.1234.COM"
kadmin.local -q "addprinc -randkey HTTP/namenode.emr.1234.com@EMR.1234.COM"
kadmin.local -q "addprinc -randkey HTTP/datanode.emr.1234.com@EMR.1234.COM"


kadmin.local -q "addprinc -randkey rm/resourcemanager.emr.1234.com@EMR.1234.COM"
kadmin.local -q "addprinc -randkey nm/nodemanager.emr.1234.com@EMR.1234.COM"


kadmin.local -q "xst -k /root/nn.keytab nn/namenode.emr.1234.com HTTP/namenode.emr.1234.com"
kadmin.local -q "xst -k /root/dn.keytab dn/datanode.emr.1234.com HTTP/datanode.emr.1234.com"
kadmin.local -q "xst -k /root/rm.keytab rm/resourcemanager.emr.1234.com"
kadmin.local -q "xst -k /root/nm.keytab nm/nodemanager.emr.1234.com"
kadmin.local -q "xst -k /root/test.keytab test"


chmod 400 /root/nn.keytab
chmod 400 /root/dn.keytab
chmod 400 /root/rm.keytab
chmod 400 /root/nm.keytab
chmod 400 /root/test.keytab

> 本地用户test
kadmin.local -q  "addprinc -pw 123456 test"

cd hdfs/kerberos
docker cp kdc1:/root/nn.keytab nn.keytab
docker cp kdc1:/root/dn.keytab dn.keytab
docker cp kdc1:/root/rm.keytab rm.keytab
docker cp kdc1:/root/nm.keytab nm.keytab
docker cp kdc1:/etc/krb5.conf krb5.conf
docker cp kdc1:/root/test.keytab test.keytab

--- 
> kdc2上执行

docker exec -it kdc2 bash

kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.6789.COM@EMR.1234.COM"
kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.1234.COM@EMR.6789.COM"

kadmin.local -q "getprinc krbtgt/EMR.6789.COM@EMR.1234.COM"
kadmin.local -q "getprinc krbtgt/EMR.1234.COM@EMR.6789.COM"

kadmin.local -q "addprinc -randkey nn/namenode.emr.6789.com@EMR.6789.COM"
kadmin.local -q "addprinc -randkey dn/datanode.emr.6789.com@EMR.6789.COM"
kadmin.local -q "addprinc -randkey HTTP/namenode.emr.6789.com@EMR.6789.COM"
kadmin.local -q "addprinc -randkey HTTP/datanode.emr.6789.com@EMR.6789.COM"


kadmin.local -q "addprinc -randkey rm/resourcemanager.emr.6789.com@EMR.6789.COM"
kadmin.local -q "addprinc -randkey nm/nodemanager.emr.6789.com@EMR.6789.COM"


kadmin.local -q "xst -k /root/nn.keytab nn/namenode.emr.6789.com HTTP/namenode.emr.6789.com"
kadmin.local -q "xst -k /root/dn.keytab dn/datanode.emr.6789.com HTTP/datanode.emr.6789.com"
kadmin.local -q "xst -k /root/rm.keytab rm/resourcemanager.emr.6789.com"
kadmin.local -q "xst -k /root/nm.keytab nm/nodemanager.emr.6789.com"


chmod 400 /root/nn.keytab
chmod 400 /root/dn.keytab
chmod 400 /root/rm.keytab
chmod 400 /root/nm.keytab

> 本地用户test1
kadmin.local -q  "addprinc -pw 123456 test1"

cd shell/hdfs/kerberos1
docker cp kdc2:/root/nn.keytab nn.keytab
docker cp kdc2:/root/dn.keytab dn.keytab
docker cp kdc2:/root/rm.keytab rm.keytab
docker cp kdc2:/root/nm.keytab nm.keytab
docker cp kdc2:/etc/krb5.conf krb5.conf