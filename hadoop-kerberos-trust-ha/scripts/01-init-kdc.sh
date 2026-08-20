#!/bin/bash
# ============================================================
# 01-init-kdc.sh —— 初始化双 KDC 跨域互信环境（HDFS HA 版）
#
# 与基础版的差异（HA 需要）：
#   - 每个集群有 nn1 / nn2 两台 NameNode，需分别导出 nn1.keytab / nn2.keytab
#   - 新增 3 台 JournalNode 主体 jn/jn1、jn/jn2、jn/jn3（共享 jn.keytab）
#   - keytab 分发到 ha/kerberos 与 ha/kerberos1
#
# 步骤：
#   1) 构建并启动 kdc1 / kdc2
#   2) 等待两个 KDC 就绪
#   3) kdc1(EMR.1234.COM) 建立互信、创建服务 principal、导出 keytab
#   4) kdc2(EMR.6789.COM) 同上
#   5) 将 krb5.conf 与 keytab 分发到 ha/kerberos* 目录
#
# 幂等说明：
#   - 不依赖 kadmin 退出码判断 principal 是否存在（部分 krb5 版本中
#     getprinc 对不存在的 principal 也返回 0）；
#   - addprinc 无条件执行，已存在的 principal 会报 "already exists" 并忽略，
#     密钥保持不变；
#   - keytab 先删除再重新导出，导出后逐个校验文件非空，失败立即报错。
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
  local realm=$2
  for i in $(seq 1 60); do
    if docker exec "$container" bash -c \
        "kadmin.local -q 'listprincs' 2>/dev/null | grep -qF 'krbtgt/${realm}@${realm}'"; then
      echo "  $container 已就绪 (数据库可用)"
      return 0
    fi
    sleep 5
  done
  echo "错误: $container 在 300 秒内未就绪，请检查: docker logs $container" >&2
  return 1
}
wait_kdc kdc1 "EMR.1234.COM"
wait_kdc kdc2 "EMR.6789.COM"

# ---------- 3) kdc1: 互信 + principal + keytab ----------
echo
echo "=============================================="
echo " [3/5] kdc1 (EMR.1234.COM) 建立互信并导出 keytab"
echo "=============================================="
docker exec kdc1 bash -c '
set -e

# 3.1 跨域互信：两个方向的 krbtgt principal（两侧密码一致 = 123456）
kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.6789.COM@EMR.1234.COM" >/dev/null 2>&1 || true
kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.1234.COM@EMR.6789.COM" >/dev/null 2>&1 || true
if ! kadmin.local -q "listprincs" 2>/dev/null | grep -qE \
    "krbtgt/EMR\.6789\.COM@EMR\.1234\.COM|krbtgt/EMR\.1234\.COM@EMR\.6789\.COM"; then
  echo "错误: 双向互信 krbtgt principal 创建失败" >&2
  exit 1
fi
echo "  [kdc1] 双向互信 krbtgt 已确认"

# 3.2 HDFS / YARN 服务 principal（已存在则忽略，密钥不变）
for p in \
  nn/nn1.emr.1234.com \
  nn/nn2.emr.1234.com \
  HTTP/nn1.emr.1234.com \
  HTTP/nn2.emr.1234.com \
  dn/datanode.emr.1234.com \
  HTTP/datanode.emr.1234.com \
  jn/jn1.emr.1234.com \
  jn/jn2.emr.1234.com \
  jn/jn3.emr.1234.com \
  HTTP/jn1.emr.1234.com \
  HTTP/jn2.emr.1234.com \
  HTTP/jn3.emr.1234.com \
  rm/resourcemanager.emr.1234.com \
  nm/nodemanager.emr.1234.com; do
  kadmin.local -q "addprinc -randkey $p@EMR.1234.COM" >/dev/null 2>&1 || true
done

# 3.3 本地测试用户 test（密码 123456）
kadmin.local -q "addprinc -pw 123456 test@EMR.1234.COM" >/dev/null 2>&1 || true

# 3.4 导出 keytab（先删除旧文件，避免 ktadd 追加产生重复条目）
rm -f /root/nn1.keytab /root/nn2.keytab /root/dn.keytab /root/jn.keytab \
      /root/rm.keytab /root/nm.keytab /root/test.keytab
kadmin.local -q "xst -k /root/nn1.keytab nn/nn1.emr.1234.com HTTP/nn1.emr.1234.com" >/dev/null 2>&1 || true
kadmin.local -q "xst -k /root/nn2.keytab nn/nn2.emr.1234.com HTTP/nn2.emr.1234.com" >/dev/null 2>&1 || true
kadmin.local -q "xst -k /root/dn.keytab dn/datanode.emr.1234.com HTTP/datanode.emr.1234.com" >/dev/null 2>&1 || true
kadmin.local -q "xst -k /root/jn.keytab jn/jn1.emr.1234.com jn/jn2.emr.1234.com jn/jn3.emr.1234.com HTTP/jn1.emr.1234.com HTTP/jn2.emr.1234.com HTTP/jn3.emr.1234.com" >/dev/null 2>&1 || true
kadmin.local -q "xst -k /root/rm.keytab rm/resourcemanager.emr.1234.com" >/dev/null 2>&1 || true
kadmin.local -q "xst -k /root/nm.keytab nm/nodemanager.emr.1234.com" >/dev/null 2>&1 || true
kadmin.local -q "xst -norandkey -k /root/test.keytab test@EMR.1234.COM" >/dev/null 2>&1 || true

