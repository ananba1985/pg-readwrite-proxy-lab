# 由 pg-readwrite-proxy-lab 管理。不要直接编辑生成文件。
wal_level = 'replica'
max_wal_senders = {{MAX_WAL_SENDERS}}
max_replication_slots = {{MAX_REPLICATION_SLOTS}}
wal_keep_segments = {{WAL_KEEP_SEGMENTS}}
wal_sender_timeout = '60s'
hot_standby = on
listen_addresses = '{{PRIMARY_LISTEN_ADDRESSES}}'
cluster_name = 'rw-primary'
