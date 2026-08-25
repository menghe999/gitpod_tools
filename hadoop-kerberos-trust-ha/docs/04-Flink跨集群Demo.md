# 04. Flink 1.18.1 跨集群演示（example-job）

用 **Flink 1.18.1** 跑一个跨集群 Demo：作业运行在 **ns1234** 的 YARN 上、状态/checkpoint
落在 **ns1234** HDFS，但数据来自 **ns6789** HDFS（跨域 Kerberos 互信），逐行打印到
日志后写出到 **ns6789** 的另一个目录；全程以 **test@EMR.1234.COM** 租户运行。

## 需求映射

| 需求 | 实现 |
|---|---|
| 1. Flink 状态使用 ns1234 HDFS | `flink-conf.yaml`：`state.backend=filesystem`、`state.checkpoints.dir=hdfs://ns1234/flink/checkpoints`；作业带 keyed `ValueState`（行计数），checkpoint 真实落盘 |
| 2. Flink 运行在 ns1234 的 YARN | `flink run-application -t yarn-application` 提交到 `resourcemanager.emr.1234.com`（cluster-a 的 yarn-site.xml） |
| 3. 采集 ns6789 文件并打印日志 | 有界 `FileSource`（`TextLineInputFormat`）读 `hdfs://nn1.emr.6789.com:9000/user/test/input`（跨域用显式地址，见 FAQ Q7），每条记录 `System.out.println("[FlinkDemo] 采集自 ns6789: ...")` 进 TaskManager 日志 |
| 4. 写出到 ns6789 另一目录 | `FileSink`（`SimpleStringEncoder`）写 `hdfs://nn1.emr.6789.com:9000/user/test/output`（`part-*` 文件） |
| 5. 使用 test 租户 | `security.kerberos.login.keytab=/root/test.keytab` + `principal=test@EMR.1234.COM`，JAAS 自登录（不依赖 kinit 二进制） |

## 架构

```
                      ┌───────────────────────── ns1234（EMR.1234.COM）─────────────────────────┐
                      │                                                                          │
  flink-client 容器    │  yarn-application 提交 ──► ResourceManager ──► TaskManagers（NM 容器内）   │
  （test keytab）      │         │                    │                     │                    │
        │              │         └─ 状态/checkpoint 落 hdfs://ns1234/flink/checkpoints           │
        │              └──────────────────────────────────────────────────────────────────────────┘
        │  跨域（krbtgt 互信，test@EMR.1234.COM 访问 EMR.6789.COM）
        ▼
  ┌───────────────────────── ns6789（EMR.6789.COM）─────────────────────────┐
  │ 输入: hdfs://nn1.emr.6789.com:9000/user/test/input（sample.txt）          │
  │ 输出: hdfs://nn1.emr.6789.com:9000/user/test/output（part-*）             │
  └──────────────────────────────────────────────────────────────────────────────┘
```

## 前提

1. 已完成 `bash scripts/01-init-kdc.sh`（生成 `ha/kerberos/test.keytab`）与
   `bash scripts/02-start-hdfs.sh`（NN 集群 + YARN 均就绪）；
2. 容器可访问外网下载 Flink 发行版（首次约 330MB，仅需一次）。

## 步骤

### 1) 环境准备（04）

```bash
bash scripts/04-flink-setup.sh
```

- 启动 `flink-client` 容器（bde2020/hadoop-namenode 镜像，JDK8 + Hadoop 3.2.1，
  挂载 `flink/`、`test.keytab`、cluster-a 配置，静态 IP `.60`）；
- **冒烟测试（下载前）**：RM 8088 可达 + test 租户 JAAS（免 kinit）访问 ns1234 与
  跨域 ns6789——任何一步失败立即报错并给排查指引，避免白下 330MB；
- 下载 `flink-1.18.1-bin-scala_2.12.tgz` 到 `flink/dist/`（幂等，已存在则跳过）；
- 应用 `flink/conf/flink-conf.yaml` 到 `dist/conf/`；
- 确保 `dist/lib` 有 `flink-connector-files`（FileSource/FileSink 依赖，缺失则从
  Maven 中央仓库补下）。

### 2) 提交演示作业（05）

```bash
bash scripts/05-flink-demo.sh
# 自定义目录：bash scripts/05-flink-demo.sh hdfs://nn1.emr.6789.com:9000/user/test/in2 hdfs://nn1.emr.6789.com:9000/user/test/out2
```

