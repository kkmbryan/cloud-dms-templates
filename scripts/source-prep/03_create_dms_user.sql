-- ==============================================================================
-- Migration accounts on the MySQL 8.0 source (runbook section 2.2)
-- ==============================================================================
-- Run as an administrative user in an interactive session, for example:
--   mysql --defaults-extra-file=/root/.mysql-admin.cnf
--   mysql> SET @dms_password = '...';         -- 1 to 32 characters
--   mysql> SET @xtrabackup_password = '...';  -- Scenario 2 PHYSICAL only
--   mysql> SOURCE 03_create_dms_user.sql
--
-- Set the passwords interactively so they don't land in this file or in shell
-- history. The same DMS password goes to Terraform as
-- TF_VAR_source_gce_mysql_password; the user name is source_gce_mysql_username.
--
-- The file grants the Scenario 1 privileges by default. For Scenario 2, comment
-- out the Scenario 1 GRANT and uncomment the Scenario 2 GRANT.
--
-- The xtrabackup user is created only when @xtrabackup_password is set.
--
-- No FLUSH PRIVILEGES is needed: CREATE USER and GRANT update the grant
-- tables and the in-memory privilege cache.
-- ==============================================================================

-- Guard: if @dms_password is unset, empty or longer than 32 characters, @stmt
-- below is NULL and PREPARE fails, so the user isn't created (and the GRANT
-- that follows fails because the user doesn't exist).
SELECT IF(@dms_password IS NULL OR @dms_password = '' OR CHAR_LENGTH(@dms_password) > 32,
          'ERROR: SET @dms_password (1-32 characters) before you SOURCE this file',
          'OK: @dms_password is set') AS dms_password_check;

-- ------------------------------------------------------------------------------
-- 1) DMS migration user. DMS requires host '%' and a password of 32 characters
--    or fewer.
-- ------------------------------------------------------------------------------
-- CREATE USER can't take a user variable, so build the statement dynamically.
SET @stmt = IF(@dms_password IS NULL OR @dms_password = '' OR CHAR_LENGTH(@dms_password) > 32,
               NULL,
               CONCAT('CREATE USER IF NOT EXISTS ''dms_migration''@''%'' IDENTIFIED BY ',
                      QUOTE(@dms_password)));
PREPARE create_dms_user FROM @stmt;
EXECUTE create_dms_user;
DEALLOCATE PREPARE create_dms_user;
SET @stmt = NULL;

-- Optional: require TLS for this account. DMS connects with TLS when the
-- Terraform variable source_ssl_type is REQUIRED (default), SERVER_ONLY or
-- SERVER_CLIENT. Alternatively enforce TLS for every account with
-- SET PERSIST require_secure_transport = ON; preflight_check.sh reports both.
-- ALTER USER 'dms_migration'@'%' REQUIRE SSL;
--
-- Host: keep '%'. The DMS "Configure your source database" doc creates the
-- migration user with host '%', so these scripts follow it. Restrict where
-- connections can come from with the VPC firewall instead: the templates allow
-- tcp:3306 only from the Network Attachment subnet (create_source_firewall_rule).

-- Scenario 1 (DMS-managed dump):
--   Required by DMS: REPLICATION SLAVE, REPLICATION CLIENT, EXECUTE, SELECT,
--                    SHOW VIEW, TRIGGER, RELOAD.
--   Recommended extra (events / parallel dump): EVENT, LOCK TABLES.
--   preflight_check.sh FAILs on a missing required privilege and WARNs on a
--   missing recommended extra.
GRANT REPLICATION SLAVE, REPLICATION CLIENT, EXECUTE, SELECT, SHOW VIEW, TRIGGER, EVENT, RELOAD, LOCK TABLES
  ON *.* TO 'dms_migration'@'%';

-- Scenario 2 (you provide the seed): CDC privileges only.
-- GRANT REPLICATION SLAVE, REPLICATION CLIENT, EXECUTE ON *.* TO 'dms_migration'@'%';

-- Do NOT grant BACKUP_ADMIN to dms_migration: DMS rejects a migration account
-- with BACKUP_ADMIN on MySQL 8.0 and later.

-- ------------------------------------------------------------------------------
-- 2) XtraBackup user (Scenario 2 PHYSICAL only), local connections only.
--    Every statement below is a no-op (DO 0) when @xtrabackup_password is unset.
-- ------------------------------------------------------------------------------
SET @xb = (@xtrabackup_password IS NOT NULL AND @xtrabackup_password <> '');

SET @stmt = IF(@xb, CONCAT('CREATE USER IF NOT EXISTS ''xtrabackup''@''localhost'' IDENTIFIED BY ',
                           QUOTE(@xtrabackup_password)), 'DO 0');
PREPARE xb FROM @stmt; EXECUTE xb; DEALLOCATE PREPARE xb;

-- GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'xtrabackup'@'localhost';
SET @stmt = IF(@xb, 'GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO ''xtrabackup''@''localhost''', 'DO 0');
PREPARE xb FROM @stmt; EXECUTE xb; DEALLOCATE PREPARE xb;

-- GRANT SELECT ON performance_schema.log_status TO 'xtrabackup'@'localhost';
SET @stmt = IF(@xb, 'GRANT SELECT ON performance_schema.log_status TO ''xtrabackup''@''localhost''', 'DO 0');
PREPARE xb FROM @stmt; EXECUTE xb; DEALLOCATE PREPARE xb;

-- GRANT SELECT ON performance_schema.keyring_component_status TO 'xtrabackup'@'localhost';
SET @stmt = IF(@xb, 'GRANT SELECT ON performance_schema.keyring_component_status TO ''xtrabackup''@''localhost''', 'DO 0');
PREPARE xb FROM @stmt; EXECUTE xb; DEALLOCATE PREPARE xb;

-- ------------------------------------------------------------------------------
-- 3) Clear the variables and review the result.
-- ------------------------------------------------------------------------------
SET @stmt = NULL, @xb = NULL, @dms_password = NULL, @xtrabackup_password = NULL;
SHOW GRANTS FOR 'dms_migration'@'%';
-- Scenario 2 PHYSICAL only:
-- SHOW GRANTS FOR 'xtrabackup'@'localhost';
