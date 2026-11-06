# Compute Engine 上的 MySQL 8.0 迁移至 Cloud SQL for MySQL（8.0 / 8.4）— Database Migration Service Terraform 模板

[English](README.md) | **简体中文**

模块化的 Terraform 配置，借助 **Database Migration Service (DMS)** 持续迁移（初始数据填充 + binlog CDC），将自管理的 **Compute Engine 上的 MySQL 8.0** 迁移至 **Cloud SQL for MySQL（`MYSQL_8_0` 或 `MYSQL_8_4`，Enterprise Plus）**，并在较短的切换窗口内完成切换。

> [!NOTE]
> 本项目不是 Google 官方支持的产品。模板依据 [Apache 2.0 许可证](LICENSE)按“原样”提供，不附带任何形式的保证。在生产环境中使用之前，请先在非生产项目中测试，并根据您自己的要求进行验证。已测试的内容请参阅 [TESTING.zh-CN.md](TESTING.zh-CN.md)。

---

## 1. 架构概览与关键设计决策

| 架构维度 | 设计决策 | 工程依据 |
| :--- | :--- | :--- |
| **目标数据库版本** | `MYSQL_8_4`（默认）或 `MYSQL_8_0` | DMS 支持将 MySQL 8.0 源迁移至 Cloud SQL 8.0 和 8.4 目标实例。物理（XtraBackup）初始数据仅支持 `MYSQL_8_0` 目标（请参阅第 2 节中的支持矩阵）。 |
| **网络连接** | 默认使用 **Private Service Connect (`PSC`)**（可选 `PSA`） | Cloud SQL 实例仅使用 PSC（无公共 IP）。复制方面，会将 Compute Engine Network Attachment 挂接到实例（`psc_config.network_attachment_uri`，PSC 接口），使 DMS 能够访问您 VPC 中的源端。应用方面，模板会创建 PSC 使用方端点（内部 IP + 转发规则），并为实例 DNS 名称创建私有 Cloud DNS 记录。 |
| **目标版本类型与高可用** | Cloud SQL **Enterprise Plus**（`REGIONAL` 高可用 + Data Cache） | 区域级高可用、Data Cache（`data_cache_enabled = true`）、基于二进制日志的时间点恢复以及自动备份。 |
| **切换策略** | 持续复制（`type = "CONTINUOUS"`） | 两个模板在初始数据填充完成后均持续复制基于 GTID 的二进制日志变更，便于您验证目标实例，并在较短的维护窗口内完成提升。 |
| **网络安全** | `ACCEPT_MANUAL` Network Attachment + 源端防火墙规则 | Network Attachment 仅接受 Cloud SQL 租户项目，该项目在同一次 apply 中从实例推导得出（`ACCEPT_AUTOMATIC` 为可选项）。一条防火墙规则（已开启日志）仅允许 Network Attachment 子网访问源端 MySQL 端口。请参阅 [docs/security_hardening.zh-CN.md](docs/security_hardening.zh-CN.md)。 |
| **传输加密** | `source_ssl_type = "REQUIRED"`、`cloudsql_ssl_mode = "ENCRYPTED_ONLY"` | DMS 通过 TLS 从源端复制数据，Cloud SQL 仅接受加密的客户端连接。CMEK（`cloudsql_kms_key_name`、`staging_bucket_kms_key_name`）为可选项。 |
| **生命周期** | `migration_enabled = true` → 切换后设为 `false` | 设为 `false` 后会下线 DMS 作业、连接配置文件、Network Attachment 和防火墙规则，并保留 Cloud SQL、PSC 端点和 DNS（运维手册第 10.2 节）。 |

