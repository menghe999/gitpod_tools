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
#      ⚠️ 实测：compose 覆盖 entrypoint 后，镜像的 CMD **不会**自动传入本脚本，
#      必须在 compose 里用 command: 显式指定（如 /run.sh、zkServer.sh
#      start-foreground），否则原 entrypoint 的 `exec "$@"` 空操作 → exit 0。
#      "$@" 把 command 原样透传给原 entrypoint，行为与不包装时完全一致；
#   3) 防御性 fallback：若 ORIG_ENTRYPOINT 不存在/不可执行，直接执行 CMD。
# ============================================================
set -u

if [ -x /root/install-krb5.sh ]; then
  /root/install-krb5.sh >/tmp/install-krb5.log 2>&1 &
  echo "[entry] krb5-user 后台安装中（容器内日志: /tmp/install-krb5.log）"
fi

ORIG="${ORIG_ENTRYPOINT:-}"
echo "[entry] 收到 CMD 参数: $*（共 $# 个）ORIG_ENTRYPOINT=${ORIG:-空}"
echo "        若参数为空，说明镜像 CMD 未传入，需在 compose 的 command: 显式指定（见 zk1/datanode 注释）"
if [ -n "$ORIG" ] && [ -x "$ORIG" ]; then
  exec "$ORIG" "$@"
fi

echo "[entry] 警告: 未找到原始 entrypoint（ORIG_ENTRYPOINT=${ORIG:-空}），直接执行 CMD: $*" >&2
exec "$@"
