# 生产化注意事项

项目交付是基于 NebulaCM PostgreSQL 12.0 的“一主一从一 Pgpool”可验证基线，并且不自动提升 Standby。以下事项必须在生产部署前单独评审。

## 部署前就绪门禁

- 一键入口通过启动参数和缺项交互补全收集全部地址、数据库端口、Pgpool 入口端口、Primary/Standby 共用的 SSH 端口、CIDR、现有业务账号与两类密码，然后才启动检查；密码允许按物理隔离环境约定直接从启动参数传入。正常流程不回显密码；业务数据库连接或认证失败时，按现场调试约定在终端及 root-only 完整诊断日志中打印本次 `BUSINESS_PASSWORD` 明文。检查阶段只允许 `/var/tmp` 下 root-only 临时配置/随机凭据、临时解压、SSH `known_hosts` 与远端暂存，不允许覆盖解压目录的既有运行配置，也不允许修改数据库、服务或账号。只有只读检查通过并由用户输入 `APPLY` 后才备份并落盘新配置。
- 三个节点的平台门禁均为 Kylin Linux Advanced Server V10 aarch64；数据库节点还必须通过既有 NebulaCM PostgreSQL 12.0 运行时版本、路径和文件哈希检查。
- Primary 必须校验厂商运行时与文件哈希、非恢复态、配置/HBA 可解析、数据库超级用户权限、业务账号/密码、既有探针兼容性、客户端连接计数、无自定义表空间、无外来复制连接/冲突槽、PGDATA 权限与可读性、备份容量及三机网络。探针不存在不阻断只读门禁，输入 `APPLY` 后才自动初始化专用 `business.rw_probe` 并授权给现有业务用户。
- 安装器在 Pgpool 节点把完整 stdout/stderr 保存到 `/var/log/pg-readwrite-proxy-lab/install-<时间>-<PID>.log`，目录权限 700、文件权限 600；失败块包含节点、阶段、真实脚本/行号、失败命令、远端退出码及 PostgreSQL 原始错误。认证失败日志可能包含业务密码明文，必须纳入隔离区敏感日志管理。
- Standby 必须校验同版厂商运行时、当前角色与 system identifier、客户端连接计数、PGDATA/HOME/挂载和安全移动条件、旧数据保留容量、新基础备份容量以及到 Primary/Pgpool 的网络。
- Pgpool 节点必须校验麒麟 V10 ARM64/glibc 基线、SELinux、无数据库服务端、安装/配置路径和既有服务归属、端口、四个载荷哈希与归档路径、试解压、所有可执行文件的动态库闭包和版本。主机防火墙及上游 ACL 由用户单独配置，安装器不得读取或修改。
- 已有 Pgpool 更新时，门禁使用 `SHOW POOL_POOLS.pool_connected` 识别当前前端会话，并按 `pool_pid` 去重；除门禁自身连接外必须为零。它把 `pool_backendpid` 精确交给 Primary/Standby，只豁免这些 PID，不按来源 IP、账号或客户端程序名宽泛放行。
- 除 Primary/Standby 数据库客户端连接数外，任一门禁失败必须退出并清理本次生成的临时凭据及远端暂存，不提供“忽略并继续”开关。数据库连接非零时只允许通过交互菜单作出一次性人工授权；既有 Pgpool 的外部前端连接不适用该例外，仍必须先清空。选择退出时保持零持久变更，无效选项会继续要求输入。三台服务器都返回 `READY` 且连接策略完成选择后，才打印变更摘要并接受人工输入 `APPLY`。
- 门禁是部署瞬间的证据，不替代变更审批、维护窗口、完整备份、恢复预案和回退负责人。输入 `APPLY` 后，脚本会在停止既有 Pgpool 前再次复核前端连接，并在任何持久变更前统一重查两台数据库连接；如果连接在首次菜单后才出现，会再次要求人工选择。Primary/Standby 的变更脚本还会在本机实际停机前重新统计。没有强制授权时连接必须归零；获得本次运行的强制授权后，脚本会记录最终数量并使用 `pg_ctl -m fast stop` 中断会话。未提交事务会回滚，客户端需具备断线恢复能力。如果之后外部状态变化或执行失败，应按脚本给出的备份路径恢复，不得无条件重跑。