```mermaid
flowchart LR
  subgraph APP_VPC["客户 VPC（europe-west2）"]
    GCE["MySQL 8.0 源虚拟机<br/>(GTID=ON, ROW binlog)"]
    NA["PSC Network Attachment<br/>（ACCEPT_MANUAL，专用子网）"]
    FW["防火墙规则<br/>（NA 子网至 tcp:3306）"]
    EP["PSC 端点 + 私有 DNS<br/>（应用）"]
    APP["应用"]
  end

  subgraph GCS_STAGE["Cloud Storage（场景 2）"]
    GCS["暂存存储桶<br/>（mysqldump 文件或已准备的 XtraBackup 文件夹）"]
  end

  subgraph DMS_CONTROL["Database Migration Service"]
    JOB["DMS 迁移作业<br/>（CONTINUOUS：初始数据 + CDC）"]
  end

  subgraph CSQL_PRODUCER["Cloud SQL 提供方 VPC"]
    CSQL["Cloud SQL for MySQL 8.0 / 8.4<br/>（仅 PSC，无公共 IP）"]
  end

  CSQL -->|"PSC 接口：复制至端口 3306"| NA
  NA --> FW
  FW -->|"TLS（source_ssl_type）"| GCE
  GCE -->|"场景 2：上传初始数据"| GCS
  GCS -->|"场景 2：从 dump_path 填充"| CSQL
  JOB -->|"编排初始数据填充、降级与 CDC"| CSQL
  APP --> EP
  EP -->|"提升之后"| CSQL
```

---

## 2. 迁移场景

如需选择场景，请使用[运维手册第 1 节](docs/gce_mysql80_to_cloudsql_dms_migration_runbook.zh-CN.md)中的决策矩阵。如果目标为 8.4，另请阅读运维手册第 1.2 节中的 8.0 → 8.4 注意事项。

### 场景 1：从 Compute Engine 上的 MySQL 8.0 在线迁移 + 持续 CDC（`templates/01-live-migration-gce-cdc`）
- **适用场景：** 源虚拟机能够承受由 DMS 管理的并行逻辑转储（默认 `dump_parallel_level = "OPTIMAL"`）的数据库。
- **工作流程：**
  1. DMS 通过 PSC 接口（Network Attachment）以私有方式访问源 MySQL 8.0 实例。
  2. DMS 从源端执行并行逻辑全量转储（`dump_type = "LOGICAL"`），将数据导入 Cloud SQL（`MYSQL_8_4` 或 `MYSQL_8_0`）实例。
  3. 转储完成后，DMS 进入 **CDC 阶段**，持续重放变更，直至提升。

### 场景 2：基于 Cloud Storage 中的备份迁移 + 持续 CDC（`templates/02-backup-migration-gcs-cdc`）
- **适用场景：** 大型数据库，或对延迟敏感的生产工作负载，希望自行控制初始数据的生成时间与方式。
- **支持的初始数据格式（`dump_type`）：**
  - **`LOGICAL`（默认 — `mysqldump`）：** 上传到暂存存储桶的单个压缩 mysqldump 文件。`dump_path` 指向该文件。适用于 `MYSQL_8_0` 和 `MYSQL_8_4` 目标。
  - **`PHYSICAL`（Percona XtraBackup）：** 经过**准备**（先 `xtrabackup --backup`，再 `--prepare`）并上传到存储桶中**专用文件夹**的完整备份。`dump_path` 指向该文件夹。**仅支持 `MYSQL_8_0` 目标。** 请使用 [`scripts/xtrabackup_to_gcs.sh`](templates/02-backup-migration-gcs-cdc/scripts/xtrabackup_to_gcs.sh)。
- **自动配置存储桶 IAM：** Terraform 会在存储桶上为 DMS 服务代理和 Cloud SQL 实例服务账号授予 `roles/storage.objectViewer` 与 `roles/storage.legacyBucketReader`，并为 `backup_writer_members` 授予 `roles/storage.objectCreator` + `roles/storage.objectViewer`。 在 `DMS_MANAGED_CLOUDSQL` 模式下，实例由 DMS 在 apply 之后创建，因此请在 `verify` 之前自行为其服务账号授予这两个读取角色：`gcloud storage buckets add-iam-policy-binding gs://BUCKET --member=serviceAccount:INSTANCE_SA --role=roles/storage.objectViewer`（再使用 `roles/storage.legacyBucketReader` 重复执行一次）。
- **Terraform Provider 互斥防护：** 在 `google_database_migration_service_migration_job` 中，`dump_path` 与 `dump_flags` 互斥。设置 `dump_path`（场景 2）时，`modules/dms-migration-job` 会省略 `dump_flags` 和 `performance_config`。

### 支持矩阵

| 初始数据（`dump_type`） | 模板 | 目标 `MYSQL_8_0` | 目标 `MYSQL_8_4` | `dump_path` |
| :--- | :--- | :--- | :--- | :--- |
| 由 DMS 管理的逻辑转储（`LOGICAL`） | 01 | 支持 | 支持 | 不使用 |
| mysqldump 文件（`LOGICAL`，默认） | 02 | 支持 | 支持 | 单个文件：`gs://<bucket>/<path>.sql.gz` |
| 已准备的 Percona XtraBackup（`PHYSICAL`） | 02 | 支持 | **DMS 不支持**（Terraform 验证会拒绝） | 专用文件夹：`gs://<bucket>/<folder>` |

