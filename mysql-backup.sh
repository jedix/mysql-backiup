#!/bin/bash
####################################################################
#Script Name: mysql-backup.sh
#Description: wrapper for Percona XtraBackup which can be controlled
#             with env varaibles to create backups and upload them
#             to Amazon S3 storage
#Author:      Jens Rey
#Email:       jrey@cocus.com
#Version:     1.0.0
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
--s3-host=HOSTNAME  HOSTNAME:PORT for S3 endpoint (default: s3.amazonaws.com)
--s3-host-bucket=HOST_BUCKET
                    DNS-style bucket+hostname:port template for accessing
                    a bucket (default: %(bucket)s.s3.amazonaws.com)
--s3-bucket=BUCKET  S3 bucket to store the backup in (default: empty)
--s3-path=PATH      path inside S3 bucket to store the backup in (default: empty)
--s3-secret-key=SECRET
                    AWS secret Key
--s3-access-key=ACCESS-KEY
                    AWS access Key
--s3-access-token=ACCESS-TOKEN
                    AWS access Token
--help              display this help
USAGE
exit 0
}


# load config defaults

if [ -f /etc/sysconfig/mysql-backup ]; then
    . /etc/sysconfig/mysql-backup
fi


# set default values

MYSQL_BACKUP_USER=${MYSQL_BACKUP_USER:-backupuser}
MYSQL_BACKUP_TARGET=${MYSQL_BACKUP_TARGET:-local}
MYSQL_BACKUP_MODE=${MYSQL_BACKUP_MODE:-full}
MYSQL_BACKUP_PATH=${MYSQL_BACKUP_PATH:-/backup/}
MYSQL_BACKUP_DIR=${MYSQL_BACKUP_DIR:-db}
MYSQL_BACKUP_XTRABACKUP_BINARY=${MYSQL_BACKUP_XTRABACKUP_BINARY:-/usr/bin/xtrabackup}
MYSQL_BACKUP_S3_BINARY=${MYSQL_BACKUP_S3_BINARY:-/usr/bin/s3cmd}
MYSQL_BACKUP_S3_HOST=${MYSQL_BACKUP_S3_HOST:-s3.amazonaws.com}
MYSQL_BACKUP_S3_HOST_BUCKET=${MYSQL_BACKUP_S3_HOST_BUCKET:-%(bucket)s.s3.amazonaws.com}


# parse command line arguments

while [ $# -gt 0 ]; do
  case "$1" in
    --user=*)
      MYSQL_BACKUP_USER="${1#*=}"
      ;;
    --password=*)
      MYSQL_BACKUP_PASSWORD="${1#*=}"
      ;;
    --target=*)
      MYSQL_BACKUP_TARGET="${1#*=}"
      ;;
    --mode=*)
      MYSQL_BACKUP_MODE="${1#*=}"
      ;;
    --path=*)
      MYSQL_BACKUP_PATH="${1#*=}"
      ;;
    --dirname=*)
      MYSQL_BACKUP_DIR="${1#*=}"
      ;;
    --base-dir=*)
      MYSQL_BACKUP_BASEDIR="${1#*=}"
      ;;
    --pxb-binary=*)
      MYSQL_BACKUP_XTRABACKUP_BINARY="${1#*=}"
      ;;
    --s3-binary=*)
      MYSQL_BACKUP_S3_BINARY="${1#*=}"
      ;;
    --s3-bucket=*)
      MYSQL_BACKUP_S3_BUCKET="${1#*=}"
      ;;
    --s3-path=*)
      MYSQL_BACKUP_S3_PATH="${1#*=}"
      ;;
    --s3-host=*)
      MYSQL_BACKUP_S3_HOST="${1#*=}"
      ;;
    --s3-host-bucket=*)
      MYSQL_BACKUP_S3_HOST_BUCKET="${1#*=}"
      ;;
    --s3-secret-key=*)
      MYSQL_BACKUP_S3_SECRET_KEY="${1#*=}"
      ;;
    --s3-access-key=*)
      MYSQL_BACKUP_S3_ACCESS_KEY="${1#*=}"
      ;;
    --s3-access-token=*)
      MYSQL_BACKUP_S3_ACCESS_TOKEN="${1#*=}"
      ;;
    -h|--help) print_usage;;
    *)
      print_usage
      exit 1
  esac
  shift
