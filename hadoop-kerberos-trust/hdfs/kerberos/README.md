本目录文件由 scripts/01-init-kdc.sh 自动生成，请勿手动创建：

  krb5.conf    集群 A（EMR.1234.COM）使用的 krb5.conf（含两个 realm 与 capaths）
  *.keytab     nn / dn / rm / nm / test 的 keytab（来自 kdc1）

先执行：bash scripts/01-init-kdc.sh
再启动：bash scripts/02-start-hdfs.sh
