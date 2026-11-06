# Cloud DMS 迁移 — 多领域专家（SME）架构、安全与 Terraform 验证报告

[English](sme_audit_and_validation_report.md) | **简体中文**

- **范围**：与具体客户无关的企业级参考架构
- **源环境**：Google Compute Engine (GCE) 上的自管理 MySQL 8.0
- **目标环境**：Cloud SQL for MySQL（默认 `MYSQL_8_4` LTS 或 `MYSQL_8_0`，Enterprise Plus 区域级高可用）
- **迁移服务**：Google Cloud Database Migration Service (Cloud DMS) — 持续变更数据捕获（CDC）
- **仓库路径**：`cloud-dms-templates/`
- **评审小组**：
  - `infra-sme` — 首席云网络与存储基础设施 SME
  - `db-sme` — 首席数据库迁移与 Cloud SQL SME
  - `iac-auditor` — 首席安全与基础设施即代码（IaC）审计员
- **审计状态**：**已批准（100% 通过 — 0 个错误，0 个警告）**

---

## 1. 执行摘要

Cloud DMS Terraform 模板仓库（`cloud-dms-templates`）已完成全面的多 SME 架构评审、安全加固审计，以及基于 `hashicorp/google` provider `v8.9.0`（兼容 `>= 5.30.0` 及 Terraform `>= 1.5.0`）的自动化 Terraform Schema 验证。

全部五个可复用 Terraform 模块和两个生产根模板均通过了 `terraform fmt -check -recursive`、`terraform init -backend=false` 和 `terraform validate`，**零错误、零警告**。

---

## 2. 架构决策记录（ADR）

> [!IMPORTANT]
> **为什么 Cloud DMS 将 GCE MySQL 8.0 迁移至 `MYSQL_8_0` 或 `MYSQL_8_4` LTS（而非直接跨越至 9.7）**
> 原生 MySQL 二进制日志复制与 Google Cloud Database Migration Service (Cloud DMS) 支持同版本迁移（`8.0 -> 8.0`）以及相邻 LTS 主版本升级（`8.0 -> 8.4`）。在基于 GTID 的实时持续复制过程中直接跨越主版本（`8.0 -> 9.7`）不受 MySQL InnoDB 数据字典及二进制日志复制内部机制支持。此外，MySQL `8.4` 是 Oracle 当前的长期支持（LTS）版本线，且已获 Cloud SQL for MySQL 支持。如果组织未来需要 MySQL `9.x`，经验证的企业级路径是：通过 Cloud DMS 迁移至 `MYSQL_8_4`（或先迁移至 `MYSQL_8_0`，再就地升级至 `MYSQL_8_4`），提升 Cloud SQL 实例，然后执行受控的提升后主版本升级（`8.0 -> 8.4 -> 9.x`）。

| 架构决策领域 | 经验证的工程决策与依据 |
| :--- | :--- |
| **ADR-01：目标数据库版本（`MYSQL_8_4` 与 `MYSQL_8_0`）** | 两个模板及 `modules/cloudsql-mysql-destination` 均强制执行 `contains(["MYSQL_8_0", "MYSQL_8_4"], var.database_version)`，以 `MYSQL_8_4` 作为推荐的 LTS 默认版本，并支持 `MYSQL_8_0` 以与源端严格保持一致。 |
| **ADR-02：默认使用 Private Service Connect (`PSC`) 连接** | `modules/networking-psc` 与 `modules/cloudsql-mysql-destination` 默认使用 `connectivity_type = "PSC"` 和 `destination_mode = "EXISTING_CLOUDSQL"`，结合 `google_compute_network_attachment`、Cloud SQL 的 `psc_config.network_attachment_uri`（PSC 出站）及 `demote-destination`，规避 VPC 对等互连的传递性瓶颈，同时保留可选的 `PSA` 支持。 |
| **ADR-03：场景 1 — 在线迁移 + 持续 CDC** | `templates/01-live-migration-gce-cdc` 预配一个 `CONTINUOUS` DMS 迁移作业，先执行多线程在线逻辑初始转储（`dump_type = "LOGICAL"`，`dump_parallel_level = "MAX"`），随后持续执行基于 GTID 的行格式二进制日志 CDC。 |
| **ADR-04：场景 2 — 基于 GCS 备份填充 + 持续 CDC** | `templates/02-backup-migration-gcs-cdc` 预配经过加固的区域级 GCS 暂存存储桶（`modules/gcs-migration-staging`），以及一个通过 `dump_path` 填充初始数据的 `CONTINUOUS` DMS 迁移作业，支持 `PHYSICAL`（Percona XtraBackup 8.0，数 TB 级数据库的默认选项）和 `LOGICAL`（`mysqldump`）两种备份，随后执行基于 GTID 的持续 Binlog CDC。 |
| **ADR-05：互斥防护（`dump_path` 与 `dump_flags`）** | `modules/dms-migration-job` 在 `google_database_migration_service_migration_job` 中强制执行严格互斥：当填充了 `dump_path`（场景 2）时，`dump_flags` 和 `performance_config` 会被动态禁用（`!local.use_gcs_backup_dump`），避免 provider Schema 冲突。 |
| **ADR-06：Cloud SQL Enterprise Plus 高可用与弹性** | `modules/cloudsql-mysql-destination` 默认配置 `edition = "ENTERPRISE_PLUS"`、`availability_type = "REGIONAL"`、`data_cache_enabled = true`、`deletion_protection = true`、`binary_log_enabled = true` 和 `point_in_time_recovery_enabled = true`，事务日志保留 7 天，并保留 30 个自动备份。 |

