# 运维手册：通过 Cloud DMS 将 GCE 自管理 MySQL 8.0 迁移至 Cloud SQL（8.0 / 8.4）

[English](gce_mysql80_to_cloudsql_dms_migration_runbook.md) | **简体中文**

> [!IMPORTANT]
> **目标 MySQL 版本策略（`MYSQL_8_0` 与 `MYSQL_8_4` LTS）**
> Google Cloud Database Migration Service (DMS) 支持从 **MySQL 8.0** 迁移至 **Cloud SQL for MySQL 8.0 (`MYSQL_8_0`)** 或 **Cloud SQL for MySQL 8.4 LTS (`MYSQL_8_4`)**。
> MySQL 与 Cloud DMS **不支持跨越 LTS 主版本**（例如在单次 DMS 迁移中直接从 `8.0` 迁移至 `9.7`）。如未来需要采用 MySQL `9.x`，请先迁移至 `MYSQL_8_4`（或先迁移至 `MYSQL_8_0`，再就地升级至 `8.4`），提升实例后，再执行受控的提升后主版本升级（`8.0 -> 8.4 -> 9.x`）。

---

## 1. 迁移决策矩阵：场景 1 与场景 2

| 评估标准 | 场景 1：在线迁移 + 持续 CDC（`01-live-migration-gce-cdc`） | 场景 2：GCS 中的备份 + 持续 CDC（`02-backup-migration-gcs-cdc`） |
| :--- | :--- | :--- |
| **数据库规模** | 小型至中型（`< 500 GB`） | 大型至数 TB 级（`500 GB – 15+ TB`） |
| **初始数据填充机制** | 由 DMS 管理、直接从 GCE MySQL 8.0 执行的并行逻辑转储（`dump_type = "LOGICAL"`，`dump_parallel_level = "MAX"`） | 通过 `dump_path` 使用预先暂存在 GCS 中的物理备份（`Percona XtraBackup`，`dump_type = "PHYSICAL"`）或逻辑转储（`mysqldump`，`dump_type = "LOGICAL"`） |
| **对源 GCE 主实例的影响** | 初始并行转储期间存在中等程度的读 I/O 与 CPU 开销 | 几乎无影响（通过 `xtrabackup` 进行热物理流式备份，或从 GCE 只读副本获取） |
| **持续复制** | 基于 GTID 的持续 Binlog CDC（`type = "CONTINUOUS"`） | 基于 GTID 的持续 Binlog CDC（`type = "CONTINUOUS"`），自动从备份的 GTID 坐标处恢复 |
| **切换停机时间** | 近零（最终提升期间仅需数分钟） | 近零（最终提升期间仅需数分钟） |

---

## 2. 阶段 1：源 GCE MySQL 8.0 预检验证

在启动场景 1 或场景 2 之前，请在源端自管理 GCE MySQL 8.0 实例（`/etc/mysql/mysql.conf.d/mysqld.cnf` 或 `/etc/my.cnf`）上验证以下必需参数：

### 2.1 GTID 与 Binlog CDC 必需的 `my.cnf` 参数

```ini
[mysqld]
server_id                  = 1001
log_bin                    = mysql-bin
binlog_format              = ROW
binlog_row_image           = FULL
gtid_mode                  = ON
enforce_gtid_consistency   = ON
binlog_expire_logs_seconds = 604800   # Retain binlogs for at least 7 days (604,800s) during initial seeding
```

在 GCE MySQL 8.0 实例上验证当前运行时的参数值：

```sql
SHOW GLOBAL VARIABLES WHERE Variable_name IN (
  'server_id',
  'log_bin',
  'binlog_format',
  'binlog_row_image',
  'gtid_mode',
  'enforce_gtid_consistency',
  'binlog_expire_logs_seconds'
);
```

### 2.2 创建专用的 DMS 复制与迁移用户

以 `root` 身份连接到 GCE MySQL 8.0 源实例，并创建迁移用户：

