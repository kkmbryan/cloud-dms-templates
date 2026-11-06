#!/usr/bin/env bash
# ==============================================================================
# Read-only pre-flight check of a self-managed MySQL 8.0 source for a
# Database Migration Service (DMS) continuous migration to Cloud SQL for MySQL.
# ==============================================================================
# Runs only SELECT / SHOW statements. Prints a PASS / WARN / FAIL table and
# exits non-zero when at least one check FAILs.
#
# Credentials are read ONLY from a MySQL option file (mode 0600 or 0400) passed
# with --defaults-extra-file. The script never accepts a password argument.
#   cat > ~/.my-dms.cnf <<'EOF'
#   [client]
#   user=root
#   password=...
#   EOF
#   chmod 600 ~/.my-dms.cnf
#
# Use an administrative account: the grant, DEFINER and view/routine checks
# read mysql.user, SHOW GRANTS for another user, and information_schema.
#
# Usage:
#   MYSQL_DEFAULTS_FILE=~/.my-dms.cnf ./preflight_check.sh \
#     [--scenario 1|2] [--dms-user dms_migration] [--seed-hours 24] \
#     [--backup-gtid '<gtid set>'] \
#     [--host 127.0.0.1] [--port 3306] [--socket /var/run/mysqld/mysqld.sock]
#
# Exit codes: 0 = no FAIL (WARNs allowed), 1 = at least one FAIL,
#             2 = usage, option file or connection error.
# ==============================================================================

set -euo pipefail
umask 077

SCRIPT_NAME="$(basename "$0")"
SYSTEM_SCHEMAS="'mysql','sys','performance_schema','information_schema'"
MIN_RETENTION_SECONDS=604800 # 7 days
RETENTION_BUFFER_HOURS=24
MAX_LISTED=10

DEFAULTS_FILE="${MYSQL_DEFAULTS_FILE:-}"
MYSQL_HOST="${MYSQL_HOST:-}"
MYSQL_PORT="${MYSQL_PORT:-}"
MYSQL_SOCKET="${MYSQL_SOCKET:-}"
SCENARIO="1"
DMS_USER="dms_migration"
DMS_HOST="%"
SEED_HOURS="24"
BACKUP_GTID=""

usage() {
  cat <<EOF
Usage: MYSQL_DEFAULTS_FILE=<option file> ${SCRIPT_NAME} [options]

Read-only pre-flight check of a MySQL 8.0 source for Database Migration Service.

Options:
  --defaults-extra-file F MySQL option file with [client] user/password (mode 0600
                          or 0400). Default: \$MYSQL_DEFAULTS_FILE.
  --host H                MySQL host (default: client default / option file).
  --port P                MySQL port.
  --socket S              Unix socket.
  --scenario 1|2          1 = DMS-managed dump, 2 = seed from Cloud Storage (default: 1).
  --dms-user U            DMS migration user, host '%' (default: dms_migration).
  --seed-hours N          Expected total seed time in hours: dump + upload + restore
                          (default: 24). Used for the binlog retention check.
  --backup-gtid SET       GTID set of the seed (Scenario 2). FAIL unless
                          GTID_SUBSET(@@GLOBAL.gtid_purged, SET) = 1.
  -h, --help              Show this help.

Exit codes: 0 = no FAIL, 1 = at least one FAIL, 2 = usage/connection error.
EOF
}

die() {
  echo "${SCRIPT_NAME}: ERROR: $*" >&2
  exit 2
}

need_arg() {
  [[ $# -ge 2 && -n "$2" ]] || die "option $1 requires a value (see --help)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) need_arg "$@"; DEFAULTS_FILE="$2"; shift 2 ;;
    --defaults-extra-file=*) DEFAULTS_FILE="${1#*=}"; shift ;;
    --host) need_arg "$@"; MYSQL_HOST="$2"; shift 2 ;;
    --port) need_arg "$@"; MYSQL_PORT="$2"; shift 2 ;;
    --socket) need_arg "$@"; MYSQL_SOCKET="$2"; shift 2 ;;
    --scenario) need_arg "$@"; SCENARIO="$2"; shift 2 ;;
    --dms-user) need_arg "$@"; DMS_USER="$2"; shift 2 ;;
    --seed-hours) need_arg "$@"; SEED_HOURS="$2"; shift 2 ;;
    --backup-gtid) need_arg "$@"; BACKUP_GTID="$2"; shift 2 ;;
    -p* | --password*) die "passwords are not accepted on the command line; use --defaults-extra-file" ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

