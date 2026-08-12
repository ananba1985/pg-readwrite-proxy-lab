# PostgreSQL 读写分离离线安装器

本项目用于在三台 CentOS 7 aarch64 服务器上部署：现有 NebulaCM PostgreSQL 12.0 Primary、新建物理 Standby、独立 Pgpool-II 4.7.2。它不使用 Docker、不引入业务应用，也不在数据库节点安装或替换 PostgreSQL。

当前离线载荷只支持并已验收 `CentOS Linux 7.9.2009 AltArch aarch64`。项目附带的麒麟 V10 ARM64 机器仅用于兼容性探测；实测当前载荷缺少该系统所需的 OpenSSL 1.0、readline 6 和 libnsl 兼容库，因此安装器会在平台预检阶段拒绝麒麟，不能把 CentOS 7 验收结果外推为麒麟支持。

## 架构与边界

```text
业务客户端
    |
    | PostgreSQL 协议（默认 9999，仅允许配置的客户端 CIDR）
    v
Pgpool-II
    |-- DML / 事务内写后读 ------> Primary
    `-- 普通 SELECT -------------> Standby
                                      ^
                                      | Streaming Replication
                                      `---------- Primary
```

- Primary 与 Standby 必须已安装同一受支持发行版：`NebulaCM_Dbn_PostgreSQL-install-runtime-12.0-ky10-aarch64-20241212.tar.gz`。
- 固定数据库路径为 `/opt/pgsql12/bin`，PGDATA 为 `/pgsql/12/data`，生命周期通过 `pg_ctl` 和既有 `rc.local` 管理；不存在数据库 systemd unit。
- Pgpool 节点只安装官方 PostgreSQL 12.0 客户端库和 Pgpool-II，不包含 `postgres` 服务端、不创建 PGDATA。
- 基线没有自动提升命令。Standby 故障可以被健康检查摘除，但不会 promote；Primary 标记为不可自动故障转移。

## 一键离线安装

将最终归档复制到 Pgpool-II 服务器，解压并以 root 运行：

```bash
tar -xzf pg-readwrite-proxy-offline-<版本>-centos7-aarch64.tar.gz
cd pg-readwrite-proxy-offline-<版本>-centos7-aarch64
sudo bash install.sh
```

启动阶段会一次性要求输入：

- Pgpool、Primary、Standby 的内网 IPv4；
- PostgreSQL 端口、Pgpool 对外端口、两台数据库服务器的 SSH 端口；
- 允许访问 Pgpool 的客户端 IPv4 CIDR；
- 已存在的业务用户名和数据库名；
- 两台数据库服务器的公共 root SSH 密码（隐藏输入）；
- 现有业务用户密码（隐藏输入）；
- 维护窗口确认词 `APPLY`。

脚本随后自动生成复制、监控、PCP 与 AES 密钥，并依次执行：

1. 三节点只读预检；
2. 备份 Primary 配置，创建/轮换专用复制和监控角色，删除旧的 `repl 0.0.0.0/0` HBA，使用 `pg_ctl` 重启；
3. 校验 Standby 现有 NebulaCM 运行时，将非空旧 PGDATA 移到 `/var/backups/pg-readwrite-proxy-lab/`，使用 `pg_basebackup` 初始化；
4. 在 Pgpool 节点离线安装客户端和 Pgpool-II，配置认证、健康检查和延迟阈值；
5. 验证角色、`streaming`、节点识别、DML 路由、普通 SELECT 路由、事务写后读、监听范围，以及从 Primary 访问 Pgpool 对外入口。

脚本不创建、不改名、不改密现有业务用户/数据库。配置与凭据保存在解压目录的 `config/`，权限为 600；部署后应迁入密钥系统。安装期 `sshpass` 只解压到 `/var/tmp` 私有目录，退出时清理，不写入系统目录。

## 安全与回滚

- `config/cluster.env.example` 中两个破坏性门禁默认均为 `no`。只有一键入口收到 `APPLY` 后，运行副本才设为 `yes`。
- Primary 修改前将配置复制到 `/var/backups/pg-readwrite-proxy-lab/primary-<时间>/`。
- 对已知的 PG_Safe_tool `hba/pg_hba_tmp.conf`，脚本会先备份再修复为 `postgres:postgres 0600`，并扫描整个 PGDATA；发现其他 postgres 不可读路径会在基础备份前失败关闭。
- Standby 原 PGDATA 只移动、不删除。若基础备份失败，原目录仍在时间戳备份中；检查原因后再决定恢复或重跑。
- Pgpool 每次配置前备份既有配置；PCP 只监听 localhost。
- `MANAGE_FIREWALL=no` 时脚本不猜测现场网络策略；必须由防火墙/安全组放行 Standby→Primary 5432、Pgpool→两后端 5432，以及客户端 CIDR→Pgpool 9999。
- 不提交 `config/cluster.env`、`config/secrets.env`、`config/pool-users.txt`，也不记录密码、厂商管理员密码或授权信息。

## 离线包校验与构建

最终二进制载荷只有三项：

- Pgpool-II 4.7.2（链接到 `/opt/pgpool-client-12.0/lib`）；
- 官方 PostgreSQL 12.0 客户端（无服务端）；
- sshpass 1.10（仅安装期临时使用）。

归档同时携带三份对应源码与 SHA256 清单。校验：

```bash
cd packages
sha256sum -c MANIFEST.sha256
sha256sum -c SOURCES.sha256
```

在 CentOS 7 aarch64 构建机重建载荷使用 `packages/build-arm64-payloads.sh`；生成交付包使用：

```bash
sudo bash scripts/90-package-offline.sh <版本>
```

脚本只按 SHA 清单拷贝载荷，不会把本地旧包、NebulaCM 厂商介质、PG_Safe_tool、授权文件或虚机文件带入交付包。

## 单步运维与验证

- `scripts/00-preflight.sh`：按角色只读预检。
- `scripts/10-configure-primary.sh`：配置 Primary。
- `scripts/20-install-postgresql-standby.sh`：仅校验 Standby 已安装的 NebulaCM，名字为兼容既有步骤编号。
- `scripts/21-bootstrap-standby.sh`：初始化物理 Standby。
- `scripts/30-install-pgpool.sh`、`31-configure-pgpool.sh`：安装和配置 Pgpool。
- `scripts/40-verify-cluster.sh`：路由与复制验收。
- `scripts/41-observe-cluster.sh`：只读观察复制/Pgpool 状态。
- `vm/reset-pgpool-environment.ps1`：本机三虚拟机实验环境专用；默认只读预检，显式传入 `-ConfirmReset` 才将 Pgpool 节点恢复到项目安装器运行前状态。

测试数据说明见 [docs/TEST_DATA.md](docs/TEST_DATA.md)，故障与延迟演练见 [docs/failure-and-delay-tests.md](docs/failure-and-delay-tests.md)，生产化清单见 [docs/production-notes.md](docs/production-notes.md)。
三机真实部署、路由、延迟与故障恢复结果见 [docs/acceptance-report.md](docs/acceptance-report.md)。