# 3.5 校验：所有 keytab 必须导出成功且非空
for f in nn1.keytab nn2.keytab dn.keytab jn.keytab rm.keytab nm.keytab test.keytab; do
  if [ ! -s "/root/$f" ]; then
    echo "错误: /root/$f 导出失败（principal 可能未创建成功）" >&2
    exit 1
  fi
done
chmod 400 /root/*.keytab
echo "  [kdc1] keytab 导出完成: nn1 / nn2 / dn / jn / rm / nm / test"
'

# ---------- 4) kdc2: 互信 + principal + keytab ----------
echo
echo "=============================================="
echo " [4/5] kdc2 (EMR.6789.COM) 建立互信并导出 keytab"
echo "=============================================="
docker exec kdc2 bash -c '
set -e

# 4.1 跨域互信：两个方向的 krbtgt principal（与 kdc1 密码一致 = 123456）
kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.6789.COM@EMR.1234.COM" >/dev/null 2>&1 || true
kadmin.local -q "addprinc -pw 123456 krbtgt/EMR.1234.COM@EMR.6789.COM" >/dev/null 2>&1 || true
if ! kadmin.local -q "listprincs" 2>/dev/null | grep -qE \
    "krbtgt/EMR\.6789\.COM@EMR\.1234\.COM|krbtgt/EMR\.1234\.COM@EMR\.6789\.COM"; then
  echo "错误: 双向互信 krbtgt principal 创建失败" >&2
  exit 1
fi
echo "  [kdc2] 双向互信 krbtgt 已确认"

# 4.2 HDFS 服务 principal（已存在则忽略，密钥不变）
for p in \
  nn/nn1.emr.6789.com \
  nn/nn2.emr.6789.com \
  HTTP/nn1.emr.6789.com \
  HTTP/nn2.emr.6789.com \
  dn/datanode.emr.6789.com \
  HTTP/datanode.emr.6789.com; do
  kadmin.local -q "addprinc -randkey $p@EMR.6789.COM" >/dev/null 2>&1 || true
done

# 4.3 本地测试用户 test1（密码 123456）
kadmin.local -q "addprinc -pw 123456 test1@EMR.6789.COM" >/dev/null 2>&1 || true

# 4.4 导出 keytab
rm -f /root/nn1.keytab /root/nn2.keytab /root/dn.keytab /root/test1.keytab
kadmin.local -q "xst -k /root/nn1.keytab nn/nn1.emr.6789.com HTTP/nn1.emr.6789.com" >/dev/null 2>&1 || true
kadmin.local -q "xst -k /root/nn2.keytab nn/nn2.emr.6789.com HTTP/nn2.emr.6789.com" >/dev/null 2>&1 || true
kadmin.local -q "xst -k /root/dn.keytab dn/datanode.emr.6789.com HTTP/datanode.emr.6789.com" >/dev/null 2>&1 || true
kadmin.local -q "xst -norandkey -k /root/test1.keytab test1@EMR.6789.COM" >/dev/null 2>&1 || true

# 4.5 校验：所有 keytab 必须导出成功且非空
for f in nn1.keytab nn2.keytab dn.keytab test1.keytab; do
  if [ ! -s "/root/$f" ]; then
    echo "错误: /root/$f 导出失败（principal 可能未创建成功）" >&2
    exit 1
  fi
done
chmod 400 /root/*.keytab
echo "  [kdc2] keytab 导出完成: nn1 / nn2 / dn / test1"
'

# ---------- 5) 分发到 ha 目录 ----------
echo
echo "=============================================="
echo " [5/5] 分发 krb5.conf / keytab 到 ha/kerberos*"
echo "=============================================="
mkdir -p ha/kerberos ha/kerberos1

docker cp kdc1:/etc/krb5.conf ha/kerberos/krb5.conf
for f in nn1.keytab nn2.keytab dn.keytab jn.keytab rm.keytab nm.keytab test.keytab; do
  docker cp "kdc1:/root/$f" "ha/kerberos/$f"
done
echo "  集群 A 文件已就绪: $(ls ha/kerberos | tr '\n' ' ')"

docker cp kdc2:/etc/krb5.conf ha/kerberos1/krb5.conf
for f in nn1.keytab nn2.keytab dn.keytab test1.keytab; do
  docker cp "kdc2:/root/$f" "ha/kerberos1/$f"
done
echo "  集群 B 文件已就绪: $(ls ha/kerberos1 | tr '\n' ' ')"

chmod 644 ha/kerberos/* ha/kerberos1/* 2>/dev/null || true

echo
echo "=============================================="
echo " 初始化完成！下一步："
echo "   bash scripts/02-start-hdfs.sh"
echo "   bash scripts/03-verify.sh"
echo "=============================================="
