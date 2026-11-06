# Source Preparation: MySQL 8.0 on Compute Engine for Database Migration Service

**English** | [简体中文](README.zh-CN.md)

Files to prepare and check the self-managed MySQL 8.0 source before you run `verify` and `start` on the Database Migration Service (DMS) migration job. They implement [runbook section 2](../../docs/gce_mysql80_to_cloudsql_dms_migration_runbook.md#2-phase-1-source-mysql-80-pre-flight-verification).

| File | Purpose | Run on |
| :--- | :--- | :--- |
| `01_mysqld_dms_source.cnf` | `my.cnf` drop-in: `server_id`, `bind_address`, ROW binlog, `binlog_row_image=FULL`, GTID, binlog retention | Source VM (needs a restart) |
| `02_enable_gtid_online.sql` | Enable GTIDs online, step by step, without a restart | Source VM, interactive `mysql` session |
| `03_create_dms_user.sql` | `dms_migration@'%'` (DMS) and `xtrabackup@'localhost'` (Scenario 2 `PHYSICAL` only) | Source VM, administrative account |
| `preflight_check.sh` | Read-only checks with a PASS / WARN / FAIL table | Source VM, or any host that can reach the source on port 3306 |

---

## 1. Order of Operations

1. Apply `01_mysqld_dms_source.cnf` and restart mysqld, **or** run `02_enable_gtid_online.sql` step by step if the binlog is already on and you can't restart.
2. Size the binlog retention: `binlog_expire_logs_seconds` must be at least the total seed time (dump + upload + restore) plus a buffer, and never less than 7 days (`604800`). If the binlogs after the seed's GTID position are purged before CDC starts, the job fails and you must take a new seed.
3. Create the accounts with `03_create_dms_user.sql`.
4. Run `preflight_check.sh` (or `make preflight`) until it reports no FAIL. Review every WARN.
5. Scenario 2: after the seed is taken, run the check again with `--backup-gtid`.

---

## 2. Configure Binlog and GTID

Copy the drop-in and restart mysqld during a maintenance window. Ubuntu and Debian packages set `bind-address = 127.0.0.1` in `mysqld.cnf`; the drop-in sets `bind_address = 0.0.0.0` and must sort after `mysqld.cnf` (hence `zz-`). Restrict TCP port 3306 with VPC firewall rules to the PSC Network Attachment subnet:

```bash
sudo cp scripts/source-prep/01_mysqld_dms_source.cnf /etc/mysql/mysql.conf.d/zz-dms-source.cnf
sudo systemctl restart mysql
```

Without a restart, follow [Enabling GTID Transactions Online](https://dev.mysql.com/doc/refman/8.0/en/replication-mode-change-online-enable-gtids.html) with `02_enable_gtid_online.sql`. Run it one step at a time in an interactive session; don't pipe the whole file into `mysql`:

1. `SET PERSIST enforce_gtid_consistency = WARN`, then watch the error log under normal load and fix every GTID-unsafe statement.
2. `SET PERSIST enforce_gtid_consistency = ON`.
3. `SET PERSIST gtid_mode = OFF_PERMISSIVE`.
4. `SET PERSIST gtid_mode = ON_PERMISSIVE`.
5. Wait until `SHOW GLOBAL STATUS LIKE 'Ongoing_anonymous_transaction_count'` returns `0`.
6. `SET PERSIST gtid_mode = ON`.

> [!IMPORTANT]
> DMS accepts only `gtid_mode` `ON` or `OFF`. A source left in `OFF_PERMISSIVE` or `ON_PERMISSIVE` fails `verify`, and `preflight_check.sh` reports it as FAIL.

---

## 3. Create the Migration Accounts

Set the passwords as session variables so they don't appear in the file or in shell history, then source the file:

```sql
-- mysql --defaults-extra-file=/root/.mysql-admin.cnf
SET @dms_password = 'REPLACE_ME_MAX_32_CHARS';
SET @xtrabackup_password = 'REPLACE_WITH_SECURE_PASSWORD';  -- Scenario 2 PHYSICAL only
SOURCE scripts/source-prep/03_create_dms_user.sql
```

The file grants the Scenario 1 privileges: the set required by DMS (`REPLICATION SLAVE`, `REPLICATION CLIENT`, `EXECUTE`, `SELECT`, `SHOW VIEW`, `TRIGGER`, `RELOAD`) plus the recommended extra `EVENT` and `LOCK TABLES` (events / parallel dump). For Scenario 2, comment out the Scenario 1 `GRANT` and uncomment the Scenario 2 `GRANT` first. The `xtrabackup` user is created only when `@xtrabackup_password` is set. Don't grant `BACKUP_ADMIN` to `dms_migration`, and you don't need `FLUSH PRIVILEGES`.

To require TLS for the migration account, uncomment `ALTER USER 'dms_migration'@'%' REQUIRE SSL;` in the file, or enforce TLS for all accounts with `SET PERSIST require_secure_transport = ON;`. The host stays `'%'` because the DMS documentation creates the user that way; the template's firewall rule limits port 3306 to the Network Attachment subnet instead.

---

## 4. Run the Pre-Flight Check

Create a MySQL option file for an administrative account (the check reads `mysql.user`, `SHOW GRANTS` and `information_schema`). The script reads credentials only from this file and refuses a password on the command line or a file that isn't mode `0600` or `0400`:

```bash
cat > ~/.my-dms.cnf <<'EOF'
[client]
user=root
password=REPLACE_ME
EOF
chmod 600 ~/.my-dms.cnf
```

Run the check on the source VM:

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

For a mysqldump seed, the GTID set is the `SET @@GLOBAL.GTID_PURGED` value at the top of the dump file. For an XtraBackup seed, it's in `xtrabackup_binlog_info`.

| Option | `make` variable | Default | Meaning |
| :--- | :--- | :--- | :--- |
| `--defaults-extra-file F` | `MYSQL_DEFAULTS_FILE` | `$MYSQL_DEFAULTS_FILE` (`make`: `~/.my-dms.cnf`) | Option file with `[client]` user and password, mode `0600` or `0400` |
| `--host`, `--port`, `--socket` | `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_SOCKET` | Client defaults | Connection to the source |
| `--scenario 1\|2` | `SCENARIO` | `1` | Privilege set expected for the DMS user |
| `--dms-user U` | `DMS_USER` | `dms_migration` | DMS user, host `'%'` |
| `--seed-hours N` | `SEED_HOURS` | `24` | Total seed time (dump + upload + restore) for the retention check |
| `--backup-gtid SET` | `BACKUP_GTID` | Not set | GTID set of the seed; FAIL unless `GTID_SUBSET(@@GLOBAL.gtid_purged, SET) = 1` |

Exit codes: `0` no FAIL (WARNs allowed), `1` at least one FAIL, `2` usage, option file or connection error.

### 4.1 Checks

| Check | FAIL when | WARN when |
| :--- | :--- | :--- |
| `version` | — | The server isn't MySQL 8.0 |
| `server_id` | `server_id` is `0` | — |
| `log_bin` | The binary log is off | — |
| `bind_address` | — | Loopback only (`127.0.0.1`, `localhost`, `::1`): DMS can't connect over TCP |
| `binlog_format` | Not `ROW` | — |
| `binlog_row_image` | Not `FULL` | — |
| `gtid_mode` | Not `ON` (`OFF_PERMISSIVE` and `ON_PERMISSIVE` included) | — |
| `enforce_gtid_consistency` | Not `ON` | — |
| `binlog_retention` | Retention < seed time (`binlog_expire_logs_seconds`, or `expire_logs_days` × 86400 when the former is `0`) | < seed time + 24 h buffer, or < 7 days |
| `dms_user_grants` | User `'<dms-user>'@'%'` missing, a required scenario privilege missing, or `BACKUP_ADMIN` present | `ALL PRIVILEGES` granted, or Scenario 1 recommended extra `EVENT` / `LOCK TABLES` missing |
| `tls` | — | TLS isn't available (`have_ssl` not `YES`; Terraform's default `source_ssl_type = "REQUIRED"` then fails `verify`), or TLS is available but not enforced (`require_secure_transport = OFF` and the DMS user has no `REQUIRE SSL`) |
| `non_innodb_tables` | — | User tables that aren't InnoDB |
| `primary_keys` | — | User tables without a primary key or a unique `NOT NULL` key |
| `definers` | — | Events, routines, triggers or views whose DEFINER doesn't exist or is `root@localhost` |
| `system_schema_refs` | — | Views, routines, triggers or events that reference `mysql`, `sys`, `performance_schema` or `information_schema` |
| `lower_case_table_names` | Value other than `0` or `1` | Value `1`: set Terraform `cloudsql_lower_case_table_names = 1` before the instance is created (it can't be changed later) |
| `character_set/collation` | — | Not `utf8mb4` / `utf8mb4_0900_ai_ci`: set the Cloud SQL flags to match |
| `sql_mode` | — | Differs from the MySQL 8.0 default: set the Cloud SQL flag to match |
| `time_zone` | — | Not UTC: set the Cloud SQL flag `default_time_zone` to match |
| `innodb_page_size` | Not `16384` | — |
| `user_db_size` | — | — (reported only; compare with the runbook decision matrix) |
| `backup_gtid` | `GTID_SUBSET(@@GLOBAL.gtid_purged, '<set>')` isn't `1` | — |

The script runs only `SELECT` and `SHOW` statements in a read-only session. It prints the full lists (tables, DEFINERs, objects) under `Details:` after the table.

---

## 5. Monitor Replication Lag and Validate Data

After `start`, `make lag` reads `datamigration.googleapis.com/migration_job/max_replica_sec_lag` for the job. If that metric returns no data and `CLOUDSQL_INSTANCE` is set, it falls back to `cloudsql.googleapis.com/database/replication/replica_lag` for the destination instance (`database_id = PROJECT_ID:CLOUDSQL_INSTANCE`) and prints which metric it used. In testing, the DMS metric returned no data during the first minutes of CDC while the Cloud SQL metric did. Metrics can take several minutes to appear. The target calls the Cloud Monitoring API (`projects.timeSeries.list`) with `curl`, and passes the `gcloud` access token on standard input, not on the command line:

```bash
make lag PROJECT_ID=my-gcp-project-01 REGION=europe-west2 JOB_ID=gce-live-mysql80-cdc LAG_MINUTES=30

# With the Cloud SQL replica lag fallback
make lag PROJECT_ID=my-gcp-project-01 REGION=europe-west2 JOB_ID=gce-live-mysql80-cdc \
  CLOUDSQL_INSTANCE="$(terraform -chdir=templates/01-live-migration-gce-cdc output -raw cloudsql_instance_name)"
```

Optionally, compare row counts between the source and the Cloud SQL destination with the open-source [Data Validation Tool](https://github.com/GoogleCloudPlatform/professional-services-data-validator) (DVT). DVT isn't required by the templates. Install it in a virtual environment on a host that can reach both databases, and store the database passwords in Secret Manager instead of on the command line. With `--secret-manager-type GCP`, `--password` is a secret name; host, port and user are literal values (DVT uses the literal value when no secret with that name exists):

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

During CDC, counts can differ for tables that are being written; run the final comparison after the source is read-only at cutover.
