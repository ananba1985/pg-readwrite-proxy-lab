# 麒麟 V10 一键部署实机验收报告

验收日期：2026-08-12 至 2026-08-13

本报告不记录任何密码、私钥或厂商授权信息。测试使用项目生成的完整候选归档，在独立麒麟 Pgpool 节点上执行 `sudo bash install.sh`；数据库节点使用既有 NebulaCM PostgreSQL 12.0，未携带或替换厂商服务端运行时。

## 验收拓扑

| 角色 | 地址 | 系统与架构 | 结果 |
| --- | --- | --- | --- |
| Primary | `192.168.80.110:5432` | CentOS Linux 7.9 AltArch aarch64 | `rw-primary`，非恢复态 |
| Standby | `192.168.80.120:5432` | CentOS Linux 7.9 AltArch aarch64 | `rw-standby`，恢复态 |
| Pgpool-II | `192.168.80.140:9999` | Kylin Linux Advanced Server V10 (Halberd) aarch64，glibc 2.28 | Pgpool-II 4.7.2，systemd active/enabled |

PCP 只监听 localhost `9898`。Pgpool 节点只有 PostgreSQL 12.0 客户端，没有 `postgres` 服务端或 PGDATA；firewalld 仅按配置的客户端 CIDR 放行 TCP/9999。

## 离线载荷

四项载荷均在麒麟 V10 aarch64 上原生构建并通过 SHA256、试解压、版本和全部可执行文件 `ldd` 闭包检查：

| 载荷 | SHA256 |
| --- | --- |
| Pgpool-II 4.7.2 | `b80c79b8e6537a14a6adc8ab4ae58baa40a2e027c8fc99a3589510462425dbea` |
| PostgreSQL 12.0 client | `1314901d8b0de906fcc47c7784913fd347d07a3b563475f8eae4e16310ba8667` |
| 麒麟私有非 glibc 运行库 | `6d00411d0098b2bab0c3f9e3a0d5d009907189eb2b0e3a743edd3063bce9a257` |
| sshpass 1.10 | `84bcff17fc7e48d0a8552c985818e17e485f95a66b3c50c4eedde6bcbdc96ffd` |

私有运行库不包含 glibc、动态加载器或 PostgreSQL/Pgpool 项目自身重复库，并随包保存对应许可证。三份上游源码由 `packages/SOURCES.sha256` 固定。

## 部署前门禁

完整候选包完成以下实机验证：

- 收集全部输入后才启动检查；三节点均返回 `READINESS_RESULT=READY` 后才出现 `APPLY` 提示。
- 在已有集群状态输入非 `APPLY`，安装器退出并报告三台服务器均未执行部署变更；检查前后 Primary、Standby、Pgpool 服务/配置/监听/防火墙指纹完全一致。
- Pgpool 有一个真实前端客户端时，门禁在代理节点失败，未进入部署阶段。
- 从 Pgpool 主机绕过代理直接连接 Primary 时，即使来源 IP 与 Pgpool 相同，Primary 仍按精确后端 PID 识别为非受信任连接并失败关闭。
- 已有 Pgpool 的空闲后端连接不会造成误报；`SHOW POOL_POOLS` 证明的 PID 才会被数据库侧豁免。
- 用户输入 `APPLY` 后、停止既有 Pgpool 前再次检查前端连接；停止后、任何配置落盘前再次证明两台数据库的普通客户端连接归零；Primary/Standby 在各自实际改动前还保留本机连接复核。

## 初次部署与幂等更新

初次部署成功完成 Primary 参数/HBA 备份、复制/监控账号、物理复制槽、Standby 基础备份与 Pgpool 安装。原独立 Standby 数据目录移动到：

```text
/var/backups/pg-readwrite-proxy-lab/standby-pgdata-20260812-205036
```

它未被删除。随后多次使用完整一键入口执行幂等更新，最后一次完整 `APPLY` 在 2026-08-13 06:14（测试机时区）完成：

- Primary 已满足需重启参数，本次没有重复重启；配置仍先备份到 `/var/backups/pg-readwrite-proxy-lab/primary-<时间>/`。
- Standby 识别为同一 system identifier 的既有恢复节点，不移动或覆盖 PGDATA，只刷新受管配置和复制凭据。
- 既有 Pgpool 在二次连接复核通过后受控停止并恢复；新配置、服务、认证和防火墙均生效。
- 解压目录中的旧运行配置在落盘新配置前备份到 `/var/backups/pg-readwrite-proxy-lab/installer-config-<时间>/`。

## 复制与 SQL 路由

最终自动验收结果：

| 检查项 | 结果 |
| --- | --- |
| Primary | `rw-primary`，`pg_is_in_recovery()=false` |
| Standby | `rw-standby`，`pg_is_in_recovery()=true` |
| 复制 | `rw_standby|streaming|async` |
| 最终 replay lag | `0` bytes |
| Pgpool backend 0 | `192.168.80.110:5432`，`up/up`，`primary`，读权重 0 |
| Pgpool backend 1 | `192.168.80.120:5432`，`up/up`，`standby`，读权重 1 |
| `INSERT` / `UPDATE` / `DELETE` | 全部返回 `rw-primary` |
| 普通 `SELECT` | 返回 `rw-standby` |
| 显式事务内写后读 | 返回 `rw-primary` |
| 外部入口 | 从 Primary 作为远端客户端访问 `.140:9999` 成功，返回既有业务用户、库和 `rw-standby` |

路由测试只使用 `business.rw_probe` 隔离探针表，测试数据已自动清理。业务用户和数据库为既有对象，安装器没有创建、改名或修改其密码。

## 故障与延迟边界

上一轮同一 PostgreSQL/Pgpool 配置基线已经完成 Standby 停机退化和 WAL replay 暂停延迟演练：Standby 被摘除或延迟超过阈值后，普通读退化到 Primary；恢复回放/显式挂接后重新达到 streaming，并且全程没有 promote。此次麒麟改造只替换 Pgpool 节点操作系统和离线运行时，未再次执行会中断 Standby 或暂停回放的演练。生产必须在单独批准的维护窗口按 `docs/failure-and-delay-tests.md` 复验。

## 交付检查与已知边界

- 最终归档名为 `pg-readwrite-proxy-offline-20260812-kylin-v10-aarch64.tar.gz`，SHA256 以同目录外置 `.sha256` 文件为准。
- 最终白名单打包链路另行完成三节点严格只读门禁，并以非 `APPLY` 输入退出；三节点均返回 `READY`，没有执行部署变更。
- 归档只包含四项清单载荷、三份固定源码、项目脚本/模板/文档；不含虚拟机、旧 CentOS 载荷、NebulaCM 厂商介质、PG_Safe_tool、授权材料或真实运行配置。
- 所有 Shell 脚本通过 `bash -n`；载荷和源码清单在打包前后均校验通过；真实秘密值反向扫描不得命中归档提取内容。
- 当前是异步复制与单 Pgpool，不等于零数据丢失或入口高可用。TLS、双 Pgpool/VIP、fencing/仲裁、备份恢复、监控、RPO/RTO 和生命周期治理见 `docs/production-notes.md`。
