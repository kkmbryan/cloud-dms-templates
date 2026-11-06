#!/usr/bin/env bash
# ==============================================================================
# Percona XtraBackup -> Cloud Storage for a DMS PHYSICAL seed (Scenario 2)
# ==============================================================================
# Creates a full physical backup of a self-managed MySQL 8.0 server, prepares
# it, and uploads the prepared files to a DEDICATED Cloud Storage folder, as
# described in:
#   https://cloud.google.com/database-migration/docs/mysql/migrate-with-physical-xtrabackup
#
# Steps: prechecks -> xtrabackup --backup -> (--decompress) -> --prepare ->
#        gcloud storage rsync --recursive <prepared dir> gs://<bucket>/<folder>
#
# PHYSICAL seeds are supported only for a MYSQL_8_0 Cloud SQL target.
#
# Run it on the source VM as an OS user that can read the MySQL datadir.
# The VM's gcloud identity needs roles/storage.objectCreator + objectViewer on the bucket
# (Terraform variable backup_writer_members).
#
# Usage:
#   # Folder = Terraform output, e.g. gs://my-dms-staging-bucket/xtrabackup/mysql80-full
#   export GCS_BACKUP_FOLDER="$(terraform -chdir=templates/02-backup-migration-gcs-cdc output -raw configured_dump_path)"
#
#   # Credentials, option A: an existing option file (mode 0600 or 0400) with
#   #   [client]
#   #   user=xtrabackup
#   #   password=...
#   export XTRABACKUP_DEFAULTS_FILE="/root/.xtrabackup.cnf"
#
#   # Credentials, option B: user name only; the script prompts for the
#   # password and writes it to a 0600 temporary option file.
#   export XTRABACKUP_USER="xtrabackup"
#
#   ./xtrabackup_to_gcs.sh
#
# Optional environment variables:
#   MYSQL_SOCKET          Unix socket (default: client default). Use with 'xtrabackup'@'localhost'.
#   MYSQL_HOST/MYSQL_PORT TCP connection instead of the socket.
#   MYSQL_DATADIR         MySQL datadir (default: /var/lib/mysql).
#   BACKUP_BASE_DIR       Local directory for the backup (default: /var/tmp/xtrabackup-dms).
#   PARALLEL_THREADS      xtrabackup --parallel (default: 4).
#   XTRABACKUP_COMPRESS   "true" to back up with --compress and decompress before
#                         --prepare (saves local disk during the copy phase only).
#   KEEP_LOCAL_BACKUP     "false" to delete the local copy after a verified upload
#                         (default: true).
# ==============================================================================

set -euo pipefail
umask 077

MYSQL_DATADIR="${MYSQL_DATADIR:-/var/lib/mysql}"
BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/var/tmp/xtrabackup-dms}"
PARALLEL_THREADS="${PARALLEL_THREADS:-4}"
XTRABACKUP_COMPRESS="${XTRABACKUP_COMPRESS:-false}"
KEEP_LOCAL_BACKUP="${KEEP_LOCAL_BACKUP:-true}"
GCS_MAX_OBJECT_BYTES=$((5 * 1024 * 1024 * 1024 * 1024)) # 5 TiB Cloud Storage object limit

log() { echo "[$(date -u +%H:%M:%SZ)] [INFO] $*"; }
warn() { echo "[$(date -u +%H:%M:%SZ)] [WARN] $*" >&2; }
die() {
  echo "[$(date -u +%H:%M:%SZ)] [ERROR] $*" >&2
  exit 1
}

