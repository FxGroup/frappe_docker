#!/usr/bin/env bash
set -e

echo "🚀 Starting runtime configurator…"

cd /home/frappe/frappe-bench

# ── Only set configs if env var is defined ──
[ -n "$DB_HOST" ]       && bench set-config -g db_host       "$DB_HOST"
[ -n "$DB_PORT" ]       && bench set-config -gp db_port      "$DB_PORT"
[ -n "$REDIS_CACHE" ]   && bench set-config -g redis_cache   "redis://$REDIS_CACHE"
[ -n "$REDIS_QUEUE" ]   && bench set-config -g redis_queue   "redis://$REDIS_QUEUE"
[ -n "$REDIS_QUEUE" ]   && bench set-config -g redis_socketio "redis://$REDIS_QUEUE"
[ -n "$SOCKETIO_PORT" ] && bench set-config -gp socketio_port "$SOCKETIO_PORT"

# 2) Create & populate all sites (now that DB is up)
for site in fxmed.local naturalmeds.local rnlabs.local therahealth.local; do
  echo "💡 Creating / bootstrapping $site"
  apps=$(jq -r --arg s "$site" '.[]|select(.site==$s)|.apps|join(" ")' /assets/apps.json)

  # new-site only takes one app, so split:
  first=$(echo $apps | cut -d' ' -f1)
  rest=$(echo $apps | cut -d' ' -f2-)

  echo "Creating site $site and installing app $first"
  bench new-site "$site" \
    --admin-password "${ADMIN_PASSWORD:-Admin123}" \
    --mariadb-root-password "${MYSQL_ROOT_PASSWORD:-root}" \
    --install-app "$first"

  echo "Site $site created"  

  if [ -n "$rest" ]; then
    echo "Installing app $rest into $site"
    bench --site "$site" install-app $rest
  fi

  # and run migrations to be safe
  echo "Migrating $site"  
  bench --site "$site" migrate
  echo "Migrating $site complete" 
done

echo "✅ Runtime bootstrap complete."

