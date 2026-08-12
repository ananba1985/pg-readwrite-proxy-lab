# 由 pg-readwrite-proxy-lab 管理。不要直接编辑生成文件。
hot_standby = on
listen_addresses = '{{STANDBY_LISTEN_ADDRESSES}}'
port = {{STANDBY_PORT}}
cluster_name = 'rw-standby'
recovery_target_timeline = 'latest'
