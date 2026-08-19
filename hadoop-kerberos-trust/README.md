# hadoop-kerberos-trust

**双 KDC 跨域互信 + 双 HDFS 集群 + 自动验证** 的 Docker 一键部署工具包。

基于真实 EMR 场景模拟：两个互不信任的 Kerberos realm（`EMR.1234.COM` / `EMR.6789.COM`）
各自拥有独立的 KDC 与 HDFS 集群，通过 **Kerberos 跨域互信（Cross-Realm Trust）**，
实现两个集群之间的用户互访。拿到本目录后，只需 Docker 环境即可完成部署与验证，
无需任何其他外部依赖。

```
┌──────────────────────────────┐         ┌──────────────────────────────┐
│  Realm: EMR.1234.COM         │         │  Realm: EMR.6789.COM         │
│                              │ 信任关系 │                              │
│  kdc1  (172.28.0.2)  ◄──────┼─────────┼──►  kdc2  (172.28.0.3)       │
│  集群A: namenode(.21)        │ krbtgt  │   集群B: namenode1(.31)      │
│         datanode(.22)        │ 双向互信 │          datanode1(.32)      │
│         resourcemanager      │         │                              │
│  用户: test@EMR.1234.COM     │         │  用户: test1@EMR.6789.COM    │
└──────────────────────────────┘         └──────────────────────────────┘
         test 可访问集群B ◄──────────────────────► test1 可访问集群A
```

## 一、前置要求

| 项目 | 要求 |
|---|---|
| Docker Engine | 20.10+（能跑 `docker compose` v2，或 `docker-compose` ≥ 1.29） |
| 内存 | 建议 ≥ 8GB（2 KDC + 6 Hadoop 容器，约 4-6GB 峰值） |
| 磁盘 | ≥ 15GB（centos:7、hadoop 镜像约 4GB + 容器数据） |
| 端口 | 88 / 89 / 749 / 750 / 50070 / 50080 / 8088 |
| 网段 | 默认 `172.28.0.0/24`；与现有 Docker 网络冲突时用 `SUBNET_BASE` 整体迁移（见 FAQ Q1.4） |
| 网络 | 需能访问 Docker Hub、vault.centos.org（KDC 构建用）、archive.debian.org（验证时安装 krb5-user 用） |

## 二、快速开始（三条命令）

```bash
# 1. 初始化双 KDC：构建镜像、启动、建立双向互信、创建 principal、导出并分发 keytab
bash scripts/01-init-kdc.sh

# 2. 启动双 HDFS 集群（Kerberos 安全模式）
bash scripts/02-start-hdfs.sh

# 3. 自动验证：双集群双向互访（约 2-5 分钟，含 NameNode 就绪等待）
bash scripts/03-verify.sh
```

看到如下输出即代表跨域互信验证通过：

```
==============================================
 验证结果: PASS=10  FAIL=0
==============================================
 ✅ 双 KDC 跨域互信验证全部通过！
```

清理环境：

```bash
bash scripts/00-cleanup.sh          # 停止并删除所有容器/数据卷/网络
bash scripts/00-cleanup.sh --purge  # 额外删除生成的 keytab / krb5.conf，恢复初始状态
```

## 三、脚本说明

| 脚本 | 作用 | 可重复执行 |
|---|---|---|
| `01-init-kdc.sh` | 构建启动 kdc1/kdc2；建互信 krbtgt、HDFS 服务 principal、测试用户；导出 keytab 并分发到 `hdfs/kerberos*` | ✅ 幂等 |
| `02-start-hdfs.sh` | 预检 keytab 产物 → 启动集群 A（EMR.1234.COM）与集群 B（EMR.6789.COM） | ✅ |
| `03-verify.sh` | 容器存活检查 → 安装 krb5-user（按需）→ 等待 NameNode → 双向跨域验证 → 输出 PASS/FAIL | ✅ |
| `00-cleanup.sh` | 停止删除所有容器/数据卷/网络；`--purge` 额外清除生成的凭据文件 | ✅ |

> 脚本自动兼容 `docker compose`（v2）与 `docker-compose`（v1）。

## 四、目录结构

