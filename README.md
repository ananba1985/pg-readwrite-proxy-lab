# PostgreSQL 读写分离麒麟离线安装器

本项目提供一套三机一键部署工具：两台 Kylin Linux Advanced Server V10 aarch64 数据库服务器分别作为 NebulaCM PostgreSQL 12.0 Primary 和物理 Standby，另一台麒麟 V10 aarch64 服务器作为 Pgpool-II 4.7.2 统一入口。项目不使用容器、不引入业务应用，也不在数据库节点安装或替换 PostgreSQL。

当前离线载荷只面向并校验上述组合。Pgpool、PostgreSQL 客户端和所需非 glibc 运行库均在麒麟 V10 ARM64 上原生构建；安装过程不访问软件仓库，也不依赖目标机预装编译器。

## 架构与边界

```text
业务客户端
    |
    | PostgreSQL 协议（默认 5432，仅允许配置的客户端 CIDR）
    v
麒麟 V10 Pgpool-II
    |-- DML / 事务内写后读 ------> Primary
    `-- 普通 SELECT -------------> Standby
                                      ^
                                      | Streaming Replication
                                      `---------- Primary
```

- Primary 与 Standby 必须已安装同一已验收发行版：`NebulaCM_Dbn_PostgreSQL-install-runtime-12.0-ky10-aarch64-20241212.tar.gz`。
- 固定数据库路径为 `/opt/pgsql12/bin`，PGDATA 为 `/pgsql/12/data`，生命周期通过 `pg_ctl` 和既有 `rc.local` 管理。
- Pgpool 节点只安装 `/opt/pgpool-client-12.0`、`/opt/pgpool-II-4.7.2` 和 `/opt/pgpool-runtime-kylin-v10`，不包含 `postgres` 服务端、不创建 PGDATA。
- 基线不自动提升 Standby。Standby 故障可被健康检查摘除，但不会执行 promote；Primary 标记为禁止自动故障转移。

## 一键离线安装

将最终归档复制到麒麟 Pgpool 服务器，校验、解压并以 root 运行：

```bash
sha256sum -c pg-readwrite-proxy-offline-<版本>-kylin-v10-aarch64.tar.gz.sha256
tar -xmzf pg-readwrite-proxy-offline-<版本>-kylin-v10-aarch64.tar.gz
cd pg-readwrite-proxy-offline-<版本>-kylin-v10-aarch64
sudo bash install.sh
```

也可以在启动命令中一次传入全部配置和密码：

```bash
sudo bash install.sh \
  --pgpool-host 192.168.80.140 \
  --primary-host 192.168.80.110 \
  --standby-host 192.168.80.120 \
  --postgresql-port 5432 \
  --pgpool-port 5432 \
  --ssh-port 22022 \
  --allowed-client-cidrs 192.168.80.0/24 \
  --business-user rw_lab_test \
  --business-database rw_proxy_lab \
  --root-ssh-password '数据库服务器root密码' \
  --business-password '现有业务用户密码'
```

参数同时支持 `--name value` 和 `--name=value`。正常流程不回显密码；如果业务数据库连接或认证失败，安装器会按当前物理隔离环境的调试约定，在终端和 root-only 完整诊断日志中打印本次 `BUSINESS_PASSWORD` 明文。包含空格或 Shell 特殊字符的值应使用单引号。使用 `sudo bash install.sh --help` 可查看完整参数。可以只传一部分参数，未传入的项目才会交互补全；全部参数齐全时不会出现配置输入提示。旧命令中的 `--manage-pgpool-firewall yes|no` 仍可传入以保持兼容，但会被明确忽略，不触发任何防火墙检查或操作；新命令应直接删除该参数。

配置参数与密码可以在启动阶段传入，但最终部署授权不提前：三节点只读检查全部通过后，仍须输入 `APPLY` 才会修改环境。

只读检查会统计 Primary 和 Standby 的客户端连接。连接数为 `0` 时按原流程继续；任一节点非零时会显示操作菜单。只有选择“已确认业务停止写入，允许中断连接”才会继续。输入 `APPLY` 后、任何持久变更前会再统一统计一次；如果此时首次出现连接，菜单会再次弹出。数据库变更脚本还会在实际停机前作最后统计，并使用 `pg_ctl -m fast stop` 中断仍存在的会话。未提交事务会回滚，客户端连接会断开；该授权仅对本次安装进程有效，不写入长期配置。

启动阶段会从参数读取以下项目；没有传入的项目才会要求输入：

