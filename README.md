# PostgreSQL Read/Write Proxy Lab

用于复现和验证三节点 PostgreSQL Streaming Replication + Pgpool-II 读写分离的实验项目。仓库保存可审查、可重复执行的脚本和配置模板；虚拟机磁盘、操作系统镜像、数据库安装包、密码、私钥及运行日志不会提交到 GitHub。

## 固定拓扑

| 角色 | 固定 IP | 当前本地实验状态 |
| --- | --- | --- |
| Primary | `192.168.80.110` | 独立 PostgreSQL 12.22，可加载确定性业务测试数据 |
| 第二台数据库服务器 | `192.168.80.120` | 独立 PostgreSQL 12.22，等待项目脚本配置为 Standby |
| Pgpool-II | `192.168.80.130` | 独立代理服务器，不承载数据库 |

三台 CentOS 7 ARM64 虚拟机通过专用 QEMU 二层网络直接使用 IP 通信，不依赖主机名。默认基线不会自动配置主从、自动故障转移或 Standby 提升。

## 仓库内容

- `vm/`：Windows/QEMU 三机创建、启动、固定 IP 网络、root 密码互联和数据库基线重置工具。
- `scripts/`：Primary、Standby、Pgpool-II 的预检、部署、配置与验收脚本。
- `templates/`：PostgreSQL 与 Pgpool-II 配置模板。
- `config/*.example`：不含真实密码的参数示例。
- `scripts/sql/`：Primary 确定性业务数据生成及只读验收 SQL。

当前本地 ARM 实验使用 PostgreSQL 12.22，安装目录和数据目录固定为：

```text
/opt/pgsql12
/opt/pgsql12/bin
/pgsql/12/data
/pgsql/12/data/postgresql.conf
/pgsql/12/data/pg_hba.conf
```

根目录的集群一键部署器面向 EL 8/9 和 PostgreSQL 14–18。它与 CentOS 7 ARM/PostgreSQL 12 本地实验基线尚未合并为同一条已验收路径；后续适配和完整主从/Pgpool 验收应通过项目脚本迭代完成。

## 本地虚拟机操作

在 Windows PowerShell 中执行：

```powershell
.\vm\start-all.ps1
.\vm\status.ps1
.\vm\stop-all.ps1
```

详细拓扑和 SSH 使用方式见 [`vm/README.md`](vm/README.md)。虚拟机镜像和 QEMU 运行产物需要在本机单独准备，不由本仓库分发。

## 恢复两套独立数据库基线

以下命令会删除两台数据库服务器现有的 `/opt/pgsql12` 和 `/pgsql/12/data`，然后使用本机已校验、但不会提交到 GitHub 的 ARM64 安装归档重新安装并分别执行 `initdb`：

```powershell
.\vm\reset-both-independent-pg12.ps1 -ConfirmReset
```

重置结果是两套互相独立的 PostgreSQL，不包含复制账号、复制槽、WAL receiver 或 recovery signal。主从关系由项目部署脚本另行配置。

## Primary 测试数据

在 Primary 创建或重建 `rw_proxy_lab`：

```powershell
.\vm\load-primary-test-data.ps1 -ConfirmReset
```

`business-v1` 数据集使用固定公式生成，共 632,000 行：

- `business.customers`：30,000 行
- `business.products`：2,000 行
- `business.orders`：150,000 行
- `business.order_items`：450,000 行
- `business.rw_probe`：后续读写路由测试专用空表

完整说明和验收命令见 [`docs/TEST_DATA.md`](docs/TEST_DATA.md)。

## 安全边界

- `config/cluster.env`、`config/secrets.env`、`config/pool-users.txt` 不进入版本库。
- `vm/disks/`、`vm/seeds/`、`vm/keys/`、`vm/runtime/` 不进入版本库。
- qcow2、ISO、固件、RPM/DEB、压缩归档和编译二进制由 `.gitignore` 统一排除。
- 修改现有 Primary 前必须备份配置；Primary 重启必须经过维护窗口确认。
- Standby 非空 PGDATA 默认拒绝覆盖；自动故障转移必须先设计 fencing、仲裁、RPO/RTO 与回切方案。

本仓库公开不等于包含任何现场凭据或授权材料。运行脚本前请先阅读 [`AGENTS.md`](AGENTS.md) 中的项目协作与安全约束。
