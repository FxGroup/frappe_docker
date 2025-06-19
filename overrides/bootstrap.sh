#!/usr/bin/env bash
set -e

echo "🚀 Starting configurator bootstrap…"

# ── Only set configs if env var is defined ──
[ -n "$DB_HOST" ]       && bench set-config -g db_host       "$DB_HOST"
[ -n "$DB_PORT" ]       && bench set-config -gp db_port      "$DB_PORT"
[ -n "$REDIS_CACHE" ]   && bench set-config -g redis_cache   "redis://$REDIS_CACHE"
[ -n "$REDIS_QUEUE" ]   && bench set-config -g redis_queue   "redis://$REDIS_QUEUE"
[ -n "$REDIS_QUEUE" ]   && bench set-config -g redis_socketio "redis://$REDIS_QUEUE"
[ -n "$SOCKETIO_PORT" ] && bench set-config -gp socketio_port "$SOCKETIO_PORT"

# ── Create sites if missing ──
for site in fxmed.local naturalmeds.local rnlabs.local therahealth.local; do
  echo "💡 Processing site: $site"
  if [ ! -d "/home/frappe/frappe-bench/sites/$site" ]; then
    echo "✨ Creating site: $site"
    bench new-site "$site" \
      --admin-password "${ADMIN_PASSWORD:-Admin123}" \
      --mariadb-root-password "${MYSQL_ROOT_PASSWORD:-root}" \
      --mariadb-user-host-login-scope='%' \
      --install-app erpnext
  else
    echo "✅ Site $site already exists"
  fi
done

# ── Install custom apps into each real site folder ──
if [ -f /assets/custom-apps.txt ]; then
  for entry in /home/frappe/frappe-bench/sites/*; do
    [ -d "$entry" ] || continue
    site=$(basename "$entry")
    [ "$site" = "Assets" ] && continue

    echo "🔄 Installing custom apps into site: $site"
    while IFS= read -r repo; do
      url=${repo%%#*}
      branch=${repo##*#}
      name=$(basename "$url" .git)

      if [ ! -d "/home/frappe/frappe-bench/apps/$name" ]; then
        bench get-app "$name" "$url" --branch "$branch"
      fi

      bench --site "$site" install-app "$name"
    done < /assets/custom-apps.txt
  done
fi