脚本依次：
1. 检查 `flink-client`/`resourcemanager`/`nodemanager` 容器与发行版（含 RM 8088 可达性）；
2. **容器内编译**：`javac -cp "$FLINK_DIST/lib/*"` 编译 `flink/job/CrossClusterDemo.java`
   并打 jar（**无需 Maven**，镜像自带 JDK8）；
3. **ns6789 造数**：以 `test@EMR.1234.COM`（JAAS login.conf + keytab，无需 kinit）
   创建 `input/sample.txt`（3 行文本）；
4. **提交**：`flink run-application -t yarn-application -c CrossClusterDemo`，
   参数为 ns6789 输入/输出目录；作业运行在 ns1234 的 YARN；
5. **验证**：轮询 `yarn application -status` 至 FINISHED，列出 ns6789 输出
   （`part-*` 内容）与 ns1234 checkpoint 目录。

## 验证与结果查看

```bash
# 采集日志（TaskManager stdout）
docker exec flink-client bash -c 'yarn logs -applicationId <APP_ID> | grep FlinkDemo'

# 输出文件（ns6789）
docker exec flink-client bash -c 'hadoop fs -cat hdfs://nn1.emr.6789.com:9000/user/test/output/part-*'

# checkpoint（ns1234）
docker exec flink-client bash -c 'hadoop fs -ls -R hdfs://ns1234/flink/checkpoints'

# RM Web UI（宿主端口 8088）可看应用与日志
```

预期输出文件内容形如：

```
累计采集 1 行
累计采集 2 行
累计采集 3 行
```

checkpoint 目录出现 `chk-1`、`chk-2` …（含 `_metadata`），证明状态确实落在 ns1234。

## 原理要点

- **test 租户的两种登录方式**：Flink 本身用 `security.kerberos.login.*`（JAAS keytab
  自登录，作业与 TM 都能直接跨域访问 ns6789）；脚本里临时验证用的 hadoop/yarn CLI
  用 `HADOOP_OPTS` + login.conf 的 Krb5LoginModule（同样不依赖 kinit 二进制，
  与 FAQ Q13 一脉相承）；
- **跨域为什么用显式地址**：客户端（cluster-a 配置）只声明 ns1234 nameservice，
  ns6789 的 nameservice 定义不在配置里（FAQ Q7）；`hdfs://nn1.emr.6789.com:9000`
  直接走信任的 krbtgt 完成认证；
- **checkpoint 为什么能落 ns1234**：TM 在 nodemanager 容器内（cluster-a 网络），
  `state.checkpoints.dir` 指向 `hdfs://ns1234/...`，由 TM 以 test 身份写入；
- **TM 为什么有 Hadoop 类**：Flink 1.18 的 AM/TM 类路径来自 hadoop 配置的
  `yarn.application.classpath`（`Utils.setupYarnClassPath`），**不继承**客户端
  `HADOOP_CLASSPATH`——cluster-a/yarn-site.xml 已显式配置为容器内绝对路径
  （`/opt/hadoop-3.2.1/...`，TM 与 NM 同容器同文件系统）；
- **有界作业**：`FileSource` 读完输入目录即结束，适合演示与断言。

## 常见问题

| 现象 | 处理 |
|---|---|
| `04` 下载慢/失败 | 检查宿主机外网；可手动下载 tgz 放到 `flink/dist/` 后重跑 |
| `05` 报 `flink-client 未运行` | 先跑 `bash scripts/04-flink-setup.sh`；或 `docker compose -f ha/docker-compose.yml up -d flink-client` |
| 提交报 YARN 认证失败 | 确认 RM/NM 已起（`docker ps`）；`test.keytab` 是否存在（`docker exec flink-client ls -l /root/test.keytab`） |
| TM 报 `NoClassDefFoundError`（hadoop 类） | 已内置修复：cluster-a/yarn-site.xml 的 `yarn.application.classpath` 指向 `/opt/hadoop-3.2.1`（Flink 1.18 的 AM/TM 类路径只认此配置，不认客户端 `HADOOP_CLASSPATH`）；bind mount 即时生效，无需重启 RM/NM |
| 作业 FAILED，日志在 `yarn logs -applicationId <id>` | 先看 `grep -A20 Exception` 定位；常见为跨域主体/权限，检查 `docker logs nodemanager` |
| ns6789 输出/输入权限 | `dfs.permissions.enabled=false`，任意认证主体可写；若仍失败看日志中的认证栈 |
