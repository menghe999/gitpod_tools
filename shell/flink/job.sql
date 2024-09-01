CREATE FUNCTION CalculateFunction AS 'cn.com.bsfit.flink.udf.CalculateFunction';

-- 创建数据源
CREATE TABLE SourceTable (
    id INT  NOT NULL,
    val INT  NOT NULL
) WITH (
    'connector' = 'datagen',
    'rows-per-second' = '5'
);

-- 创建数据接收器
CREATE TABLE SinkTable (
    id INT  NOT NULL,
    prime_count BIGINT
) WITH (
    'connector' = 'print'
);

-- 执行查询
INSERT INTO SinkTable
SELECT id, CalculateFunction(val) AS prime_count
FROM SourceTable;