- 当前 Pgpool、现有 Primary、Standby 目标机的内网 IPv4；
- PostgreSQL 后端端口和 Pgpool 对外端口（两者默认均为 `5432`）；
- Primary 与 Standby 共用的 root SSH 端口（默认 `22`，支持非标准端口）；
- 首次部署允许写入 Pgpool `pool_hba.conf` 的客户端 IPv4 CIDR；主机防火墙和上游 ACL 由用户自行配置；
- 已存在的业务用户名和数据库名；
- 两台数据库服务器的公共 root SSH 密码，以及现有业务用户密码（未通过启动参数提供时隐藏输入）；
- 维护窗口确认词 `APPLY`。

脚本会先在 root-only 临时配置中生成复制、监控、PCP 与 AES 密钥，然后依次完成：

1. 三节点基础预检和严格只读就绪检查；检查 SSH/root 权限、平台、命令、路径/挂载、网络路由与端口、离线载荷、数据库版本/角色、业务对象与凭据、活动连接、表空间/复制槽、PGDATA 权限、备份和基础备份容量；
2. 任一检查失败即清理本次临时配置并退出，三台服务器均不执行部署变更；
3. 全部技术检查显示 `READY` 后，如果数据库连接非零，先显示退出/强制中断菜单；完成选择后才打印完整变更摘要并要求输入 `APPLY`；
4. 确认后才备份并配置 Primary，在既有业务库中自动初始化/校验专用 `business.rw_probe` 路由探针，初始化 Standby，安装/配置麒麟 Pgpool；
5. 最终验证角色、`streaming`、节点识别、DML/SELECT 路由、事务写后读、监听范围，以及从 Primary 访问统一入口。

检查阶段允许的唯一写入是 `/var/tmp` 下本次会话的 root-only 临时配置/随机凭据、离线载荷试解压目录、SSH `known_hosts` 和两台数据库节点的临时暂存；这些内容不会覆盖解压目录中的既有运行配置，不会改变数据库或系统服务，并会在检查失败或用户取消时清理。安装器把完整 stdout/stderr 保存到 Pgpool 节点 `/var/log/pg-readwrite-proxy-lab/install-<时间>-<PID>.log`（目录 700、文件 600），错误时同时输出主机、阶段、真实脚本/行号、失败命令、远端退出码和数据库原始错误。远端暂存解压不保留源文件修改时间，因此节点间 1 秒级时钟偏差不会触发 `tar` 失败；SSH 平台检查通过 Unix 时间估算显式允许 `5` 秒偏差，超过门禁才要求先同步系统时间。安装器完全不检查、不启动、不停止、不配置主机防火墙，也不调用 `firewall-cmd`；网络放行由用户在安装器之外处理。依赖、权限、路径、容量、网络、端口、载荷或数据库状态等技术门禁没有跳过选项。Primary/Standby 数据库客户端连接数是唯一具备人工例外菜单的运行状态：只有用户明确确认停写并接受会话中断后才允许非零继续；既有 Pgpool 的外部前端连接仍必须先清空。输入 `APPLY` 后，已有 Pgpool 场景还会在停止服务前再次复核前端连接；Primary 与 Standby 各自在实际改动前做最后一次本机连接统计，未授权时非零即失败，已授权时记录数量并由 fast stop 中断。

幂等更新检测到本项目 Pgpool 正在运行时，会通过 `SHOW POOL_POOLS` 确认除本次只读检查外没有前端连接，并把当前连接池的后端 PID 精确传给 Primary/Standby 核验。这样只豁免本次已证明属于 Pgpool 的空闲后端，来源 IP 相同的直连客户端仍会失败关闭。如果更新在重新配置 Pgpool 前中断，退出清理会尝试恢复既有 Pgpool 服务。

脚本不会创建、改名或改密现有业务用户/数据库。运行参数与凭据保存在解压目录的 `config/`，权限为 600；安装后应迁入受控密钥系统。安装期 `sshpass` 只解压到 `/var/tmp` 私有目录，退出时清理。

## 同步中断后的状态检测与安全续装

如果完整安装已经进入大体量 `pg_basebackup`，不要中断同步，也不要为了更新校验脚本重新执行全量初始化。归档根目录中与 `install.sh` 并列的 `repair.sh` 接受完全相同的启动参数；缺项才交互补全。应在原安装进程退出后执行，也可以在同步期间先运行一次确认状态：检测到 `install.sh`、`21-bootstrap-standby.sh` 或 `pg_basebackup` 仍在运行时，它只记录日志并返回 `REPAIR_RESULT=WAITING_FOR_CURRENT_INSTALL_OR_BASEBACKUP`，不停止任何进程。

