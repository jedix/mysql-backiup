#!/bin/bash
####################################################################
#Script Name: mysql-backup.sh
#Description: wrapper for Percona XtraBackup which can be controlled
#             with env varaibles to create backups and upload them
#             to Amazon S3 storage
#Author:      Jens Rey
#Email:       jrey@cocus.com
####################################################################

# display usage
print_usage() {
cat <<-USAGE >&2
This script is used to create a backup the MySQL database.

Usage: ${0##*/} [OPTIONS]

Options:

--user=USER         MySQL user with needed privileges (default: backupuser)
--password=PASSWORD password for MySQL user (default: empty)
--target=TARGET     backup target can be local or s3 (default: local)
--mode=MODE         backup mode can be full or incremental (default: full)
--path=PATH         local directory where backups will be stored
                    (default: /backup/)
--dirname=DIR       directory for current backup (inside [PATH]), will be
                    created, for full backups, "_full" will be appended
                    automatically (default: db)
--base-dir=PATH     for incremental backups only, local directory where the
                    full backup is stored (default: [DIRNAME]_full)
--pxb-binary=BINARY path to XtraBackup binary (default: /usr/bin/xtrabackup)
--s3-binary=BINARY  path to s3cmd binary (default: /usr/bin/s3cmd)
--s3-bucket=BUCKET  S3 bucket to store the backup in (default: empty)
--s3-path=PATH      path inside S3 bucket to store the backup in (default: empty)
--help              display this help
USAGE
exit 0
}


# set default values

BACKUP_USER=${BACKUP_USER:-backupuser}
BACKUP_TARGET=${BACKUP_TARGET:-local}
BACKUP_MODE=${BACKUP_MODE:-full}
BACKUP_PATH=${BACKUP_PATH:-/backup/}
BACKUP_DIR=${BACKUP_DIR:-db}
BACKUP_XTRABACKUP_BINARY=${BACKUP_XTRABACKUP_BINARY:-/usr/bin/xtrabackup}
BACKUP_S3_BINARY=${BACKUP_S3_BINARY:-/usr/bin/s3cmd}

# parse command line arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --user=*)
      BACKUP_USER="${1#*=}"
      ;;
    --password=*)
      BACKUP_PASSWORD="${1#*=}"
      ;;
    --target=*)
      BACKUP_TARGET="${1#*=}"
      ;;
    --mode=*)
      BACKUP_MODE="${1#*=}"
      ;;
    --path=*)
      BACKUP_PATH="${1#*=}"
      ;;
    --dirname=*)
      BACKUP_DIR="${1#*=}"
      ;;
    --base-dir=*)
      BACKUP_BASEDIR="${1#*=}"
      ;;
    --pxb-binary=*)
      BACKUP_XTRABACKUP_BINARY="${1#*=}"
      ;;
    --s3-binary=*)
      BACKUP_S3_BINARY="${1#*=}"
      ;;
    --s3-bucket=*)
      BACKUP_S3_BUCKET="${1#*=}"
      ;;
    --s3-path=*)
      BACKUP_S3_PATH="${1#*=}"
      ;;
    -h|--help) print_usage;;
    *)
      print_usage
      exit 1
  esac
  shift
done

if [[ "${BACKUP_PATH: -1}" != "/" ]]; then
	BACKUP_PATH="${BACKUP_PATH}/"
fi

if [[ "${BACKUP_MODE}" == "full" ]]; then
	BACKUP_DIR="${BACKUP_DIR}_full"
fi

BACKUP_FULLPATH="${BACKUP_PATH}${BACKUP_DIR}"

if [[ -z "${BACKUP_BASEDIR}" ]]; then
	BACKUP_BASEDIR="${BACKUP_DIR}_full"
fi

BACKUP_FULLBASEPATH="${BACKUP_PATH}${BACKUP_BASEDIR}"

if [[ ! -z "${BACKUP_S3_PATH}" && "${BACKUP_S3_PATH: -1}" != "/" ]]; then
	BACKUP_S3_PATH="${BACKUP_S3_PATH}/"
fi

# Check options

