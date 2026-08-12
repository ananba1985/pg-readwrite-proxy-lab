# 麒麟 V10 Pgpool 离线载荷

`payload/` 保存私有离线交付所需的 ARM64 二进制载荷，`sources/` 保存允许再分发的对应源码；二者和 `dist/` 默认不进入 Git。构建和打包前必须校验：

```bash
cd packages
sha256sum -c MANIFEST.sha256
sha256sum -c SOURCES.sha256
```

## 数据库介质边界

Primary 和 Standby 的数据库运行时必须预先由厂商流程安装，项目不会携带、覆盖或替换 `/opt/pgsql12`。厂商介质、授权程序、授权信息和 PG_Safe_tool 不进入公开仓库或本项目离线归档。

Pgpool 节点只携带从 PostgreSQL 12.0 官方源码构建的客户端，不含 `postgres` 服务端，不初始化 PGDATA。

## 四项二进制载荷

- `pgpool-II-4.7.2-pg12.0-aarch64-kylin-v10.tar.gz`：安装到 `/opt/pgpool-II-4.7.2`。
- `postgresql-client-12.0-aarch64-kylin-v10.tar.gz`：安装到 `/opt/pgpool-client-12.0`，不含服务端。
- `pgpool-runtime-kylin-v10-aarch64.tar.gz`：安装到 `/opt/pgpool-runtime-kylin-v10`，只包含 `ldd` 审计得到的非 glibc 私有依赖及其许可证；不复制 glibc 或动态加载器。
- `sshpass-1.10-aarch64-kylin-v10.tar.gz`：仅在安装期间临时使用，不注册常驻服务。

`MANIFEST.sha256` 只列这四项最终载荷；`SOURCES.sha256` 固定 Pgpool-II、PostgreSQL 和 sshpass 三份源码。打包器按清单逐项复制，不夹带目录中的旧载荷。

麒麟原生构建入口为 `build-kylin-v10-payloads.sh`。旧的 `build-arm64-payloads.sh` 仅保留历史 CentOS 7 载荷的可追溯构建方法，不属于当前交付入口。
