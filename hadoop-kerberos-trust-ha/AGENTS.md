# AGENTS.md — hadoop-kerberos-trust-ha

给 AI 编码代理（Claude Code / Codex / Cursor 等）的本目录工作指南。本文件描述该目录
的架构、命令、约定与修改时的联动清单，帮助代理在不破坏环境的前提下安全地阅读、修改
和验证代码。所有文档与注释均为中文，新增内容请保持中文。

---

## 1. 项目概览

**双集群 HDFS 高可用 + Kerberos 跨域互信（最小可用 HA 版）+ Flink 1.18.1 跨集群示例**，共 15 个容器：

- **双 KDC 跨域互信**：`kdc1`（EMR.1234.COM）、`kdc2`（EMR.6789.COM），双向 krbtgt
  互信（密码 `123456`），支持 `test@EMR.1234.COM` ↔ `test1@EMR.6789.COM` 互访；
- **每集群 NameNode HA**：双 NN（active/standby）+ 3 台共享 JournalNode（QJM 仲裁
  2/3）+ 单节点 ZooKeeper + ZKFC 自动故障转移；
- **客户端访问**：本域走 nameservice（`hdfs://ns1234` / `hdfs://ns6789`，
  `ConfiguredFailoverProxyProvider` 自动路由）；跨域用显式地址
  （`hdfs://nn1.emr.6789.com:9000`）；
- **Flink 示例**（docs/04）：作业运行在 ns1234 的 YARN、状态/checkpoint 落
  `hdfs://ns1234/flink/checkpoints`，以 `test@EMR.1234.COM` 租户采集 ns6789 文件、
  打印日志并写回 ns6789 另一目录（`flink/` 目录 + `scripts/04/05-flink-*.sh`）。

定位是**验证 HA 功能与跨域互信协同的演示环境，非生产配置**。已知简化：ZK 单节点、
每集群 1 台 DN（`dfs.replication=1`）、隔离方法 `shell(true)`、Web UI 为 HTTP_ONLY。

## 2. 常用命令

所有命令在**本目录**（`hadoop-kerberos-trust-ha/`）下执行；脚本内部自行 `cd` 到仓库根，
因此从本目录运行即可。

```bash
bash scripts/01-init-kdc.sh        # [首次必做] 构建并启动双 KDC、建立互信、生成并分发 keytab（约 2-3 分钟，幂等）
bash scripts/02-start-hdfs.sh      # 启动 HA 集群：ZK → JN → 双 NN → DN/YARN（约 3-5 分钟）
bash scripts/03-verify.sh          # 自动验证：HA 状态 + 故障转移演练 + 双向跨域互信（PASS/FAIL 汇总）
bash scripts/04-flink-setup.sh     # [可选] Flink 1.18.1：下载发行版 + 启动 flink-client（约 460MB，幂等）
bash scripts/05-flink-demo.sh      # [可选] 编译/造数/提交/验证 Flink 跨集群演示作业（test 租户）
bash scripts/00-cleanup.sh         # 停止并删除容器/数据卷/网络；加 --purge 额外删除生成的 keytab 与 krb5.conf
```

> 前提：Docker 20.10+（compose v2 或 docker-compose v1）、内存 ≥ 8GB、磁盘 ≥ 10GB、
> 可访问 Docker Hub（`zookeeper:3.8`、`bde2020/hadoop-datanode:2.0.0-hadoop3.2.1-java8`）。
> 内存不足时通过 `ha/docker-compose.yml` 的 `HADOOP_HEAPSIZE`（NN=768 / JN=512）调低。

## 3. 目录结构

