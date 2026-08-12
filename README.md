# PostgreSQL 读写分离麒麟离线安装器

本项目提供一套三机一键部署工具：两台现有 CentOS 7 aarch64 数据库服务器分别作为 NebulaCM PostgreSQL 12.0 Primary 和物理 Standby，一台 Kylin Linux Advanced Server V10 aarch64 服务器作为 Pgpool-II 4.7.2 统一入口。项目不使用容器、不引入业务应用，也不在数据库节点安装或替换 PostgreSQL。

当前离线载荷只面向并校验上述组合。Pgpool、PostgreSQL 客户端和所需非 glibc 运行库均在麒麟 V10 ARM64 上原生构建；安装过程不访问软件仓库，也不依赖目标机预装编译器。

## 架构与边界

```text
业务客户端
    |
    | PostgreSQL 协议（默认 9999，仅允许配置的客户端 CIDR）
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
tar -xzf pg-readwrite-proxy-offline-<版本>-kylin-v10-aarch64.tar.gz
cd pg-readwrite-proxy-offline-<版本>-kylin-v10-aarch64
sudo bash install.sh
```

启动阶段会要求输入：

- 当前 Pgpool、现有 Primary、Standby 目标机的内网 IPv4；
- PostgreSQL、Pgpool 和两台数据库服务器 SSH 端口；
- 允许访问 Pgpool 的客户端 IPv4 CIDR；
- 是否由安装器在麒麟 firewalld 中精确放行客户端到 Pgpool 端口；
- 已存在的业务用户名和数据库名；
- 两台数据库服务器的公共 root SSH 密码，以及现有业务用户密码（均隐藏输入）；
- 维护窗口确认词 `APPLY`。

脚本会先在 root-only 临时配置中生成复制、监控、PCP 与 AES 密钥，然后依次完成：

1. 三节点基础预检和严格只读就绪检查；检查 SSH/root 权限、平台、命令、路径/挂载、网络路由与端口、离线载荷、数据库版本/角色、业务对象与凭据、活动连接、表空间/复制槽、PGDATA 权限、备份和基础备份容量、firewalld；
2. 任一检查失败即清理本次临时配置并退出，三台服务器均不执行部署变更；
3. 全部显示 `READY` 后才打印完整变更摘要并要求输入 `APPLY`；
4. 确认后才备份并配置 Primary，初始化 Standby，安装/配置麒麟 Pgpool；
5. 最终验证角色、`streaming`、节点识别、DML/SELECT 路由、事务写后读、监听范围，以及从 Primary 访问统一入口。

检查阶段允许的唯一写入是 `/var/tmp` 下本次会话的 root-only 临时配置/随机凭据、离线载荷试解压目录、SSH `known_hosts` 和两台数据库节点的临时暂存；这些内容不会覆盖解压目录中的既有运行配置，不会改变数据库或系统服务，并会在检查失败或用户取消时清理。门禁没有跳过选项：任意依赖、权限、路径、容量、网络、端口、载荷或数据库状态不满足，就不会出现 `APPLY` 提示。输入 `APPLY` 后，已有 Pgpool 场景还会在停止服务前再次复核前端连接；复核通过后才临时停止入口，并确认两台数据库的普通客户端连接已归零。Primary 与 Standby 各自在实际改动前还会做最后一次本机连接检查，随后安装器才备份旧运行配置并落盘新配置。

幂等更新检测到本项目 Pgpool 正在运行时，会通过 `SHOW POOL_POOLS` 确认除本次只读检查外没有前端连接，并把当前连接池的后端 PID 精确传给 Primary/Standby 核验。这样只豁免本次已证明属于 Pgpool 的空闲后端，来源 IP 相同的直连客户端仍会失败关闭。如果更新在重新配置 Pgpool 前中断，退出清理会尝试恢复既有 Pgpool 服务。

脚本不会创建、改名或改密现有业务用户/数据库。运行参数与凭据保存在解压目录的 `config/`，权限为 600；安装后应迁入受控密钥系统。安装期 `sshpass` 只解压到 `/var/tmp` 私有目录，退出时清理。

## 安全与回滚

- 示例配置中的 Primary 重启和 Standby 重建门禁默认都是 `no`；一键入口只在用户输入 `APPLY` 后生成授权值。
- Primary 修改前备份到 `/var/backups/pg-readwrite-proxy-lab/primary-<时间>/`。
- 厂商工具遗留的 `hba/pg_hba_tmp.conf` 会先备份再修复权限；发现其他 postgres 不可读路径时会在基础备份前失败关闭。
- Standby 原 PGDATA 只移动、不删除；Pgpool 每次配置前也备份现有配置。
- 数据库节点防火墙和 Pgpool 防火墙分开管理。默认不修改当前未运行 firewalld 的数据库节点；麒麟节点仅按客户端 CIDR开放 TCP/9999，PCP 9898 只监听 localhost 且不添加外部规则。
- 不提交 `config/cluster.env`、`config/secrets.env`、`config/pool-users.txt`，也不记录密码、厂商管理员密码或授权信息。

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

打包器只按 SHA 清单复制载荷，不会带入本地旧包、NebulaCM 厂商介质、PG_Safe_tool、授权文件或虚拟机文件。

## 运维与验证入口

- `scripts/00-preflight.sh`：按角色只读预检。
- `scripts/05-readiness-check.sh`：`APPLY` 之前的严格只读就绪门禁。
- `scripts/06-state-fingerprint.sh`：比较检查前后将受影响持久状态的无敏感信息指纹。
- `scripts/07-count-business-sessions.sh`：幂等更新停止既有 Pgpool 后确认数据库普通客户端连接归零。
- `scripts/10-configure-primary.sh`：配置 Primary。
- `scripts/20-install-postgresql-standby.sh`：只校验 Standby 已安装的 NebulaCM。
- `scripts/21-bootstrap-standby.sh`：初始化物理 Standby。
- `scripts/30-install-pgpool.sh`、`31-configure-pgpool.sh`：安装和配置麒麟 Pgpool。
- `scripts/40-verify-cluster.sh`：复制与 SQL 路由验收。
- `scripts/41-observe-cluster.sh`：只读观察复制/Pgpool 状态。

测试数据见 [docs/TEST_DATA.md](docs/TEST_DATA.md)，故障与延迟演练见 [docs/failure-and-delay-tests.md](docs/failure-and-delay-tests.md)，生产化清单见 [docs/production-notes.md](docs/production-notes.md)，实机证据见 [docs/acceptance-report.md](docs/acceptance-report.md)。
