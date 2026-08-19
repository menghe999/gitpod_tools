#!/bin/bash
# ============================================================
# 01-init-kdc.sh —— 初始化双 KDC 跨域互信环境
#
# 步骤：
#   1) 构建并启动 kdc1 / kdc2
#   2) 等待两个 KDC 就绪
#   3) kdc1(EMR.1234.COM) 建立互信、创建服务 principal、导出 keytab
#   4) kdc2(EMR.6789.COM) 同上（EMR.6789.COM）
#   5) 将 krb5.conf 与 keytab 分发到 hdfs/kerberos* 目录
#
# 幂等：重复执行安全（principal 已存在则跳过，keytab 重新导出覆盖）。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# 兼容 docker compose v2 / docker-compose v1
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  DC="docker-compose"
fi

# ---------- 1) 构建并启动双 KDC ----------
echo "=============================================="
echo " [1/5] 构建并启动双 KDC (kdc1 / kdc2)"
echo "=============================================="
(cd kerberos && $DC up -d --build)

# ---------- 2) 等待 KDC 就绪 ----------
echo
echo "=============================================="
echo " [2/5] 等待 KDC 就绪"
echo "=============================================="
wait_kdc() {
  local container=$1
  for i in $(seq 1 60); do
    if docker exec "$container" bash -c 'kadmin.local -q "listprincs" >/dev/null 2>&1'; then
      echo "  $container 已就绪"
      return 0
    fi
    sleep 5
  done
  echo "错误: $container 在 300 秒内未就绪，请检查: docker logs $container" >&2
  return 1
}
wait_kdc kdc1
wait_kdc kdc2

# ---------- 3) kdc1: 互信 + principal + keytab ----------
echo
echo "=============================================="
echo " [3/5] kdc1 (EMR.1234.COM) 建立互信并导出 keytab"
echo "=============================================="
docker exec kdc1 bash -c '
set -e

# 3.1 跨域互信：两个方向的 krbtgt principal（两侧密码必须一致 = 123456）
if ! kadmin.local -q "getprinc krbtgt/EMR.6789.COM@EMR.1234.COM" >/dev/null 2>&1; then
  kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.6789.COM@EMR.1234.COM"
  echo "  已创建 krbtgt/EMR.6789.COM@EMR.1234.COM"
fi
if ! kadmin.local -q "getprinc krbtgt/EMR.1234.COM@EMR.6789.COM" >/dev/null 2>&1; then
  kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.1234.COM@EMR.6789.COM"
  echo "  已创建 krbtgt/EMR.1234.COM@EMR.6789.COM"
fi

# 3.2 HDFS / YARN 服务 principal
for p in \
  nn/namenode.emr.1234.com \
  dn/datanode.emr.1234.com \
  HTTP/namenode.emr.1234.com \
  HTTP/datanode.emr.1234.com \
  rm/resourcemanager.emr.1234.com \
  nm/nodemanager.emr.1234.com; do
  if ! kadmin.local -q "getprinc $p@EMR.1234.COM" >/dev/null 2>&1; then
    kadmin.local -q "addprinc -randkey $p@EMR.1234.COM"
    echo "  已创建 $p@EMR.1234.COM"
  fi
done

# 3.3 本地测试用户 test（密码 123456）
if ! kadmin.local -q "getprinc test@EMR.1234.COM" >/dev/null 2>&1; then
  kadmin.local -q "addprinc -pw 123456 test@EMR.1234.COM"
  echo "  已创建 test@EMR.1234.COM"
fi

