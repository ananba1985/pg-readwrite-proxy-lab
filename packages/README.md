# NebulaCM 12.0 环境的离线载荷

`payload/` 保存项目私有离线交付所需的 ARM64 二进制载荷，`sources/` 保存允许再分发的对应源码。两者及 `dist/` 默认不提交公开 Git 仓库。构建和打包前必须按实际清单执行 SHA256 校验：

```bash
cd packages
sha256sum -c MANIFEST.sha256
sha256sum -c SOURCES.sha256
```

## 数据库介质边界

Primary 和 Standby 目标机的唯一数据库介质是：

```text
NebulaCM_Dbn_PostgreSQL-install-runtime-12.0-ky10-aarch64-20241212.tar.gz
```

数据库必须使用介质自带的 `install.sh`、每台服务器对应的授权信息和配套 `PG_Safe_tool` 安装维护。厂商介质、授权程序、授权申请信息、授权码和维护工具不进入公开仓库，也不由公开离线包重新分发。

项目部署包不得携带另一套数据库服务器运行时，不得覆盖现有 `/opt/pgsql12` 或绕过厂商安装流程。Pgpool 节点使用从 PostgreSQL 12.0 官方源码独立构建的客户端文件，安装到 `/opt/pgpool-client-12.0`；它不包含 `postgres` 服务端。Pgpool 节点不得初始化 PGDATA 或运行数据库服务。

## 项目载荷

- Pgpool-II 4.7.2 ARM64，安装前缀 `/opt/pgpool-II-4.7.2`；固定链接到 `/opt/pgpool-client-12.0/lib/libpq.so.5`。
- sshpass 1.10 ARM64，仅在安装期通过 root 密码编排 Primary/Standby，部署后不作为常驻服务。
- 项目脚本、配置模板、验收 SQL、故障演练和生产注意事项。
- `MANIFEST.sha256` 完整性清单，以及允许再分发组件的许可文本。

`MANIFEST.sha256` 只列出三项最终二进制；`SOURCES.sha256` 固定三份对应源码。打包器按清单逐项复制，不会把目录中的旧载荷夹带进交付包。构建步骤见 `build-arm64-payloads.sh`，最终打包入口见 `scripts/90-package-offline.sh`。
