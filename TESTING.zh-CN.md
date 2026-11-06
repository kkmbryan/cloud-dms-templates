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
| Shell 检查 | ShellCheck 0.10.0 | `templates/02-backup-migration-gcs-cdc/scripts/xtrabackup_to_gcs.sh` | 通过 |

## 2. 端到端在线测试

| 日期 | 代码版本 | 源端 | 目标 | 场景 | 初始数据 | 结果 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 2026-11 | 初始版本（`91b9c77`） | Compute Engine 上的 MySQL 8.0.46 | Cloud SQL for MySQL 8.4，Enterprise Plus | 1（模板 01） | 由 DMS 管理的逻辑转储 | 通过：verify、start、CDC、promote。 |
| 2026-11 | 初始版本（`91b9c77`） | Compute Engine 上的 MySQL 8.0.46 | Cloud SQL for MySQL 8.4，Enterprise Plus | 2（模板 02） | mysqldump 文件（`LOGICAL`） | 手动为 Cloud SQL 实例服务账号授予存储桶读取权限后通过。现在由 Terraform 自动授予。 |
| — | 当前版本 | MySQL 8.0 | Cloud SQL for MySQL 8.0 | 2（模板 02） | 已准备的 Percona XtraBackup 文件夹（`PHYSICAL`） | **待重新测试。** 尚未进行端到端测试。 |
| — | 当前版本 | MySQL 8.0 | Cloud SQL for MySQL 8.4 | 1 和 2 | 逻辑 | 使用当前代码（原生连接配置文件与迁移作业、PSC 端点与 DNS、自动存储桶 IAM）在 `europe-west2` 中**待重新测试**。 |

## 3. 已知限制

- **物理初始数据：** DMS 仅在 `MYSQL_8_0` 目标上支持 `PHYSICAL`（XtraBackup）初始数据。备份必须经过准备，存放在专用文件夹中，且单个文件不得超过 5 TB。
- **状态中的密钥：** 由于 DMS 连接配置文件资源没有只写密码参数，源端迁移密码会（以敏感值形式）存储在 Terraform 状态中。Cloud SQL root 密码使用只写参数 `root_password_wo`，不会被存储。请使用受保护的远程状态后端。
- **`local-exec` 步骤：** 将 Network Attachment 挂接到 Cloud SQL 实例以及降级目标实例，会在运行 Terraform 的机器上使用该机器当前有效的 `gcloud` 账号执行 `gcloud`。
- **迁移期间不要执行 Terraform apply：** 作业运行期间，DMS 会更改目标实例上的部分设置。在 `start` 与 `promote` 之间，请勿对目标实例运行 `terraform apply`。
- **Network Attachment 授权：** Network Attachment 默认使用 `ACCEPT_AUTOMATIC`。
- **PSC DNS 区域：** 默认私有区域覆盖 `network` 中的 `<region>.sql.goog.`。如果 VPC 中已存在此类区域（例如用于其他 Cloud SQL PSC 实例），请设置 `psc_existing_dns_zone_name`。
- **`DMS_MANAGED_CLOUDSQL` 模式：** 上述在线测试未覆盖此模式。在场景 2 中，您必须自行为 DMS 创建的实例的服务账号授予存储桶读取权限。