# ------------------------------------------------------------------------------
# Input validation (values are interpolated into SQL, so allow-list them).
# ------------------------------------------------------------------------------
[[ "${SCENARIO}" == "1" || "${SCENARIO}" == "2" ]] || die "--scenario must be 1 or 2"
[[ "${SEED_HOURS}" =~ ^[0-9]+$ && "${SEED_HOURS}" -ge 1 ]] || die "--seed-hours must be a positive integer"
[[ "${DMS_USER}" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "--dms-user may contain only letters, digits, '_', '.', '-' (max 32)"
if [[ -n "${BACKUP_GTID}" ]]; then
  BACKUP_GTID="$(tr -d '[:space:]' <<<"${BACKUP_GTID}")"
  [[ "${BACKUP_GTID}" =~ ^[0-9A-Za-z:,_-]+$ ]] || die "--backup-gtid contains characters that are not valid in a GTID set"
fi
[[ -z "${MYSQL_PORT}" || "${MYSQL_PORT}" =~ ^[0-9]+$ ]] || die "--port must be numeric"

# ------------------------------------------------------------------------------
# Option file checks.
# ------------------------------------------------------------------------------
[[ -n "${DEFAULTS_FILE}" ]] || die "set MYSQL_DEFAULTS_FILE or pass --defaults-extra-file (see --help)"
[[ -f "${DEFAULTS_FILE}" ]] || die "option file not found: ${DEFAULTS_FILE}"
[[ -r "${DEFAULTS_FILE}" ]] || die "option file not readable: ${DEFAULTS_FILE}"
FILE_MODE="$(stat -c '%a' "${DEFAULTS_FILE}")"
[[ "${FILE_MODE}" == "600" || "${FILE_MODE}" == "400" ]] ||
  die "option file ${DEFAULTS_FILE} has mode ${FILE_MODE}; run: chmod 600 ${DEFAULTS_FILE}"

command -v mysql >/dev/null 2>&1 || die "mysql client not found in PATH"

# --defaults-extra-file must be the first option.
MYSQL_CMD=(mysql "--defaults-extra-file=${DEFAULTS_FILE}")
[[ -n "${MYSQL_HOST}" ]] && MYSQL_CMD+=("--host=${MYSQL_HOST}")
[[ -n "${MYSQL_PORT}" ]] && MYSQL_CMD+=("--port=${MYSQL_PORT}")
[[ -n "${MYSQL_SOCKET}" ]] && MYSQL_CMD+=("--socket=${MYSQL_SOCKET}")
MYSQL_CMD+=(--batch --skip-column-names --connect-timeout=10
  "--init-command=SET SESSION TRANSACTION READ ONLY")

# q SQL: run one read-only query; tab-separated rows on stdout.
q() {
  local out
  if ! out="$("${MYSQL_CMD[@]}" -e "$1" 2>&1)"; then
    echo "${SCRIPT_NAME}: ERROR: query failed: ${out}" >&2
    return 2
  fi
  printf '%s' "${out}"
}

# ------------------------------------------------------------------------------
# Result collection.
# ------------------------------------------------------------------------------
declare -a R_STATUS=() R_CHECK=() R_DETAIL=()
DETAILS=""
FAILS=0
WARNS=0

add() { # add STATUS CHECK DETAIL
  R_STATUS+=("$1")
  R_CHECK+=("$2")
  R_DETAIL+=("$3")
  case "$1" in
    FAIL) FAILS=$((FAILS + 1)) ;;
    WARN) WARNS=$((WARNS + 1)) ;;
  esac
}

add_details() { # add_details TITLE LINES
  DETAILS+=$'\n'"--- $1"$'\n'"$2"$'\n'
}

# count_lines TEXT: number of non-empty lines.
count_lines() {
  if [[ -z "$1" ]]; then echo 0; else printf '%s\n' "$1" | grep -c .; fi
}

# first_items TEXT: first MAX_LISTED lines joined with ", " (tabs -> '.').
first_items() {
  printf '%s\n' "$1" | head -n "${MAX_LISTED}" | tr '\t' '.' | paste -sd, - | sed 's/,/, /g'
}