done

if [[ "${MYSQL_BACKUP_PATH: -1}" != "/" ]]; then
    MYSQL_BACKUP_PATH="${MYSQL_BACKUP_PATH}/"
fi

if [[ "${MYSQL_BACKUP_MODE}" == "full" ]]; then
    MYSQL_BACKUP_DIR="${MYSQL_BACKUP_DIR}_full"
fi

MYSQL_BACKUP_FULLPATH="${MYSQL_BACKUP_PATH}${MYSQL_BACKUP_DIR}"

if [[ -z "${MYSQL_BACKUP_BASEDIR}" ]]; then
    MYSQL_BACKUP_BASEDIR="${MYSQL_BACKUP_DIR}_full"
fi

MYSQL_BACKUP_FULLBASEPATH="${MYSQL_BACKUP_PATH}${MYSQL_BACKUP_BASEDIR}"

if [[ ! -z "${MYSQL_BACKUP_S3_PATH}" && "${MYSQL_BACKUP_S3_PATH: -1}" != "/" ]]; then
    MYSQL_BACKUP_S3_PATH="${MYSQL_BACKUP_S3_PATH}/"
fi

# Check options

if ! [[ "${MYSQL_BACKUP_TARGET}" == "local" || "${MYSQL_BACKUP_TARGET}" == "s3" ]]; then
    cat <<-ERR >&2
Invalid backup target: "${MYSQL_BACKUP_TARGET}"

Choices:
  local   store the backup locally
  s3      upload the backup to Amazon S3 storage
ERR
    exit 1
fi


if ! [[ "${MYSQL_BACKUP_MODE}" == "full" || "${MYSQL_BACKUP_MODE}" == "incremental" ]]; then
    cat <<-ERR >&2
Invalid backup mode: "${MYSQL_BACKUP_MODE}"

Choices:
  full          create a full backup
  incremental   create an incremental backup
ERR
    exit 1
fi

if ! [[ -d "${MYSQL_BACKUP_PATH}" ]]; then
  mkdir -p ${MYSQL_BACKUP_PATH}
fi

if ! [[ -d "${MYSQL_BACKUP_PATH}" && -r "${MYSQL_BACKUP_PATH}" && -w "${MYSQL_BACKUP_PATH}" && -x "${MYSQL_BACKUP_PATH}" ]]; then
  cat <<-ERR >&2
Backup path not found and could not be created or wrong permissions: "${MYSQL_BACKUP_PATH}"
ERR
  exit 1
fi

if [[ "${MYSQL_BACKUP_MODE}" == "incremental" ]] && ! [[ -d "${MYSQL_BACKUP_FULLBASEPATH}" && -r "${MYSQL_BACKUP_FULLBASEPATH}" && -x "${MYSQL_BACKUP_FULLBASEPATH}" ]]; then
    cat <<-ERR >&2
Backup base directory not found or wrong permissions: "${MYSQL_BACKUP_FULLBASEPATH}"
ERR
    exit 1
fi

if ! [[ -x "${MYSQL_BACKUP_XTRABACKUP_BINARY}" ]]; then
    cat <<-ERR >&2
XtraBackup binary not found or wrong permissions: "${MYSQL_BACKUP_XTRABACKUP_BINARY}"
ERR
    exit 1
fi

if [[ "${MYSQL_BACKUP_TARGET}" == "s3"  && ! -x "${MYSQL_BACKUP_S3_BINARY}" ]]; then
    cat <<-ERR >&2
s3cmd binary not found or wrong permissions: "${MYSQL_BACKUP_S3_BINARY}"
ERR
    exit 1
fi

if [[ "${MYSQL_BACKUP_TARGET}" == "s3"  && -z "${MYSQL_BACKUP_S3_BUCKET}" ]]; then
    cat <<-ERR >&2
No S3 bucket given. Use "--s3-bucket BUCKET".
ERR
    exit 1
fi

# delete previously created backup

