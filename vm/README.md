# 三台 ARM CentOS 7 虚拟机

本目录保存 PostgreSQL Streaming Replication + Pgpool-II 实验用的三机 QEMU 配置。实际磁盘、cloud-init ISO、SSH 私钥和运行日志均为本机产物，已由 `.gitignore` 排除。

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

## PostgreSQL 12 独立安装基线重置

Primary 和第二台数据库服务器的“默认安装完成”状态是两套互相独立的 PostgreSQL 12.22：两者分别执行 `initdb`，没有复制账号、复制槽、WAL receiver、`primary_conninfo` 或 recovery signal。Streaming Replication 必须由项目部署脚本另行配置。

从项目根目录同时重置两台数据库服务器：

```powershell
.\vm\reset-both-independent-pg12.ps1 -ConfirmReset
```

该命令是破坏性操作，会停止两台 PostgreSQL 服务并且只删除以下两个精确目标，然后使用已校验的 ARM64 安装归档重新安装、初始化和启动：

- `/opt/pgsql12`
- `/pgsql/12/data`

脚本不会删除 Nebula 安装包、授权二维码、源码构建目录或其他 `/pgsql/12` 子目录。删除 PGDATA 前会把配置文件和 `pg_controldata` 结果保存到 `/var/backups/pg-readwrite-proxy-lab/independent-reset-*`，但不会备份业务数据。

包装器会把单机重置命令安装到两台服务器。只重置当前服务器时可在该服务器显式执行：

```bash
sudo /usr/local/sbin/reset-independent-pg12 --confirm-reset
```

单机脚本只接受 `192.168.80.110` 或 `192.168.80.120`，并在任何删除之前校验 CPU 架构、`/pgsql` 挂载、固定目标路径、5432 监听状态和 PostgreSQL 归档 SHA256。省略 `--confirm-reset` 时拒绝执行。
