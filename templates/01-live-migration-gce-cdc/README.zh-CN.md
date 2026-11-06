# 场景 1：从 Compute Engine 上的自管理 MySQL 8.0 在线迁移 + 持续 CDC

[English](README.md) | **简体中文**

## 概览

此根 Terraform 模板使用 **Database Migration Service (DMS)** 部署端到端的 **在线初始转储 + 持续变更数据捕获（CDC）** 流水线，将 **Compute Engine 上的自管理 MySQL 8.0** 迁移至 **Cloud SQL for MySQL（默认 `MYSQL_8_4`，或 `MYSQL_8_0`）**，切换窗口较短。默认区域：`europe-west2`。

### 关键架构要点

- **灵活的目标版本（`MYSQL_8_4` 或 `MYSQL_8_0`）**：默认使用 `MYSQL_8_4`（启用 Data Cache 的 Enterprise Plus），同时支持 `MYSQL_8_0`。
- **默认使用 Private Service Connect (PSC)**：创建 Compute Engine **Network Attachment**，并将其挂接到仅使用 PSC 的 Cloud SQL 实例（PSC 接口，`psc_config.network_attachment_uri`），使 DMS 能够访问您 VPC 中的源端。Private Services Access（`PSA`）为可选项。
- **提升后的应用访问**：为实例 DNS 名称创建 **PSC 使用方端点**（内部 IP + 转发规则）和 **私有 Cloud DNS 记录**（`create_psc_endpoint = true`）。
- **命令行中不出现密码**：DMS 连接配置文件和迁移作业均为原生 Terraform 资源。Cloud SQL root 密码通过 `google_sql_user` 的只写参数 `password_wo` 设置在 `root@'%'` 上，不会存储在状态中。
- **收紧的复制路径**：Network Attachment 使用 `ACCEPT_MANUAL`，仅接受 Cloud SQL 租户项目，该项目在同一次 apply 中从实例推导得出。一条防火墙规则（已开启日志）仅允许来自 Network Attachment 子网（`network_attachment_subnet`）的 `tcp:source_gce_mysql_port` 流量访问源虚拟机（`source_target_tags` 或 `source_target_service_accounts`）。DMS 通过 TLS 连接（`source_ssl_type = "REQUIRED"`），Cloud SQL 仅接受加密连接（`cloudsql_ssl_mode = "ENCRYPTED_ONLY"`）。请参阅 [docs/security_hardening.zh-CN.md](../../docs/security_hardening.zh-CN.md)。
- **由 DMS 管理的初始加载（`dump_parallel_level = "OPTIMAL"`）**：DMS 从在线源端执行并行逻辑转储，然后切换为基于 GTID 的持续 binlog 复制（`type = "CONTINUOUS"`）。`OPTIMAL` 是 DMS 的推荐值；`MAX` 会增加源端负载。

---

## 架构流程

```mermaid
flowchart LR
    subgraph GCE_VPC["客户 VPC"]
        GCE["Compute Engine 虚拟机：自管理 MySQL 8.0<br/>(GTID=ON, ROW binlog)"]
        NA["PSC Network Attachment<br/>（ACCEPT_MANUAL，专用子网）"]
        FW["防火墙规则<br/>（NA 子网至 tcp:3306，已记录日志）"]
        EP["PSC 端点 + 私有 DNS"]
    end

    subgraph DMS_Control["Database Migration Service"]
        JOB["DMS 迁移作业<br/>（CONTINUOUS：OPTIMAL 并行转储 + CDC<br/>+ demote-destination）"]
    end

    subgraph CloudSQL_Producer["Cloud SQL 提供方 VPC"]
        CSQL["Cloud SQL for MySQL 8.4 / 8.0<br/>（仅 PSC + network_attachment_uri）"]
    end

    CSQL -->|"PSC 接口：network_attachment_uri"| NA
    NA --> FW
    FW -->|"TLS（source_ssl_type），端口 3306"| GCE
    GCE -->|"步骤 1：并行逻辑转储<br/>步骤 2：持续 binlog CDC"| CSQL
    JOB -->|"编排转储、降级与 CDC"| CSQL
    EP -->|"提升后供应用访问"| CSQL
```

---

## 使用说明

请先完成[前提条件](../../README.zh-CN.md#3-前提条件)以及[运维手册第 2 节](../../docs/gce_mysql80_to_cloudsql_dms_migration_runbook.zh-CN.md)中的源端准备工作（`make preflight` 不得报告任何 FAIL）。顺序为：**apply → 用户、授权、DEFINER 与参数（运维手册第 5 节）→ verify → start**。

### 1. 配置变量

将 `terraform.tfvars.example` 复制为 `terraform.tfvars` 并填写您的环境值，包括供防火墙规则使用的 `network_attachment_subnet` 和 `source_target_tags`（或 `source_target_service_accounts`）。请通过环境变量传递密码（例如从 Secret Manager 读取），而不要将其写入磁盘，并将状态保存在远程后端中（[`backend.tf.example`](backend.tf.example)）：

```bash
cp terraform.tfvars.example terraform.tfvars
cp backend.tf.example backend.tf   # edit the bucket and KMS key
export TF_VAR_cloudsql_root_password="$(gcloud secrets versions access latest --secret=cloudsql-root-password)"
export TF_VAR_source_gce_mysql_password="$(gcloud secrets versions access latest --secret=dms-source-password)"
```

### 2. 初始化并验证

```bash
terraform init
terraform validate
```

### 3. 规划并应用

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

### 4. 验证并启动 DMS 迁移作业

在 Terraform 创建连接配置文件和迁移作业并完成目标实例降级、且已完成运维手册第 5 节之后执行。在 `start` 与 `promote` 之间不要运行 `terraform apply`：DMS 会更改目标实例的备份与恢复设置（运维手册第 6 节）。

```bash
# Verify pre-flight connectivity and MySQL 8.0 replication configuration
gcloud database-migration migration-jobs verify gce-live-mysql80-cdc \
  --region=europe-west2

# Start the live initial dump + continuous CDC replication
gcloud database-migration migration-jobs start gce-live-mysql80-cdc \
  --region=europe-west2
```

### 5. 切换 / 提升

使用 `make lag`（`max_replica_sec_lag`；设置了 `CLOUDSQL_INSTANCE` 时会回退到目标实例的 `replica_lag`）或在 Cloud Monitoring 中监控复制延迟。在切换窗口内，当复制延迟接近 `0` 时，停止源 MySQL 8.0 实例上的写入，完成 Go / No-Go 检查清单和回退决策（运维手册第 8 节），然后提升 Cloud SQL 目标实例：

```bash
gcloud database-migration migration-jobs promote gce-live-mysql80-cdc \
  --region=europe-west2
```

然后将应用指向 Terraform 输出 `psc_endpoint_dns_name`，并运行 `terraform plan`/`apply`（运维手册第 9.1 节）。如需清理与下线，请参阅运维手册第 10 节。

### 6. 下线迁移对象

提升之后，设置 `migration_enabled = false` 并执行 apply。Terraform 会删除 DMS 作业、连接配置文件、降级步骤、Network Attachment 和源端防火墙规则；Cloud SQL、PSC 端点和 DNS 会保留。分离 Network Attachment 会**重启实例**，因此请在维护窗口内执行（运维手册第 10.2 节）。

```bash
terraform plan -var migration_enabled=false -out=tfplan   # Review: Cloud SQL, endpoint and DNS are not destroyed
terraform apply tfplan
```