## 客户端访问策略同步

- Streaming Replication 不会持续同步 `pg_hba.conf`。Primary 只会看到 Pgpool 的后端来源地址，而 Pgpool 才能看到真实业务客户端地址，因此两层规则职责不同：Primary 保留复制/监控/Pgpool 后端通道，Pgpool 执行客户端入口白名单。
- 首次 `install.sh` 仍使用经审批的 `--allowed-client-cidrs` 建立入口；后续 `repair.sh` 从 Primary `pg_hba_file_rules` 提取普通 IPv4 `host` 允许规则中的地址集合，排除项目受管区块、回环地址和全网地址，去重后写成 Pgpool 的 `host all all <CIDR> md5`。规则数量不设固定上限，也不使用测试环境固定地址。
- 该功能只同步 IP/CIDR，不尝试复制数据库名、用户名、规则顺序或其他认证语义。IPv6、hostname、`reject`、`hostssl` 等非普通规则直接忽略。日志保留 Primary HBA 路径及 SHA256、同步/去重/忽略数量、Pgpool 策略 SHA256 和源行号。
- 只有用户输入 `REPAIR` 后才执行续装；正常健康状态下只更新 Pgpool 本机。旧安装器在基础备份后启动超时的唯一例外，是启动/等待已经通过证据链校验的 Standby PGDATA；它不会修改或 reload Primary，也不会重新执行基础备份。
- 大库基础备份完成后，Standby 首次恢复可能超过旧版 `pg_ctl -w -t 120` 的等待窗口。新版安装器以非等待方式拉起 postmaster，并单独等待最长 1800 秒；如果旧版已经在该点中断，`repair.sh` 只有在完整证据链确认当前 PGDATA 来自已完成基础备份且 system identifier 与 Primary 一致后，才允许启动/等待现有 Standby。续启脚本禁止 `pg_basebackup`、PGDATA 移动和数据库停止操作。
- `pool_hba.conf` 只是数据库代理层限制，不能替代 Pgpool 主机防火墙、交换区 ACL 或零信任访问控制；多层策略均应最小授权并由变更流程管理。

## Pgpool-II 高可用与入口

- 单独 Pgpool 服务器的对外端口默认使用 PostgreSQL 标准端口 `5432`；业务切换时只需替换主机地址。它与 Primary/Standby 不在同一服务器，后端同样使用 `5432` 不冲突。这是尚未部署环境的新建基线，不设计 `9999` 迁移、兼容监听或旧规则清理步骤。
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

- Primary、Standby 与 Pgpool 节点均以麒麟 V10 aarch64 为部署基线；PostgreSQL 12 的上游常规支持生命周期已经结束，NebulaCM PostgreSQL 12.0 的实际支持期限、补丁和安全责任必须以厂商合同为准，并纳入生产风险评审。
- Pgpool 载荷是在麒麟 V10 aarch64 上原生构建的，不是通用 ARM64 包；安装器会校验发行版、架构和 glibc 2.28 基线。私有运行库闭包不包含 glibc/动态加载器，操作系统小版本升级后必须重新执行依赖与回归验收。
- 不得用软链接伪造 OpenSSL/readline/libnsl ABI，也不得把 CentOS 系统库直接复制到麒麟。重新构建必须使用 `packages/build-kylin-v10-payloads.sh` 并更新 SHA 清单。
- 客户端 CIDR 必须最小化；PCP 只监听 localhost；后端 5432 只允许 Standby 和 Pgpool 地址。
- 当前实验入口未启用 TLS。跨不可信网络生产使用前必须部署服务端证书、客户端验证和密钥轮换。
- `config/secrets.env` 与业务明文密码只应短暂存在于安装主机，完成 `pool_passwd` 生成后迁移到密钥系统并按制度擦除。
- 一键安装首次连接使用隔离管理网中的 root 密码 SSH；生产应预置并核验 SSH 主机密钥，优先改为短期安装密钥或堡垒机审计，避免只依赖首次连接信任。