# 3.4 导出 keytab（先删除旧文件，避免 ktadd 追加产生重复条目）
rm -f /root/nn.keytab /root/dn.keytab /root/rm.keytab /root/nm.keytab /root/test.keytab
kadmin.local -q "xst -k /root/nn.keytab nn/namenode.emr.1234.com HTTP/namenode.emr.1234.com"
kadmin.local -q "xst -k /root/dn.keytab dn/datanode.emr.1234.com HTTP/datanode.emr.1234.com"
kadmin.local -q "xst -k /root/rm.keytab rm/resourcemanager.emr.1234.com"
kadmin.local -q "xst -k /root/nm.keytab nm/nodemanager.emr.1234.com"
kadmin.local -q "xst -norandkey -k /root/test.keytab test@EMR.1234.COM"
chmod 400 /root/*.keytab
echo "  keytab 导出完成: nn / dn / rm / nm / test"
'

# ---------- 4) kdc2: 互信 + principal + keytab ----------
echo
echo "=============================================="
echo " [4/5] kdc2 (EMR.6789.COM) 建立互信并导出 keytab"
echo "=============================================="
docker exec kdc2 bash -c '
set -e

# 4.1 跨域互信：两个方向的 krbtgt principal（与 kdc1 密码一致 = 123456）
if ! kadmin.local -q "getprinc krbtgt/EMR.6789.COM@EMR.1234.COM" >/dev/null 2>&1; then
  kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.6789.COM@EMR.1234.COM"
  echo "  已创建 krbtgt/EMR.6789.COM@EMR.1234.COM"
fi
if ! kadmin.local -q "getprinc krbtgt/EMR.1234.COM@EMR.6789.COM" >/dev/null 2>&1; then
  kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.1234.COM@EMR.6789.COM"
  echo "  已创建 krbtgt/EMR.1234.COM@EMR.6789.COM"
fi

# 4.2 HDFS 服务 principal
for p in \
  nn/namenode.emr.6789.com \
  dn/datanode.emr.6789.com \
  HTTP/namenode.emr.6789.com \
  HTTP/datanode.emr.6789.com \
  rm/resourcemanager.emr.6789.com \
  nm/nodemanager.emr.6789.com; do
  if ! kadmin.local -q "getprinc $p@EMR.6789.COM" >/dev/null 2>&1; then
    kadmin.local -q "addprinc -randkey $p@EMR.6789.COM"
    echo "  已创建 $p@EMR.6789.COM"
  fi
done

# 4.3 本地测试用户 test1（密码 123456）
if ! kadmin.local -q "getprinc test1@EMR.6789.COM" >/dev/null 2>&1; then
  kadmin.local -q "addprinc -pw 123456 test1@EMR.6789.COM"
  echo "  已创建 test1@EMR.6789.COM"
fi

# 4.4 导出 keytab
rm -f /root/nn.keytab /root/dn.keytab /root/rm.keytab /root/nm.keytab /root/test1.keytab
kadmin.local -q "xst -k /root/nn.keytab nn/namenode.emr.6789.com HTTP/namenode.emr.6789.com"
kadmin.local -q "xst -k /root/dn.keytab dn/datanode.emr.6789.com HTTP/datanode.emr.6789.com"
kadmin.local -q "xst -k /root/rm.keytab rm/resourcemanager.emr.6789.com"
kadmin.local -q "xst -k /root/nm.keytab nm/nodemanager.emr.6789.com"
kadmin.local -q "xst -norandkey -k /root/test1.keytab test1@EMR.6789.COM"
chmod 400 /root/*.keytab
echo "  keytab 导出完成: nn / dn / rm / nm / test1"
'

# ---------- 5) 分发到 hdfs 目录 ----------
echo
echo "=============================================="
echo " [5/5] 分发 krb5.conf / keytab 到 hdfs/kerberos*"
echo "=============================================="
mkdir -p hdfs/kerberos hdfs/kerberos1

docker cp kdc1:/etc/krb5.conf hdfs/kerberos/krb5.conf
for f in nn.keytab dn.keytab rm.keytab nm.keytab test.keytab; do
  docker cp "kdc1:/root/$f" "hdfs/kerberos/$f"
done
echo "  集群 A 文件已就绪: $(ls hdfs/kerberos | tr '\n' ' ')"

docker cp kdc2:/etc/krb5.conf hdfs/kerberos1/krb5.conf
for f in nn.keytab dn.keytab rm.keytab nm.keytab test1.keytab; do
  docker cp "kdc2:/root/$f" "hdfs/kerberos1/$f"
done
echo "  集群 B 文件已就绪: $(ls hdfs/kerberos1 | tr '\n' ' ')"

chmod 644 hdfs/kerberos/* hdfs/kerberos1/* 2>/dev/null || true

echo
echo "=============================================="
echo " 初始化完成！下一步："
echo "   bash scripts/02-start-hdfs.sh"
echo "   bash scripts/03-verify.sh"
echo "=============================================="