若日志已经出现 `pg_basebackup: base backup completed`，但随后 `pg_ctl: server did not start in time`，不要重跑 `install.sh`。这表示基础备份已经完成，失败点是 Standby 首次恢复的启动等待窗口。`repair.sh` 会先只读校验恢复状态文件、`standby.signal`、受管配置、`PG_VERSION`、`pg_control` 和 Primary system identifier；证据全部一致后，用户输入 `REPAIR` 才会启动或继续等待当前 Standby PGDATA，最长等待 1800 秒。该续启入口不包含 `pg_basebackup`，不移动 PGDATA，不停止 Primary/Standby；Standby 达到 `streaming` 后才继续安装 Pgpool。

全量参数示例：

```bash
sudo bash repair.sh \
  --pgpool-host 192.168.80.140 \
  --primary-host 192.168.80.110 \
  --standby-host 192.168.80.120 \
  --postgresql-port 5432 \
  --pgpool-port 5432 \
  --ssh-port 22022 \
  --allowed-client-cidrs 192.168.80.0/24 \
  --business-user rw_lab_test \
  --business-database rw_proxy_lab \
  --root-ssh-password '数据库服务器root密码' \
  --business-password '现有业务用户密码'
```

`repair.sh` 先把本次全部参数与原安装已保存的 `config/cluster.env`、`config/secrets.env` 逐项比对，再检测主从角色、system identifier、复制槽、WAL receiver、`streaming`、监控/业务凭据、路由探针、Pgpool 运行时、配置、服务、自启、监听和节点识别。`--allowed-client-cidrs` 在 repair 中只用于确认“正在修复原安装会话”，不再作为要落盘的访问白名单；实际白名单每次都由 Primary 动态读取。判定规则如下：

- 完整安装或基础同步仍运行：只报告 `WAITING`，退出码 `10`；
- 主从不同源或 Standby 既不可用又缺少完整基础备份证据：报告 `BLOCKED_DATABASE`，退出码 `20`，不修改数据库；已证明基础备份完成的启动中断会列出 `standby_resume_existing_pgdata`，输入 `REPAIR` 后只续启现有 PGDATA；
- Primary HBA 无法稳定读取、存在解析错误，或没有可同步的普通 IPv4 `host` 白名单：报告 `BLOCKED_PRIMARY_POLICY`，退出码 `25`，不修改任何节点；
- Pgpool 本机有可修复项：逐项列出，只有用户输入 `REPAIR` 后才执行本机离线运行时、配置和 systemd 服务修复；其他输入返回退出码 `30`；
- 所有检查通过：报告 `REPAIR_RESULT=HEALTHY`；修复并验收通过则报告 `REPAIR_RESULT=REPAIRED`。

该入口源码和回归门禁禁止调用 `10-configure-primary.sh`、`20-install-postgresql-standby.sh`、`21-bootstrap-standby.sh`，并禁止执行 `pg_basebackup` 或停止数据库。唯一允许的数据库动作是调用 `22-resume-standby-after-basebackup.sh` 启动/等待已经完成基础备份的 Standby PGDATA；其他修复只调用 Pgpool 本机的 `30-install-pgpool.sh`、`31-configure-pgpool.sh`。随后通过专用 `business.rw_probe` 做少量可自动清理的 DML/SELECT 路由验收。完整日志写入 `/var/log/pg-readwrite-proxy-lab/repair-<时间>-<PID>.log`，目录 700、文件 600。

### repair 同步 Primary 访问策略

Primary 是业务客户端 IP 白名单的来源。`repair.sh` 使用厂商超级用户入口只读查询 `pg_hba_file_rules`，提取受管区块之外所有普通 IPv4 `host` + `md5`/`scram-sha-256` 规则中的 IP/CIDR，去重后生成 Pgpool 的 `host all all <CIDR> md5` 规则。规则数量不限，单 IP 会规范化为 `/32`，网段会规范化为 CIDR。日志记录源 HBA SHA256、同步数量、去重数量、忽略数量、策略 SHA256 和源行号。

