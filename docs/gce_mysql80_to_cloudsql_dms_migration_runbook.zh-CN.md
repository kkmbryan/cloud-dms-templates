# 运维手册：通过 Database Migration Service 将 Compute Engine 上的自管理 MySQL 8.0 迁移至 Cloud SQL（8.0 / 8.4）

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
| **初始数据填充机制** | 由 DMS 管理、直接从源 MySQL 8.0 执行的并行逻辑转储（`dump_type = "LOGICAL"`，`dump_parallel_level = "OPTIMAL"`） | 通过 `dump_path` 使用 GCS 中的 mysqldump 文件（`dump_type = "LOGICAL"`，默认）或已准备的 Percona XtraBackup 文件夹（`dump_type = "PHYSICAL"`，仅限 `MYSQL_8_0` 目标） |
| **对源主实例的影响** | 初始并行转储期间存在中等程度的读 I/O 与 CPU 开销 | 无 DMS 转储负载；由您按自己的时间安排运行 mysqldump 或 XtraBackup |
| **持续复制** | 基于 GTID 的持续 Binlog CDC（`type = "CONTINUOUS"`） | 基于 GTID 的持续 Binlog CDC（`type = "CONTINUOUS"`），自动从备份的 GTID 坐标处恢复 |
| **切换停机时间** | 近零（最终提升期间仅需数分钟） | 近零（最终提升期间仅需数分钟） |

### 1.1 初始数据支持矩阵

| 初始数据（`dump_type`） | 模板 | 目标 `MYSQL_8_0` | 目标 `MYSQL_8_4` | `dump_path` |
| :--- | :--- | :--- | :--- | :--- |
| 由 DMS 管理的逻辑转储（`LOGICAL`） | 01 | 支持 | 支持 | 不使用 |
| mysqldump 文件（`LOGICAL`，默认） | 02 | 支持 | 支持 | 单个文件：`gs://<bucket>/<path>.sql.gz` |
| 已准备的 Percona XtraBackup（`PHYSICAL`） | 02 | 支持 | **DMS 不支持**（Terraform 验证会拒绝） | 专用文件夹：`gs://<bucket>/<folder>` |

