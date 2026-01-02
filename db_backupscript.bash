#!/bin/bash


set -o errexit
set -o pipefail
set -o nounset

START_TIME=$(date +%s)

# MYSQL CREDENTIALS
MYSQL_USER="root"
MYSQL_PASSWORD="test"
MYSQL_HOST="localhost"
MYSQL_PORT="3306"


# DATABASE
DATABASE_NAME="test"


# BACKUP SETTINGS
BACKUP_DIR="/data/apps/test/database/weekly/backups"
LOG_DIR="/data/apps/test/database/weekly/logs"
DATE="$(date +'%Y-%m-%d_%H-%M-%S_%N')"

BACKUP_RETENTION_DAYS=7
LOG_RETENTION_DAYS=30

# Minimum required free disk space (MB)
MIN_FREE_SPACE_MB=30720   # 30 GB


# S3 SETTINGS
ENABLE_S3_UPLOAD="false"
S3_BUCKET="usaa-staging"
S3_PREFIX="mysql"


# BINARIES
MYSQLDUMP="/usr/bin/mysqldump"
GZIP="/usr/bin/gzip"
FIND="/usr/bin/find"
MKDIR="/usr/bin/mkdir"
DATE_CMD="/usr/bin/date"
AWS_CLI="/usr/bin/aws"


# FILES
LOG_FILE="${LOG_DIR}/mysql_${DATABASE_NAME}_${DATE}.log"
BACKUP_FILE="${BACKUP_DIR}/${DATABASE_NAME}_${DATE}.sql.gz"


# FUNCTIONS

log() {
    echo "[$(${DATE_CMD} '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}


# PRECHECKS

${MKDIR} -p "${BACKUP_DIR}" "${LOG_DIR}"

[[ -z "${DATABASE_NAME}" ]] && error_exit "DATABASE_NAME is not set"

[[ -x "${MYSQLDUMP}" ]] || error_exit "mysqldump not found"
[[ -x "${GZIP}" ]] || error_exit "gzip not found"
[[ -x "${FIND}" ]] || error_exit "find not found"

if [[ "${ENABLE_S3_UPLOAD}" == "true" ]]; then
    [[ -x "${AWS_CLI}" ]] || error_exit "aws cli not found"
fi


# DISK SPACE CHECK

# Portable disk-space check
AVAILABLE_SPACE_KB=$(df -k "${BACKUP_DIR}" | awk 'NR==2 {print $4}')
AVAILABLE_SPACE_MB=$(( AVAILABLE_SPACE_KB / 1024 ))

if [[ "${AVAILABLE_SPACE_MB}" -lt "${MIN_FREE_SPACE_MB}" ]]; then
    error_exit "Insufficient disk space: ${AVAILABLE_SPACE_MB}MB available, ${MIN_FREE_SPACE_MB}MB required"
fi

log "Disk space check passed: ${AVAILABLE_SPACE_MB}MB available"


########################################
# START BACKUP
########################################
log "Starting MySQL backup"
log "Database: ${DATABASE_NAME}"

${MYSQLDUMP} \
  --user="${MYSQL_USER}" \
  --password="${MYSQL_PASSWORD}" \
  --host="${MYSQL_HOST}" \
  --port="${MYSQL_PORT}" \
  --single-transaction \
  --routines \
  --events \
  --triggers \
  --complete-insert \
  --skip-comments \
  --max-allowed-packet=2048M \
  "${DATABASE_NAME}" \
  2>>"${LOG_FILE}" \
| ${GZIP} > "${BACKUP_FILE}" \
|| error_exit "MySQL dump failed"

log "Backup created: ${BACKUP_FILE}"


# S3 UPLOAD

if [[ "${ENABLE_S3_UPLOAD}" == "true" ]]; then
    log "Uploading backup to S3"
    ${AWS_CLI} s3 cp \
        "${BACKUP_FILE}" \
        "s3://${S3_BUCKET}/${S3_PREFIX}/${DATABASE_NAME}/" \
        --storage-class STANDARD_IA \
        >>"${LOG_FILE}" 2>&1 \
        || error_exit "S3 upload failed"
    log "S3 upload completed"
else
    log "S3 upload disabled"
fi


# CLEANUP OLD BACKUPS

log "Removing backups older than ${BACKUP_RETENTION_DAYS} days"
${FIND} "${BACKUP_DIR}" -type f -name "${DATABASE_NAME}_*.sql.gz" \
    -mtime +${BACKUP_RETENTION_DAYS} -print -delete >> "${LOG_FILE}"

log "Removing logs older than ${LOG_RETENTION_DAYS} days"
${FIND} "${LOG_DIR}" -type f -name "mysql_${DATABASE_NAME}_*.log" \
    -mtime +${LOG_RETENTION_DAYS} -print -delete >> "${LOG_FILE}"


# FINISH

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS_LEFT=$((DURATION % 60))

log "Total script execution time: ${MINUTES} min ${SECONDS_LEFT} sec"

log "MySQL backup completed successfully"
exit 0

