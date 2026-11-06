# 源准备：用于 Database Migration Service 的 Compute Engine 上的 MySQL 8.0

[English](README.md) | **简体中文**

本目录中的文件用于在对 Database Migration Service (DMS) 迁移作业运行 `verify` 和 `start` 之前，准备并检查自管理的源 MySQL 8.0。它们实现了[运行手册第 2 节](../../docs/gce_mysql80_to_cloudsql_dms_migration_runbook.zh-CN.md#2-阶段-1源-mysql-80-预检验证)的内容。

| 文件 | 用途 | 运行位置 |
| :--- | :--- | :--- |
| `01_mysqld_dms_source.cnf` | `my.cnf` 附加配置文件：`server_id`、`bind_address`、ROW 格式 binlog、`binlog_row_image=FULL`、GTID、binlog 保留时间 | 源虚拟机（需要重启） |
| `02_enable_gtid_online.sql` | 无需重启，逐步在线启用 GTID | 源虚拟机，交互式 `mysql` 会话 |
| `03_create_dms_user.sql` | `dms_migration@'%'`（DMS）和 `xtrabackup@'localhost'`（仅场景 2 `PHYSICAL`） | 源虚拟机，管理员账号 |
| `preflight_check.sh` | 只读检查，输出 PASS / WARN / FAIL 表格 | 源虚拟机，或任何可通过 3306 端口访问源的主机 |

---

## 1. 操作顺序

1. 应用 `01_mysqld_dms_source.cnf` 并重启 mysqld；**或者**，如果 binlog 已开启且无法重启，请逐步运行 `02_enable_gtid_online.sql`。
2. 确定 binlog 保留时间：`binlog_expire_logs_seconds` 必须至少等于初始数据的总耗时（转储 + 上传 + 恢复）加上缓冲时间，并且不得少于 7 天（`604800`）。如果在 CDC 开始之前，初始数据 GTID 位置之后的 binlog 已被清除，作业将失败，您必须重新制作初始数据。
3. 使用 `03_create_dms_user.sql` 创建账号。
4. 运行 `preflight_check.sh`（或 `make preflight`），直到没有 FAIL。逐一检查每个 WARN。
5. 场景 2：制作初始数据后，使用 `--backup-gtid` 再次运行检查。

---

## 2. 配置 Binlog 和 GTID

在维护时段内复制附加配置文件并重启 mysqld。Ubuntu 和 Debian 软件包会在 `mysqld.cnf` 中设置 `bind-address = 127.0.0.1`；附加配置文件设置 `bind_address = 0.0.0.0`，并且其文件名排序必须在 `mysqld.cnf` 之后（因此使用 `zz-` 前缀）。请使用 VPC 防火墙规则将 TCP 3306 端口限制为仅允许 PSC 网络连接 (Network Attachment) 子网访问：

```bash
sudo cp scripts/source-prep/01_mysqld_dms_source.cnf /etc/mysql/mysql.conf.d/zz-dms-source.cnf
sudo systemctl restart mysql
```

如果不重启，请按照[在线启用 GTID 事务](https://dev.mysql.com/doc/refman/8.0/en/replication-mode-change-online-enable-gtids.html)使用 `02_enable_gtid_online.sql`。请在交互式会话中一次执行一个步骤；不要将整个文件通过管道传给 `mysql`：

1. `SET PERSIST enforce_gtid_consistency = WARN`，然后在正常负载下观察错误日志，修复所有 GTID 不安全的语句。
2. `SET PERSIST enforce_gtid_consistency = ON`。
3. `SET PERSIST gtid_mode = OFF_PERMISSIVE`。
4. `SET PERSIST gtid_mode = ON_PERMISSIVE`。
5. 等待 `SHOW GLOBAL STATUS LIKE 'Ongoing_anonymous_transaction_count'` 返回 `0`。
6. `SET PERSIST gtid_mode = ON`。

> [!IMPORTANT]
> DMS 仅接受 `gtid_mode` 为 `ON` 或 `OFF`。停留在 `OFF_PERMISSIVE` 或 `ON_PERMISSIVE` 状态的源会导致 `verify` 失败，`preflight_check.sh` 也会将其报告为 FAIL。

---

## 3. 创建迁移账号

将密码设置为会话变量，使其不会出现在文件或 shell 历史记录中，然后执行该文件：

```sql
-- mysql --defaults-extra-file=/root/.mysql-admin.cnf
SET @dms_password = 'REPLACE_ME_MAX_32_CHARS';
SET @xtrabackup_password = 'REPLACE_WITH_SECURE_PASSWORD';  -- Scenario 2 PHYSICAL only
SOURCE scripts/source-prep/03_create_dms_user.sql
```

该文件授予场景 1 的权限：DMS 必需的权限集（`REPLICATION SLAVE`、`REPLICATION CLIENT`、`EXECUTE`、`SELECT`、`SHOW VIEW`、`TRIGGER`、`RELOAD`），以及推荐的额外权限 `EVENT` 和 `LOCK TABLES`（用于事件 / 并行转储）。对于场景 2，请先注释掉场景 1 的 `GRANT`，并取消注释场景 2 的 `GRANT`。仅当设置了 `@xtrabackup_password` 时才会创建 `xtrabackup` 用户。不要向 `dms_migration` 授予 `BACKUP_ADMIN`，也不需要执行 `FLUSH PRIVILEGES`。

---

## 4. 运行预检

为管理员账号创建 MySQL 选项文件（检查会读取 `mysql.user`、`SHOW GRANTS` 和 `information_schema`）。脚本只从该文件读取凭据，会拒绝命令行中的密码，也会拒绝权限不是 `0600` 或 `0400` 的文件：

```bash
cat > ~/.my-dms.cnf <<'EOF'
[client]
user=root
password=REPLACE_ME
EOF
chmod 600 ~/.my-dms.cnf
```

在源虚拟机上运行检查：

```bash
# From the repository root
make preflight MYSQL_DEFAULTS_FILE=~/.my-dms.cnf SCENARIO=1 DMS_USER=dms_migration SEED_HOURS=24

# Or directly
MYSQL_DEFAULTS_FILE=~/.my-dms.cnf ./scripts/source-prep/preflight_check.sh \
  --scenario 1 --dms-user dms_migration --seed-hours 24

# Remote source over TCP, or a local Unix socket
MYSQL_DEFAULTS_FILE=~/.my-dms.cnf ./scripts/source-prep/preflight_check.sh --host 10.10.0.10 --port 3306
MYSQL_DEFAULTS_FILE=~/.my-dms.cnf ./scripts/source-prep/preflight_check.sh --socket /var/run/mysqld/mysqld.sock

# Scenario 2: confirm that no binlog after the seed was purged
make preflight MYSQL_DEFAULTS_FILE=~/.my-dms.cnf SCENARIO=2 \
  BACKUP_GTID='3E11FA47-71CA-11E1-9E33-C80AA9429562:1-5000'
```

对于 mysqldump 初始数据，GTID 集合是转储文件开头 `SET @@GLOBAL.GTID_PURGED` 的值。对于 XtraBackup 初始数据，它位于 `xtrabackup_binlog_info` 中。

| 选项 | `make` 变量 | 默认值 | 含义 |
| :--- | :--- | :--- | :--- |
| `--defaults-extra-file F` | `MYSQL_DEFAULTS_FILE` | `$MYSQL_DEFAULTS_FILE`（`make`：`~/.my-dms.cnf`） | 包含 `[client]` 用户名和密码的选项文件，权限为 `0600` 或 `0400` |
| `--host`, `--port`, `--socket` | `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_SOCKET` | 客户端默认值 | 到源的连接 |
| `--scenario 1\|2` | `SCENARIO` | `1` | DMS 用户应具备的权限集 |
| `--dms-user U` | `DMS_USER` | `dms_migration` | DMS 用户，主机为 `'%'` |
| `--seed-hours N` | `SEED_HOURS` | `24` | 用于保留时间检查的初始数据总耗时（转储 + 上传 + 恢复） |
| `--backup-gtid SET` | `BACKUP_GTID` | 未设置 | 初始数据的 GTID 集合；除非 `GTID_SUBSET(@@GLOBAL.gtid_purged, SET) = 1`，否则为 FAIL |

退出代码：`0` 表示没有 FAIL（允许 WARN），`1` 表示至少有一个 FAIL，`2` 表示用法、选项文件或连接错误。

### 4.1 检查项

| 检查项 | FAIL 条件 | WARN 条件 |
| :--- | :--- | :--- |
| `version` | — | 服务器不是 MySQL 8.0 |
| `server_id` | `server_id` 为 `0` | — |
| `log_bin` | 二进制日志未开启 | — |
| `bind_address` | — | 仅环回地址（`127.0.0.1`、`localhost`、`::1`）：DMS 无法通过 TCP 连接 |
| `binlog_format` | 不是 `ROW` | — |
| `binlog_row_image` | 不是 `FULL` | — |
| `gtid_mode` | 不是 `ON`（包括 `OFF_PERMISSIVE` 和 `ON_PERMISSIVE`） | — |
| `enforce_gtid_consistency` | 不是 `ON` | — |
| `binlog_retention` | 保留时间 < 初始数据耗时（`binlog_expire_logs_seconds`；当其为 `0` 时使用 `expire_logs_days` × 86400） | < 初始数据耗时 + 24 小时缓冲，或 < 7 天 |
| `dms_user_grants` | 用户 `'<dms-user>'@'%'` 不存在、缺少场景必需的权限，或存在 `BACKUP_ADMIN` | 授予了 `ALL PRIVILEGES`，或缺少场景 1 推荐的额外权限 `EVENT` / `LOCK TABLES` |
| `non_innodb_tables` | — | 存在非 InnoDB 的用户表 |
| `primary_keys` | — | 存在没有主键或唯一 `NOT NULL` 键的用户表 |
| `definers` | — | 事件、例程、触发器或视图的 DEFINER 不存在或为 `root@localhost` |
| `system_schema_refs` | — | 视图、例程、触发器或事件引用了 `mysql`、`sys`、`performance_schema` 或 `information_schema` |
| `lower_case_table_names` | 值不是 `0` 或 `1` | 值为 `1`：请在创建实例之前设置 Terraform `cloudsql_lower_case_table_names = 1`（之后无法更改） |
| `character_set/collation` | — | 不是 `utf8mb4` / `utf8mb4_0900_ai_ci`：请设置对应的 Cloud SQL 标志 |
| `sql_mode` | — | 与 MySQL 8.0 默认值不同：请设置对应的 Cloud SQL 标志 |
| `time_zone` | — | 不是 UTC：请设置对应的 Cloud SQL 标志 `default_time_zone` |
| `innodb_page_size` | 不是 `16384` | — |
| `user_db_size` | — | —（仅报告；请与运行手册中的决策矩阵对照） |
| `backup_gtid` | `GTID_SUBSET(@@GLOBAL.gtid_purged, '<set>')` 不为 `1` | — |

脚本只在只读会话中运行 `SELECT` 和 `SHOW` 语句。完整列表（表、DEFINER、对象）会在表格之后的 `Details:` 部分输出。

---

## 5. 监控复制延迟并验证数据

`start` 之后，`make lag` 会读取该作业的 `datamigration.googleapis.com/migration_job/max_replica_sec_lag`。如果该指标没有返回数据且设置了 `CLOUDSQL_INSTANCE`，它会回退到目标实例的 `cloudsql.googleapis.com/database/replication/replica_lag`（`database_id = PROJECT_ID:CLOUDSQL_INSTANCE`），并输出实际使用的指标。在测试中，CDC 开始后的最初几分钟内 DMS 指标没有返回数据，而 Cloud SQL 指标有数据。指标可能需要几分钟才会出现。该目标使用 `curl` 调用 Cloud Monitoring API（`projects.timeSeries.list`），并通过标准输入而不是命令行传递 `gcloud` 访问令牌：

```bash
make lag PROJECT_ID=my-gcp-project-01 REGION=europe-west2 JOB_ID=gce-live-mysql80-cdc LAG_MINUTES=30

# With the Cloud SQL replica lag fallback
make lag PROJECT_ID=my-gcp-project-01 REGION=europe-west2 JOB_ID=gce-live-mysql80-cdc \
  CLOUDSQL_INSTANCE="$(terraform -chdir=templates/01-live-migration-gce-cdc output -raw cloudsql_instance_name)"
```

您还可以选择使用开源的 [Data Validation Tool](https://github.com/GoogleCloudPlatform/professional-services-data-validator) (DVT) 比较源与 Cloud SQL 目标之间的行数。这些模板并不依赖 DVT。请在可以同时访问两个数据库的主机上的虚拟环境中安装它，并将数据库密码存储在 Secret Manager 中，而不是写在命令行上。使用 `--secret-manager-type GCP` 时，`--password` 是 Secret 名称；主机、端口和用户名是字面值（如果不存在同名 Secret，DVT 会使用字面值）：

```bash
python3 -m venv ~/dvt && . ~/dvt/bin/activate
pip install google-pso-data-validator

# --password is a Secret Manager secret name; --host, --port and --user are literal values
data-validation connections add --secret-manager-type GCP --secret-manager-project-id my-gcp-project-01 \
  --connection-name dms_src MySQL --host 10.10.0.10 --port 3306 --user dvt_reader --password dvt-src-password
data-validation connections add --secret-manager-type GCP --secret-manager-project-id my-gcp-project-01 \
  --connection-name dms_tgt MySQL --host "<psc_endpoint_dns_name>" --port 3306 --user dvt_reader --password dvt-tgt-password

make validate-data DVT_SOURCE_CONN=dms_src DVT_TARGET_CONN=dms_tgt DVT_TABLES='app_db1.orders,app_db1.customers'
```

在 CDC 期间，正在写入的表的行数可能不一致；请在切换时将源设为只读之后再进行最终比较。
