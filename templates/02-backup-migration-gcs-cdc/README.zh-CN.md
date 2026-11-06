# 场景 2：基于 GCS 中的备份迁移（Percona XtraBackup / mysqldump）+ 持续 CDC

[English](README.md) | **简体中文**

## 概览

此根 Terraform 模板借助 **Google Cloud Database Migration Service (DMS)** 部署 **基于备份填充的持续变更数据捕获（CDC）** 迁移流水线，适用于将数 TB 级或对负载敏感的 **自管理 Compute Engine (GCE) 上的 MySQL 8.0** 工作负载迁移至 **Cloud SQL for MySQL（默认 `MYSQL_8_4` LTS 或 `MYSQL_8_0`）**。

### 为什么选择场景 2（GCS 中的备份 + CDC）？

- **生产主实例零初始转储负载**：无需针对正在运行的生产 GCE MySQL 8.0 主实例执行在线转储，而是从 GCE 虚拟机（或专用只读副本）将非阻塞的 **Percona XtraBackup (`PHYSICAL`)** 或 **`mysqldump` (`LOGICAL`)** 备份流式传输到区域级 **Cloud Storage (GCS)** 暂存存储桶。
- **快速导入数 TB 数据 + 自动恢复 GTID CDC**：Cloud DMS 直接从 `dump_path`（`gs://<bucket>/<object>`）为目标 Cloud SQL 实例填充初始数据，自动读取备份中内嵌的 GTID/binlog 坐标，并连接到在线运行的 GCE MySQL 8.0 源端，持续传输 **Binlog CDC** 变更，直至切换。
- **严格遵循 Terraform Schema（`dump_path` 与 `dump_flags`）**：强制执行 Google Terraform Provider 的要求，即在 `google_database_migration_service_migration_job` 上 `dump_path` 与 `dump_flags` 互斥。

---

## 架构流程

```mermaid
flowchart LR
    subgraph GCE_VPC["生产 VPC"]
        GCE["GCE 虚拟机：自管理 MySQL 8.0\n(GTID=ON, ROW Binlog)"]
        NA["PSC Network Attachment\n(dms-mysql-psc-na)"]
    end

    subgraph GCS_Stage["区域级 Cloud Storage"]
        GCS["GCS 暂存存储桶\n(Percona XtraBackup PHYSICAL\n或 mysqldump LOGICAL)"]
    end

    subgraph DMS_Control["Google Cloud DMS"]
        JOB["DMS 迁移作业\n(CONTINUOUS：GCS dump_path + CDC\n+ demote-destination)"]
    end

    subgraph CloudSQL_Producer["Cloud SQL 提供方 VPC"]
        CSQL["Cloud SQL for MySQL 8.4 / 8.0\n(纯 PSC + network_attachment_uri)"]
    end

    GCE -->|1. 流式传输非阻塞备份\nstream_xtrabackup_to_gcs.sh| GCS
    GCS -->|2. 恢复初始数据\n(dump_path)| CSQL
    CSQL -->|PSC 出站：network_attachment_uri| NA
    NA -->|内部路由（端口 3306）| GCE
    GCE -->|3. 基于 GTID 的持续 Binlog CDC| CSQL
    JOB -->|编排数据填充、降级与 CDC| CSQL
```

---

## 使用说明

### 1. 配置变量

将 `terraform.tfvars.example` 复制为 `terraform.tfvars`，并自定义您的项目、网络和备份路径设置：

```bash
cp terraform.tfvars.example terraform.tfvars
```

### 2. 初始化、验证并应用基础设施

```bash
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

### 3. 将 Percona XtraBackup 从 GCE MySQL 8.0 流式传输至 GCS

在源 GCE MySQL 8.0 虚拟机（或只读副本）上，运行随附的辅助脚本 `scripts/stream_xtrabackup_to_gcs.sh`，将热物理备份直接流式传输到已预配的 GCS 暂存存储桶：

```bash
export MYSQL_USER="dms_backup_user"
export MYSQL_PASSWORD="YOUR_SECURE_PASSWORD"
export BUCKET_NAME="prod-dms-mysql80-staging-sg"
export BACKUP_OBJECT_PATH="backups/mysql80-full.xbstream"

./scripts/stream_xtrabackup_to_gcs.sh
```

### 4. 验证并启动 DMS 备份 + CDC 迁移作业

当备份文件已存在于 `gs://${BUCKET_NAME}/${BACKUP_OBJECT_PATH}` 后：

```bash
# Verify connection profiles, GCS permissions, and GTID replication topology
gcloud database-migration migration-jobs verify gcs-bkp-mysql80-cdc \
  --region=asia-southeast1

# Start the migration job (restores from GCS dump_path, then enters continuous CDC)
gcloud database-migration migration-jobs start gcs-bkp-mysql80-cdc \
  --region=asia-southeast1
```

### 5. 切换 / 提升

在计划的维护窗口内，当 CDC 延迟降至 `0 seconds` 时，停止应用对 GCE MySQL 8.0 的写入，并提升 Cloud SQL：

```bash
gcloud database-migration migration-jobs promote gcs-bkp-mysql80-cdc \
  --region=asia-southeast1
```
