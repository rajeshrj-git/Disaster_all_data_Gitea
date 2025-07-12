#!/bin/bash
set -eo pipefail

# --------------------------
# Configuration
# --------------------------
CONFIG_FILE="${1:-./credential_config.sh}"

# --------------------------
# Load Configuration
# --------------------------
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Critical Error: Configuration file '$CONFIG_FILE' not found" >&2
    echo "💡 Create a configuration file with the following variables:" >&2
    echo "   # Database Configuration" >&2
    echo "   DB_USER=\"gitea\"" >&2
    echo "   DB_PASS=\"your_password_here\"" >&2
    echo "   DB_HOST=\"localhost\"" >&2
    echo "   GITEA_DATA_DIR=\"/var/lib/gitea\"" >&2
    echo "   # AWS S3 Configuration" >&2
    echo "   AWS_ACCESS_KEY_ID=\"your_aws_access_key\"" >&2
    echo "   AWS_SECRET_ACCESS_KEY=\"your_aws_secret_key\"" >&2
    echo "   AWS_DEFAULT_REGION=\"us-east-1\"" >&2
    echo "   S3_BUCKET=\"your-bucket-name\"" >&2
    echo "   S3_PATH=\"gitea-backups\"" >&2
    echo "   # Retention Policy" >&2
    echo "   RETENTION_DAYS=7" >&2
    exit 1
fi

source "$CONFIG_FILE"

# --------------------------
# Validate Configuration
# --------------------------
declare -a REQUIRED_VARS=("DB_USER" "DB_PASS" "AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY" "S3_BUCKET")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        echo "❌ Critical Error: $var is not set in configuration file" >&2
        exit 1
    fi
done

# Set defaults
DB_HOST="${DB_HOST:-localhost}"
GITEA_DATA_DIR="${GITEA_DATA_DIR:-/var/lib/gitea}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
S3_PATH="${S3_PATH:-gitea-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
REPO_DIR="${GITEA_DATA_DIR}/data/gitea-repositories"

# --------------------------
# Initialize Backup
# --------------------------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="gitea_backup_${TIMESTAMP}.zip"
TMP_DIR=$(mktemp -d -t gitea_backup_XXXXXX)
LOG_FILE="/var/log/gitea_backup_${TIMESTAMP}.log"

cleanup() {
    local exit_code=$?
    [[ -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
    exit $exit_code
}
trap cleanup EXIT

# --------------------------
# Logging Setup
# --------------------------
exec > >(tee -a "$LOG_FILE") 2>&1
echo "[$(date)] Starting Gitea Backup Process"
echo "Configuration:"
echo "  - Database User: $DB_USER"
echo "  - Database Host: $DB_HOST"
echo "  - Repository Directory: $REPO_DIR"
echo "AWS S3 Configuration:"
echo "  - S3 Bucket: $S3_BUCKET"
echo "  - S3 Path: $S3_PATH"
echo "  - AWS Region: $AWS_DEFAULT_REGION"
echo "Retention Policy: $RETENTION_DAYS days"

# --------------------------
# Pre-flight Checks
# --------------------------
echo "🔍 Running pre-flight checks..."

# Check directories
if [[ ! -d "$REPO_DIR" ]]; then
    echo "❌ Repository directory not found: $REPO_DIR" >&2
    exit 1
fi

# Check database connectivity
if ! mysql -u "$DB_USER" -p"$DB_PASS" -h "$DB_HOST" -e "SHOW DATABASES;" &>/dev/null; then
    echo "❌ Database connection failed" >&2
    echo "   Troubleshooting:" >&2
    echo "   1. Verify credentials" >&2
    echo "   2. Check service: systemctl status mysql" >&2
    echo "   3. Verify privileges: SHOW GRANTS FOR '$DB_USER'@'$DB_HOST'" >&2
    exit 2
fi

# Check AWS CLI
if ! command -v aws &>/dev/null; then
    echo "❌ AWS CLI is not installed" >&2
    echo "   Install with: sudo apt install awscli (Debian/Ubuntu) or sudo yum install awscli (RHEL/CentOS)" >&2
    exit 3
fi

# Verify AWS credentials
if ! AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
   AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
   AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
   aws sts get-caller-identity &>/dev/null; then
    echo "❌ AWS credentials verification failed" >&2
    exit 4
fi

# Check S3 bucket access
if ! AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
   AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
   AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
   aws s3 ls "s3://$S3_BUCKET" &>/dev/null; then
    echo "❌ Cannot access S3 bucket: $S3_BUCKET" >&2
    exit 5
fi

# --------------------------
# Backup Process
# --------------------------

# 1. Backup ALL databases
echo "🛢️ Backing up ALL databases..."
if ! MYSQL_PWD="$DB_PASS" mysqldump \
    --single-transaction \
    --routines \
    --triggers \
    --add-drop-table \
    --disable-keys \
    --extended-insert \
    -u "$DB_USER" \
    -h "$DB_HOST" \
    --all-databases > "$TMP_DIR/all_databases.sql"; then
    echo "❌ Database backup failed" >&2
    exit 6
fi

# 2. Backup repositories
echo "📦 Backing up repositories..."
if ! rsync -a --delete --info=progress2 "$REPO_DIR/" "$TMP_DIR/repositories/"; then
    echo "❌ Repository backup failed" >&2
    exit 7
fi

# 3. Create archive
echo "🗜️ Creating backup archive..."
if ! (cd "$TMP_DIR" && zip -qr -9 "$TMP_DIR/$BACKUP_NAME" .); then
    echo "❌ Archive creation failed" >&2
    exit 8
fi

# 4. Verify backup
echo "✅ Verifying backup integrity..."
if ! zip -T "$TMP_DIR/$BACKUP_NAME"; then
    echo "❌ Backup archive is corrupted" >&2
    exit 9
fi

# 5. Upload to S3
echo "☁️ Uploading backup to S3..."
S3_FULL_PATH="s3://$S3_BUCKET/$S3_PATH/$BACKUP_NAME"
if ! AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
   AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
   AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
   aws s3 cp "$TMP_DIR/$BACKUP_NAME" "$S3_FULL_PATH"; then
    echo "❌ Failed to upload backup to S3" >&2
    exit 10
fi

# 6. Apply retention policy
echo "🧹 Applying retention policy ($RETENTION_DAYS days)..."
aws s3 ls "s3://$S3_BUCKET/$S3_PATH/" | \
  while read -r line; do
    create_date=$(echo "$line" | awk '{print $1" "$2}')
    create_epoch=$(date -d "$create_date" +%s)
    older_than_epoch=$(date -d "$RETENTION_DAYS days ago" +%s)
    if [[ "$create_epoch" -lt "$older_than_epoch" ]]; then
      file=$(echo "$line" | awk '{print $4}')
      echo "Deleting old backup: $file"
      aws s3 rm "s3://$S3_BUCKET/$S3_PATH/$file"
    fi
  done

# --------------------------
# Completion
# --------------------------
BACKUP_SIZE=$(du -h "$TMP_DIR/$BACKUP_NAME" | cut -f1)
echo "✅ Backup completed successfully!"
echo "   ☁️  S3 Location: $S3_FULL_PATH"
echo "   📊 Size: $BACKUP_SIZE"
echo "   📝 Log: $LOG_FILE"
echo "[$(date)] Backup process completed"
exit 0