if [[ -d "${MYSQL_BACKUP_FULLPATH}" ]]; then
    rm -rf ${MYSQL_BACKUP_FULLPATH}
fi


# create backup

MYSQL_BACKUP_COMMAND="${MYSQL_BACKUP_XTRABACKUP_BINARY} --user=${MYSQL_BACKUP_USER}"

if ! [[ -z ${MYSQL_BACKUP_PASSWORD} ]]; then
    MYSQL_BACKUP_COMMAND="${MYSQL_BACKUP_COMMAND} --password=${MYSQL_BACKUP_PASSWORD}"
fi

MYSQL_BACKUP_COMMAND="${MYSQL_BACKUP_COMMAND} --no-timestamp --target-dir=${MYSQL_BACKUP_FULLPATH} --parallel=4 --use-memory=640M"

if [[ "${MYSQL_BACKUP_MODE}" == "incremental" ]]; then
    MYSQL_BACKUP_COMMAND="${MYSQL_BACKUP_COMMAND} --incremental-basedir=${MYSQL_BACKUP_FULLBASEPATH}"
fi

if [[ "${MYSQL_BACKUP_MODE}" == "incremental" ]]; then
    MYSQL_BACKUP_COMMAND="${MYSQL_BACKUP_COMMAND} --apply-log-only"
fi

MYSQL_BACKUP_COMMAND="${MYSQL_BACKUP_COMMAND} --backup"

${MYSQL_BACKUP_COMMAND}


# check result

if [[ "$?" != "0" ]]; then
    cat <<-ERR >&2
There was an error while executing the following command:
${MYSQL_BACKUP_COMMAND}
ERR
    exit 1
fi


# archive backup

MYSQL_BACKUP_TARNAME="${MYSQL_BACKUP_PATH}$(date +%Y%m%d-%H%M)-${MYSQL_BACKUP_DIR}.tgz"
tar czf ${MYSQL_BACKUP_TARNAME} -C ${MYSQL_BACKUP_PATH} ${MYSQL_BACKUP_DIR}


# upload and delete archive

if [[ "${MYSQL_BACKUP_TARGET}" == "s3" ]]; then
    MYSQL_BACKUP_S3_COMMAND="${MYSQL_BACKUP_S3_BINARY}"
    if ! [[ -z ${MYSQL_BACKUP_S3_SECRET_KEY} ]]; then
        MYSQL_BACKUP_S3_COMMAND="${MYSQL_BACKUP_S3_COMMAND} --secret=${MYSQL_BACKUP_S3_SECRET_KEY}"
    fi
    if ! [[ -z ${MYSQL_BACKUP_S3_ACCESS_KEY} ]]; then
        MYSQL_BACKUP_S3_COMMAND="${MYSQL_BACKUP_S3_COMMAND} --access_key=${MYSQL_BACKUP_S3_ACCESS_KEY}"
    fi
    if ! [[ -z ${MYSQL_BACKUP_S3_ACCESS_TOKEN} ]]; then
        MYSQL_BACKUP_S3_COMMAND="${MYSQL_BACKUP_S3_COMMAND} --access_token=${MYSQL_BACKUP_S3_ACCESS_TOKEN}"
    fi
    if ! [[ -z ${MYSQL_BACKUP_S3_HOST} ]]; then
        MYSQL_BACKUP_S3_COMMAND="${MYSQL_BACKUP_S3_COMMAND} --host=${MYSQL_BACKUP_S3_HOST}"
    fi
    if ! [[ -z ${MYSQL_BACKUP_S3_HOST_BUCKET} ]]; then
        MYSQL_BACKUP_S3_COMMAND="${MYSQL_BACKUP_S3_COMMAND} --host-bucket=${MYSQL_BACKUP_S3_HOST_BUCKET}"
    fi

    MYSQL_BACKUP_S3_COMMAND="${MYSQL_BACKUP_S3_COMMAND} --mime-type=application/tar+gz put ${MYSQL_BACKUP_TARNAME} s3://${MYSQL_BACKUP_S3_BUCKET}/${MYSQL_BACKUP_S3_PATH}"
    ${MYSQL_BACKUP_S3_COMMAND}
    rm ${MYSQL_BACKUP_TARNAME}
fi