参考资料：[使用 Percona XtraBackup 物理文件迁移](https://cloud.google.com/database-migration/docs/mysql/migrate-with-physical-xtrabackup)、[已知限制](https://cloud.google.com/database-migration/docs/mysql/known-limitations)。

---

## 3. 前提条件

| 要求 | 详细信息 | 检查方式 |
| :--- | :--- | :--- |
| **工具** | Terraform `>= 1.11`（只写 root 密码）、Google Cloud CLI（`gcloud`）、Bash。`local-exec` 步骤（挂接与分离 Network Attachment、降级）会调用 `gcloud`。 | `terraform version`、`gcloud version` |
| **凭据** | 供 Terraform 使用的应用默认凭据（ADC），以及供 `local-exec` 步骤使用的有效 `gcloud` 账号，两者都需要具备下方的部署者角色。如需让两者使用同一身份，请设置 `impersonate_service_account`（提供程序会模拟该服务账号，`local-exec` 步骤会获得 `CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT`）；销毁时的分离步骤会沿用同一设置。 | `gcloud auth application-default login`、`gcloud auth list` |
| **API** | `datamigration`、`sqladmin`、`compute`、`servicenetworking`、`storage`、`dns`。 | 请参阅下方命令 |
| **DMS 服务代理** | 必须在首次 apply 之前存在（场景 2 会为其授予存储桶访问权限）。 | 请参阅下方命令 |
| **部署者角色** | 项目级的 `roles/datamigration.admin`、`roles/cloudsql.admin`、`roles/compute.networkAdmin`、`roles/compute.securityAdmin`（源端防火墙规则）、`roles/dns.admin`、`roles/storage.admin`（场景 2）以及 `roles/serviceusage.serviceUsageConsumer`。最小权限详情：[docs/security_hardening.zh-CN.md](docs/security_hardening.zh-CN.md)。 | `gcloud projects get-iam-policy PROJECT_ID` |
| **网络** | 供 Network Attachment 使用的专用小子网（`network_attachment_subnet`，例如 `/28`），以及供防火墙规则使用的源虚拟机网络标记或服务账号（`source_target_tags` 或 `source_target_service_accounts`）。 | `gcloud compute networks subnets list` |
| **组织政策** | 检查组织政策预检表中的约束条件（`sql.restrictPublicIp`、`gcp.restrictNonCmekServices`、`gcp.resourceLocations`、PSC 限制）。 | [docs/security_hardening.zh-CN.md](docs/security_hardening.zh-CN.md) |
| **状态与密钥凭据** | 启用版本控制和 CMEK 的远程 GCS 后端（各模板中的 `backend.tf.example`）；密码通过 `TF_VAR_*` 从 Secret Manager 读取。 | `gcloud secrets versions access latest --secret=...` |
| **源数据库** | [运维手册第 2 节](docs/gce_mysql80_to_cloudsql_dms_migration_runbook.zh-CN.md)中的 GTID 与 binlog 设置以及迁移账号，可使用 [`scripts/source-prep/`](scripts/source-prep/README.zh-CN.md) 完成准备。 | `make preflight`（在源虚拟机上） |

```bash
export PROJECT_ID="my-gcp-project-01"
gcloud config set project "${PROJECT_ID}"
gcloud auth application-default login

gcloud services enable datamigration.googleapis.com sqladmin.googleapis.com \
  compute.googleapis.com servicenetworking.googleapis.com \
  storage.googleapis.com dns.googleapis.com

# Create the DMS service agent (service-PROJECT_NUMBER@gcp-sa-datamigration.iam.gserviceaccount.com)
gcloud beta services identity create --service=datamigration.googleapis.com --project="${PROJECT_ID}"
```

---

## 4. 代码库结构

```text
cloud-dms-templates/
├── .github/
│   ├── CODEOWNERS
│   ├── ISSUE_TEMPLATE/                   # Bug report and feature request templates
│   ├── pull_request_template.md
│   └── workflows/
│       └── terraform-ci.yml              # Automated fmt & validate CI pipeline
├── .gitignore                            # Excludes state, .terraform, secrets
├── .pre-commit-config.yaml               # Pre-commit hooks (fmt, validate, tflint, checkov)
├── .tflint.hcl                           # TFLint Google ruleset configuration
├── CONTRIBUTING.md                       # Development gates, EN/zh-CN sync, customer-safe content
├── LICENSE                               # Apache License 2.0
├── SECURITY.md                           # Vulnerability reporting (GitHub private advisory)
├── Makefile                              # Day-1/Day-2 automation targets
├── README.md                             # Root architecture & usage documentation
├── README.zh-CN.md                       # Simplified Chinese (zh-CN) root documentation
├── TESTING.md                            # What has been tested, and known limitations
├── TESTING.zh-CN.md
├── docs/
│   ├── gce_mysql80_to_cloudsql_dms_migration_runbook.md
│   ├── gce_mysql80_to_cloudsql_dms_migration_runbook.zh-CN.md
│   ├── security_hardening.md             # Network, TLS, secrets, CMEK, org policy, IAM, audit logs
│   └── security_hardening.zh-CN.md
├── scripts/
│   └── source-prep/                      # Source MySQL 8.0 preparation (make preflight)
│       ├── 01_mysqld_dms_source.cnf      # my.cnf drop-in: server_id, ROW binlog, GTID, retention
│       ├── 02_enable_gtid_online.sql     # Step-by-step online GTID enablement
│       ├── 03_create_dms_user.sql        # DMS and XtraBackup accounts, per-scenario grants
│       ├── preflight_check.sh            # Read-only PASS/WARN/FAIL source check
│       ├── README.md
│       └── README.zh-CN.md
├── modules/
│   ├── networking-psc/                   # PSC Network Attachment (ACCEPT_MANUAL) + source firewall rule (or PSA peering)
│   ├── gcs-migration-staging/            # Staging bucket + reader/writer IAM
│   ├── cloudsql-mysql-destination/       # Cloud SQL MySQL 8.0 / 8.4 target + PSC interface
│   ├── cloudsql-psc-endpoint/            # PSC consumer endpoint + private DNS for applications
│   ├── dms-connection-profiles/          # Source and destination DMS connection profiles
│   └── dms-migration-job/                # Continuous DMS migration job + demote step
└── templates/
    ├── 01-live-migration-gce-cdc/        # Root Template 1: DMS-managed dump + CDC
    │   ├── .terraform.lock.hcl
    │   ├── backend.tf.example            # GCS remote state with versioning + CMEK
    │   ├── README.md
    │   └── README.zh-CN.md
    └── 02-backup-migration-gcs-cdc/      # Root Template 2: seed from Cloud Storage + CDC
        ├── .terraform.lock.hcl
        ├── backend.tf.example
        ├── README.md
        ├── README.zh-CN.md
        └── scripts/
            └── xtrabackup_to_gcs.sh
```

---

## 5. 快速入门与运维命令

所有场景都遵循相同的顺序：**预检 → apply → 生成初始数据并再次 apply（仅场景 2）→ 用户、授权、DEFINER 与参数 → verify → start → promote**。在 `start` 与 `promote` 之间不要运行 `terraform apply`（运维手册第 6 节）。

### 在本地验证所有模板
```bash
make fmt-check
make validate
```

### 部署场景 1（在线迁移 + CDC）
```bash
cd templates/01-live-migration-gce-cdc
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: project_id, network, subnets (incl. network_attachment_subnet),
# source IP and source_target_tags (firewall rule)
cp backend.tf.example backend.tf   # optional but recommended: remote state (edit bucket/key)
export TF_VAR_cloudsql_root_password="$(gcloud secrets versions access latest --secret=cloudsql-root-password)"
export TF_VAR_source_gce_mysql_password="$(gcloud secrets versions access latest --secret=dms-source-password)"
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### 部署场景 2（从 Cloud Storage 填充初始数据 + CDC）
```bash
# 1. Phase 1: provision the bucket (with IAM), Cloud SQL, PSC endpoint and profiles.
#    DMS checks dump_path when the job is created, so the job comes in phase 2.
cd templates/02-backup-migration-gcs-cdc
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: dump_type and backup_gcs_path (see the support matrix)
export TF_VAR_cloudsql_root_password='REPLACE_ME'
export TF_VAR_source_gce_mysql_password='REPLACE_ME_MAX_32_CHARS'
terraform init
terraform plan -var create_migration_job=false -out=tfplan
terraform apply tfplan

# 2. The one seed location used everywhere
terraform output -raw configured_dump_path

# 3. On the source VM, write the seed to exactly that location:
#    LOGICAL  -> mysqldump ... | gzip | gcloud storage cp - "<configured_dump_path>"
#    PHYSICAL -> GCS_BACKUP_FOLDER="<configured_dump_path>" ./scripts/xtrabackup_to_gcs.sh
#    (full commands: runbook section 4, Option B)

# 4. Phase 2: create the migration job and demote the destination
terraform plan -out=tfplan
terraform apply tfplan
```

### 第 2 天：DMS 作业验证、监控与切换提升
```bash
# Scenario 1 job ID: gce-live-mysql80-cdc. Scenario 2 job ID: gcs-bkp-mysql80-cdc.
# Verify source/destination connectivity, GTID/binlog settings and (Scenario 2) bucket access
make verify-job PROJECT_ID=my-gcp-project-01 REGION=europe-west2 JOB_ID=gce-live-mysql80-cdc

# Start the migration job
make start-job PROJECT_ID=my-gcp-project-01 REGION=europe-west2 JOB_ID=gce-live-mysql80-cdc

# Monitor the job state and phase (FULL_DUMP -> CDC). Replication lag is in Cloud Monitoring:
# datamigration.googleapis.com/migration_job/max_replica_sec_lag; make lag falls back to the
# destination's cloudsql.googleapis.com/database/replication/replica_lag when CLOUDSQL_INSTANCE is set
make status-job PROJECT_ID=my-gcp-project-01 REGION=europe-west2 JOB_ID=gce-live-mysql80-cdc
make lag PROJECT_ID=my-gcp-project-01 REGION=europe-west2 JOB_ID=gce-live-mysql80-cdc LAG_MINUTES=30 CLOUDSQL_INSTANCE=<cloudsql_instance_name>

# Promote the Cloud SQL destination during the cutover window
make promote-job PROJECT_ID=my-gcp-project-01 REGION=europe-west2 JOB_ID=gce-live-mysql80-cdc
```

提升之前，请完成运维手册第 8 节中的 Go / No-Go 检查清单和回退决策。提升之后，应用连接到 `terraform output -raw psc_endpoint_dns_name`（即实例 DNS 名称，由私有区域解析为 PSC 端点 IP），并使用 TLS；然后运行 `terraform plan`/`apply`（运维手册第 9.1 节）。如需下线迁移对象并保留 Cloud SQL，请设置 `migration_enabled = false` 并执行 apply（运维手册第 10.2 节；分离 Network Attachment 会重启实例）。


### 从早期版本升级

对使用早期版本模板创建的栈执行 apply 之前，请先检查 `terraform plan`：

- **防火墙规则：** `create_source_firewall_rule = true` 为默认值，需要设置 `source_target_tags` 或 `source_target_service_accounts`，否则 plan 会因前置条件失败。如果您已自行管理等效规则，请设置 `create_source_firewall_rule = false`。
- **Network Attachment：** `psc_connection_preference` 现在默认为 `ACCEPT_MANUAL`，并已移除 `dms_tenant_project_id`。plan 会原地更新现有挂接（接受列表 = Cloud SQL 租户项目），不会替换它。
- **状态地址：** `moved` 块会把 DMS 连接配置文件和作业映射到新的 `[0]` 地址，挂接和降级步骤会原地更新，因此不会替换或重新运行任何资源。
- **迁移窗口：** 提升之前，不要对已降级的目标实例执行 apply（运维手册第 6 节）。

---

## 6. 测试、支持与许可

- [TESTING.zh-CN.md](TESTING.zh-CN.md) 列出了已测试的版本和场景以及已知限制。
- [docs/security_hardening.zh-CN.md](docs/security_hardening.zh-CN.md) 介绍了网络控制、TLS、密钥凭据与状态、CMEK、组织政策、部署者 IAM 以及审核日志。
- 请按照 [SECURITY.md](SECURITY.md) 中的说明报告安全漏洞。贡献规则：[CONTRIBUTING.md](CONTRIBUTING.md)。
- 本项目不是 Google 官方支持的产品，不提供支持或 SLA。
- 依据 [Apache License 2.0](LICENSE) 授权。
