#!/usr/bin/env bash
set -euo pipefail

# Configuration
REMOTE_USER="frappe"
REMOTE_HOST="170.64.152.170"
REMOTE_BENCH_PATH="/home/frappe/frappe-bench"
LOCAL_BENCH_PATH="/home/frappe/frappe-bench"

# Local database configuration (set these to match your Docker environment)
LOCAL_DB_HOST="${DB_HOST:-db}"
LOCAL_DB_PORT="${DB_PORT:-3306}"
LOCAL_DB_USER="${DB_USER:-root}"
LOCAL_DB_PASSWORD="${DB_PASSWORD:-root}"
LOCAL_SITE="${1}.local"  # Dynamic local site name based on parameter

# Function to display usage
usage() {
    echo "Usage: $0 <site_name>"
    echo "Example: $0 fxmed"
    echo "This will pull backup from erpnext.${1}.co.nz and restore to ${1}.local"
    exit 1
}

# Check if site name provided
if [ $# -eq 0 ]; then
    usage
fi

SITE_NAME=$1
REMOTE_SITE="erpnext.${SITE_NAME}.co.nz"
REMOTE_BACKUP_DIR="${REMOTE_BENCH_PATH}/sites/${REMOTE_SITE}/private/backups"
LOCAL_TEMP_DIR="/tmp/backups"

echo "🚀 Starting backup pull and restore process..."
echo "Remote site: $REMOTE_SITE"
echo "Local site: $LOCAL_SITE"

# Check if we're in the right directory
if [[ ${PWD} != "$LOCAL_BENCH_PATH" ]]; then
    echo "❌ Error: Must be run from $LOCAL_BENCH_PATH"
    exit 1
fi

# Create local temp directory
mkdir -p "$LOCAL_TEMP_DIR"

echo "📦 Creating backup on remote server..."
# Run the backup command on remote server
ssh "${REMOTE_USER}@${REMOTE_HOST}" "cd ${REMOTE_BENCH_PATH} && bench --site ${REMOTE_SITE} backup --exclude 'Error Log,Access Log,Activity Log,Website Theme'"

echo "🔍 Finding latest backup file..."
# Get the latest backup file path from remote server
LATEST_BACKUP=$(ssh "${REMOTE_USER}@${REMOTE_HOST}" "
    dir=${REMOTE_BACKUP_DIR}
    latest=''
    for file in \"\$dir\"/*; do
        [[ \$file -nt \$latest ]] && latest=\$file
    done
    echo \$latest
")

if [ -z "$LATEST_BACKUP" ]; then
    echo "❌ Error: No backup file found on remote server"
    exit 1
fi

echo "📥 Downloading backup file: $(basename $LATEST_BACKUP)"
# Download the backup file
scp "${REMOTE_USER}@${REMOTE_HOST}:${LATEST_BACKUP}" "$LOCAL_TEMP_DIR/"

LOCAL_BACKUP_FILE="$LOCAL_TEMP_DIR/$(basename $LATEST_BACKUP)"

echo "🗄️  Restoring backup to local site: $LOCAL_SITE"
# Restore the backup to local site
bench --site "$LOCAL_SITE" --verbose partial-restore "$LOCAL_BACKUP_FILE"

echo "🔧 Updating database configuration for local environment..."
# Update database config to match local environment
bench --site "$LOCAL_SITE" set-config db_host "$DB_HOST"
bench --site "$LOCAL_SITE" set-config db_port "$DB_PORT"
# Use environment variables or default values for local DB credentials
bench --site "$LOCAL_SITE" set-config db_user "${LOCAL_DB_USER:-root}"
bench --site "$LOCAL_SITE" set-config db_password "${LOCAL_DB_PASSWORD:-root}"

echo "⚙️  Configuring local site for development..."

# Stop email queue (if the function exists)
echo "  - Stopping email queue..."
bench --site "$LOCAL_SITE" execute "fxnmrnth.api.stopQueue" 2>/dev/null || echo "    (stopQueue function not found - skipping)"

# Stop WooCommerce stock sync
echo "  - Stopping WooCommerce stock sync..."
bench --site "$LOCAL_SITE" execute --kwargs "{'stop_flag': 1}" "fxnmrnth.fxnmrnth.doctype.woocommerce.woocommerce.stop_stock_sync" 2>/dev/null || echo "    (WooCommerce sync function not found - skipping)"

# Stop Laravel stock sync
echo "  - Stopping Laravel stock sync..."
bench --site "$LOCAL_SITE" execute --kwargs "{'stop_flag': 1}" "fxnmrnth.fxnmrnth.doctype.laravel.laravel.stop_stock_sync" 2>/dev/null || echo "    (Laravel sync function not found - skipping)"

# Stop S3 Backup
echo "  - Stopping S3 backup..."
bench --site "$LOCAL_SITE" execute --kwargs "{'stop_flag': 1}" "fxnmrnth.api.stop_s3_backup" 2>/dev/null || echo "    (S3 backup function not found - skipping)"

# Disable scheduler
echo "  - Disabling scheduler..."
bench --site "$LOCAL_SITE" disable-scheduler

echo "🧹 Cleaning up temporary files..."
rm -f "$LOCAL_BACKUP_FILE"

echo ""
echo "✅ Backup restore completed successfully!"
echo "🎯 Local site '$LOCAL_SITE' has been restored from '$REMOTE_SITE'"
echo "🔧 Development configurations applied:"
echo "   - Email queue stopped"
echo "   - Stock sync disabled"
echo "   - S3 backup disabled" 
echo "   - Scheduler disabled"
echo ""
echo "🚀 Your local site is ready for development!"