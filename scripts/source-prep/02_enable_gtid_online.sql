-- ==============================================================================
-- Enable GTIDs online on a running MySQL 8.0 source (no restart)
-- ==============================================================================
-- Procedure: https://dev.mysql.com/doc/refman/8.0/en/replication-mode-change-online-enable-gtids.html
--
-- DMS accepts only gtid_mode = ON or OFF; a source left in OFF_PERMISSIVE or
-- ON_PERMISSIVE fails `verify`. For continuous (CDC) migrations, finish at ON.
--
-- RUN THIS FILE STEP BY STEP in an interactive mysql session as an account with
-- SYSTEM_VARIABLES_ADMIN (or SUPER). Do NOT pipe the whole file into mysql:
-- step 1 requires you to watch the error log under production load before you
-- continue, and step 5 requires you to wait.
--
-- If the source has existing replicas, run each step on EVERY server in the
-- topology. Complete each step on all servers before you start the next step.
--
-- SET PERSIST writes each value to mysqld-auto.cnf, so the state survives a
-- restart at any point. Persisted values take precedence over my.cnf; keep
-- 01_mysqld_dms_source.cnf consistent with the final state.
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- Step 0: Check the starting state. Expected: gtid_mode = OFF, log_bin = 1.
-- ------------------------------------------------------------------------------
SELECT @@GLOBAL.gtid_mode, @@GLOBAL.enforce_gtid_consistency, @@GLOBAL.log_bin,
       @@GLOBAL.binlog_format, @@GLOBAL.server_id;

-- ------------------------------------------------------------------------------
-- Step 1: Warn about GTID-unsafe statements.
-- ------------------------------------------------------------------------------
SET PERSIST enforce_gtid_consistency = WARN;

-- Let the normal application workload run (cover batch jobs and peak hours),
-- then check the MySQL error log for GTID consistency warnings, for example:
--   sudo grep -i 'gtid' /var/log/mysql/error.log
-- Typical causes: CREATE TABLE ... SELECT, CREATE/DROP TEMPORARY TABLE inside a
-- transaction, or mixing transactional and non-transactional (e.g. MyISAM)
-- tables in one transaction. Fix the application before you continue.
-- Do NOT continue while new warnings appear.

-- ------------------------------------------------------------------------------
-- Step 2: Enforce GTID consistency (GTID-unsafe statements now fail).
-- ------------------------------------------------------------------------------
SET PERSIST enforce_gtid_consistency = ON;

-- ------------------------------------------------------------------------------
-- Step 3: New transactions stay anonymous; replicated transactions may be
-- anonymous or GTID.
-- ------------------------------------------------------------------------------
SET PERSIST gtid_mode = OFF_PERMISSIVE;

-- ------------------------------------------------------------------------------
-- Step 4: New transactions get GTIDs; replicated transactions may be
-- anonymous or GTID.
-- ------------------------------------------------------------------------------
SET PERSIST gtid_mode = ON_PERMISSIVE;

-- ------------------------------------------------------------------------------
-- Step 5: Wait until no anonymous transactions are in flight.
-- Repeat until Value = 0 on every server. On replicas, also wait until all
-- anonymous transactions from the source have been applied.
-- ------------------------------------------------------------------------------
SHOW GLOBAL STATUS LIKE 'Ongoing_anonymous_transaction_count';

-- If you use the binary logs for anything other than replication (for example
-- point-in-time recovery), wait until you no longer need the binlogs that
-- contain anonymous transactions. Optionally rotate the binlog now:
-- FLUSH BINARY LOGS;

-- ------------------------------------------------------------------------------
-- Step 6: Enable GTID mode.
-- ------------------------------------------------------------------------------
SET PERSIST gtid_mode = ON;

-- ------------------------------------------------------------------------------
-- Step 7: Confirm the final state. Expected: ON, ON.
-- ------------------------------------------------------------------------------
SELECT @@GLOBAL.gtid_mode, @@GLOBAL.enforce_gtid_consistency;
SELECT VARIABLE_NAME, VARIABLE_VALUE
  FROM performance_schema.persisted_variables
 WHERE VARIABLE_NAME IN ('gtid_mode', 'enforce_gtid_consistency');

-- Existing replicas that use binlog file/position can now switch to
-- auto-positioning (on each replica):
--   STOP REPLICA;
--   CHANGE REPLICATION SOURCE TO SOURCE_AUTO_POSITION = 1;
--   START REPLICA;
