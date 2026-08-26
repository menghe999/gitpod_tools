#!/bin/bash
# ============================================================
# container-entry.sh —— 容器统一入口包装（用于使用镜像默认 entrypoint 的服务）
#
# 覆盖服务：zk1（zookeeper:3.8）、datanode / datanode1 / resourcemanager /
# nodemanager（bde2020/hadoop-*）——这些容器在 compose 中没有自定义
# start-*.sh，主进程由镜像默认 entrypoint + CMD 启动。
#
# 职责：
#   1) 后台补装 krb5-user（kinit），幂等且不阻塞主进程启动（离线时属正常，
#      见 install-krb5.sh 与 FAQ Q13）；
#   2) 将控制权交回镜像原始 entrypoint（由环境变量 ORIG_ENTRYPOINT 指定）：
#      - bde2020/hadoop-*  -> /entrypoint.sh
#      - zookeeper:3.8     -> /docker-entrypoint.sh
#      镜像默认 CMD 通过 "$@" 原样透传（如 zkServer.sh start-foreground、
#      hdfs datanode），因此与不包装时的行为完全一致；
#   3) 防御性 fallback：若 ORIG_ENTRYPOINT 不存在/不可执行，直接执行 CMD。
# ============================================================
set -u

if [ -x /root/install-krb5.sh ]; then
  /root/install-krb5.sh >/tmp/install-krb5.log 2>&1 &
  echo "[entry] krb5-user 后台安装中（容器内日志: /tmp/install-krb5.log）"
fi

ORIG="${ORIG_ENTRYPOINT:-}"
if [ -n "$ORIG" ] && [ -x "$ORIG" ]; then
  exec "$ORIG" "$@"
fi

echo "[entry] 警告: 未找到原始 entrypoint（ORIG_ENTRYPOINT=${ORIG:-空}），直接执行 CMD: $*" >&2
exec "$@"