```
hadoop-kerberos-trust/
├── README.md                 # 本文件
├── docs/
│   ├── 01-原理说明.md          # Kerberos 跨域互信原理与本方案架构
│   ├── 02-手动验证.md          # 手工分步操作（学习/对照用，脚本已自动化）
│   └── 03-常见问题.md          # 排错 FAQ
├── kerberos/                 # 双 KDC（跨域互信）
│   ├── docker-compose.yml    #   固定网络 hadoop-kerberos-net
│   ├── Dockerfile            #   kdc1/kdc2 共用镜像模板（centos:7）
│   ├── start-kdc.sh          #   按环境变量动态生成 krb5.conf 的启动模板
│   └── custom-repo/          #   centos:7 失效源替换为 vault.centos.org
├── hdfs/                     # 双 HDFS 集群
│   ├── docker-compose.yml    #   集群 A（EMR.1234.COM）
│   ├── docker-compose-1.yml  #   集群 B（EMR.6789.COM）
│   ├── hadoop/  hadoop1/     #   两集群的 core/hdfs/yarn/ssl 配置
│   ├── ca/bash/              #   HTTPS 用的 keystore/truststore 与生成脚本
│   ├── kerberos/             #   集群 A 凭据（01 脚本生成，勿手改）
│   └── kerberos1/            #   集群 B 凭据（01 脚本生成，勿手改）
└── scripts/                  # 一键脚本（01/02/03/00）
```

## 五、架构要点（详见 docs/01-原理说明.md）

1. **跨域互信的本质**：每个 KDC 数据库中同时存在方向相反的 `krbtgt/<对方realm>@<本realm>`
   principal，且两侧密钥一致（本方案统一密码 `123456`）。
2. **krb5.conf 的 `[capaths]`**：声明两 realm 直连互信（`.` = 直接信任）。
3. **时钟同步**：所有容器统一 `TZ=Asia/Shanghai` 并挂载 `/etc/localtime`、`/etc/timezone`，
   Kerberos 对时钟偏移敏感（默认 ±5 分钟）。
4. **auth_to_local**：两个集群的 `core-site.xml` 均配置了把两个 realm 的 principal
   映射为本地用户名的规则，跨域用户才能落地。
5. **keytab 每次初始化动态生成**：KDC 数据库每次全新创建，因此 keytab 无法预置，
   必须由 `01-init-kdc.sh` 在运行时生成并分发（这正是本工具"拿到即可部署"的关键）。

## 六、手动验证（不跑脚本时的对照操作）

进入容器手工执行（等价于 `03-verify.sh` 做的事情）：

```bash
# 集群 A 的 NameNode 容器
docker exec -it namenode bash
kinit -kt /root/test.keytab test                      # test@EMR.1234.COM
hdfs dfs -ls hdfs://namenode.emr.1234.com:9000/user   # 本域访问
hdfs dfs -ls hdfs://namenode.emr.6789.com:9000/user   # 跨域访问集群 B

# 集群 B 的 NameNode 容器
docker exec -it namenode1 bash
kinit -kt /root/test1.keytab test1                    # test1@EMR.6789.COM
hdfs dfs -ls hdfs://namenode.emr.6789.com:9000/user   # 本域访问
hdfs dfs -ls hdfs://namenode.emr.1234.com:9000/user   # 跨域访问集群 A
```

## 七、扩展实验（可选）

- **跨集群文件同步**：原项目（github.com/menghe999/gitpod_tools，`shell/hdfs/demo`）提供
  `hdfs-file-sync` 示例，用 `test` 的 keytab 定时把集群 A 的文件拷贝到集群 B。
- **Flink on YARN（安全模式）**：原项目 `shell/hdfs/flink-example` 演示带 Kerberos
  参数提交 Flink 任务（`-Dsecurity.kerberos.login.keytab=... -Dsecurity.kerberos.login.principal=...`）。

## 八、安全声明

本工具中所有 keytab、密码（`123456`、`master1234` 等）均为**测试用途**，
仅用于本地/演示环境，严禁用于生产。

## 九、快速排错入口

| 现象 | 处理 |
|---|---|
| `01` 启动报 `Pool overlaps with other one on this address space` | 网段与现有 Docker 网络冲突：`export SUBNET_BASE=172.30.0` 后重跑 01/02/03，或删除占用网段的旧网络（见 `docs/03-常见问题.md` Q1.4） |
| `01` 卡在"等待 KDC 就绪" | `docker logs kdc1` 查看；多为 centos:7 镜像或 vault.centos.org 拉取/访问失败 |
| `03` 中 kinit 报 clock skew | 检查容器时间：`docker exec kdc1 date`，确认宿主时区正确 |
| `03` 跨域访问失败 | 查看 `docs/03-常见问题.md` 的排查步骤 |
| 端口被占用 | 修改 `kerberos/docker-compose.yml` 与 `hdfs/*.yml` 的 ports 映射 |
