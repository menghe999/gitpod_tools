docker-compose up -d

docker exec -it kdc1 bash

kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.6789.COM@EMR.1234.COM"

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


chmod 400 /root/nn.keytab
chmod 400 /root/dn.keytab
chmod 400 /root/rm.keytab
chmod 400 /root/nm.keytab



docker cp kdc1:/root/nn.keytab nn.keytab
docker cp kdc1:/root/dn.keytab dn.keytab
docker cp kdc1:/root/rm.keytab rm.keytab
docker cp kdc1:/root/nm.keytab nm.keytab