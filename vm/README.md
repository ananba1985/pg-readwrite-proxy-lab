# ARM 三机数据库实验与麒麟 Pgpool 验证机

本目录保存 PostgreSQL Streaming Replication + Pgpool-II 实验用的三机 QEMU 配置。实际磁盘、cloud-init ISO、SSH 私钥和运行日志均为本机产物，已由 `.gitignore` 排除。

当前最终 Pgpool 角色已迁移到单独的麒麟 V10 验证机 `192.168.80.140`（本机 SSH `22021`）。下表中的 `.130` 是上一轮 CentOS Pgpool 基线，保留用于历史回归，正式麒麟一键安装和验收不要以它作为统一入口。

## 拓扑

三台虚拟机各有两张 virtio 网卡：

- 管理网卡使用 QEMU user networking，仅绑定本机 SSH 转发，不允许外部主机直接访问。
- 集群网卡分别连接到一个轻量 QEMU 交换机进程的三个本机 socket 端口；三个端口接入同一个 QEMU hub。它等价于文章中 `br0 + tap0/tap1` 所提供的共享二层网络，但适用于当前 Windows 宿主机且不需要管理员权限。
- 集群网卡不配置默认网关，避免数据库流量误走管理网卡。
- 每张集群网卡都有独立 MAC；固定地址沿用文章的 `192.168.80.0/24` 方案。
- 三台虚拟机之间直接使用固定 IP 通信；cloud-init 不写入三机主机名映射，互通验收也不依赖 DNS 或 `/etc/hosts`。

| 角色 | 主机名 | 集群地址 | 集群 MAC | 本机 SSH |
| --- | --- | --- | --- | --- |
| Primary | `pg-primary` | `192.168.80.110/24` | `52:54:00:12:34:10` | `127.0.0.1:22011` |
| Standby | `pg-standby` | `192.168.80.120/24` | `52:54:00:12:34:20` | `127.0.0.1:22012` |
| Pgpool-II | `pg-pgpool` | `192.168.80.130/24` | `52:54:00:12:34:30` | `127.0.0.1:22013` |

交换机端口 `127.0.0.1:15911`、`:15912`、`:15913` 只在本机监听。集群总线只在三台 QEMU 之间承载二层帧；Windows 宿主机本身没有 `192.168.80.100` 地址。宿主机管理通过上表 SSH 转发完成。

## 操作

从项目根目录执行：

```powershell
.\vm\start-all.ps1
.\vm\status.ps1
.\vm\stop-all.ps1
```

SSH 私钥生成在 `vm/keys/lab_rsa`，登录用户是 `labadmin`，不设置密码：

```powershell
ssh -i .\vm\keys\lab_rsa -p 22011 labadmin@127.0.0.1
ssh -i .\vm\keys\lab_rsa -p 22012 labadmin@127.0.0.1
ssh -i .\vm\keys\lab_rsa -p 22013 labadmin@127.0.0.1
```

三台集群节点同时启用了共用的 `root` 密码认证。密码保存在被 Git 忽略且限制 ACL 的 `vm/keys/root-password.txt`；可在本机显式查看：

```powershell
Get-Content .\vm\keys\root-password.txt
```

从任一虚拟机直接按固定 IP 登录其他节点，例如：

```bash
ssh root@192.168.80.120
ssh root@192.168.80.130
```

重新生成密码并同步到三台虚拟机时执行：

```powershell
.\vm\configure-root-password.ps1 -Rotate
.\vm\verify-root-password-login.ps1
```

如需强制停止，必须显式执行 `.\vm\stop-all.ps1 -Force`。正常情况应先使用不带 `-Force` 的脚本，让来宾系统完成关机。

## NebulaCM PostgreSQL 12.0 基线

Primary 和 Standby 目标机都通过下列厂商介质自带的 `install.sh` 和各自主机授权码完成安装：

```text
NebulaCM_Dbn_PostgreSQL-install-runtime-12.0-ky10-aarch64-20241212.tar.gz
```

两台当前仍是互相独立的 NebulaCM PostgreSQL 12.0 实例：`pg_is_in_recovery()` 均为 `false`，system identifier 不同，没有 WAL receiver 或 recovery signal。Streaming Replication 必须由项目部署脚本从现有 Primary 初始化，不能把当前 Standby 目标机误写成已经完成的 Standby。

两台固定路径相同：

```text
/opt/pgsql12
/opt/pgsql12/bin
/pgsql/12/data
/pgsql/12/data/postgresql.conf
/pgsql/12/data/pg_hba.conf
```

厂商安装器没有创建 PostgreSQL systemd unit；当前使用 `/opt/pgsql12/bin/pg_ctl` 管理进程，并由 `/etc/rc.d/rc.local` 启动。状态检查示例：

```bash
sudo runuser -u postgres -- \
  /opt/pgsql12/bin/pg_ctl -D /pgsql/12/data status
```

数据库重装只能使用上述厂商介质、每台机器自己的授权信息和配套 `PG_Safe_tool`。任何不调用厂商安装、授权及维护流程的数据库重建入口都不属于当前环境，不得用于这两台虚拟机。

## PG_Safe_tool 与测试数据

两台均已部署 `PG_Safe_tool 1.0.8`，路径为：

```text
/var/tmp/pg-safe-tool-stage-1.0.8/PG_Safe_tool
```

Primary 已通过该工具创建 `rw_lab_test`、`rw_proxy_lab` 和三条固定 IP HBA 规则；Standby 目标机只部署工具并执行只读检查。不要在 Standby 上手工重复创建业务用户和数据库，物理基础备份会从 Primary 带入这些对象。

Primary 测试数据可在项目根目录重新生成：

```powershell
.\vm\load-primary-test-data.ps1 -ConfirmReset
```

该命令只原子重建 `rw_proxy_lab` 中的 `business` schema，不负责重装数据库。完整的真实环境、凭据文件位置、维护工具约束和数据库验收结果见被 Git 忽略的 [`runtime/DEVELOPMENT_TEST_ENVIRONMENT.md`](runtime/DEVELOPMENT_TEST_ENVIRONMENT.md)。

## Pgpool-II 环境重置

后续重复测试项目离线安装器前，可先对独立 Pgpool 节点执行只读预检。无参数与显式 `-PreflightOnly` 完全等价，都不会修改远端环境：

```powershell
.\vm\reset-pgpool-environment.ps1
.\vm\reset-pgpool-environment.ps1 -PreflightOnly
```

确认要恢复到“项目安装器尚未运行”的状态后，必须显式打开破坏性门禁：

```powershell
.\vm\reset-pgpool-environment.ps1 -ConfirmReset
```

该重置入口仅处理历史 `.130` CentOS Pgpool 基线。当前麒麟 `.140` 的清理与重测必须按精确目标执行，不能误用本脚本。旧基线的运行配置若明确记录了 `MANAGE_FIREWALL=yes`，脚本仍会按其中客户端 CIDR 精确删除 TCP/9999 规则。

脚本保留虚拟机磁盘、网络、SSH/root 登录、操作系统包、构建工具、离线介质和安装器源码，也不会连接或修改 Primary、Standby。重置前后只保留不含口令的元数据审计到 `/var/backups/pg-readwrite-proxy-lab/pgpool-reset-<时间>/`；完成后需要重新运行项目离线安装器才能恢复 Pgpool 服务。