```sql
CREATE USER IF NOT EXISTS 'dms_repl_user'@'%' IDENTIFIED BY 'REPLACE_WITH_SECURE_PASSWORD';

-- Required privileges for initial logical dump and continuous GTID Binlog CDC
GRANT REPLICATION SLAVE, REPLICATION CLIENT, SELECT, SHOW VIEW, TRIGGER, EVENT
  ON *.* TO 'dms_repl_user'@'%';

-- Additional privileges if using Percona XtraBackup 8.0 on the source GCE VM
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, PERFORMANCE_SCHEMA.*
  ON *.* TO 'dms_repl_user'@'%';

FLUSH PRIVILEGES;
```

---

## 3. 阶段 2：Private Service Connect (PSC) 与出站 Network Attachment 架构

两个模板均默认使用 **Private Service Connect（`connectivity_type = "PSC"`，`destination_mode = "EXISTING_CLOUDSQL"`）**，以规避 VPC 对等互连的传递性限制：

1. **Cloud SQL 纯 PSC + 出站 Network Attachment（`network_attachment_uri`）**：
   - `cloudsql-mysql-destination` 模块会配置 `psc_enabled = true`（同时 `ipv4_enabled = false`），填充 `allowed_consumer_projects`，并将 `psc_config.network_attachment_uri` 绑定到 Compute Engine Network Attachment，使目标 Cloud SQL 实例能够直接与您的 VPC 子网建立私有出站复制连接。
2. **Compute Engine Network Attachment**：
   - `networking-psc` 模块会在您的 GCE 子网中预配 `google_compute_network_attachment`。未指定 `dms_tenant_project_id` 时，默认使用 `ACCEPT_AUTOMATIC`；指定 `dms_tenant_project_id` 时，则强制使用 `ACCEPT_MANUAL`，并将 `producer_accept_lists` 限制为您的项目和指定的租户项目。
3. **自动降级目标实例（`demote-destination`）**：
   - 当 `destination_mode = "EXISTING_CLOUDSQL"` 时，`dms-migration-job` 模块会创建迁移作业并自动运行 `gcloud database-migration migration-jobs demote-destination`，使独立的 Cloud SQL 实例为 `verify` 和 `start` 做好准备。

---

## 4. 阶段 3：执行迁移

### 方案 A：场景 1 — 在线迁移 + 持续 CDC（`templates/01-live-migration-gce-cdc`）

1. **部署 Terraform 基础设施**：
   ```bash
   cd templates/01-live-migration-gce-cdc
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your project_id, VPC, GCE IP, and credentials
   terraform init
   terraform validate
   terraform apply
   ```
2. **运行预检验证**：
   ```bash
   gcloud database-migration migration-jobs verify gce-live-mysql80-cdc \
     --region=asia-southeast1
   ```
3. **启动在线转储 + 持续 CDC**：
   ```bash
   gcloud database-migration migration-jobs start gce-live-mysql80-cdc \
     --region=asia-southeast1
   ```

---

### 方案 B：场景 2 — GCS 中的备份 + 持续 CDC（`templates/02-backup-migration-gcs-cdc`）

1. **部署 Terraform 基础设施（GCS 暂存存储桶 + Cloud SQL + DMS 作业）**：
   ```bash
   cd templates/02-backup-migration-gcs-cdc
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars (choose dump_type = "PHYSICAL" for XtraBackup or "LOGICAL" for mysqldump)
   terraform init
   terraform validate
   terraform apply
   ```