if ! [[ "${BACKUP_TARGET}" == "local" || "${BACKUP_TARGET}" == "s3" ]]; then
	cat <<-ERR >&2
Invalid backup target: "${BACKUP_TARGET}"

Choices:
  local   store the backup locally
  s3      upload the backup to Amazon S3 storage
ERR
	exit 1
fi


if ! [[ "${BACKUP_MODE}" == "full" || "${BACKUP_MODE}" == "incremental" ]]; then
	cat <<-ERR >&2
Invalid backup mode: "${BACKUP_MODE}"

Choices:
  full          create a full backup
  incremental   create an incremental backup
ERR
	exit 1
fi


if ! [[ -d "${BACKUP_PATH}" && -r "${BACKUP_PATH}" && -w "${BACKUP_PATH}" && -x "${BACKUP_PATH}" ]]; then
	cat <<-ERR >&2
Backup path not found or wrong permissions: "${BACKUP_PATH}"
ERR
	exit 1
fi

if [[ "${BACKUP_MODE}" == "incremental" ]] && ! [[ -d "${BACKUP_FULLBASEPATH}" && -r "${BACKUP_FULLBASEPATH}" && -x "${BACKUP_FULLBASEPATH}" ]]; then
	cat <<-ERR >&2
Backup base directory not found or wrong permissions: "${BACKUP_FULLBASEPATH}"
ERR
	exit 1
fi

if ! [[ -x "${BACKUP_XTRABACKUP_BINARY}" ]]; then
	cat <<-ERR >&2
XtraBackup binary not found or wrong permissions: "${BACKUP_XTRABACKUP_BINARY}"
ERR
	exit 1
fi

if [[ "${BACKUP_TARGET}" == "s3"  && ! -x "${BACKUP_S3_BINARY}" ]]; then
	cat <<-ERR >&2
s3cmd binary not found or wrong permissions: "${BACKUP_S3_BINARY}"
ERR
	exit 1
fi

if [[ "${BACKUP_TARGET}" == "s3"  && -z "${BACKUP_S3_BUCKET}" ]]; then
	cat <<-ERR >&2
No S3 bucket given. Use "--s3-bucket BUCKET".
ERR
	exit 1
fi

# delete previously created backup

if [[ -d "${BACKUP_FULLPATH}" ]]; then
	rm -rf ${BACKUP_FULLPATH}
fi


# create backup

BACKUP_COMMAND="${BACKUP_XTRABACKUP_BINARY} --user=${BACKUP_USER}"

if ! [[ -z ${BACKUP_PASSWORD} ]]; then
	BACKUP_COMMAND="${BACKUP_COMMAND} --password=${BACKUP_PASSWORD}"
fi

BACKUP_COMMAND="${BACKUP_COMMAND} --no-timestamp --target-dir=${BACKUP_FULLPATH} --parallel=4 --use-memory=640M"

if [[ "${BACKUP_MODE}" == "incremental" ]]; then
	BACKUP_COMMAND="${BACKUP_COMMAND} --incremental-basedir=${BACKUP_FULLBASEPATH}"
fi

if [[ "${BACKUP_MODE}" == "incremental" ]]; then
	BACKUP_COMMAND="${BACKUP_COMMAND} --apply-log-only"
fi

BACKUP_COMMAND="${BACKUP_COMMAND} --backup"

${BACKUP_COMMAND}


# check result

if [[ "$?" != "0" ]]; then
	cat <<-ERR >&2
There was an error while executing the following command:
${BACKUP_COMMAND}
ERR
	exit 1
fi


# archive backup
BACKUP_TARNAME="${BACKUP_PATH}$(date +%Y%m%d-%H%M)-${BACKUP_DIR}.tgz"
tar czf ${BACKUP_TARNAME} -C ${BACKUP_PATH} ${BACKUP_DIR}
exit 1
# upload and delete archive
if [[ "${BACKUP_MODE}" == "s3" ]]; then
	${BACKUP_S3_BINARY} put -f ${BACKUP_TARNAME} s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_PATH}
	rm ${BACKUP_TARNAME}
fi
