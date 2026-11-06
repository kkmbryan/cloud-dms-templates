# 测试

[English](TESTING.md) | **简体中文**

本页记录已测试的内容、所用版本以及已知不可用的情况。本页不是认证或支持声明。在生产环境中使用之前，请先在您自己的非生产项目中测试这些模板。

## 1. 静态检查（每次变更）

| 检查项 | 工具与版本 | 范围 | 结果 |
| :--- | :--- | :--- | :--- |
| 格式 | `terraform fmt -check -recursive`（Terraform 1.11.4） | 所有模块和模板 | 通过 |
| 验证 | `terraform init -backend=false` + `terraform validate`（Terraform 1.11.4，`hashicorp/google` 8.10.0） | 两个根模板 | 通过 |
| 规划 | 在 `europe-west2` 的空测试项目中运行 `terraform plan`（不执行 apply） | 两个模板：默认 `EXISTING_CLOUDSQL` + `PSC` 模式，以及 `DMS_MANAGED_CLOUDSQL`、`PHYSICAL` + `MYSQL_8_0`、关闭 PSC 端点、使用现有 DNS 区域等变体 | 通过 |
| 负面验证 | `terraform plan` | `PHYSICAL` + `MYSQL_8_4`、`PHYSICAL` 使用文件路径、`backup_gcs_path` 带结尾斜杠、源密码超过 32 个字符 | 按预期被拒绝 |
| Shell 检查 | ShellCheck 0.10.0 | `templates/02-backup-migration-gcs-cdc/scripts/xtrabackup_to_gcs.sh`、`scripts/source-prep/preflight_check.sh` | 通过 |
| `psc_config` 上的 `ignore_changes` | `terraform plan`（PR-3） | 模板 01，以原生方式管理 `network_attachment_uri` | 从实例引用 Network Attachment 会产生依赖循环（`ACCEPT_MANUAL` 挂接需要先有实例）。创建后使用字面 URI 时，plan 显示没有更改。模板保留 `ignore_changes`。 |

## 2. 端到端在线测试

