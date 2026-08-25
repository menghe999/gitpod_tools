import org.apache.flink.api.common.eventtime.WatermarkStrategy;
import org.apache.flink.api.common.serialization.SimpleStringEncoder;
import org.apache.flink.api.common.state.ValueState;
import org.apache.flink.api.common.state.ValueStateDescriptor;
import org.apache.flink.configuration.Configuration;
import org.apache.flink.connector.file.sink.FileSink;
import org.apache.flink.connector.file.src.FileSource;
import org.apache.flink.connector.file.src.reader.TextLineInputFormat;
import org.apache.flink.core.fs.Path;
import org.apache.flink.streaming.api.datastream.DataStream;
import org.apache.flink.streaming.api.environment.StreamExecutionEnvironment;
import org.apache.flink.streaming.api.functions.KeyedProcessFunction;
import org.apache.flink.util.Collector;

/**
 * Flink 跨集群演示作业（Flink 1.18.1，纯 DataStream API，单文件、无 Maven 依赖）。
 *
 * 需求映射：
 *   1. 运行位置：通过 `flink run-application -t yarn-application` 提交到 ns1234 的 YARN
 *      （resourcemanager.emr.1234.com），JobManager/TaskManager 由 YARN 拉起；
 *   2. 状态后端：checkpoint 目录配置在 flink-conf.yaml
 *      （state.checkpoints.dir=hdfs://ns1234/flink/checkpoints），本作业带一个
 *      keyed ValueState（行计数），checkpoint 会真实落到 ns1234 HDFS；
 *   3. 数据源：读取 ns6789 集群的输入目录（显式地址 hdfs://nn1.emr.6789.com:9000，
 *      与 FAQ Q7 的跨域约定一致），逐行打印到 TaskManager 日志；
 *   4. 输出：写出到 ns6789 集群的另一个目录（FileSink，part-*.out 文件）；
 *   5. 租户：以 test@EMR.1234.COM 运行（flink-conf.yaml 的 security.kerberos.login.*
 *      指向 /root/test.keytab，JAAS 自登录，不依赖 kinit 二进制）。
 *
 * 用法：CrossClusterDemo <ns6789输入目录> <ns6789输出目录>
 * 示例：CrossClusterDemo hdfs://nn1.emr.6789.com:9000/user/test/input \
 *                        hdfs://nn1.emr.6789.com:9000/user/test/output
 */
public class CrossClusterDemo {

  public static void main(String[] args) throws Exception {
    if (args.length < 2) {
      throw new IllegalArgumentException(
          "用法: CrossClusterDemo <ns6789输入目录> <ns6789输出目录>");
    }
    String inputPath = args[0];
    String outputPath = args[1];

    StreamExecutionEnvironment env = StreamExecutionEnvironment.getExecutionEnvironment();

    // 周期 checkpoint（状态落 ns1234，见 flink-conf.yaml 的 state.checkpoints.dir）
    env.enableCheckpointing(10_000L);

    // 有界文件源：读尽 ns6789 输入目录后作业自然结束（适合演示/验证）
    FileSource<String> source = FileSource
        .forRecordStreamFormat(new TextLineInputFormat(), new Path(inputPath))
        .build();

    DataStream<String> lines = env
        .fromSource(source, WatermarkStrategy.noWatermarks(), "ns6789-file-source");

    lines
        // 逐行打印到 TaskManager 日志（yarn logs 可见）
        .map(line -> {
          System.out.println("[FlinkDemo] 采集自 ns6789: " + line);
          return line;
        })
        // keyed state 计数：证明状态后端（ns1234）在工作
        .keyBy(line -> "all")
        .process(new CountProcessFunction())
        .map(cnt -> "累计采集 " + cnt + " 行")
        // 写回 ns6789 的另一个目录
        .sinkTo(FileSink
            .forRowFormat(new Path(outputPath), new SimpleStringEncoder<String>("UTF-8"))
            .build());

    env.execute("CrossClusterDemo: ns6789采集->日志->ns6789写出 (state/checkpoint on ns1234, yarn on ns1234)");
  }

  /** keyed state 行计数：状态由 checkpoint 定期快照到 hdfs://ns1234/flink/checkpoints */
  public static class CountProcessFunction extends KeyedProcessFunction<String, String, Long> {
    private transient ValueState<Long> count;

    @Override
    public void open(Configuration parameters) {
      count = getRuntimeContext().getState(
          new ValueStateDescriptor<>("line-count", Long.class));
    }

    @Override
    public void processElement(String value, Context ctx, Collector<Long> out) throws Exception {
      long c = (count.value() == null ? 0L : count.value()) + 1L;
      count.update(c);
      out.collect(c);
    }
  }
}
