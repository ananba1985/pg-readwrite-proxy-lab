# Standby 的物理复制连接
host    replication    {{REPLICATION_USER}}    {{STANDBY_ADDRESS_CIDR}}    md5
# Standby 初始化脚本用于检查复制槽和主库状态
host    postgres       {{REPLICATION_USER}}    {{STANDBY_ADDRESS_CIDR}}    md5
# Pgpool-II 到两个 PostgreSQL 后端的连接。
# md5 规则对旧 MD5 账号兼容；当角色密码是 SCRAM verifier 时 PostgreSQL 会自动使用 SCRAM。
host    postgres       {{MONITOR_USER}}        {{PGPOOL_ADDRESS_CIDR}}     md5
# 现有业务账号从独立 Pgpool 节点访问现有业务库；脚本不创建账号/数据库、不修改其密码。
host    {{BUSINESS_DATABASE}} {{BUSINESS_USER}} {{PGPOOL_ADDRESS_CIDR}}     md5