| 日期 | 代码版本 | 源端 | 目标 | 场景 | 初始数据 | 结果 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 2026-11 | 初始版本（`91b9c77`） | Compute Engine 上的 MySQL 8.0.46 | Cloud SQL for MySQL 8.4，Enterprise Plus | 1（模板 01） | 由 DMS 管理的逻辑转储 | 通过：verify、start、CDC、promote。 |
| 2026-11 | 初始版本（`91b9c77`） | Compute Engine 上的 MySQL 8.0.46 | Cloud SQL for MySQL 8.4，Enterprise Plus | 2（模板 02） | mysqldump 文件（`LOGICAL`） | 手动为 Cloud SQL 实例服务账号授予存储桶读取权限后通过。现在由 Terraform 自动授予。 |
| 2026-11-06 | PR-2 | Compute Engine 上的 MySQL 8.0.46（Ubuntu 22.04） | Cloud SQL for MySQL 8.4（8.4.11），Enterprise，可用区级 | 1（模板 01） | 由 DMS 管理的逻辑转储 | 通过：`make preflight`（全新虚拟机上为 FAIL，执行 `scripts/source-prep` 后为 PASS）、apply、verify、start、CDC、promote。客户端通过 PSC 端点和私有 DNS 记录访问实例。提升后 apply 之后无 Terraform 漂移。 |
| 2026-11-06 | PR-2 | Compute Engine 上的 MySQL 8.0.46（Ubuntu 22.04） | Cloud SQL for MySQL 8.4（8.4.11），Enterprise，可用区级 | 2（模板 02） | mysqldump 文件（`LOGICAL`） | 通过：两阶段 apply、verify、start、CDC、promote。存储桶 IAM 全自动。`GTID_SUBSET` = 1，行数一致。 |
| 2026-11-06 | PR-2 | Compute Engine 上的 MySQL 8.0.46（Ubuntu 22.04） | Cloud SQL for MySQL 8.0，Enterprise，可用区级 | 2（模板 02） | 已准备的 Percona XtraBackup 8.0.35 文件夹（`PHYSICAL`） | 通过：`xtrabackup_to_gcs.sh`（备份、准备、上传到专用文件夹）、两阶段 apply、verify、start、CDC、promote。`GTID_SUBSET` = 1，行数一致。 |
| 2026-11-06 | PR-3（T4） | MySQL 8.0.46（Ubuntu 22.04），`require_secure_transport = ON` | Cloud SQL for MySQL 8.4（8.4.11），Enterprise，可用区级，`cloudsql_ssl_mode = "ENCRYPTED_ONLY"` | 1（模板 01） | 由 DMS 管理的逻辑转储 | 通过：`ACCEPT_MANUAL` Network Attachment（租户项目从实例推导）、以网络标记为目标的防火墙规则、`source_ssl_type = "REQUIRED"`，然后 verify、start、CDC、promote。通过 PSC 端点和 DNS 记录：TLS 1.2 会话，`GTID_SUBSET` = 1，行数一致，提升后可写入；`--ssl-mode=DISABLED` 被拒绝。提升后 apply（包括 `cloudsql_password_validation_policy`）之后无漂移。`make preflight` 报告 `tls` PASS。 |
| 2026-11-06 | PR-3（T5） | 与 T4 相同的栈，提升之后 | 相同 | 1（模板 01） | — | 通过：`migration_enabled = false` 在约 6 分钟内销毁了 7 个资源（作业、连接配置文件、降级和挂接步骤、Network Attachment、防火墙规则）（分离约 5 分钟）。Cloud SQL、PSC 端点和 DNS 保留；重启期间，通过端点进行的客户端探测失败约 20 秒。之后客户端可以连接并写入；下一次 plan 显示没有更改。随后执行 `terraform destroy`。 |
| 2026-11-06 | PR-3（T6） | MySQL 8.0.46 | Cloud SQL for MySQL 8.0，Enterprise，可用区级 | 1（模板 01） | 由 DMS 管理的逻辑转储 | 通过：使用全部默认值的单次 apply（`ACCEPT_MANUAL`、以服务账号为目标的防火墙规则、`REQUIRED` TLS）、verify、start、CDC。删除 `RUNNING` 作业（不使用 `--force`）被接受；实例仍为只读副本。随后 `terraform destroy` 分离了 Network Attachment 并删除了所有资源。 |
| 2026-11-06 | PR-3（T7） | MySQL 8.0.46 | Cloud SQL for MySQL 8.4，Enterprise，可用区级，CMEK | 2（模板 02） | CMEK 存储桶中的 mysqldump 文件（`LOGICAL`） | 通过：使用 `cloudsql_kms_key_name` 和 `staging_bucket_kms_key_name` 的两阶段 apply、非当前版本生命周期规则、verify、start、CDC。在作业处于 CDC 阶段且为 `RUNNING` 时执行 `terraform destroy`，删除了作业（约 1 分钟），分离了 Network Attachment，并在约 7 分钟内销毁了全部 16 个资源。 |
| 2026-11-06 | PR-3（负面测试） | MySQL 8.0.46 | Cloud SQL for MySQL 8.4 | 1（模板 01） | — | (a) `create_source_firewall_rule = false`：`verify` 失败，报错 "Failure connecting to the source database. Make sure the connectivity information on the connection profile is correct and the source database is reachable." (b) `ACCEPT_MANUAL` 且 `psc_producer_accept_list` 错误：挂接步骤失败并报错 `[ERROR_NETWORK_ATTACHMENT_POLICY_FORBIDDEN]`，且未创建连接端点；修正列表后挂接被原地更新，下一次 apply 完成了挂接。 |

## 3. 已知限制