```
hadoop-kerberos-trust-ha/
├── AGENTS.md                     # 本文件
├── README.md                     # 架构说明、快速开始、排错速查（最权威入口）
├── docs/
│   ├── 01-原理说明-HA.md         # HDFS HA 原理（QJM/ZKFC）+ 与跨域互信的结合
│   ├── 02-手动验证-HA.md         # 手工命令：查状态/手动切换/nameservice 访问/数据一致性
│   ├── 03-常见问题-HA.md         # Q0~Q14 排错表（改配置前先查这里）
│   └── 04-Flink跨集群Demo.md     # Flink 1.18.1 示例：需求映射/步骤/验证/FAQ
├── kerberos/                     # 双 KDC：Dockerfile / start-kdc.sh / custom-repo（与基础版一致）
├── flink/                        # Flink 示例：job/ 源码、conf/flink-conf.yaml、dist/(下载产物勿提交)
├── ha/
│   ├── docker-compose.yml        # ZK + 3×JN + 4×NN + 2×DN + RM/NM + flink-client（15 容器，静态 IP 见 §5）
│   ├── conf/
│   │   ├── cluster-a/            # core-site.xml / hdfs-site.xml(HA) / yarn-site.xml
│   │   ├── cluster-b/            # core-site.xml / hdfs-site.xml(HA)
│   │   ├── journalnode/          # hdfs-site.xml（JN 专用，含 SPNEGO 配置，见 FAQ Q0）
│   │   ├── scripts/              # start-nn.sh / start-jn.sh（容器 entrypoint，见 FAQ Q11）
│   │   │                          install-krb5.sh（启动时补装 krb5-user/kinit，幂等）
│   │   │                          container-entry.sh（默认 entrypoint 容器的入口包装）
│   │   └── zk/                   # zoo.cfg（显式 clientPort=2181，见 FAQ Q10）
│   └── kerberos/  kerberos1/     # 【生成产物】01 分发的 krb5.conf 与 keytab，勿手改、勿提交
└── scripts/
    ├── 00-cleanup.sh             # 清理（--purge 删除 keytab）
    ├── 01-init-kdc.sh            # KDC 初始化 + 互信 + principal + keytab 导出/分发
    ├── 02-start-hdfs.sh          # 分阶段启动 + 就绪等待
    ├── 03-verify.sh              # 自动验证（24 项 PASS 检查）
    ├── 04-flink-setup.sh         # Flink 发行版下载 + flink-client 启动（幂等）
    └── 05-flink-demo.sh          # Flink 作业：编译(javac)/ns6789 造数/提交 YARN/验证
```

## 4. 硬性约定（违反会踩坑）

1. **生成产物只读**：`ha/kerberos/`、`ha/kerberos1/` 由 `01-init-kdc.sh` 生成
   （krb5.conf + keytab），`.gitignore` 已忽略 `*.keytab`。**绝不提交 keytab**；
   如需"全新重来"，必须 `bash scripts/00-cleanup.sh --purge` 后重跑 01 ——
   keytab 与 KDC 数据库强绑定，删除容器/数据卷后不重跑 01 必报 Kerberos 错误
   （"Server not found in Kerberos database"，FAQ Q6）。
2. **与基础版互斥部署**：`hadoop-kerberos-trust` 与 `hadoop-kerberos-trust-ha` 使用
   相同的网络名 `hadoop-kerberos-net`（默认网段 172.28.0.0/24）和宿主端口
   （88/50070/8088 等），**同一宿主机只部署一套**。整体迁移网段用
   `export SUBNET_BASE=172.30.0`，且 **01/02 脚本必须同值**（compose 中 `${SUBNET_BASE:-172.28.0}`）。
3. **脚本风格**：所有 scripts 以 `set -euo pipefail`（03 用 `set -uo pipefail`）开头；
   兼容 compose v2/v1：`docker compose version >/dev/null 2>&1 && DC="docker compose" || DC="docker-compose"`；
   分阶段输出用 `==> [x/y] 步骤` 或 `[i/j]` 格式；就绪检查用带轮数上限的 `for i in $(seq 1 N)` + `sleep 5`，
   超时报错并给出 `docker logs <容器>` 排查提示。
4. **不动生成产物与运行期状态**：不要手写 keytab/krb5.conf 内容；不要在容器里手工
   format/bootstrap 绕脚本（重启幂等逻辑在 `start-nn.sh`，参考 docs/01 第 2 节）。
5. **改配置后必须重建容器**：compose 中配置/脚本以 bind mount 挂载，`docker restart`
   或 `docker compose up -d --force-recreate <svc>` 才会生效（见 FAQ Q10/Q11 的修复步骤）。