# ------------------------------------------------------------------------------
# Connectivity and server variables (one round trip).
# ------------------------------------------------------------------------------
# Fields are joined with CHAR(31) (not a tab) so that an empty sql_mode doesn't
# collapse under IFS whitespace splitting.
VARS="$(q "/* chk:vars */ SELECT CONCAT_WS(CHAR(31),
  @@GLOBAL.version, @@GLOBAL.server_id, @@GLOBAL.log_bin, @@GLOBAL.binlog_format,
  @@GLOBAL.binlog_row_image, @@GLOBAL.gtid_mode, @@GLOBAL.enforce_gtid_consistency,
  @@GLOBAL.binlog_expire_logs_seconds, @@GLOBAL.expire_logs_days,
  @@GLOBAL.lower_case_table_names, @@GLOBAL.character_set_server,
  @@GLOBAL.collation_server, @@GLOBAL.sql_mode, @@GLOBAL.time_zone,
  @@GLOBAL.system_time_zone, @@GLOBAL.innodb_page_size, IFNULL(@@GLOBAL.bind_address, ''))")" ||
  die "cannot connect to MySQL with ${DEFAULTS_FILE} (see the error above)"

IFS=$'\x1f' read -r V_VERSION V_SERVER_ID V_LOG_BIN V_BINLOG_FORMAT V_ROW_IMAGE V_GTID_MODE \
  V_ENFORCE_GTID V_EXPIRE_SECONDS V_EXPIRE_DAYS V_LCTN V_CHARSET V_COLLATION V_SQL_MODE \
  V_TIME_ZONE V_SYSTEM_TZ V_PAGE_SIZE V_BIND_ADDRESS <<<"${VARS}"

# MySQL version.
if [[ "${V_VERSION}" == 8.0.* ]]; then
  add PASS "version" "${V_VERSION}"
else
  add WARN "version" "${V_VERSION}: these templates are written for a MySQL 8.0 source"
fi

# server_id >= 1.
if [[ "${V_SERVER_ID}" =~ ^[0-9]+$ && "${V_SERVER_ID}" -ge 1 ]]; then
  add PASS "server_id" "${V_SERVER_ID}"
else
  add FAIL "server_id" "${V_SERVER_ID}: set a unique non-zero server_id (01_mysqld_dms_source.cnf)"
fi

# log_bin.
if [[ "${V_LOG_BIN}" == "1" || "${V_LOG_BIN}" == "ON" ]]; then
  add PASS "log_bin" "ON"
else
  add FAIL "log_bin" "OFF: enable the binary log (log_bin, needs a restart)"
fi

# bind_address: DMS connects over TCP from the PSC Network Attachment subnet.
LOOPBACK_ONLY=1
IFS=',' read -r -a BIND_LIST <<<"${V_BIND_ADDRESS// /}"
[[ ${#BIND_LIST[@]} -eq 0 ]] && LOOPBACK_ONLY=0
for addr in "${BIND_LIST[@]}"; do
  case "${addr}" in
    127.* | localhost | ::1) ;;
    *) LOOPBACK_ONLY=0 ;;
  esac
done
if [[ "${LOOPBACK_ONLY}" == "1" ]]; then
  add WARN "bind_address" "${V_BIND_ADDRESS}: loopback only, DMS can't connect; set bind_address (01_mysqld_dms_source.cnf) and restart"
else
  add PASS "bind_address" "${V_BIND_ADDRESS:-*}"
fi

# binlog_format.
if [[ "${V_BINLOG_FORMAT}" == "ROW" ]]; then
  add PASS "binlog_format" "ROW"
else
  add FAIL "binlog_format" "${V_BINLOG_FORMAT}: set binlog_format=ROW"
fi

# binlog_row_image.
if [[ "${V_ROW_IMAGE}" == "FULL" ]]; then
  add PASS "binlog_row_image" "FULL"
else
  add FAIL "binlog_row_image" "${V_ROW_IMAGE}: set binlog_row_image=FULL"
fi

# gtid_mode: DMS accepts only ON or OFF; CDC in these templates needs ON.
case "${V_GTID_MODE}" in
  ON) add PASS "gtid_mode" "ON" ;;
  OFF_PERMISSIVE | ON_PERMISSIVE)
    add FAIL "gtid_mode" "${V_GTID_MODE}: DMS accepts only ON or OFF; finish 02_enable_gtid_online.sql" ;;
  *) add FAIL "gtid_mode" "${V_GTID_MODE}: enable GTIDs (02_enable_gtid_online.sql, no restart)" ;;