以下内容不会成为客户端白名单：本项目 `# BEGIN/END PG_RW_PROXY_HBA` 区块中的 Standby 复制、监控、Pgpool 到后端通道，以及本机回环规则。`repair.sh` 不会把 Primary HBA 写到 Standby，也不会修改或 reload Primary；Streaming Replication 本身也不会持续复制 HBA 配置文件。

这项同步只复制“允许访问的 IPv4 地址集合”，不复制 Primary 规则中的数据库名、用户名、先后顺序或认证细节。回环地址、`0.0.0.0/0`、IPv6、hostname、`reject`、`hostssl` 等非普通规则直接忽略；Pgpool 仍通过自己的 `pool_passwd` 校验实际登录账号。该行为有意保持简单，适用于现场现有的普通 IPv4 白名单。

## 安全与回滚

- 示例配置中的 Primary 重启和 Standby 重建门禁默认都是 `no`；一键入口只在用户输入 `APPLY` 后生成授权值。
- Primary 修改前备份到 `/var/backups/pg-readwrite-proxy-lab/primary-<时间>/`。
- 厂商工具遗留的 `hba/pg_hba_tmp.conf` 会先备份再修复权限；发现其他 postgres 不可读路径时会在基础备份前失败关闭。
- Standby 原 PGDATA 只移动、不删除；Pgpool 每次配置前也备份现有配置。
- 主机防火墙和上游 ACL 不属于本安装器职责。用户必须自行放行：Pgpool 到 Primary/Standby 的 PostgreSQL 端口、Standby 到 Primary 的复制端口，以及允许的业务客户端到 Pgpool TCP/5432；PCP 9898 仍只监听 localhost。Pgpool 与后端 PostgreSQL 位于不同服务器，因此同用 5432 不构成端口冲突。
- `5432` 是尚未部署环境的新建基线；安装器不包含未发生的 `9999` 端口迁移、双端口兼容监听或旧防火墙规则清理逻辑。
- 不提交 `config/cluster.env`、`config/secrets.env`、`config/pool-users.txt`、诊断日志、厂商管理员密码或授权信息。业务认证失败日志会按物理隔离环境约定包含 `BUSINESS_PASSWORD` 明文，排障完成后应由现场人员按其日志保留制度处置。

## 离线载荷与构建

`packages/MANIFEST.sha256` 固定四项麒麟载荷：Pgpool-II 4.7.2、PostgreSQL 12.0 客户端、麒麟私有运行库闭包和 sshpass 1.10。`packages/SOURCES.sha256` 固定三份对应上游源码。

```bash
cd packages
sha256sum -c MANIFEST.sha256
sha256sum -c SOURCES.sha256
```

在联网的麒麟 V10 aarch64 构建机重建载荷：

```bash
sudo bash packages/build-kylin-v10-payloads.sh
```

生成最终离线归档：

```bash
sudo bash scripts/90-package-offline.sh <版本>
```

打包器只按 SHA 清单复制载荷，不会带入本地旧包、NebulaCM 厂商介质、PG_Safe_tool、授权文件或虚拟机文件。最终归档成员使用固定历史修改时间，首次解压不依赖构建机与隔离区服务器的时钟同步；交付身份以版本文件名和外置 SHA256 为准。

## 运维与验证入口

- `scripts/00-preflight.sh`：按角色只读预检。
- `scripts/05-readiness-check.sh`：`APPLY` 之前的严格只读就绪门禁。
- `scripts/06-state-fingerprint.sh`：比较检查前后将受影响持久状态的无敏感信息指纹。
- `scripts/07-count-business-sessions.sh`：幂等更新停止既有 Pgpool 后重新统计数据库普通客户端连接，供零连接门禁或人工强制授权判断。
- `scripts/10-configure-primary.sh`：配置 Primary。
- `scripts/20-install-postgresql-standby.sh`：只校验 Standby 已安装的 NebulaCM。
- `scripts/21-bootstrap-standby.sh`：初始化物理 Standby。
- `scripts/30-install-pgpool.sh`、`31-configure-pgpool.sh`：安装和配置麒麟 Pgpool。
- `scripts/40-verify-cluster.sh`：复制与 SQL 路由验收。
- `scripts/41-observe-cluster.sh`：只读观察复制/Pgpool 状态。

测试数据见 [docs/TEST_DATA.md](docs/TEST_DATA.md)，故障与延迟演练见 [docs/failure-and-delay-tests.md](docs/failure-and-delay-tests.md)，生产化清单见 [docs/production-notes.md](docs/production-notes.md)，实机证据见 [docs/acceptance-report.md](docs/acceptance-report.md)。