---

## 3. 自动化 Terraform 与 Git 验证证据

所有验证检查均在 `cloud-dms-templates/` 中基于 Terraform 和 `hashicorp/google` provider `v8.9.0` 执行：

| 验证检查项 | 执行结果与输出摘要 |
| :--- | :--- |
| **Git 仓库初始化（`git status`）** | **通过** — 已在 `main` 分支上初始化本地 Git 仓库，`.gitignore` 排除了 `.terraform/`、`*.tfstate*`、`*.tfvars`（保留 `*.tfvars.example`）和 `.terraform.lock.hcl`。 |
| **递归格式检查（`terraform fmt -check -recursive`）** | **通过** — `modules/` 和 `templates/` 中所有 `.tf` 与 `.tfvars.example` 文件的退出码均为 `0`。 |
| **场景 1 验证（`templates/01-live-migration-gce-cdc`）** | **通过** — `terraform init -backend=false && terraform validate` 初始化了模块 `networking`、`cloudsql_destination`、`dms_connection_profiles` 和 `dms_migration_job`，并返回 `Success! The configuration is valid.`（0 个错误，0 个警告）。 |
| **场景 2 验证（`templates/02-backup-migration-gcs-cdc`）** | **通过** — `terraform init -backend=false && terraform validate` 初始化了模块 `networking`、`gcs_migration_staging`、`cloudsql_destination`、`dms_connection_profiles` 和 `dms_migration_job`，并返回 `Success! The configuration is valid.`（0 个错误，0 个警告）。 |
| **CI/CD 与运维工具（`Makefile` 与 `.github/workflows/terraform-ci.yml`）** | **通过** — `Makefile` 提供 `fmt`、`fmt-check`、`validate`、`lint`、`verify-job`、`status-job`、`promote-job` 和 `clean`。GitHub Actions 工作流会在推送和拉取请求事件上自动执行格式检查与 Schema 验证。 |

---

## 4. 安全与合规审计检查清单

