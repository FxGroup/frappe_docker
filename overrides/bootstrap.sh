#!/usr/bin/env bash
set -euxo pipefail

echo "🚀 Starting runtime configurator…"
cd /home/frappe/frappe-bench

# State tracking file
STATE_FILE="/home/frappe/frappe-bench/sites/.bootstrap_state"
CONFIG_CHECKSUM_FILE="/home/frappe/frappe-bench/sites/.config_checksum"

# Function to log completion of steps
log_step_complete() {
    echo "$1" >> "$STATE_FILE"
    echo "✅ Step completed: $1"
}

# Function to check if step was completed
is_step_complete() {
    [ -f "$STATE_FILE" ] && grep -q "^$1$" "$STATE_FILE"
}

# Function to get current config checksum
get_config_checksum() {
    echo -n "${DB_HOST}:${DB_PORT}:${REDIS_CACHE}:${REDIS_QUEUE}:${SOCKETIO_PORT}" | md5sum | cut -d' ' -f1
}

# Function to check if config has changed
config_changed() {
    local current_checksum=$(get_config_checksum)
    if [ -f "$CONFIG_CHECKSUM_FILE" ]; then
        local stored_checksum=$(cat "$CONFIG_CHECKSUM_FILE")
        [ "$current_checksum" != "$stored_checksum" ]
    else
        return 0  # No stored checksum means config "changed"
    fi
}

# Initialize directories and files
echo "📁 Setting up directories and files..."
mkdir -p sites
if [ ! -f sites/common_site_config.json ]; then
    echo "{}" > sites/common_site_config.json
    echo "✨ Created sites/common_site_config.json"
fi

# Update apps.txt files (always do this as it's quick and apps might change)
if ! is_step_complete "apps_txt_updated" || [ apps -nt sites/apps.txt ] || [ apps -nt apps.txt ]; then
    echo "📝 Updating apps.txt files..."
    ls -1 apps > sites/apps.txt
    ls -1 apps > apps.txt    
    log_step_complete "apps_txt_updated"
else
    echo "⏭️  Apps.txt files are up to date"
fi

# Configure bench settings (only if config changed)
if ! is_step_complete "bench_config_set" || config_changed; then
    echo "⚙️  Setting bench configuration..."
    bench set-config -g db_host       "$DB_HOST"
    bench set-config -gp db_port      "$DB_PORT"
    bench set-config -g redis_cache   "redis://$REDIS_CACHE"
    bench set-config -g redis_queue   "redis://$REDIS_QUEUE"
    bench set-config -gp socketio_port "$SOCKETIO_PORT"
    bench set-config -g developer_mode 1
    
    # Store the config checksum
    get_config_checksum > "$CONFIG_CHECKSUM_FILE"
    
    log_step_complete "bench_config_set"
else
    echo "⏭️  Bench configuration is up to date"
fi

# Check if bootstrap is completely done
if grep -q "^bootstrap_complete_" "$STATE_FILE" 2>/dev/null && ! config_changed; then
    echo "✅ Bootstrap already completed and config unchanged. Exiting."
    exit 0
fi

# Process each site
for site in fxmed.local naturalmeds.local rnlabs.local therahealth.local; do
    echo ""
    echo "🏥 Processing site: $site"
    
    # Get apps for this site
    apps=$(jq -r --arg s "$site" \
        '.[] | select(.site==$s) | .apps | join(" ")' \
        /assets/apps.json)
    
    # Create site if it doesn't exist
    if [ -d "/home/frappe/frappe-bench/sites/$site" ]; then
        echo "⏭️  Site $site already exists"
    else
        echo "✨ Creating site $site..."
        bench new-site \
            --admin-password "${ADMIN_PASSWORD:-Admin123}" \
            --mariadb-root-password "${MYSQL_ROOT_PASSWORD:-root}" \
            --db-host "$DB_HOST" \
            --db-port "$DB_PORT" \
            --verbose \
            --force \
            "$site"
        log_step_complete "site_created_$site"
        echo "✅ Site $site created"

    fi

    # Install apps (check each app individually)
    echo "📦 Checking apps for $site: $apps"
    for app in $apps; do
        app_state_key="app_installed_${site}_${app}"
        
        # Check if app is already installed
        if bench --site "$site" list-apps | grep -q "^$app$" 2>/dev/null; then
            if is_step_complete "$app_state_key"; then
                echo "⏭️  App $app already installed on $site"
                continue
            fi
        fi
        
        echo "📦 Installing app $app on $site..."
        if bench --site "$site" install-app "$app" --force; then
            log_step_complete "$app_state_key"
            echo "✅ App $app installed on $site"
        else
            echo "❌ Failed to install app $app on $site"
            exit 1
        fi
    done

    # Run migrations (with smart checking)
    migration_state_key="migrated_$site"
    
    # Check if we need to migrate (always migrate if new apps were installed)
    need_migration=false
    
    # Check if any apps were just installed
    for app in $apps; do
        if ! is_step_complete "app_installed_${site}_${app}"; then
            need_migration=true
            break
        fi
    done
    
    # Or if migration was never completed
    if ! is_step_complete "$migration_state_key"; then
        need_migration=true
    fi
    
    # Or if database schema might be outdated (check last migration vs app updates)
    if [ -f "/home/frappe/frappe-bench/sites/$site/site_config.json" ]; then
        site_config_time=$(stat -c %Y "/home/frappe/frappe-bench/sites/$site/site_config.json" 2>/dev/null || echo 0)
        apps_time=$(stat -c %Y "apps" 2>/dev/null || echo 0)
        if [ $apps_time -gt $site_config_time ]; then
            need_migration=true
        fi
    fi
    
    if [ "$need_migration" = true ]; then
        echo "🔄 Running migrations for $site..."
        if bench --site "$site" migrate; then
            log_step_complete "$migration_state_key"
            echo "✅ Migration completed for $site"
        else
            echo "❌ Migration failed for $site"
            exit 1
        fi
    else
        echo "⏭️  Migrations up to date for $site"
    fi
done

# Final cleanup and completion marker
echo ""
echo "🧹 Final cleanup..."
log_step_complete "bootstrap_complete_$(date +%Y%m%d_%H%M%S)"

echo ""
echo "✅ Runtime bootstrap complete!"
echo "📊 Bootstrap state saved in: $STATE_FILE"

# Optional: Show summary of what was done
echo ""
echo "📋 Bootstrap Summary:"
echo "  - Configuration: $(config_changed && echo "Updated" || echo "Unchanged")"
echo "  - Sites processed: fxmed.local, naturalmeds.local, rnlabs.local, therahealth.local"
echo "  - State file: $STATE_FILE"
echo ""