- **物理初始数据：** DMS 仅在 `MYSQL_8_0` 目标上支持 `PHYSICAL`（XtraBackup）初始数据。备份必须经过准备，存放在专用文件夹中，且单个文件不得超过 5 TB。
- **状态中的密钥：** 由于 DMS 连接配置文件资源没有只写密码参数，源端迁移密码会（以敏感值形式）存储在 Terraform 状态中。Cloud SQL root 密码通过 `google_sql_user` 的只写参数 `password_wo` 设置在 `root@'%'` 上，不会被存储。请使用受保护的远程状态后端。
- **`local-exec` 步骤：** 挂接和分离 Network Attachment 以及降级目标实例，会在运行 Terraform 的机器上使用该机器当前有效的 `gcloud` 账号执行 `gcloud`；如果设置了 `impersonate_service_account`，则使用该服务账号。
- **迁移期间不要执行完整的 Terraform apply：** 降级后，DMS 会更改目标实例的备份设置，在提升之前，完整的 `terraform apply` 会失败并报错 `Backups cannot be enabled for read replica instance`。如确需在此期间更改防火墙规则，请仅指定该规则（运维手册第 6 节）。
- **`psc_config` 偏差：** `psc_config` 位于 `ignore_changes` 中，因此之后对 `allowed_consumer_projects` 的更改需要使用 `gcloud sql instances patch --allowed-psc-projects`。
- **密码验证策略：** 请在提升之后设置 `cloudsql_password_validation_policy`；在创建时设置会导致 API 拒绝创建实例，因为 root 密码是之后才设置的。
- **`migration_enabled = false`：** 仅适用于提升之后，且仅适用于 `EXISTING_CLOUDSQL` 模式。分离 Network Attachment 会重启实例。
- **被放弃的迁移：** 在提升之前删除作业（T6、T7）会留下源表示实例 `<instance>-master`（`ON_PREMISES_INSTANCE`），该实例不由 Terraform 管理；请使用 `gcloud sql instances delete` 将其删除。
- **Network Attachment 授权：** 使用租户项目 ID 的 `ACCEPT_MANUAL` 被接受；挂接会以租户项目编号显示该连接。
- **PSC DNS 区域：** 默认私有区域覆盖 `network` 中的 `<region>.sql.goog.`。如果 VPC 中已存在此类区域（例如用于其他 Cloud SQL PSC 实例），请设置 `psc_existing_dns_zone_name`。
- **PR-2 在线测试发现并已修复的问题：**
  - DMS 在创建迁移作业时会检查初始数据是否存在，因此场景 2 需要两次 apply（`create_migration_job = false`，上传初始数据，然后再次 apply）。
  - `gcloud storage cp` 需要 `storage.objects.get`，因此备份写入方除 `roles/storage.objectCreator` 外还获得 `roles/storage.objectViewer`。
  - 仅使用只写 root 密码时，provider 会删除默认的 `root@'%'` 用户；模块现在会重新创建该用户。
  - `--prepare` 之后空的 `#innodb_redo` 目录导致上传失败；脚本现在使用 `gcloud storage rsync`。
  - 源端视图的 DEFINER 用户在 Cloud SQL 上不存在时，`verify` 会以“Definer is not supported”失败，创建该用户后通过（运维手册第 5 节）。
- **解除 Network Attachment**（`gcloud sql instances patch --clear-psc-network-attachment-uri`）在测试中会重启实例（约 5 分钟）。
- **Percona XtraBackup 版本：** 最新的 XtraBackup 8.0 版本（8.0.35）低于当前的 MySQL 8.0 服务器版本。此时辅助脚本要求 XtraBackup 8.0.34 或更高版本，并添加 `--lock-ddl=ON`。
- **Data Validation Tool：** 已记录 `make validate-data`，但在线测试中未运行。
- **`DMS_MANAGED_CLOUDSQL` 模式：** 上述在线测试未覆盖此模式。在场景 2 中，您必须自行为 DMS 创建的实例的服务账号授予存储桶读取权限。