esac

# enforce_gtid_consistency.
if [[ "${V_ENFORCE_GTID}" == "ON" ]]; then
  add PASS "enforce_gtid_consistency" "ON"
else
  add FAIL "enforce_gtid_consistency" "${V_ENFORCE_GTID}: must be ON (02_enable_gtid_online.sql)"
fi

# Binlog retention vs. seed time.
SEED_SECONDS=$((SEED_HOURS * 3600))
RECOMMENDED=$(((SEED_HOURS + RETENTION_BUFFER_HOURS) * 3600))
((RECOMMENDED < MIN_RETENTION_SECONDS)) && RECOMMENDED=${MIN_RETENTION_SECONDS}
# binlog_expire_logs_seconds takes precedence; when it is 0, MySQL 8.0 still
# purges after expire_logs_days (deprecated) if that is > 0.
RETENTION="${V_EXPIRE_SECONDS}"
RETENTION_SOURCE="binlog_expire_logs_seconds"
if [[ "${RETENTION}" == "0" && "${V_EXPIRE_DAYS}" =~ ^[1-9][0-9]*$ ]]; then
  RETENTION=$((V_EXPIRE_DAYS * 86400))
  RETENTION_SOURCE="expire_logs_days=${V_EXPIRE_DAYS}"
fi
if [[ "${RETENTION}" == "0" ]]; then
  add PASS "binlog_retention" "no automatic purge (binlog_expire_logs_seconds=0, expire_logs_days=0); watch disk space"
elif ((RETENTION < SEED_SECONDS)); then
  add FAIL "binlog_retention" "${RETENTION}s (${RETENTION_SOURCE}) < seed time ${SEED_SECONDS}s (--seed-hours ${SEED_HOURS}); set binlog_expire_logs_seconds >= ${RECOMMENDED}"
elif ((RETENTION < RECOMMENDED)); then
  add WARN "binlog_retention" "${RETENTION}s (${RETENTION_SOURCE}); recommended >= ${RECOMMENDED}s (seed ${SEED_HOURS}h + ${RETENTION_BUFFER_HOURS}h buffer, 7 days minimum)"
else
  add PASS "binlog_retention" "${RETENTION}s (${RETENTION_SOURCE}) >= ${RECOMMENDED}s (seed ${SEED_HOURS}h + ${RETENTION_BUFFER_HOURS}h buffer, 7 days minimum)"
fi

# ------------------------------------------------------------------------------
# DMS user grants.
# ------------------------------------------------------------------------------
if [[ "${SCENARIO}" == "1" ]]; then
  # Required by the DMS "Configure your source database" doc (FAIL if missing).
  REQUIRED_PRIVS=("REPLICATION SLAVE" "REPLICATION CLIENT" "EXECUTE" "SELECT" "SHOW VIEW" "TRIGGER" "RELOAD")
  # Recommended extra (events / parallel dump; WARN if missing).
  RECOMMENDED_PRIVS=("EVENT" "LOCK TABLES")
else
  REQUIRED_PRIVS=("REPLICATION SLAVE" "REPLICATION CLIENT" "EXECUTE")
  RECOMMENDED_PRIVS=()
fi

USER_EXISTS="$(q "/* chk:dms_user_exists */ SELECT COUNT(*) FROM mysql.user WHERE User = '${DMS_USER}' AND Host = '${DMS_HOST}'")"
if [[ "${USER_EXISTS}" != "1" ]]; then
  add FAIL "dms_user_grants" "'${DMS_USER}'@'${DMS_HOST}' does not exist (03_create_dms_user.sql)"