6. **密码与测试身份**：互信 krbtgt 密码 `123456`、master 密码 `master1234/master6789`、
   测试用户 `test`/`test1`（密码 123456）——全部为测试用途，注释中勿写成生产凭据。

## 5. 容器 / 主机名 / IP 速查（`${SUBNET_BASE:-172.28.0}` 前缀）

| 容器 | 主机名（realm） | IP | 角色 |
|---|---|---|---|
| kdc1 / kdc2 | — | .2 / .3 | 双 KDC（EMR.1234.COM / EMR.6789.COM） |
| zk1 | zk1 | .10 | ZooKeeper（ZKFC 仲裁，2181） |
| jn1 / jn2 / jn3 | jnN.emr.1234.com | .11 / .12 / .13 | JournalNode（QJM 8485，跨域供 ns6789 使用） |
| datanode / resourcemanager / nodemanager | datanode.emr.1234.com 等 | .22 / .23 / .24 | 集群 A DN / RM / NM |
| flink-client | flink-client.emr.1234.com | .60 | Flink 1.18.1 客户端（提交作业到 ns1234 YARN，docs/04） |
| datanode1 | datanode.emr.6789.com | .32 | 集群 B DN |
| namenode-a1 / a2 | nn1 / nn2.emr.1234.com | .41 / .42 | 集群 A NN（ns1234） |
| namenode-b1 / b2 | nn1 / nn2.emr.6789.com | .51 / .52 | 集群 B NN（ns6789） |

compose 中每服务都有完整 `extra_hosts`（YAML 锚点 `*EXTRA_HOSTS`）；**新增服务或改 IP
时必须同步更新锚点与 `03-verify.sh` 的容器检查列表**。

## 6. 修改代码时的联动清单（防漏）

- **新增 Kerberos principal / keytab** → 改 `scripts/01-init-kdc.sh` 三处：
  principal 列表（§3.2/§4.2）、keytab 导出（§3.4/§4.4）、非空校验列表（§3.5/§4.5），
  以及 `02-start-hdfs.sh` 预检清单（§预检）与 `ha/kerberos*/README.md` 的文件清单。
- **新增/改名容器** → 改 `ha/docker-compose.yml`（服务 + `extra_hosts` 锚点）、
  `scripts/03-verify.sh` 的容器存活检查列表（§0）与 kinit 可用性检查（§0.5）、
  `README.md` 架构图与目录结构。**新容器必须接入 krb5 补装**：compose 挂载
  `./conf/scripts/install-krb5.sh:/root/install-krb5.sh:ro`；自定义 entrypoint 的
  脚本开头调用它（后台、best-effort），默认 entrypoint 的容器用
  `container-entry.sh` 包装（`entrypoint: ["/bin/bash","/root/container-entry.sh"]`
  + `ORIG_ENTRYPOINT=<镜像原始入口>`）。
- **改 HA 配置**（hdfs-site / core-site / start-*.sh）→ 先读 `docs/03-常见问题-HA.md`
  的 Q0/Q10/Q11（SPNEGO 缺配置、ZK clientPort、`_HOST` 反向解析竞态），并在
  `docs/01-原理说明-HA.md` 中同步原理描述。
- **改验证逻辑** → 保持 `03-verify.sh` 的 `ok/bad/run/nn_state/check_state/wait_state`
  辅助函数风格，新增检查沿用 `[PASS]/[FAIL]` 输出，最终 `exit $FAIL`。
- **任何改动** → 同步更新 `README.md`（排错速查表）与对应 `docs/*-HA.md`；文档与脚本
  不一致是本仓库最常见的问题。

## 7. 常见陷阱速查（详见 docs/03-常见问题-HA.md）

