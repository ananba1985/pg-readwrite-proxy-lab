# 生产化注意事项

项目交付是基于 NebulaCM PostgreSQL 12.0 的“一主一从一 Pgpool”可验证基线，并且不自动提升 Standby。以下事项必须在生产部署前单独评审。

## Pgpool-II 高可用与入口

- 单 Pgpool 是明确的单点。生产建议部署两台 Pgpool-II，启用 watchdog，并结合有仲裁能力的第三观察点。
- VIP 必须由网络团队确认二层可达、ARP/云网络限制与漂移权限；若不能使用 VIP，应由硬件负载均衡或四层负载均衡提供稳定入口。
- 双 Pgpool 的配置、`pool_passwd`、PCP 凭据与密钥应由受控配置管理同步，且变更需做滚动验证。
- Primary 的 `DISALLOW_TO_FAILOVER`、空 `failover_command`/`follow_primary_command` 是有意设置：没有 fencing/仲裁时不自动提升，避免双主。Standby 允许被健康检查摘除只是读流量退化，不是 promote。

## 连接池容量

- 后端最大连接上界近似为 `num_init_children × max_pool × Pgpool 实例数`，还要为复制、监控、运维和直连预留连接。
- 不能只提高 `num_init_children`；需结合 `max_connections`、单连接内存、客户端并发和等待时间压测。
- 应设置应用连接超时、事务超时与空闲连接策略，避免长事务阻塞 vacuum 和复制回放。

## 主从延迟与写后读一致性

- 流复制默认异步；Primary 提交成功并不等于 Standby 已回放。
- 本项目通过 `delay_threshold_by_time=5` 避免把明显滞后的 Standby 用作普通读，但它不提供零延迟保证。
- 显式事务中发生写操作后，`disable_load_balance_on_write=transaction` 会把后续读固定到 Primary；跨连接、自动提交后的立即读取仍需业务显式走主库，或采用会话粘滞/同步复制策略。
- 余额、库存、权限、订单状态等强一致读不得仅依赖普通 SELECT 负载均衡。

## 监控

- PostgreSQL：`pg_stat_replication`、复制槽保留 WAL、WAL 目录容量、replay lag、checkpoint、连接数、锁与长事务。
- Standby：`pg_stat_wal_receiver`、恢复冲突、回放暂停和磁盘容量。
- Pgpool-II：`SHOW POOL_NODES`、健康检查失败、子进程/连接池耗尽、认证错误、入口可用性与日志量。
- 告警必须覆盖复制中断、节点角色异常、延迟越阈值、槽导致的 WAL 膨胀及 Pgpool 单点失联。

## 备份与恢复

- Standby 不是备份。必须独立执行带保留周期的全量备份、WAL 归档和异地/离线副本。
- 定期做恢复演练，并以恢复后的校验和、业务抽样和 RPO/RTO 计时作为证据。
- 复制槽可防止必要 WAL 被过早删除，但 PostgreSQL 12 没有 `max_slot_wal_keep_size`，必须对槽滞留空间做严格告警与运维处置。

## 安全与生命周期

- CentOS 7 和 PostgreSQL 12 的上游常规支持生命周期已经结束；NebulaCM PostgreSQL 12.0 的实际支持期限、补丁和安全责任必须以厂商合同为准，并纳入生产风险评审。
- 当前载荷是在 CentOS 7 aarch64 上构建并验收的，不是通用 ARM64 包。麒麟 V10 实测缺少它所需的 OpenSSL 1.0、readline 6 与 libnsl ABI；不得靠临时软链接或从 CentOS 复制系统库绕过，必须按目标发行版重新构建并全量验收。
- 客户端 CIDR 必须最小化；PCP 只监听 localhost；后端 5432 只允许 Standby 和 Pgpool 地址。
- 当前实验入口未启用 TLS。跨不可信网络生产使用前必须部署服务端证书、客户端验证和密钥轮换。
- `config/secrets.env` 与业务明文密码只应短暂存在于安装主机，完成 `pool_passwd` 生成后迁移到密钥系统并按制度擦除。
- 一键安装首次连接使用隔离管理网中的 root 密码 SSH；生产应预置并核验 SSH 主机密钥，优先改为短期安装密钥或堡垒机审计，避免只依赖首次连接信任。