else
  GRANTS="$(q "/* chk:dms_grants */ SHOW GRANTS FOR '${DMS_USER}'@'${DMS_HOST}'")"
  # Global privileges: the text between GRANT and ON *.* of each line.
  GLOBAL_PRIVS="$(printf '%s\n' "${GRANTS}" | sed -n 's/^GRANT \(.*\) ON \*\.\* TO .*/\1/p' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | tr '[:lower:]' '[:upper:]')"
  HAS_ALL=0
  grep -qx 'ALL PRIVILEGES\|ALL' <<<"${GLOBAL_PRIVS}" && HAS_ALL=1
  MISSING=()
  for p in "${REQUIRED_PRIVS[@]}"; do
    if [[ "${HAS_ALL}" == "0" ]] && ! grep -qx "${p}" <<<"${GLOBAL_PRIVS}"; then
      MISSING+=("${p}")
    fi
  done
  MISSING_EXTRA=()
  for p in "${RECOMMENDED_PRIVS[@]}"; do
    if [[ "${HAS_ALL}" == "0" ]] && ! grep -qx "${p}" <<<"${GLOBAL_PRIVS}"; then
      MISSING_EXTRA+=("${p}")
    fi
  done
  PROBLEMS=()
  if grep -qx 'BACKUP_ADMIN' <<<"${GLOBAL_PRIVS}"; then
    PROBLEMS+=("has BACKUP_ADMIN, which DMS rejects (REVOKE BACKUP_ADMIN ON *.* FROM '${DMS_USER}'@'%')")
  fi
  if [[ ${#MISSING[@]} -gt 0 ]]; then
    MISSING_LIST="$(printf '%s, ' "${MISSING[@]}")"
    PROBLEMS+=("missing required scenario ${SCENARIO} privileges on *.*: ${MISSING_LIST%, }")
  fi
  if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
    PROBLEM_LIST="$(printf '%s; ' "${PROBLEMS[@]}")"
    add FAIL "dms_user_grants" "'${DMS_USER}'@'%' ${PROBLEM_LIST%; }"
  elif [[ "${HAS_ALL}" == "1" ]]; then
    add WARN "dms_user_grants" "'${DMS_USER}'@'%' has ALL PRIVILEGES; grant only the scenario ${SCENARIO} privileges"
  elif [[ ${#MISSING_EXTRA[@]} -gt 0 ]]; then
    EXTRA_LIST="$(printf '%s, ' "${MISSING_EXTRA[@]}")"
    add WARN "dms_user_grants" "'${DMS_USER}'@'%' has the required scenario ${SCENARIO} privileges; missing recommended extra ${EXTRA_LIST%, } (events / parallel dump)"
  else
    add PASS "dms_user_grants" "'${DMS_USER}'@'%' has the scenario ${SCENARIO} privileges, no BACKUP_ADMIN"
  fi
  add_details "SHOW GRANTS FOR '${DMS_USER}'@'%'" "${GRANTS}"
fi

# ------------------------------------------------------------------------------
# TLS: DMS connects with source_ssl_type = REQUIRED by default (Terraform), so
# the server must offer TLS. have_ssl is read from performance_schema because the
# system variable is deprecated.
# ------------------------------------------------------------------------------
TLS="$(q "/* chk:tls */ SELECT CONCAT_WS(CHAR(31),
  @@GLOBAL.require_secure_transport,
  IFNULL((SELECT VARIABLE_VALUE FROM performance_schema.global_variables WHERE VARIABLE_NAME = 'have_ssl'), ''),
  IFNULL((SELECT ssl_type FROM mysql.user WHERE User = '${DMS_USER}' AND Host = '${DMS_HOST}'), ''))")"
IFS=$'\x1f' read -r V_REQUIRE_SECURE V_HAVE_SSL V_USER_SSL_TYPE <<<"${TLS}"
case "${V_REQUIRE_SECURE}" in 1 | ON) V_REQUIRE_SECURE="ON" ;; *) V_REQUIRE_SECURE="OFF" ;; esac
TLS_INFO="require_secure_transport=${V_REQUIRE_SECURE}, have_ssl=${V_HAVE_SSL:-unknown}, ${DMS_USER} ssl_type=${V_USER_SSL_TYPE:-none}"
if [[ "${V_HAVE_SSL}" != "YES" ]]; then
  add WARN "tls" "${TLS_INFO}: TLS isn't available, so source_ssl_type=REQUIRED fails verify; configure ssl_cert/ssl_key (or set source_ssl_type=NONE, not recommended)"
elif [[ "${V_REQUIRE_SECURE}" == "ON" || -n "${V_USER_SSL_TYPE}" ]]; then
  add PASS "tls" "${TLS_INFO}"
else
  add WARN "tls" "${TLS_INFO}: TLS is available but not enforced; use SET PERSIST require_secure_transport = ON or ALTER USER '${DMS_USER}'@'%' REQUIRE SSL"
fi

# ------------------------------------------------------------------------------
# Schema checks (user schemas only).
# ------------------------------------------------------------------------------
NON_INNODB="$(q "/* chk:non_innodb */ SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE
  FROM information_schema.TABLES
 WHERE TABLE_TYPE = 'BASE TABLE' AND ENGINE <> 'InnoDB'
   AND TABLE_SCHEMA NOT IN (${SYSTEM_SCHEMAS})
 ORDER BY TABLE_SCHEMA, TABLE_NAME")"
N="$(count_lines "${NON_INNODB}")"
if [[ "${N}" == "0" ]]; then
  add PASS "non_innodb_tables" "none"
else
  add WARN "non_innodb_tables" "${N} table(s), e.g. $(first_items "$(cut -f1,2 <<<"${NON_INNODB}")"); convert to InnoDB before the seed"
  add_details "Non-InnoDB user tables (schema, table, engine)" "${NON_INNODB}"
fi

NO_KEY="$(q "/* chk:no_pk */ SELECT t.TABLE_SCHEMA, t.TABLE_NAME
  FROM information_schema.TABLES t
 WHERE t.TABLE_TYPE = 'BASE TABLE'
   AND t.TABLE_SCHEMA NOT IN (${SYSTEM_SCHEMAS})
   AND NOT EXISTS (
         SELECT 1 FROM information_schema.STATISTICS s
          WHERE s.TABLE_SCHEMA = t.TABLE_SCHEMA AND s.TABLE_NAME = t.TABLE_NAME
            AND s.NON_UNIQUE = 0
          GROUP BY s.INDEX_NAME
         HAVING SUM(s.NULLABLE = 'YES') = 0)
 ORDER BY t.TABLE_SCHEMA, t.TABLE_NAME")"
N="$(count_lines "${NO_KEY}")"
if [[ "${N}" == "0" ]]; then
  add PASS "primary_keys" "every user table has a PK or a unique NOT NULL key"
else
  add WARN "primary_keys" "${N} table(s) without PK or unique NOT NULL key, e.g. $(first_items "${NO_KEY}"); CDC on them is slow and can't be validated row by row"
  add_details "Tables without a primary key or unique NOT NULL key" "${NO_KEY}"
fi

# DEFINER audit across events, routines, triggers and views.
# information_schema and mysql.user columns use different character sets and
# collations; CONVERT ... USING utf8mb4 avoids "Illegal mix of collations" in
# the UNION and in the user lookup.
DEFINER_SQL="
SELECT d.DEFINER, d.OBJ_TYPE, d.OBJ_SCHEMA, d.OBJ_NAME,
       CASE WHEN d.DEFINER = 'root@localhost' THEN 'root@localhost'
            ELSE 'user does not exist' END AS REASON
  FROM (
        SELECT CONVERT(DEFINER USING utf8mb4) AS DEFINER, 'EVENT' AS OBJ_TYPE,
               CONVERT(EVENT_SCHEMA USING utf8mb4) AS OBJ_SCHEMA, CONVERT(EVENT_NAME USING utf8mb4) AS OBJ_NAME
          FROM information_schema.EVENTS
        UNION ALL
        SELECT CONVERT(DEFINER USING utf8mb4), CONVERT(ROUTINE_TYPE USING utf8mb4),
               CONVERT(ROUTINE_SCHEMA USING utf8mb4), CONVERT(ROUTINE_NAME USING utf8mb4)
          FROM information_schema.ROUTINES
        UNION ALL
        SELECT CONVERT(DEFINER USING utf8mb4), 'TRIGGER',
               CONVERT(TRIGGER_SCHEMA USING utf8mb4), CONVERT(TRIGGER_NAME USING utf8mb4)
          FROM information_schema.TRIGGERS
        UNION ALL
        SELECT CONVERT(DEFINER USING utf8mb4), 'VIEW',
               CONVERT(TABLE_SCHEMA USING utf8mb4), CONVERT(TABLE_NAME USING utf8mb4)
          FROM information_schema.VIEWS
       ) d
 WHERE d.OBJ_SCHEMA NOT IN (${SYSTEM_SCHEMAS})
   AND (d.DEFINER = 'root@localhost'
        OR NOT EXISTS (SELECT 1 FROM mysql.user u
                        WHERE CONVERT(CONCAT(u.User, '@', u.Host) USING utf8mb4) COLLATE utf8mb4_bin
                              = d.DEFINER COLLATE utf8mb4_bin))
 ORDER BY d.DEFINER, d.OBJ_SCHEMA, d.OBJ_NAME"
BAD_DEFINERS="$(q "/* chk:definers */ ${DEFINER_SQL}")"
N="$(count_lines "${BAD_DEFINERS}")"
if [[ "${N}" == "0" ]]; then
  add PASS "definers" "every DEFINER exists and none is root@localhost"
else
  SUMMARY="$(cut -f1,5 <<<"${BAD_DEFINERS}" | sort | uniq -c |
    sed -E 's/^ *([0-9]+) ([^\t]*)\t(.*)$/\2 (\3: \1)/' | paste -sd ';' - | sed 's/;/; /g')"
  add WARN "definers" "${N} object(s): ${SUMMARY}. Create these users on Cloud SQL or change the DEFINER"
  add_details "Objects with a missing or root@localhost DEFINER (definer, type, schema, name, reason)" "${BAD_DEFINERS}"
fi

# Views, routines, triggers and events that reference system schemas.
# Single-quoted heredoc: the regex contains backticks and must not be expanded.
SYSREF_SQL="$(cat <<'SQL'
SELECT x.OBJ_TYPE, x.OBJ_SCHEMA, x.OBJ_NAME FROM (
  SELECT 'VIEW' AS OBJ_TYPE, CONVERT(TABLE_SCHEMA USING utf8mb4) AS OBJ_SCHEMA,
         CONVERT(TABLE_NAME USING utf8mb4) AS OBJ_NAME, CONVERT(VIEW_DEFINITION USING utf8mb4) AS BODY
    FROM information_schema.VIEWS
  UNION ALL
  SELECT CONVERT(ROUTINE_TYPE USING utf8mb4), CONVERT(ROUTINE_SCHEMA USING utf8mb4),
         CONVERT(ROUTINE_NAME USING utf8mb4), CONVERT(ROUTINE_DEFINITION USING utf8mb4)
    FROM information_schema.ROUTINES
  UNION ALL
  SELECT 'TRIGGER', CONVERT(TRIGGER_SCHEMA USING utf8mb4),
         CONVERT(TRIGGER_NAME USING utf8mb4), CONVERT(ACTION_STATEMENT USING utf8mb4)
    FROM information_schema.TRIGGERS
  UNION ALL
  SELECT 'EVENT', CONVERT(EVENT_SCHEMA USING utf8mb4),
         CONVERT(EVENT_NAME USING utf8mb4), CONVERT(EVENT_DEFINITION USING utf8mb4)
    FROM information_schema.EVENTS
) x
WHERE x.OBJ_SCHEMA NOT IN (SYSTEM_SCHEMAS_PLACEHOLDER)
  AND REGEXP_LIKE(x.BODY, '(^|[^a-z0-9_$])`?(mysql|sys|performance_schema|information_schema)`?[.]', 'i')
ORDER BY x.OBJ_SCHEMA, x.OBJ_NAME
SQL
)"
SYSREF_SQL="${SYSREF_SQL//SYSTEM_SCHEMAS_PLACEHOLDER/${SYSTEM_SCHEMAS}}"
SYSREFS="$(q "/* chk:sysrefs */ ${SYSREF_SQL}")"
N="$(count_lines "${SYSREFS}")"
if [[ "${N}" == "0" ]]; then
  add PASS "system_schema_refs" "no view/routine/trigger/event references mysql, sys, performance_schema or information_schema"
else
  add WARN "system_schema_refs" "${N} object(s), e.g. $(first_items "$(cut -f2,3 <<<"${SYSREFS}")"); system schemas are not migrated and differ on Cloud SQL"
  add_details "Objects that reference system schemas (type, schema, name)" "${SYSREFS}"
fi

# ------------------------------------------------------------------------------
# Server settings that must match on Cloud SQL.
# ------------------------------------------------------------------------------
case "${V_LCTN}" in
  0) add PASS "lower_case_table_names" "0 (Cloud SQL default; leave Terraform cloudsql_lower_case_table_names null or 0)" ;;
  1) add WARN "lower_case_table_names" "1: set Terraform cloudsql_lower_case_table_names = 1 BEFORE the instance is created (immutable)" ;;
  *) add FAIL "lower_case_table_names" "${V_LCTN}: Cloud SQL supports only 0 or 1; set Terraform cloudsql_lower_case_table_names" ;;