2. **将非阻塞备份从 GCE MySQL 8.0 流式传输至 GCS**：
   - **物理备份（推荐用于数 TB 级数据库 — Percona XtraBackup 8.0）**：
     在 GCE MySQL 8.0 虚拟机上运行随附的辅助脚本：
     ```bash
     export MYSQL_USER="dms_repl_user"
     export MYSQL_PASSWORD="YOUR_SECURE_PASSWORD"
     export BUCKET_NAME="prod-dms-mysql80-staging-sg"
     export BACKUP_OBJECT_PATH="backups/mysql80-full.xbstream"

     ./scripts/stream_xtrabackup_to_gcs.sh
     ```
   - **备选逻辑备份（`mysqldump`，配合 `dump_type = "LOGICAL"`）**：
     ```bash
     mysqldump \
       --host=127.0.0.1 \
       --user=dms_repl_user \
       --password="${MYSQL_PASSWORD}" \
       --all-databases \
       --single-transaction \
       --routines \
       --triggers \
       --events \
       --set-gtid-purged=ON \
       --master-data=1 \
       | gzip -c \
       | gcloud storage cp - "gs://${BUCKET_NAME}/backups/mysql80-dump.sql.gz"
     ```
3. **验证并启动基于备份填充的 CDC 迁移作业**：
   ```bash
   gcloud database-migration migration-jobs verify gcs-bkp-mysql80-cdc \
     --region=asia-southeast1

   gcloud database-migration migration-jobs start gcs-bkp-mysql80-cdc \
     --region=asia-southeast1
   ```

---

## 5. 阶段 4：监控 CDC 复制延迟与数据验证

1. **检查迁移作业阶段与状态**：
   ```bash
   gcloud database-migration migration-jobs describe gce-live-mysql80-cdc \
     --region=asia-southeast1 \
     --format="table(name, state, phase, duration)"
   ```
   - 等待 `phase` 从 `FULL_DUMP` 转换为 `CDC`。
2. **监控 Cloud Monitoring 指标**：
   - 在 Cloud Monitoring 中跟踪 `datamigration.googleapis.com/migration_job/replication_lag`，直至复制延迟稳定在 `0 seconds`。
3. **验证 GTID 收敛**：
   - 在源 GCE MySQL 8.0 上：
     ```sql
     SELECT @@GLOBAL.gtid_executed;
     ```
   - 在目标 Cloud SQL 副本上（CDC 期间为只读）：
     ```sql
     SELECT @@GLOBAL.gtid_executed;
     ```

---

## 6. 阶段 5：近零停机切换（提升）

在计划的切换窗口内按以下顺序执行：

1. **排空应用流量，并将源 GCE MySQL 8.0 设为只读**：
   ```sql
   SET GLOBAL super_read_only = ON;
   SET GLOBAL read_only = ON;
   ```
2. **确认复制延迟为零**：
   验证目标 Cloud SQL 实例上 `SELECT @@GLOBAL.gtid_executed;` 的结果与源 GCE MySQL 8.0 实例一致。
3. **提升 Cloud DMS 迁移作业**：
   ```bash
   gcloud database-migration migration-jobs promote gce-live-mysql80-cdc \
     --region=asia-southeast1
   ```
   - Cloud DMS 会断开与 GCE MySQL 8.0 源端的复制，并将 Cloud SQL for MySQL（`MYSQL_8_4` 或 `MYSQL_8_0`）实例提升为独立的可写主实例（`state = COMPLETED`）。
4. **切换应用连接端点**：
   - 更新您的私有 DNS 记录或连接字符串，使其指向 Cloud SQL PSC DNS 名称（Terraform 输出 `cloudsql_dns_name`）。

---

## 7. 阶段 6：提升后的主版本升级路径（`8.0 -> 8.4 -> 9.x`）

- 如果您为了与 GCE MySQL 8.0 严格保持一致而先迁移至 **`MYSQL_8_0`**，可通过 Terraform 将 `target_database_version = "MYSQL_8_4"` 更新后运行 `terraform apply`，就地将主版本升级至 **`MYSQL_8_4` LTS**。
- 当 Google Cloud SQL 正式发布（GA）对 MySQL **`9.x`**（`MYSQL_9_7` / 创新版或 LTS 版本线）的支持后，运行 **`MYSQL_8_4`** 的实例即可借助 Cloud SQL Enterprise Plus 的滚动维护，按受支持的逐级主版本升级路径（`8.0 -> 8.4 -> 9.x`）以近零停机方式完成升级。