| 安全控制领域 | 审计验证详情 |
| :--- | :--- |
| **密钥与凭据保护（`sensitive = true`）** | **已验证** — 所有密码和私钥输入（`root_password`、`cloudsql_root_password`、`source_password`、`source_gce_mysql_password`、`destination_password`、`dest_root_password`、`source_ssl_client_key`）在所有模块和根模板中均标记为 `sensitive = true`。 |
| **网络隔离与零公共 IP 暴露** | **已验证** — Cloud SQL 目标实例默认设置 `ipv4_enabled = false`（`var.enable_ipv4 = false`），并通过 Private Service Connect（`psc_enabled = true`，显式配置 `allowed_consumer_projects`）或 Private Services Access (`PSA`) 路由流量。 |
| **PSC Network Attachment 授权** | **已验证** — `google_compute_network_attachment.dms_psc` 支持 `ACCEPT_AUTOMATIC`，或通过 `producer_accept_lists`（`[var.project_id]` 及可选的 `var.dms_tenant_project_id`）进行显式 `ACCEPT_MANUAL` 授权，并与 Cloud SQL `psc_config.network_attachment_uri` 配合使用。 |
| **GCS 暂存存储桶加固（场景 2）** | **已验证** — `google_storage_bucket.migration_staging` 强制启用 `uniform_bucket_level_access = true`、`public_access_prevention = "enforced"`、对象 `versioning { enabled = true }`、可选 CMEK 加密（`kms_key_name`），并在 `var.retention_days`（默认 `14` 天）后通过 `Delete` 生命周期规则自动清理。 |
| **最小权限 GCS IAM 绑定** | **已验证** — `modules/gcs-migration-staging` 仅向 DMS 服务账号（`dms_service_account_email`）授予 `roles/storage.objectViewer` 和 `roles/storage.legacyBucketReader`，并向显式指定的 `backup_writer_members` 授予 `roles/storage.objectAdmin`。 |
| **数据库删除保护与时间点恢复** | **已验证** — `google_sql_database_instance.destination` 同时强制启用 Terraform 层面的 `deletion_protection = true` 和 GCP API 层面的 `deletion_protection_enabled = true`，启用 `cloudsql_iam_authentication = "on"`，并默认启用 `binary_log_enabled = true` 和 `point_in_time_recovery_enabled = true`。 |

---

## 5. 模块与交付物清单签核

| 交付物路径 | 审计范围与签核状态 |
| :--- | :--- |
| `modules/networking-psc/` | **已批准**（`infra-sme` / `iac-auditor`）— 预配 `google_compute_network_attachment` 和 `google_database_migration_service_private_connection`（`psc_interface_config`）以支持默认 `PSC`，并可选配置 `PSA` 对等互连。 |
| `modules/gcs-migration-staging/` | **已批准**（`infra-sme` / `iac-auditor`）— 预配经过加固的区域级 GCS 暂存存储桶，包含 UBLA、公共访问防护、生命周期清理、可选 CMEK 及最小权限 IAM。 |
| `modules/cloudsql-mysql-destination/` | **已批准**（`db-sme` / `iac-auditor`）— 预配 Cloud SQL for MySQL（`MYSQL_8_4` 或 `MYSQL_8_0`，`ENTERPRISE_PLUS` 区域级高可用、Data Cache、PSC/PSA、PITR、删除保护）。 |
| `modules/dms-connection-profiles/` | **已批准**（`db-sme` / `iac-auditor`）— 预配源 GCE MySQL 8.0 连接配置文件（可选 mTLS/SSL）和目标 Cloud SQL 连接配置文件（`EXISTING_CLOUDSQL` 或 `DMS_MANAGED_CLOUDSQL`）。 |
| `modules/dms-migration-job/` | **已批准**（`db-sme` / `iac-auditor`）— 预配 `CONTINUOUS` DMS 迁移作业，支持场景 1（`LOGICAL` 并行转储）和场景 2（从 GCS `dump_path` 导入 `PHYSICAL` XtraBackup 或 `LOGICAL` 转储，并与 `dump_flags` 互斥）。 |
| `templates/01-live-migration-gce-cdc/` | **已批准**（`db-sme` / `iac-auditor`）— 场景 1 的端到端根模板（GCE MySQL 8.0 在线转储 + 持续 Binlog CDC）。 |
| `templates/02-backup-migration-gcs-cdc/` | **已批准**（`db-sme` / `iac-auditor`）— 场景 2 的端到端根模板（GCS 备份填充 + 持续 Binlog CDC），包含可执行脚本 `scripts/stream_xtrabackup_to_gcs.sh`。 |
| `docs/gce_mysql80_to_cloudsql_dms_migration_runbook.md` | **已批准**（`db-sme` / `iac-auditor`）— 面向 DBA 的分步运维手册，涵盖 MySQL 8.0 GTID/binlog 前提条件、纯 PSC + PSC 出站（`network_attachment_uri`）架构、场景 1 与场景 2 的执行、CDC 监控、近零停机提升，以及 `8.0 -> 8.4 -> 9.x` 升级路径。 |

---

**签署**：
- `infra-sme`（基础设施与网络 SME）
- `db-sme`（数据库迁移与 Cloud SQL SME）
- `iac-auditor`（首席安全与 IaC 审计员）