esac

if [[ "${V_CHARSET}" == "utf8mb4" && "${V_COLLATION}" == "utf8mb4_0900_ai_ci" ]]; then
  add PASS "character_set/collation" "${V_CHARSET} / ${V_COLLATION}"
else
  add WARN "character_set/collation" "${V_CHARSET} / ${V_COLLATION}: set the Cloud SQL flags character_set_server and collation_server to match"
fi

DEFAULT_SQL_MODE="ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"
if [[ "${V_SQL_MODE}" == "${DEFAULT_SQL_MODE}" ]]; then
  add PASS "sql_mode" "MySQL 8.0 default"
else
  add WARN "sql_mode" "'${V_SQL_MODE}' differs from the 8.0 default; set the Cloud SQL flag sql_mode to match"
fi

if [[ "${V_TIME_ZONE}" == "+00:00" || "${V_TIME_ZONE}" == "UTC" ||
  ("${V_TIME_ZONE}" == "SYSTEM" && "${V_SYSTEM_TZ}" =~ ^(UTC|GMT)$) ]]; then
  add PASS "time_zone" "time_zone=${V_TIME_ZONE}, system_time_zone=${V_SYSTEM_TZ}"
else
  add WARN "time_zone" "time_zone=${V_TIME_ZONE}, system_time_zone=${V_SYSTEM_TZ}: Cloud SQL defaults to UTC; set the Cloud SQL flag default_time_zone to match"
