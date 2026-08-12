#!/usr/bin/env bash

# 维护窗口演练入口说明：服务停止/启动必须由运维在 Standby 使用 pg_ctl 执行。
# 本文件只提供可审计命令框架，不会自动提升任何节点。
set -Eeuo pipefail
cat <<'EOF'
1. Standby: runuser -u postgres -- /opt/pgsql12/bin/pg_ctl -w -D /pgsql/12/data -m fast stop
2. Pgpool: 等待 health_check_period * (max_retries + 1)，SHOW POOL_NODES 应显示 node 1 down。
3. 普通 SELECT 应退化到 rw-primary，DML 仍到 rw-primary；不得执行 promote。
4. Standby: runuser -u postgres -- /opt/pgsql12/bin/pg_ctl -w -D /pgsql/12/data -l /pgsql/12/data/log/pg-rw-proxy-startup.log start
5. 确认 wal receiver=streaming；使用 pcp_attach_node -n 1 或重启 Pgpool 重新挂接。
6. 最终必须再次执行 scripts/40-verify-cluster.sh。
EOF
