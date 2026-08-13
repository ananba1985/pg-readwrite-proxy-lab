# 项目协作约定

## 项目边界

- 本项目只服务于两台麒麟 V10 aarch64 数据库服务器与一台麒麟 V10 aarch64 Pgpool-II 服务器上的 PostgreSQL Streaming Replication + Pgpool-II 读写分离。
- 服务器角色固定为：现有 Primary、新建 Standby、独立 Pgpool-II。
- 不引入业务应用，不使用容器编排，不把代理服务器当作数据库服务器。
- 基线不自动提升 Standby。任何自动故障转移必须先补齐 fencing、仲裁、RPO/RTO 与回切方案。

## 安全约束

- 不提交 `config/cluster.env`、`config/secrets.env`、`config/pool-users.txt`。
- 物理隔离环境的一键入口允许按用户约定直接传入密码参数；脚本不得主动回显密码，也不得写入普通日志或 Git 历史。
- 修改现有 Primary 前先备份配置；Primary 重启必须经过维护窗口确认。
- 数据库连接非零时只能通过交互菜单取得本次运行的强制中断授权；实际停机前必须重新统计并提示，授权不得持久化。
- 初始化 Standby 时，非空数据目录默认拒绝处理；只有显式确认后才允许移动到备份目录，绝不直接删除。
- 对外端口只允许配置的客户端 CIDR；PCP 仅监听本机。

## 验证约定

- 先跑只读预检，再按 Primary、Standby、Pgpool-II 的顺序部署。
- 必须分别证明：Primary 非恢复态、Standby 恢复态、复制状态为 streaming、Pgpool 节点识别正确、DML 命中 Primary、普通 SELECT 命中 Standby。
- 延迟与故障测试不得在未确认维护窗口时执行。