fi

if [[ "${V_PAGE_SIZE}" == "16384" ]]; then
  add PASS "innodb_page_size" "16384"
else
  add FAIL "innodb_page_size" "${V_PAGE_SIZE}: must be 16384 (Cloud SQL default; required for a PHYSICAL seed)"
fi

# ------------------------------------------------------------------------------
# Size and (optional) backup GTID coverage.
# ------------------------------------------------------------------------------
SIZE_BYTES="$(q "/* chk:size */ SELECT COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH), 0)
  FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN (${SYSTEM_SCHEMAS})")"
SCHEMA_COUNT="$(q "/* chk:schemas */ SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN (${SYSTEM_SCHEMAS})")"
SIZE_GIB="$(awk -v b="${SIZE_BYTES}" 'BEGIN { printf "%.1f", b / 1073741824 }')"
add PASS "user_db_size" "${SIZE_GIB} GiB in ${SCHEMA_COUNT} schema(s) (data + index, approximate; see the runbook decision matrix)"

if [[ -n "${BACKUP_GTID}" ]]; then
  SUBSET="$(q "/* chk:backup_gtid */ SELECT GTID_SUBSET(@@GLOBAL.gtid_purged, '${BACKUP_GTID}')")"
  if [[ "${SUBSET}" == "1" ]]; then
    add PASS "backup_gtid" "@@GLOBAL.gtid_purged is a subset of the backup GTID set; binlogs since the backup are still available"
  else
    add FAIL "backup_gtid" "GTID_SUBSET(@@GLOBAL.gtid_purged, backup) = ${SUBSET}: binlogs after the backup were purged; take a new seed"
  fi
fi

# ------------------------------------------------------------------------------
# Report.
# ------------------------------------------------------------------------------
echo "DMS source pre-flight: scenario ${SCENARIO}, DMS user '${DMS_USER}'@'%', seed ${SEED_HOURS}h"
echo
printf '%-6s %-26s %s\n' "STATUS" "CHECK" "DETAIL"
printf '%-6s %-26s %s\n' "------" "--------------------------" "------"
for i in "${!R_STATUS[@]}"; do
  printf '%-6s %-26s %s\n' "${R_STATUS[$i]}" "${R_CHECK[$i]}" "${R_DETAIL[$i]}"
done
if [[ -n "${DETAILS}" ]]; then
  echo
  echo "Details:"
  printf '%s' "${DETAILS}"
fi
echo
echo "Summary: $((${#R_STATUS[@]} - FAILS - WARNS)) PASS, ${WARNS} WARN, ${FAILS} FAIL"

if ((FAILS > 0)); then
  exit 1
fi
exit 0
