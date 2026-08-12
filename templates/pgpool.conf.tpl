# 由 pg-readwrite-proxy-lab 生成：PostgreSQL Streaming Replication + Pgpool-II

# 客户端入口
listen_addresses = '*'
port = {{PGPOOL_PORT}}
unix_socket_directories = '/var/run/pgpool'
pcp_listen_addresses = 'localhost'
pcp_port = {{PCP_PORT}}
pcp_socket_dir = '/var/run/pgpool'
pid_file_name = '/var/run/pgpool/pgpool.pid'

# 客户端认证
enable_pool_hba = on
pool_passwd = '{{PGPOOL_CONFIG_DIR}}/pool_passwd'
allow_clear_text_frontend_auth = off
authentication_timeout = 60

# 进程与连接池
process_management_mode = 'static'
num_init_children = {{NUM_INIT_CHILDREN}}
max_pool = {{MAX_POOL}}
reserved_connections = 1
child_life_time = 300
child_max_connections = 0
connection_life_time = {{CONNECTION_LIFE_TIME}}
client_idle_limit = 0
connection_cache = on

# 原生流复制模式
backend_clustering_mode = 'streaming_replication'

# backend 0：现有 Primary。权重 0 表示普通可负载均衡 SELECT 不主动分配给 Primary。
backend_hostname0 = '{{PRIMARY_HOST}}'
backend_port0 = {{PRIMARY_PORT}}
backend_weight0 = {{PRIMARY_READ_WEIGHT}}
backend_flag0 = 'DISALLOW_TO_FAILOVER'
backend_application_name0 = ''

# backend 1：Standby，承担普通 SELECT。
backend_hostname1 = '{{STANDBY_HOST}}'
backend_port1 = {{STANDBY_PORT}}
backend_weight1 = {{STANDBY_READ_WEIGHT}}
# Standby 故障时允许健康检查将其摘除，但没有提升命令，绝不会自动提升。
backend_flag1 = 'ALLOW_TO_FAILOVER'
backend_application_name1 = '{{STANDBY_APPLICATION_NAME}}'

# SQL 路由
load_balance_mode = on
statement_level_load_balance = on
disable_load_balance_on_write = '{{DISABLE_LOAD_BALANCE_ON_WRITE}}'
allow_sql_comments = off
read_only_function_list = 'current_setting,current_database,inet_server_addr,pg_is_in_recovery'
write_function_list = ''
delay_threshold_by_time = {{READ_LAG_THRESHOLD_SECONDS}}
prefer_lower_delay_standby = on

# 流复制状态检查
sr_check_period = {{SR_CHECK_PERIOD}}
sr_check_user = '{{MONITOR_USER}}'
sr_check_password = ''
sr_check_database = 'postgres'

# 后端健康检查
health_check_period = {{HEALTH_CHECK_PERIOD}}
health_check_timeout = {{HEALTH_CHECK_TIMEOUT}}
health_check_user = '{{MONITOR_USER}}'
health_check_password = ''
health_check_database = 'postgres'
health_check_max_retries = {{HEALTH_CHECK_MAX_RETRIES}}
health_check_retry_delay = {{HEALTH_CHECK_RETRY_DELAY}}
connect_timeout = {{CONNECT_TIMEOUT_MS}}

# 基线只退化不可用节点，不执行 Standby 提升；避免在无 fencing/仲裁时产生双主。
failover_command = ''
follow_primary_command = ''
failback_command = ''
failover_on_backend_error = off
failover_on_backend_shutdown = off
auto_failback = off
detach_false_primary = off
search_primary_node_timeout = 10
use_watchdog = off

# 初期验证日志；稳定后可关闭逐节点 SQL 日志。
log_destination = 'stderr'
logging_collector = off
log_connections = on
log_disconnections = off
log_hostname = off
log_statement = off
log_per_node_statement = {{LOG_PER_NODE_STATEMENT}}
log_min_messages = warning
client_min_messages = notice

# TLS 在生产证书准备后启用，见 docs/production-notes.md。
ssl = off
