# Primary 业务测试数据

本项目的基础虚拟机重置只负责生成两套互相独立的 PostgreSQL。业务测试数据只加载到 Primary `192.168.80.110`，第二台数据库服务器保持空白基线；主从复制仍由项目部署脚本负责。

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

该操作会删除并重建 `rw_proxy_lab`。如果测试库存在活动连接，脚本会拒绝处理且不会主动终止连接。导入失败时，不完整的测试库会被移除。重置两台 PostgreSQL 基线后，需要再次运行本导入命令。

生成 SQL 保存在 `scripts/sql/primary-test-data.sql`，每次导入会把该文件的 SHA256 写入 `business.dataset_manifest`，便于确认测试数据版本。

只读验收 SQL 保存在 `scripts/sql/verify-primary-test-data.sql`。在 Primary 上可以随时执行：

```bash
sudo -u postgres /opt/pgsql12/bin/psql \
  -X -v ON_ERROR_STOP=1 -d rw_proxy_lab \
  -f /usr/local/share/pg-readwrite-proxy-lab/verify-primary-test-data.sql
```