# ------------------------------------------------------------------------------
# Inputs
# ------------------------------------------------------------------------------
GCS_BACKUP_FOLDER="${GCS_BACKUP_FOLDER:-}"
[[ -n "${GCS_BACKUP_FOLDER}" ]] || die "GCS_BACKUP_FOLDER is required (use: terraform output -raw configured_dump_path)."
[[ "${GCS_BACKUP_FOLDER}" =~ ^gs://[a-z0-9._-]+/.+[^/]$ ]] ||
  die "GCS_BACKUP_FOLDER must look like gs://<bucket>/<folder> (no trailing slash). Got: ${GCS_BACKUP_FOLDER}"

for cmd in xtrabackup mysql gcloud df du find sort; do
  command -v "${cmd}" >/dev/null 2>&1 || die "Required command '${cmd}' is not installed or not in PATH."
done

# ------------------------------------------------------------------------------
# Credentials: always through --defaults-extra-file, never --password on argv
# ------------------------------------------------------------------------------
TMP_CNF=""
cleanup() {
  if [[ -n "${TMP_CNF}" && -f "${TMP_CNF}" ]]; then
    rm -f "${TMP_CNF}"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

if [[ -n "${XTRABACKUP_DEFAULTS_FILE:-}" ]]; then
  [[ -r "${XTRABACKUP_DEFAULTS_FILE}" ]] || die "Cannot read ${XTRABACKUP_DEFAULTS_FILE}."
  perms="$(stat -c '%a' "${XTRABACKUP_DEFAULTS_FILE}")"
  [[ "${perms}" == "600" || "${perms}" == "400" ]] ||
    die "${XTRABACKUP_DEFAULTS_FILE} has mode ${perms}; use chmod 600 so other users cannot read the password."
  CNF="${XTRABACKUP_DEFAULTS_FILE}"
else
  [[ -n "${XTRABACKUP_USER:-}" ]] ||
    die "Set XTRABACKUP_DEFAULTS_FILE, or XTRABACKUP_USER (the backup account, for example 'xtrabackup'). There is no default user."
  if [[ -t 0 ]]; then
    read -r -s -p "Password for MySQL user '${XTRABACKUP_USER}': " XTRABACKUP_PASSWORD
    echo
  fi
  [[ -n "${XTRABACKUP_PASSWORD:-}" ]] || die "No password provided for ${XTRABACKUP_USER}."
  TMP_DIR_FOR_CNF="/dev/shm"
  [[ -d "${TMP_DIR_FOR_CNF}" && -w "${TMP_DIR_FOR_CNF}" ]] || TMP_DIR_FOR_CNF="${TMPDIR:-/tmp}"
  TMP_CNF="$(mktemp "${TMP_DIR_FOR_CNF}/xtrabackup-cnf.XXXXXX")"
  chmod 600 "${TMP_CNF}"
  # Escape backslashes and double quotes for the MySQL option file format.
  esc_user="${XTRABACKUP_USER//\\/\\\\}"
  esc_user="${esc_user//\"/\\\"}"
  esc_pw="${XTRABACKUP_PASSWORD//\\/\\\\}"
  esc_pw="${esc_pw//\"/\\\"}"
  {
    for group in client xtrabackup; do
      echo "[${group}]"
      echo "user=\"${esc_user}\""
      echo "password=\"${esc_pw}\""
    done
  } >"${TMP_CNF}"
  unset XTRABACKUP_PASSWORD esc_pw esc_user
  CNF="${TMP_CNF}"
fi

CONN_ARGS=()
[[ -n "${MYSQL_SOCKET:-}" ]] && CONN_ARGS+=("--socket=${MYSQL_SOCKET}")
[[ -n "${MYSQL_HOST:-}" ]] && CONN_ARGS+=("--host=${MYSQL_HOST}")
[[ -n "${MYSQL_PORT:-}" ]] && CONN_ARGS+=("--port=${MYSQL_PORT}")

# --defaults-extra-file must be the first option.
mysql_q() {
  mysql --defaults-extra-file="${CNF}" ${CONN_ARGS[@]+"${CONN_ARGS[@]}"} --batch --skip-column-names -e "$1"
}

# ------------------------------------------------------------------------------
# Prechecks
# ------------------------------------------------------------------------------
log "Running prechecks..."

SERVER_VERSION="$(mysql_q 'SELECT @@version;' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')" ||
  die "Cannot connect to MySQL with the provided credentials."
XB_VERSION="$(xtrabackup --version 2>&1 | grep -oE 'version [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | awk '{print $2}')"
[[ -n "${XB_VERSION}" ]] || die "Cannot determine the xtrabackup version."
log "MySQL server version: ${SERVER_VERSION}; xtrabackup version: ${XB_VERSION}"
[[ "${SERVER_VERSION%%.*}.$(cut -d. -f2 <<<"${SERVER_VERSION}")" == "8.0" ]] ||
  die "This script supports MySQL 8.0 sources only (DMS PHYSICAL seeds target MYSQL_8_0). Server is ${SERVER_VERSION}."
lowest="$(printf '%s\n%s\n' "${SERVER_VERSION}" "${XB_VERSION}" | sort -V | head -n1)"
XB_EXTRA_ARGS=()
if [[ "${lowest}" != "${SERVER_VERSION}" ]]; then
  # DMS asks for an XtraBackup version equal to or later than the server.
  # Percona XtraBackup 8.0.34+ can also back up newer 8.0 servers when
  # --lock-ddl=ON is used:
  # https://docs.percona.com/percona-xtrabackup/8.0/server-backup-version-comparison.html
  xb_floor="$(printf '%s\n%s\n' "8.0.34" "${XB_VERSION}" | sort -V | head -n1)"
  [[ "${xb_floor}" == "8.0.34" ]] ||
    die "xtrabackup ${XB_VERSION} is older than the server ${SERVER_VERSION}. Install Percona XtraBackup ${SERVER_VERSION} or later (8.0.34+ at minimum)."
  warn "xtrabackup ${XB_VERSION} is older than the server ${SERVER_VERSION}. Continuing with --lock-ddl=ON (supported by XtraBackup 8.0.34+). Prefer an XtraBackup release >= the server version when one is available."
  XB_EXTRA_ARGS+=(--lock-ddl=ON)
fi

PAGE_SIZE="$(mysql_q 'SELECT @@innodb_page_size;')"
[[ "${PAGE_SIZE}" == "16384" ]] || die "innodb_page_size is ${PAGE_SIZE}; DMS requires the default 16384."

log "Source CPU architecture: $(uname -m). The Cloud SQL destination must use the same architecture."

if du -sb "${MYSQL_DATADIR}" >/dev/null 2>&1; then
  DATADIR_BYTES="$(du -sb "${MYSQL_DATADIR}" | awk '{print $1}')"
else
  warn "Cannot read ${MYSQL_DATADIR}; estimating size from information_schema."
  DATADIR_BYTES="$(mysql_q 'SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables;')"
fi
mkdir -p "${BACKUP_BASE_DIR}"
FREE_BYTES="$(($(df -Pk "${BACKUP_BASE_DIR}" | awk 'NR==2 {print $4}') * 1024))"
NEEDED_BYTES="$((DATADIR_BYTES + DATADIR_BYTES / 10))"
log "Source size ~$((DATADIR_BYTES / 1024 / 1024)) MiB; free in ${BACKUP_BASE_DIR}: $((FREE_BYTES / 1024 / 1024)) MiB"
((FREE_BYTES >= NEEDED_BYTES)) ||
  die "Not enough free disk in ${BACKUP_BASE_DIR}: need ~$((NEEDED_BYTES / 1024 / 1024)) MiB (source size + 10%)."

# The DMS folder must be dedicated to this backup (no other files).
if ls_out="$(gcloud storage ls "${GCS_BACKUP_FOLDER}/**" 2>&1)"; then
  [[ -z "${ls_out}" ]] || die "${GCS_BACKUP_FOLDER} already contains objects. Use a new, empty folder."
elif grep -q "matched no objects" <<<"${ls_out}"; then
  log "Target folder ${GCS_BACKUP_FOLDER} is empty."
else
  warn "Could not list ${GCS_BACKUP_FOLDER} (missing roles/storage.objectViewer?). Make sure the folder is new and empty."
fi

# ------------------------------------------------------------------------------
# Backup, (decompress), prepare
# ------------------------------------------------------------------------------
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TARGET_DIR="${BACKUP_BASE_DIR}/full-${TIMESTAMP}"
LOG_FILE="${BACKUP_BASE_DIR}/xtrabackup-${TIMESTAMP}.log"
mkdir -p "${TARGET_DIR}"

log "Backing up ${MYSQL_DATADIR} to ${TARGET_DIR} (log: ${LOG_FILE})..."
BACKUP_ARGS=(--backup --target-dir="${TARGET_DIR}" --datadir="${MYSQL_DATADIR}" --parallel="${PARALLEL_THREADS}")
[[ "${XTRABACKUP_COMPRESS}" == "true" ]] && BACKUP_ARGS+=(--compress)
BACKUP_ARGS+=(${XB_EXTRA_ARGS[@]+"${XB_EXTRA_ARGS[@]}"})
xtrabackup --defaults-extra-file="${CNF}" ${CONN_ARGS[@]+"${CONN_ARGS[@]}"} "${BACKUP_ARGS[@]}" 2>>"${LOG_FILE}" ||
  die "xtrabackup --backup failed. See ${LOG_FILE}."
tail -n 5 "${LOG_FILE}" | grep -q "completed OK!" || die "xtrabackup --backup did not report 'completed OK!'. See ${LOG_FILE}."

if [[ "${XTRABACKUP_COMPRESS}" == "true" ]]; then
  log "Decompressing..."
  xtrabackup --decompress --remove-original --parallel="${PARALLEL_THREADS}" --target-dir="${TARGET_DIR}" 2>>"${LOG_FILE}" ||
    die "xtrabackup --decompress failed. See ${LOG_FILE}."
fi

log "Preparing the backup..."
xtrabackup --prepare --target-dir="${TARGET_DIR}" 2>>"${LOG_FILE}" ||
  die "xtrabackup --prepare failed. See ${LOG_FILE}."
tail -n 5 "${LOG_FILE}" | grep -q "completed OK!" || die "xtrabackup --prepare did not report 'completed OK!'. See ${LOG_FILE}."

if [[ -f "${TARGET_DIR}/xtrabackup_binlog_info" ]]; then
  log "Binlog/GTID position of the backup (xtrabackup_binlog_info):"
  cat "${TARGET_DIR}/xtrabackup_binlog_info"
fi

big_files="$(find "${TARGET_DIR}" -type f -size +"${GCS_MAX_OBJECT_BYTES}"c)"
[[ -z "${big_files}" ]] || die "These files exceed the 5 TiB Cloud Storage object limit and can't be used: ${big_files}"

# ------------------------------------------------------------------------------
# Upload the prepared files into the dedicated folder
# ------------------------------------------------------------------------------
LOCAL_COUNT="$(find "${TARGET_DIR}" -type f | wc -l)"
log "Uploading ${LOCAL_COUNT} files to ${GCS_BACKUP_FOLDER}/ ..."
# rsync copies the folder contents (not the folder itself) and skips empty
# directories such as #innodb_redo, which is empty after --prepare.
gcloud storage rsync --recursive "${TARGET_DIR}" "${GCS_BACKUP_FOLDER}"

if REMOTE_LIST="$(gcloud storage ls "${GCS_BACKUP_FOLDER}/**" 2>/dev/null)"; then
  REMOTE_COUNT="$(grep -c -v '/$' <<<"${REMOTE_LIST}" || true)"
  [[ "${REMOTE_COUNT}" == "${LOCAL_COUNT}" ]] ||
    die "Upload check failed: ${LOCAL_COUNT} local files, ${REMOTE_COUNT} objects in ${GCS_BACKUP_FOLDER}."
  log "Upload verified: ${REMOTE_COUNT} objects."
else
  warn "Could not list ${GCS_BACKUP_FOLDER} to verify the upload (missing roles/storage.objectViewer?). Check it with a reader account."
fi

if [[ "${KEEP_LOCAL_BACKUP}" == "false" ]]; then
  rm -rf "${TARGET_DIR}"
  log "Deleted local copy ${TARGET_DIR}."
else
  log "Local prepared backup kept at ${TARGET_DIR}."
fi

echo "=============================================================================="
echo "[SUCCESS] Prepared XtraBackup uploaded to ${GCS_BACKUP_FOLDER}"
echo "          This must equal the migration job dump_path (Terraform output configured_dump_path)."
echo "          Next: gcloud database-migration migration-jobs verify <job> --region=<region>"
echo "=============================================================================="