> [!WARNING]
> DMS 不支持以物理（XtraBackup）方式迁移至 MySQL 8.4。除非 `target_database_version = "MYSQL_8_0"`，否则模板 02 会拒绝 `dump_type = "PHYSICAL"`。物理备份必须经过**准备（prepare）**，并上传到不包含任何其他文件的**专用文件夹**，且单个备份文件不得超过 5 TB。请参阅[使用 Percona XtraBackup 物理文件迁移](https://cloud.google.com/database-migration/docs/mysql/migrate-with-physical-xtrabackup)。

---

## 2. 阶段 1：源 MySQL 8.0 预检验证

在启动场景 1 或场景 2 之前，请在自管理的源 MySQL 8.0 实例（`/etc/mysql/mysql.conf.d/mysqld.cnf` 或 `/etc/my.cnf`）上验证以下必需参数：

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

在源 MySQL 8.0 实例上验证当前运行时的参数值：

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

### 2.2 创建迁移账号

使用两个独立的账号：

| 账号 | 使用方 | 主机 | 权限 |
| :--- | :--- | :--- | :--- |
| `dms_migration` | DMS 源连接配置文件（Terraform `source_gce_mysql_username`） | `'%'`（DMS 要求） | 场景 1：`REPLICATION SLAVE`、`REPLICATION CLIENT`、`EXECUTE`、`SELECT`、`SHOW VIEW`、`TRIGGER`、`EVENT`、`RELOAD`、`LOCK TABLES`。场景 2（仅 CDC）：`REPLICATION SLAVE`、`REPLICATION CLIENT`、`EXECUTE`。**切勿**授予 `BACKUP_ADMIN`。 |
| `xtrabackup` | 源虚拟机上的 `xtrabackup_to_gcs.sh`（仅场景 2 `PHYSICAL`） | `'localhost'` | `BACKUP_ADMIN`、`PROCESS`、`RELOAD`、`LOCK TABLES`、`REPLICATION CLIENT`，以及 `performance_schema.log_status` 和 `performance_schema.keyring_component_status` 上的 `SELECT` |

以管理员用户身份连接到源 MySQL 8.0 实例并运行：

```sql
-- 1) DMS migration user. DMS requires host '%' and a password of 32 characters or fewer.
CREATE USER IF NOT EXISTS 'dms_migration'@'%' IDENTIFIED BY 'REPLACE_ME_MAX_32_CHARS';

-- Scenario 1 (DMS-managed dump):
GRANT REPLICATION SLAVE, REPLICATION CLIENT, EXECUTE, SELECT, SHOW VIEW, TRIGGER, EVENT, RELOAD, LOCK TABLES
  ON *.* TO 'dms_migration'@'%';

-- Scenario 2 (you provide the seed): CDC privileges only.
-- GRANT REPLICATION SLAVE, REPLICATION CLIENT, EXECUTE ON *.* TO 'dms_migration'@'%';

-- Do NOT grant BACKUP_ADMIN to dms_migration: DMS rejects a migration account
-- with BACKUP_ADMIN on MySQL 8.0 and later.

-- 2) XtraBackup user (Scenario 2 PHYSICAL only), local connections only.
CREATE USER IF NOT EXISTS 'xtrabackup'@'localhost' IDENTIFIED BY 'REPLACE_WITH_SECURE_PASSWORD';
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'xtrabackup'@'localhost';
GRANT SELECT ON performance_schema.log_status TO 'xtrabackup'@'localhost';
GRANT SELECT ON performance_schema.keyring_component_status TO 'xtrabackup'@'localhost';
```

> [!NOTE]
> 对于场景 2 的 `LOGICAL` 初始数据，请使用可读取所有待迁移数据库的现有管理员账号运行 `mysqldump`（需要 `SELECT`、`SHOW VIEW`、`TRIGGER`、`EVENT`、`LOCK TABLES` 和 `RELOAD`）。请通过权限为 `0600` 的选项文件（`--defaults-extra-file`）传递凭据，切勿在命令行中使用 `--password=`。参考资料：[配置源数据库](https://cloud.google.com/database-migration/docs/mysql/configure-source-database-continuous)、[Percona XtraBackup 权限](https://docs.percona.com/percona-xtrabackup/8.0/privileges.html)。

---

## 3. 阶段 2：Private Service Connect (PSC) 与出站 Network Attachment 架构

两个模板均默认使用 **Private Service Connect（`connectivity_type = "PSC"`，`destination_mode = "EXISTING_CLOUDSQL"`）**，以规避 VPC 对等互连的传递性限制：

1. **Cloud SQL 纯 PSC + 出站 Network Attachment（`network_attachment_uri`）**：
   - `cloudsql-mysql-destination` 模块会配置 `psc_enabled = true`（同时 `ipv4_enabled = false`）和 `allowed_consumer_projects`。实例创建后，模块会运行 `gcloud sql instances patch --psc-network-attachment-uri=...` 并重新读取实例；如果挂接未生效，apply 会失败。之后，目标 Cloud SQL 实例即可与您的 VPC 子网建立私有出站复制连接。
2. **Compute Engine Network Attachment**：
   - `networking-psc` 模块会在您的子网中预配 `google_compute_network_attachment`。未指定 `dms_tenant_project_id` 时，默认使用 `ACCEPT_AUTOMATIC`；指定 `dms_tenant_project_id` 时，则强制使用 `ACCEPT_MANUAL`，并将 `producer_accept_lists` 限制为您的项目和指定的租户项目。
3. **原生 DMS 连接配置文件与迁移作业**：
   - 源连接配置文件、目标连接配置文件和迁移作业均为原生 Terraform 资源。源端密码由 provider 发送到 DMS API，不会出现在命令行中。但它仍会（以敏感值形式）存储在 Terraform 状态中，因此请保护好您的状态后端。
4. **自动降级目标实例（`demote-destination`）**：
   - 当 `destination_mode = "EXISTING_CLOUDSQL"` 时，`dms-migration-job` 模块会在作业创建后运行一次 `gcloud database-migration migration-jobs demote-destination`，等待该操作完成（默认超时 3600 秒）；如果操作报告错误，apply 会失败。
5. **PSC 使用方端点与私有 DNS（应用访问）**：
   - `cloudsql-psc-endpoint` 模块（默认 `create_psc_endpoint = true`）会在 `psc_endpoint_subnet` 中预留内部 IP，创建指向实例服务连接的转发规则，并在绑定到 `network` 的 `<region>.sql.goog.` 私有 Cloud DNS 区域中为实例 DNS 名称添加 A 记录。如果您的 VPC 中已存在该区域，请设置 `psc_existing_dns_zone_name`。

---

## 4. 阶段 3：执行迁移

请先完成[前提条件](../README.zh-CN.md)。顺序始终为：**apply → 生成初始数据（场景 2）→ verify → start**。

### 方案 A：场景 1 — 在线迁移 + 持续 CDC（`templates/01-live-migration-gce-cdc`）

1. **部署 Terraform 基础设施**：
   ```bash
   cd templates/01-live-migration-gce-cdc
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your project_id, network, subnets and source IP
   export TF_VAR_cloudsql_root_password='REPLACE_ME'
   export TF_VAR_source_gce_mysql_password='REPLACE_ME_MAX_32_CHARS'
   terraform init
   terraform validate
   terraform apply
   ```
2. **运行预检验证**：
   ```bash
   gcloud database-migration migration-jobs verify gce-live-mysql80-cdc \
     --region=europe-west2
   ```
3. **启动在线转储 + 持续 CDC**：
   ```bash
   gcloud database-migration migration-jobs start gce-live-mysql80-cdc \
     --region=europe-west2
   ```

---

### 方案 B：场景 2 — GCS 中的备份 + 持续 CDC（`templates/02-backup-migration-gcs-cdc`）

1. **部署 Terraform 基础设施（GCS 暂存存储桶 + IAM + Cloud SQL + DMS 作业）**：
   ```bash
   cd templates/02-backup-migration-gcs-cdc
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars: dump_type ("LOGICAL" default, or "PHYSICAL" with MYSQL_8_0) and backup_gcs_path
   export TF_VAR_cloudsql_root_password='REPLACE_ME'
   export TF_VAR_source_gce_mysql_password='REPLACE_ME_MAX_32_CHARS'
   terraform init
   terraform validate
   terraform apply

   # The single seed location used by the migration job
   terraform output -raw configured_dump_path
   ```
2. **在源虚拟机上将初始数据生成到 `configured_dump_path`**：
   - **逻辑初始数据（`dump_type = "LOGICAL"`，默认）**：
     ```bash
     export DUMP_PATH="gs://my-dms-staging-bucket/mysqldump/mysql80-dump.sql.gz"   # = configured_dump_path
     # ~/.mysqldump.cnf (chmod 600) contains: [client] user=... password=...
     mysqldump --defaults-extra-file="${HOME}/.mysqldump.cnf" \
       --host=127.0.0.1 \
       --databases app_db1 app_db2 \
       --hex-blob \
       --no-autocommit \
       --default-character-set=utf8mb4 \
       --single-transaction \
       --routines \
       --triggers \
       --events \
       --set-gtid-purged=ON \
       | gzip -c \
       | gcloud storage cp - "${DUMP_PATH}"
     ```
     `--databases` 中只列出应用数据库（不包括 `mysql`、`sys`、`performance_schema` 或 `information_schema`）；启用 GTID 时不要使用 `--master-data`/`--source-data`；转储运行期间不要执行 DDL。请参阅[使用 mysqldump 导出 MySQL 数据库](https://cloud.google.com/database-migration/docs/mysql/mysql-dump)。
   - **物理初始数据（`dump_type = "PHYSICAL"`，仅限 `MYSQL_8_0` 目标 — Percona XtraBackup 8.0）**：
     将 [`scripts/xtrabackup_to_gcs.sh`](../templates/02-backup-migration-gcs-cdc/scripts/xtrabackup_to_gcs.sh) 复制到源虚拟机并运行。该脚本会检查 `innodb_page_size`、XtraBackup 与服务器版本、可用磁盘空间以及目标文件夹是否为空，然后依次运行 `--backup`、`--prepare`，并通过 `gcloud storage cp -r` 上传到该文件夹：
     ```bash
     export GCS_BACKUP_FOLDER="gs://my-dms-staging-bucket/xtrabackup/mysql80-full"   # = configured_dump_path
     export XTRABACKUP_USER="xtrabackup"   # the script prompts for the password
     sudo -E ./xtrabackup_to_gcs.sh
     ```
3. **验证并启动基于备份填充的 CDC 迁移作业**：
   ```bash
   gcloud database-migration migration-jobs verify gcs-bkp-mysql80-cdc \
     --region=europe-west2

   gcloud database-migration migration-jobs start gcs-bkp-mysql80-cdc \
     --region=europe-west2
   ```

---

## 5. 阶段 4：监控 CDC 复制延迟与数据验证

1. **检查迁移作业阶段与状态**：
   ```bash
   gcloud database-migration migration-jobs describe gce-live-mysql80-cdc \
     --region=europe-west2 \
     --format="table(name, state, phase, duration)"
   ```
   - 等待 `phase` 从 `FULL_DUMP` 转换为 `CDC`。
2. **监控 Cloud Monitoring 指标**：
   - 在 Cloud Monitoring 中跟踪 `datamigration.googleapis.com/migration_job/max_replica_sec_lag` 和 `datamigration.googleapis.com/migration_job/max_replica_bytes_lag`，直至复制延迟稳定在接近 `0` 的水平。请参阅[迁移作业指标](https://cloud.google.com/database-migration/docs/mysql/migration-job-metrics)。
3. **验证 GTID 收敛**：
   - 在源 MySQL 8.0 上：
     ```sql
     SELECT @@GLOBAL.gtid_executed;
     ```
   - 在目标 Cloud SQL 副本上（CDC 期间为只读），通过 PSC 端点 DNS 名称（Terraform 输出 `psc_endpoint_dns_name`）连接：
     ```sql
     SELECT @@GLOBAL.gtid_executed;
     ```

---

## 6. 阶段 5：近零停机切换（提升）

在计划的切换窗口内按以下顺序执行：

1. **排空应用流量，并将源 MySQL 8.0 设为只读**：
   ```sql
   SET GLOBAL super_read_only = ON;
   SET GLOBAL read_only = ON;
   ```
2. **确认复制延迟为零**：
   验证目标 Cloud SQL 实例上 `SELECT @@GLOBAL.gtid_executed;` 的结果与源 MySQL 8.0 实例一致。
3. **提升 Cloud DMS 迁移作业**：
   ```bash
   gcloud database-migration migration-jobs promote gce-live-mysql80-cdc \
     --region=europe-west2
   ```
   - Cloud DMS 会断开与源 MySQL 8.0 的复制，并将 Cloud SQL for MySQL（`MYSQL_8_4` 或 `MYSQL_8_0`）实例提升为独立的可写主实例（`state = COMPLETED`）。
4. **切换应用连接端点**：
   - 将连接字符串指向 PSC 端点 DNS 名称（Terraform 输出 `psc_endpoint_dns_name`）。Terraform 创建的私有区域会在 `network` 内将其解析为 PSC 端点 IP（`psc_endpoint_ip_address`）。在应用主机上测试：
     ```bash
     mysql --host="<psc_endpoint_dns_name>" --user="<app_user>" -p -e "SELECT @@hostname, @@version;"
     ```

---

## 7. 阶段 6：提升后的主版本升级路径（`8.0 -> 8.4 -> 9.x`）

- 如果您为了与源 MySQL 8.0 严格保持一致而先迁移至 **`MYSQL_8_0`**，可通过 Terraform 将 `target_database_version = "MYSQL_8_4"` 更新后运行 `terraform apply`，就地将主版本升级至 **`MYSQL_8_4` LTS**。
- 当 Google Cloud SQL 正式发布（GA）对 MySQL **`9.x`**（`MYSQL_9_7` / 创新版或 LTS 版本线）的支持后，运行 **`MYSQL_8_4`** 的实例即可借助 Cloud SQL Enterprise Plus 的滚动维护，按受支持的逐级主版本升级路径（`8.0 -> 8.4 -> 9.x`）以近零停机方式完成升级。
