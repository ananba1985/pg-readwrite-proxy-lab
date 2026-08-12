# 故障与延迟测试

以下测试只适用于 NebulaCM PostgreSQL 12.0 主从和 Pgpool-II 已由项目脚本配置完成、基础验收通过后的维护窗口。基线不会自动提升 Standby。

## Standby 故障

1. 在 Standby 使用厂商安装路径停止数据库：

   ```bash
   sudo runuser -u postgres -- \
     /opt/pgsql12/bin/pg_ctl -w -D /pgsql/12/data -m fast stop
   ```

2. 在 Pgpool 节点执行 `scripts/41-observe-cluster.sh`，确认节点 1 被识别为不可用。
3. 普通 SELECT 不应继续发送给已停止的 Standby；Pgpool 摘除 Standby 后可退化到 Primary，但不会提升任何节点。
4. 使用同一厂商路径启动 Standby：

   ```bash
   sudo runuser -u postgres -- \
     /opt/pgsql12/bin/pg_ctl -w -D /pgsql/12/data start
   ```

5. 确认 `pg_stat_wal_receiver.status=streaming`，再由运维显式重新挂接。PCP 密码不得放在命令参数；使用权限 0600 的临时 `PCPPASSFILE`，格式为 `hostname:port:username:password`：

   ```bash
   PCPPASSFILE=/root/.pcppass-maintenance \
     /opt/pgpool-II-4.7.2/bin/pcp_attach_node \
       -w -h 127.0.0.1 -p 9898 -U pgpool_admin -n 1
   ```

   完成后立即移除临时密码文件。

## 人工复制延迟

1. 在 Standby 使用厂商受控管理员入口执行：

   ```bash
   sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 \
     -c 'select pg_wal_replay_pause()'
   ```
2. 经 Pgpool 在 Primary 写入探针数据，观察 `pg_stat_replication.replay_lag` 和 `SHOW POOL_NODES` 的 delay 字段。
3. 超过 5 秒阈值后，确认 Pgpool 不再将普通 SELECT 路由给滞后 Standby。
4. 必须执行恢复回放，并等待延迟归零：

   ```bash
   sudo /opt/pgsql12/bin/tools psql -d postgres -p 5432 \
     -c 'select pg_wal_replay_resume()'
   ```

5. 再次运行 `scripts/40-verify-cluster.sh`。任何演练脚本都应设置退出清理，避免把回放长期留在暂停状态。

不要在生产库使用大量写入来“制造延迟”，也不要在未知状态下执行 promote。
