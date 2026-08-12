# 测试环境验收报告

验收日期：2026-08-12

目标环境：三台 CentOS Linux 7.9.2009 AltArch aarch64

数据库发行版：NebulaCM PostgreSQL 12.0

代理版本：Pgpool-II 4.7.2

本报告不记录任何密码、授权码或私钥。测试使用项目最终离线归档在独立 Pgpool 节点执行 `bash install.sh`，并完成一次成功的幂等重跑。

最终归档：`pg-readwrite-proxy-offline-20260812-centos7-aarch64.tar.gz`。归档 SHA256 以同目录的 `.tar.gz.sha256` 外置文件为准；校验值不写入归档内部，避免验收报告与归档形成自引用。

## 基础部署结果

| 检查项 | 验收结果 |
| --- | --- |
| Primary | `rw-primary`，`pg_is_in_recovery()=false` |
| Standby | `rw-standby`，`pg_is_in_recovery()=true` |
| 复制 | `rw_standby|streaming|async` |
| 复制延迟 | 最终 `replay_lag_bytes=0` |
| Pgpool backend 0 | `192.168.80.110:5432`，`up/up`，`primary`，读权重 0 |
| Pgpool backend 1 | `192.168.80.120:5432`，`up/up`，`standby`，读权重 1 |
| 统一入口 | `192.168.80.130:9999`，从 Primary 作为远端客户端连接成功 |
| PCP | 仅监听 localhost `9898` |
| Pgpool 节点数据库服务端 | 不存在；只有 `/opt/pgpool-client-12.0` 客户端 |

## SQL 路由结果

在 `business.rw_probe` 隔离探针表上完成并自动清理测试数据：

- `INSERT` 返回 `rw-primary`；
- 普通 `SELECT` 返回 `rw-standby`；
- `UPDATE` 返回 `rw-primary`；
- `DELETE` 返回 `rw-primary`；
- 显式事务中先写后读返回 `rw-primary`；
- 每次 DML 后均等待并证明 Standby 已回放对应结果。

## 延迟演练

在维护窗口暂停 Standby WAL replay，经 Pgpool 写入一条小型探针：

- 初始普通 SELECT 命中 `rw-standby`；
- Pgpool 检测到回放延迟后，普通 SELECT 自动回退到 `rw-primary`；
- `SHOW POOL_NODES` 显示 Standby 有时间延迟且不再作为当前负载均衡节点；
- `finally` 恢复 WAL replay 后，`replay_lag_bytes=0`，普通 SELECT 再次命中 `rw-standby`。

## Standby 故障演练

在维护窗口用厂商 `pg_ctl` 停止 Standby：

- Pgpool 健康检查约 4 秒后将节点 1 标为 `down/down`；
- 普通 SELECT 与 DML 均退化到 `rw-primary`；
- Primary 仍保持 Primary，未执行任何 promote 或自动提升；
- 启动 Standby 后确认 `pg_stat_wal_receiver.status=streaming`；
- 使用 root-only `PCPPASSFILE` 显式执行 `pcp_attach_node`，节点恢复 `up/up`；
- 恢复后再次完整执行角色、复制、DML、SELECT、事务与监听验收，全部通过。

## 安全与恢复证据

- Primary 每次修改前均写入 `/var/backups/pg-readwrite-proxy-lab/primary-<时间>/`；
- 厂商工具遗留的 `hba/pg_hba_tmp.conf` 先备份再修复为 `postgres:postgres 0600`，全 PGDATA 可读扫描通过；
- 厂商初始 `host replication repl 0.0.0.0/0 md5` 已从 Primary 和复制后的 Standby 删除；
- Standby 原独立实例移动到 `/var/backups/pg-readwrite-proxy-lab/standby-pgdata-20260812-171430`，未删除；
- 首次基础备份中断后，安装器识别 root-only 状态文件并从安全中间态恢复，证明原数据目录保护与重跑逻辑有效；
- 业务账号和业务数据库均为既有对象，安装器只验证凭据，没有创建、改名或修改业务密码；
- 交付包不含 NebulaCM 厂商介质、PG_Safe_tool、授权材料、虚机文件或真实配置/凭据。
- 正式归档中的 16 个部署核心文件与实机成功安装及幂等重跑所用版本在统一 LF 后逐字一致；归档提取后全部 Shell 脚本通过 `bash -n`，三项二进制与三份对应源码通过 SHA256 清单校验；反向扫描确认本次部署生成的五项秘密值均未进入归档。

## 麒麟 V10 隔离兼容性探测

按照环境交接文件要求，在 `192.168.80.140` 上只解压载荷并执行 `file`、`ldd` 与版本启动检查，未安装文件、未创建服务、未修改正式三机：

- 三项二进制均确认为 aarch64；
- `sshpass` 的动态依赖可解析；
- Pgpool 缺少 `libssl.so.10`、`libcrypto.so.10`、`libnsl.so.1`；
- PostgreSQL 客户端缺少 `libreadline.so.6`、`libssl.so.10`、`libcrypto.so.10`。

因此当前 CentOS 7 离线包明确不支持麒麟 V10。安装器的平台检查会拒绝该系统；如以后需要支持麒麟，必须针对其 glibc/OpenSSL/readline/libnsl 基线单独构建、打包依赖并完成完整部署验收，不能复制本报告的 CentOS 7 结论。

## 已知生产边界

- 测试环境没有运行 firewalld，安装使用 `MANAGE_FIREWALL=no`；访问范围由 Pgpool `pool_hba.conf` 限制为配置的客户端 CIDR，生产还必须配置主机/网络防火墙。
- 当前为异步复制，不能把 Pgpool 的延迟阈值等同于零延迟一致性。
- 当前只有单 Pgpool，仍是入口单点；双 Pgpool、watchdog、VIP/负载均衡、fencing 与仲裁属于生产化阶段。
- CentOS 7 与 PostgreSQL 12 已结束上游常规维护，生产支持与安全补丁须由厂商合同和升级计划覆盖。
- 当前归档仅支持 CentOS 7 aarch64；麒麟 V10 隔离探测已按上述缺失依赖判定为不兼容。
