# Standby 的物理复制连接
host    replication    {{REPLICATION_USER}}    {{STANDBY_ADDRESS_CIDR}}    scram-sha-256
# Standby 初始化脚本用于检查复制槽和主库状态
host    postgres       {{REPLICATION_USER}}    {{STANDBY_ADDRESS_CIDR}}    scram-sha-256
# Pgpool-II 到两个 PostgreSQL 后端的连接。
# md5 规则对旧 MD5 账号兼容；当角色密码是 SCRAM verifier 时 PostgreSQL 会自动使用 SCRAM。
host    all            all                     {{PGPOOL_ADDRESS_CIDR}}     md5
