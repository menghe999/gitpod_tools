# Flink 1.18.1 跨集群示例（状态/运行在 ns1234，数据跨域采自/写回 ns6789）
# 详细文档：docs/04-Flink跨集群Demo.md

# 目录说明
#   conf/flink-conf.yaml      Flink 配置模板（提交时复制到 dist/conf/）
#   job/CrossClusterDemo.java 演示作业源码（单文件，无 Maven，容器内 javac 编译）
#   dist/                     【下载产物，勿提交】flink-1.18.1 发行版（scripts/04 下载）
#   classes/  *.jar           【编译产物，勿提交】scripts/05 在容器内编译生成

# 快速开始
#   bash scripts/04-flink-setup.sh   # 下载 flink-1.18.1 并启动 flink-client 容器
#   bash scripts/05-flink-demo.sh    # 编译 + ns6789 造数 + 提交 YARN + 验证