| 现象 | 根因 / 处理 |
|---|---|
| JN 崩溃重启循环 "Principal not defined" | JN Web 缺 SPNEGO principal → `conf/journalnode/hdfs-site.xml` 已配置；改后重建容器（Q0） |
| nn2 一直等待 / bootstrapStandby 失败 | 等 nn1 先 active；JN 8485 可达；必要时 `rm -rf /hadoop/dfs/name/current` 后重启（Q2） |
| 故障转移 120s 未接管 | zk1 存活？ZKFC 日志？接管一般 ~15s（Q3） |
| NN 卡"等待 ZooKeeper (zk1:2181)" | zookeeper:3.8 镜像单节点不监听 2181 → `conf/zk/zoo.cfg` 显式 clientPort；`--force-recreate zk1`（Q10） |
| JN/NN 重启循环 "Unable to obtain password from user" | `_HOST` 被反解成短主机名 → `start-jn.sh/start-nn.sh` 已写 /etc/hosts 固化 FQDN；**勿用 sed -i 改 /etc/hosts**（bind mount 会报 Device or resource busy），须 `cat >` 原地重写（Q11） |
| NN format 静默失败/重启循环 "Server has invalid Kerberos principal ... expecting: jn/jn3@..." | NN→JN 客户端方向 `_HOST` 反解竞态：`extra_hosts` 短名（jn3）排在 FQDN 前 → 已移除 jn1-3 短名条目；`start-nn.sh` 把 JN IP 重写为 FQDN 打头并逐台断言（Q12） |
| NN 在"RPC 就绪"/"等待对端 active"后静默 exit 1 重启（无报错） | 镜像缺 krb5-user（kinit 缺失）→ 双层设计：`start-nn.sh` 对 kinit 零依赖（状态检查用 JMX/curl，zkfc/bootstrapStandby 由 JVM 自登录；`fail()`/EXIT trap 走 stdout）；同时所有容器启动时后台补装 krb5-user（`install-krb5.sh`，幂等、不阻塞启动、失败仅告警），详见 FAQ Q13 |
| DataNode 报 "Cannot start secure DataNode due to incorrect config"（登录已成功） | checkSecureConfig 要求 jsvc 特权端口或 HTTPS_ONLY+sasl resolver；HA 版全链路 HTTP_ONLY → 已加 `ignore.secure.ports.for.testing=true`（官方测试逃生口，注意无 `dfs.` 前缀，Q14） |
| Flink TM 报 NoClassDefFoundError（hadoop 类） | Flink 1.18 的 AM/TM 类路径只来自 hadoop 配置 `yarn.application.classpath`（`Utils.setupYarnClassPath`），不继承客户端 HADOOP_CLASSPATH → cluster-a/yarn-site.xml 已配容器内绝对路径 /opt/hadoop-3.2.1（docs/04） |
| 脚本 `set -u` 报 `xxx�: unbound variable`（变量已赋值） | bash 多字节解析怪癖：`$VAR` 后紧跟中文/全角字符时首字节被吞进变量名 → 一律写 `${VAR}`；审计命令见 FAQ Q15 |
| 跨域报 "Server not found in Kerberos database" | keytab 与 KDC 不匹配 → 重跑 01；extra_hosts 缺失；时钟偏差（Q6） |

## 8. 手动验证常用命令（代理排查时直接用）

```bash
# HA 状态（需先 kinit）
docker exec namenode-a1 bash -c 'kinit -kt /root/test.keytab test && hdfs haadmin -ns ns1234 -getServiceState nn1 && hdfs haadmin -ns ns1234 -getServiceState nn2'

# nameservice 代理访问（本域）
docker exec namenode-a1 bash -c 'kinit -kt /root/test.keytab test && hdfs dfs -ls hdfs://ns1234/user'

# 跨域访问（显式地址）
docker exec namenode-a1 bash -c 'kinit -kt /root/test.keytab test && hdfs dfs -ls hdfs://nn1.emr.6789.com:9000/user'

# 就绪/端口检查
docker exec jn1 bash -c '(exec 3<>/dev/tcp/localhost/8485) 2>/dev/null && echo JN-OK'
docker exec zk1 bash -c '(exec 3<>/dev/tcp/127.0.0.1/2181) 2>/dev/null && echo ZK-OK'

# 日志
docker logs namenode-a1 | grep -iE "zkfc|active|standby" | tail -20
docker logs jn1 | tail -20
```

完整手工步骤见 `docs/02-手动验证-HA.md`。
