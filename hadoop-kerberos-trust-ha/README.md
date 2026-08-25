# hadoop-kerberos-trust-ha —— 双集群 HDFS 高可用 + Kerberos 跨域互信（最小 HA 版）

在 [hadoop-kerberos-trust](../hadoop-kerberos-trust)（双 KDC 跨域互信 + 双 HDFS 集群）基础上，
为每个集群加入 **NameNode 高可用**：双 NameNode（active/standby）+ 3 台共享 JournalNode（QJM 仲裁）
+ ZooKeeper/ZKFC 自动故障转移，同时保留双集群 Kerberos 跨域互信能力。

> 定位：**最小可用 HA 版本**，用于验证 HA 功能与跨域互信在 HA 形态下的协同，非生产配置。
> 已知简化：ZooKeeper 单节点（ZK 自身非 HA）、每集群 1 台 DataNode（无数据冗余，`dfs.replication=1`）、
> 隔离方法 `shell(true)`（无 SSH 真实隔离）。

---

## 一、架构（14 个容器）

```
┌─ 共享基础层 ────────────────────────────────────────────────┐
│ kdc1 (EMR.1234.COM)  kdc2 (EMR.6789.COM)     双 KDC 跨域互信 │
│ zk1                         ZooKeeper（ZKFC 故障转移仲裁）    │
│ jn1 / jn2 / jn3             JournalNode（QJM 仲裁）          │
│                             同时服务 ns1234 与 ns6789        │
└──────────────────────────────────────────────────────────────┘
┌─ 集群 A（EMR.1234.COM / nameservice=ns1234）────────────────┐
│ namenode-a1  nn1.emr.1234.com (.41)  active/standby 候选    │
│ namenode-a2  nn2.emr.1234.com (.42)  standby/active 候选    │
│ datanode     datanode.emr.1234.com (.22)                   │
│ resourcemanager / nodemanager（YARN，保留）                  │
└──────────────────────────────────────────────────────────────┘
┌─ 集群 B（EMR.6789.COM / nameservice=ns6789）────────────────┐
│ namenode-b1  nn1.emr.6789.com (.51)                        │
│ namenode-b2  nn2.emr.6789.com (.52)                        │
│ datanode1    datanode.emr.6789.com (.32)                   │
└──────────────────────────────────────────────────────────────┘
```

- **客户端访问方式**：本域走 nameservice（`hdfs://ns1234` / `hdfs://ns6789`），由
  `ConfiguredFailoverProxyProvider` 自动路由到当前 active NameNode，NN 故障时客户端自动切换；
- **跨域访问**：`hdfs://nn1.emr.6789.com:9000`（跨域互信经双 KDC 换票；最小版跨域用显式地址，
  生产环境应在客户端配置远端 nameservice）；
- **QJM 共享**：3 台 JN 的编辑日志按 nameservice 子目录隔离（`/hadoop/dfs/journal/<ns>/current`），
  两台集群共用一组 JN，可容忍 1 台 JN 宕机（仲裁多数 2/3）。

---

## 二、前置要求

| 项目 | 要求 |
|---|---|
| Docker | 20.10+（支持 compose v2 或 docker-compose v1） |
| 内存 | ≥ 8GB（14 个容器；可通过 `HADOOP_HEAPSIZE` 环境变量调低堆内存） |
| 磁盘 | ≥ 10GB |
| 网络 | 能访问 Docker Hub（zookeeper:3.8、bde2020 镜像） |

> ⚠️ 与基础版互斥：两套包使用相同的网络名 `hadoop-kerberos-net`（默认网段 172.28.0.0/24）与
> 宿主端口（88/50070/8088 等），**不要在同一台宿主机上同时部署两套**。
> 若需整体迁移网段，与基础版相同：`export SUBNET_BASE=172.30.0`（01/02 必须同值）。

---

## 三、快速开始

```bash
# 1) 初始化双 KDC 跨域互信 + 生成 keytab（首次约 2-3 分钟）
bash scripts/01-init-kdc.sh

# 2) 启动 HA 集群（ZK → JournalNode → 双 NameNode → DN/YARN，约 3-5 分钟）
bash scripts/02-start-hdfs.sh

# 3) 自动验证（HA 状态 + 故障转移演练 + 双向跨域互信）
bash scripts/03-verify.sh
```

预期输出（关键部分）：

