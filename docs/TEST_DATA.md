# Primary 业务测试数据

业务测试数据只加载到 Primary `192.168.80.110`。Primary 上的业务用户 `rw_lab_test` 和数据库 `rw_proxy_lab` 必须先通过 PG_Safe_tool 创建；导入脚本只重建该数据库中的 `business` schema，不删除用户或数据库。第二台数据库服务器保持空白基线；主从复制仍由项目部署脚本负责。

## 数据集

测试数据库固定为 `rw_proxy_lab`，数据集版本为 `business-v1`。数据使用确定性公式生成，不读取外部文件，也不使用随机函数：

| 表 | 行数 | 用途 |
| --- | ---: | --- |
| `business.customers` | 30,000 | 客户维度、区域和等级过滤 |
| `business.products` | 2,000 | 商品维度和价格计算 |
| `business.orders` | 150,000 | 10W+ 订单主表、状态和时间范围查询 |
| `business.order_items` | 450,000 | 订单明细、关联与聚合查询 |
| `business.rw_probe` | 0 | 后续读写路由测试专用空表 |

业务数据总行数为 632,000。生成过程会校验固定行数、订单金额和外键完整性，并执行 `VACUUM (ANALYZE)`。

## 重新生成

从项目根目录执行：

```powershell
.\vm\load-primary-test-data.ps1 -ConfirmReset
```

也可以在 Primary 内执行已经安装的入口：

```bash
sudo /usr/local/sbin/reset-primary-test-data --confirm-reset-test-data
```

该操作会保留 PG_Safe_tool 创建的 `rw_lab_test` 和 `rw_proxy_lab`，在一个事务中删除并重建 `business` schema。如果测试库存在活动连接，脚本会拒绝处理且不会主动终止连接。数据生成或事务内校验失败时会整体回滚，原有 `business` schema 和数据保持不变。

QEMU TCG 模拟 ARM 时，逐行执行外键触发器非常慢。重置脚本以厂商管理连接开启会话级批量装载模式，再 `SET ROLE rw_lab_test` 创建所有业务对象；装载结束后会话自动恢复默认模式，并通过集合查询完整校验客户、订单、商品关系。数据库、schema、表、序列和索引仍归 `rw_lab_test` 所有，外键约束继续对后续 DML 正常生效。

生成 SQL 保存在 `scripts/sql/primary-test-data.sql`，每次导入会把该文件的 SHA256 写入 `business.dataset_manifest`，便于确认测试数据版本。

只读验收 SQL 保存在 `scripts/sql/verify-primary-test-data.sql`。单独验收时将切换角色和验收 SQL 写入 root-only 临时文件，再使用厂商受控入口的 `-f` 执行：

```bash
sudo bash -c 'f=$(mktemp /var/tmp/verify-business.XXXXXX.sql); \
  chmod 600 "$f"; \
  printf "%s\n" "\\set ON_ERROR_STOP on" "SET ROLE rw_lab_test;" \
    "\\i /usr/local/share/pg-readwrite-proxy-lab/verify-primary-test-data.sql" >"$f"; \
  /opt/pgsql12/bin/tools psql -d rw_proxy_lab -p 5432 -f "$f"; \
  rm -f -- "$f"'
```

不得调用 `tools pg 1`：该子命令会返回隐藏的 postgres 密码，不应进入终端、脚本输出或日志。