```
[PASS] HA: nn1 为 active（实际: active）
[PASS] HA: nn2 为 standby（实际: standby）
...
[PASS] 故障转移: nn2 自动接管成为 active
[PASS] 故障转移后: 经 nameservice 代理访问仍可用
[PASS] 故障转移后: 可读取故障前写入的数据文件
[PASS] 故障恢复: nn1 重启后回归 standby
...
验证结果: PASS=24  FAIL=0
```

---

## 四、验证内容（03-verify.sh）

1. **HA 状态**：每集群 `nn1=active / nn2=standby`（`hdfs haadmin -getServiceState`）；
2. **本域 nameservice 访问**：`hdfs dfs -ls hdfs://ns1234/user`（走故障转移代理）；
3. **跨域互信**：`test@EMR.1234.COM` 访问集群 B、`test1@EMR.6789.COM` 访问集群 A；
4. **跨域铁证**：A 在 B 创建标记目录、B 本域可见；反向同理；
5. **故障转移演练**：`docker stop` 当前 active NN → standby 在 ~15s 内自动接管 →
   代理访问与**故障前写入的数据文件读取**均正常 → 重启原 NN 自动回归 standby；
6. **故障转移后跨域**：接管后跨域访问对端集群仍可用。

---

## 五、目录结构

```
hadoop-kerberos-trust-ha/
├── README.md
├── docs/
│   ├── 01-原理说明-HA.md      HDFS HA 原理（QJM/ZKFC）+ 与跨域互信的结合
│   ├── 02-手动验证-HA.md      手工操作（查状态/手动切换/nameservice 访问）
│   └── 03-常见问题-HA.md      排错表
├── kerberos/                  双 KDC（与基础版一致：Dockerfile/start-kdc.sh/custom-repo）
├── ha/
│   ├── docker-compose.yml     ZK + 3×JN + 4×NN + 2×DN + RM/NM（14 容器）
│   ├── conf/
│   │   ├── cluster-a/         core-site / hdfs-site(HA) / yarn-site
│   │   ├── cluster-b/         core-site / hdfs-site(HA)
│   │   ├── journalnode/       hdfs-site（JN 专用）
│   │   └── scripts/           start-nn.sh / start-jn.sh（容器启动脚本）
│   └── kerberos/  kerberos1/  01 生成的 krb5.conf 与 keytab（.gitignore 忽略）
└── scripts/
    ├── 00-cleanup.sh [--purge]
    ├── 01-init-kdc.sh
    ├── 02-start-hdfs.sh
    └── 03-verify.sh
```

---

## 六、排错速查

| 现象 | 处理 |
|---|---|
| `02` 预检报缺少 keytab | 先执行 `bash scripts/01-init-kdc.sh` |
| NN 一直卡在"等待 ZooKeeper"、zk1 日志报 `clientPort is not set` | 新版 `zookeeper:3.8` 镜像单节点不生成 clientPort，见 FAQ Q10（已内置 `ha/conf/zk/zoo.cfg`） |
| nn2 一直未就绪、日志报 bootstrapStandby 失败 | 确认 nn1 已 active（`docker logs namenode-a1`），且 JN 端口可达 |
| NN format 静默失败/重启循环，日志报 `Server has invalid Kerberos principal: jn/jn3.emr.1234.com@... expecting: jn/jn3@...` | JN 的 IP 被反解成短主机名（`extra_hosts` 短名条目排在 FQDN 前）→ QJM 客户端推导 `jn/_HOST` 得到短名，见 FAQ Q12（已内置修复：compose 移除短名条目 + `start-nn.sh` 把 JN IP 重写为 FQDN 打头） |
| 故障转移演练中 standby 未在 120s 内接管 | 检查 `zk1` 是否存活、ZKFC 日志（`docker logs namenode-a2`） |
| 容器 OOM / 启动极慢 | 内存不足，调低 `HADOOP_HEAPSIZE`（compose 中默认 NN=768 / JN=512） |
| 与基础版部署冲突（网络/端口） | 两套包勿同机部署；或 `export SUBNET_BASE` 迁移网段 |

详见 [docs/03-常见问题-HA.md](docs/03-常见问题-HA.md)。

> ⚠️ 全部密码 / keytab 均为测试用途（互信 krbtgt 密码 `123456`、master 密码 `master1234/master6789`、
> 测试用户 `test/test1`），请勿用于生产环境。
