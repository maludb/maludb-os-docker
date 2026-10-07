#!/bin/bash
# bos-init — installs and reconciles the Business OS inside the container, following
# docs/install.md §3–§13 with docs/install-on-maludb-hosting.md's substitutions:
# PostgreSQL and the MaluDB API are the HOST VM's (reached as pg-host through the psql shim),
# the memory database/role are the tenant's, and only Help Desk + Spaces are installed.
#
# Runs at every boot (bos-init.service, EnvironmentFile=/etc/bos.env):
#   phase A  (every boot)   render config from env + persisted secrets, /etc/hosts, vhost,
#                           volume permissions — everything the ephemeral layer forgets
#   phase B  (once)         databases, migrations, super-admin, model, agents — guarded by
#                           markers on the bos-etc volume, resumable after a failure
#   phase C  (every boot)   app_install.php apply for helpdesk + spaces (idempotent reconcile),
#                           then the §13 verification battery and the install report
set -uo pipefail

BOS=/etc/business-os
SECRETS=$BOS/secrets
STATE=$BOS/init-state
LOG=/var/log/bos-init.log
exec > >(tee -a "$LOG") 2>&1
echo "=================== bos-init $(date -u +%FT%TZ) ==================="

die() { echo "bos-init: FATAL: $*" >&2; exit 1; }
note() { echo "-- $*"; }

# Required configuration (from /etc/bos.env via the unit)
for v in DOMAIN ADMIN_EMAIL ADMIN_NAME PG_SUPERUSER PG_SUPERUSER_PASSWORD MEM_DB MEM_USER MEM_PASSWORD MEM_SCHEMA; do
    [ -n "${!v:-}" ] || die "required variable $v is empty — check /etc/business-os-docker/bos.env on the host"
done
APP_ENV=${APP_ENV:-prod}
SCHEME=${SCHEME:-https}
MALUDB_API_URL=${MALUDB_API_URL:-http://pg-host:8000}
MODEL_KEY=${MODEL_KEY:-claude-fable-5-1}
MODEL_NAME=${MODEL_NAME:-Claude Fable 5.1}
MODEL_PROVIDER_ID=${MODEL_PROVIDER_ID:-$MODEL_KEY}
DB=certstudy

mkdir -p "$BOS" "$STATE"; install -d -m 700 "$SECRETS"

# secret NAME [generator...] — load-or-create a persisted secret on the bos-etc volume
secret() {
    local f="$SECRETS/$1"
    if [ ! -s "$f" ]; then (umask 077; openssl rand -hex "${2:-32}" > "$f"); fi
    cat "$f"
}

# set_kv FILE KEY VALUE — set KEY=VALUE in an env-style file (replace or append)
set_kv() {
    local f=$1 k=$2 v=$3
    if grep -qE "^${k}=" "$f" 2>/dev/null; then
        awk -v k="$k" -v v="$v" 'BEGIN{FS=OFS="="} index($0,k"=")==1{print k"="v; next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}

once() { # once NAME command... — run a phase-B step exactly once, resumably
    local name=$1; shift
    if [ -f "$STATE/$name" ]; then note "$name: already done"; return 0; fi
    echo "== $name"
    "$@" || die "step '$name' failed"
    touch "$STATE/$name"
}

# ======================= PHASE A — every boot ====================================================

echo "== phase A: environment, config, permissions"

# PG client defaults for the psql shim, and the superuser pgpass files
cat > "$BOS/pg-client.env" <<EOF
PGHOST=pg-host
PGPORT=5432
BOS_PG_SUPERUSER=$PG_SUPERUSER
EOF
chmod 644 "$BOS/pg-client.env"
for u in root postgres; do
    f="$BOS/pgpass-$u"
    (umask 077; printf '*:*:*:%s:%s\n' "$PG_SUPERUSER" "$PG_SUPERUSER_PASSWORD" > "$f")
    chown "$u:$u" "$f"
done

# Volume mount points lose image ownership when pre-existing volumes are attached — re-assert
install -d -o www-data -g www-data -m 750 /var/www/storage
install -d -o bos-runner -g bos-agent -m 2770 /var/lib/business-os /var/lib/business-os/agents
install -d -m 755 /srv/apps

# Loopback names (docker rewrites /etc/hosts at every start)
for n in "$DOMAIN" "www.$DOMAIN" "os.$DOMAIN" "app.$DOMAIN" "helpdesk.$DOMAIN" "spaces.$DOMAIN"; do
    grep -qE "[[:space:]]$n(\$|[[:space:]])" /etc/hosts || echo "127.0.0.1 $n" >> /etc/hosts
done

# Wait for the host's PostgreSQL and MaluDB API
for i in $(seq 1 60); do pg_isready -h pg-host -p 5432 -q && break; [ "$i" = 60 ] && die "host PostgreSQL unreachable at pg-host:5432"; sleep 2; done
PGPASSFILE="$BOS/pgpass-root" psql -h pg-host -U "$PG_SUPERUSER" -d postgres -Atc 'select 1' >/dev/null || die "superuser login $PG_SUPERUSER failed against host PostgreSQL"
for i in $(seq 1 30); do curl -fsS --max-time 3 "$MALUDB_API_URL/health" >/dev/null && break; [ "$i" = 30 ] && die "MaluDB API unreachable at $MALUDB_API_URL"; sleep 2; done

# Secrets (persisted on the bos-etc volume; stable across image upgrades)
APP_TOTP_KEY=$(secret app_totp_key);        ACTION_TOKEN_KEY=$(secret action_token_key)
SECRETS_KEY=$(secret secrets_key);          WEB_INTERNAL_KEY=$(secret web_internal_key)
RUNNER_KEY=$(secret runner_key);            ACTIONS_RELAY_KEY=$(secret actions_relay_key)
PROXY_KEY_SECRET=$(secret proxy_key_secret)
PW_RW=$(secret pw_app_rw 24); PW_REC=$(secret pw_app_records_ro 24)
PW_ACT=$(secret pw_app_activity_ro 24); PW_RUN=$(secret pw_app_runner 24)

# MaluDB memory token: reuse if still valid, else mint against the tenant's memory role (§2.3
# replaced per the hosting runbook — the memory database/user are the tenant's)
TOKEN_FILE=$SECRETS/maludb.token
if [ -s "$TOKEN_FILE" ] && curl -fsS --max-time 5 "$MALUDB_API_URL/v1/whoami" -H "Authorization: Bearer $(cat "$TOKEN_FILE")" >/dev/null 2>&1; then
    note "memory token: reusing persisted token"
else
    note "memory token: minting for db=$MEM_DB user=$MEM_USER"
    tok=$(curl -fsS -X POST "$MALUDB_API_URL/v1/tokens" -H 'Content-Type: application/json' \
        -d "$(jq -n --arg d "$MEM_DB" --arg u "$MEM_USER" --arg p "$MEM_PASSWORD" '{pg_dbname:$d,pg_user:$u,pg_password:$p,label:"kernel"}')" | jq -r .token)
    [ -n "$tok" ] && [ "$tok" != null ] || die "could not mint MaluDB memory token"
    (umask 077; printf '%s' "$tok" > "$TOKEN_FILE")
fi
MALUDB_API_TOKEN=$(cat "$TOKEN_FILE")

# config/.env (install.md §5, on the bos-config volume)
ENVF=/var/www/config/.env
[ -f "$ENVF" ] || cp /var/www/config/.env.example "$ENVF"
set_kv "$ENVF" APP_ENV "$APP_ENV"
set_kv "$ENVF" APP_URL "$SCHEME://app.$DOMAIN"
set_kv "$ENVF" OS_HOST "os.$DOMAIN"
set_kv "$ENVF" APP_HOST "app.$DOMAIN"
set_kv "$ENVF" SESSION_COOKIE_DOMAIN ".$DOMAIN"
set_kv "$ENVF" DB_HOST pg-host
set_kv "$ENVF" DB_PORT 5432
set_kv "$ENVF" DB_NAME "$DB"
set_kv "$ENVF" DB_USER app_rw
set_kv "$ENVF" DB_PASSWORD "$PW_RW"
set_kv "$ENVF" MCP_RECORDS_DB_USER app_records_ro
set_kv "$ENVF" MCP_RECORDS_DB_PASSWORD "$PW_REC"
set_kv "$ENVF" MCP_ACTIVITY_DB_USER app_activity_ro
set_kv "$ENVF" MCP_ACTIVITY_DB_PASSWORD "$PW_ACT"
set_kv "$ENVF" APP_TOTP_KEY "$APP_TOTP_KEY"
set_kv "$ENVF" ACTION_TOKEN_KEY "$ACTION_TOKEN_KEY"
set_kv "$ENVF" SECRETS_KEY "$SECRETS_KEY"
set_kv "$ENVF" WEB_INTERNAL_KEY "$WEB_INTERNAL_KEY"
set_kv "$ENVF" RUNNER_KEY "$RUNNER_KEY"
set_kv "$ENVF" ACTIONS_RELAY_KEY "$ACTIONS_RELAY_KEY"
set_kv "$ENVF" MALUDB_API_URL "$MALUDB_API_URL"
set_kv "$ENVF" MALUDB_API_TOKEN "$MALUDB_API_TOKEN"
set_kv "$ENVF" MALUDB_MEMORY_DB "$MEM_DB"
set_kv "$ENVF" MALUDB_MEMORY_USER "$MEM_USER"
set_kv "$ENVF" MALUDB_MEMORY_PASSWORD "$MEM_PASSWORD"
set_kv "$ENVF" MAIL_FROM "no-reply@$DOMAIN"
[ -n "${MALUMAIL_API_KEY:-}" ] && set_kv "$ENVF" MALUMAIL_API_KEY "$MALUMAIL_API_KEY"
chown root:www-data "$ENVF"; chmod 640 "$ENVF"

# web/.env.local (symlinked from /var/www/web/.env.local into the bos-etc volume)
WEBENV=$BOS/web.env.local
cat > "$WEBENV" <<EOF
API_BASE_URL=http://127.0.0.1:8080
LOGIN_URL=$SCHEME://app.$DOMAIN/login
WEB_INTERNAL_KEY=$WEB_INTERNAL_KEY
EOF
chown www-data:www-data "$WEBENV"; chmod 640 "$WEBENV"

# /etc/business-os/runner.env (install.md §9.2)
RENV=$BOS/runner.env
[ -f "$RENV" ] || cp /var/www/docs/deploy/runner.env.example "$RENV"
set_kv "$RENV" RUNNER_DB_USER app_runner
set_kv "$RENV" RUNNER_DB_PASSWORD "$PW_RUN"
set_kv "$RENV" RUNNER_DB_NAME "$DB"
set_kv "$RENV" RUNNER_DB_HOST pg-host
set_kv "$RENV" ACTION_TOKEN_KEY "$ACTION_TOKEN_KEY"
set_kv "$RENV" RUNNER_KEY "$RUNNER_KEY"
set_kv "$RENV" PROXY_KEY_SECRET "$PROXY_KEY_SECRET"
set_kv "$RENV" MALUDB_API_URL "$MALUDB_API_URL"
set_kv "$RENV" MALUDB_API_TOKEN "$MALUDB_API_TOKEN"
set_kv "$RENV" RUNNER_SCHEDULER on
[ -n "${ANTHROPIC_API_KEY:-}" ]  && set_kv "$RENV" ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY"
[ -n "${OPENROUTER_API_KEY:-}" ] && set_kv "$RENV" OPENROUTER_API_KEY "$OPENROUTER_API_KEY"
chown root:bos-runner "$RENV"; chmod 640 "$RENV"

# Apache vhost + landing page + web drop-in (ephemeral image layer — rendered every boot; §6, §7)
sed "s/subello\.com/$DOMAIN/g" /var/www/docs/deploy/apache-react-cutover.conf > /etc/apache2/sites-available/000-default.conf
sed -i "s/subello\.com/$DOMAIN/g" /var/www/landing/index.html
install -d /etc/systemd/system/certstudy-web.service.d
sed "s/subello\.com/$DOMAIN/g" /var/www/docs/deploy/certstudy-web.service.d-cutover.conf > /etc/systemd/system/certstudy-web.service.d/cutover.conf
systemctl daemon-reload

# ======================= PHASE B — once ==========================================================

step_memory_schema() { # hosting runbook §3: the tenant's schema must be memory-enabled
    PGPASSWORD="$MEM_PASSWORD" psql -h pg-host -U "$MEM_USER" -d "$MEM_DB" -Atc 'select 1' >/dev/null \
        || die "tenant memory login failed (user=$MEM_USER db=$MEM_DB)"
    local n
    n=$(psql -d "$MEM_DB" -Atc "select count(*) from information_schema.tables where table_schema='$MEM_SCHEMA' and table_name='maludb_episode'")
    if [ "$n" = 0 ]; then
        note "enabling memory schema $MEM_SCHEMA on $MEM_DB"
        psql -d "$MEM_DB" -Atc "SELECT count(*) FROM maludb_core.enable_memory_schema('$MEM_SCHEMA')" >/dev/null || return 1
        psql -d "$MEM_DB" -Atc "SELECT maludb_core.grant_memory_access('$MEM_SCHEMA')" >/dev/null || return 1
    fi
}

step_create_db() {
    local n
    n=$(psql -d postgres -Atc "select count(*) from pg_database where datname='$DB'") || return 1
    case "$n" in 0) psql -d postgres -c "CREATE DATABASE $DB" || return 1;; 1) :;; *) return 1;; esac
}

step_migrations() { # install.md §4 — resumable: every applied file is recorded
    local donefile=$STATE/migrations-applied f base
    touch "$donefile"
    cd /var/www || return 1
    for f in db/*.sql; do
        base=$(basename "$f")
        grep -qxF "$base" "$donefile" && continue
        echo "   migration $base"
        psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f" >/dev/null || { echo "FAILED at $base"; return 1; }
        echo "$base" >> "$donefile"
    done
}

step_role_passwords() {
    psql -c "ALTER ROLE app_rw PASSWORD '$PW_RW'" >/dev/null && \
    psql -c "ALTER ROLE app_records_ro PASSWORD '$PW_REC'" >/dev/null && \
    psql -c "ALTER ROLE app_activity_ro PASSWORD '$PW_ACT'" >/dev/null && \
    psql -c "ALTER ROLE app_runner PASSWORD '$PW_RUN'" >/dev/null && \
    PGPASSWORD="$PW_RW" psql -h pg-host -U app_rw -d "$DB" -Atc 'select 1' >/dev/null
}

step_php_check() {
    cd /var/www && [ "$(runuser -u www-data -- php -r 'require "app/bootstrap.php"; echo db()->query("select current_user")->fetchColumn();')" = app_rw ]
}

step_organizer() { # install.md §10.1 — the owner's password when given, else generated and
    local count pw   # persisted once for the host installer to show (never when owner-chosen)
    count=$(psql -d "$DB" -Atc "select count(*) from members where lower(email)=lower('$ADMIN_EMAIL')")
    if [ "$count" = 0 ]; then
        if [ -n "${ADMIN_PASSWORD:-}" ]; then
            pw=$ADMIN_PASSWORD
            note "super-admin password: using the owner's choice (not stored)"
        else
            pw=$(openssl rand -hex 9)
            (umask 077; printf '%s\n' "$pw" > "$BOS/admin-password")
            note "super-admin password: generated, stored in $BOS/admin-password (inside the container)"
        fi
        cd /var/www && runuser -u www-data -- php bin/bootstrap_organizer.php --email "$ADMIN_EMAIL" --name "$ADMIN_NAME" --password "$pw" >/dev/null || return 1
        note "super-admin $ADMIN_EMAIL created"
    else
        note "super-admin $ADMIN_EMAIL already exists"
    fi
}

step_model_registry() { # install.md §10.2
    local count
    count=$(psql -d "$DB" -Atc "select count(*) from model_registry where model_key='$MODEL_KEY'")
    [ "$count" != 0 ] && return 0
    psql -d "$DB" -c "INSERT INTO model_registry
        (model_key, display_name, provider, provider_model_id, harness, price_input_per_mtok, price_output_per_mtok,
         price_cache_read_per_mtok, price_cache_write_per_mtok, currency, status, auth_mode)
        VALUES ('$MODEL_KEY', '$MODEL_NAME', 'anthropic', '$MODEL_PROVIDER_ID', 'claude_agent_sdk',
                ${MODEL_PRICE_IN:-10}, ${MODEL_PRICE_OUT:-50}, ${MODEL_PRICE_CACHE_READ:-0.25}, ${MODEL_PRICE_CACHE_WRITE:-12.5},
                'USD', 'active', 'api_key')" >/dev/null
}

step_cron() { # install.md §10.4
    touch /var/log/certstudy-cron.log && chown www-data:www-data /var/log/certstudy-cron.log
    crontab -u www-data /var/www/docs/deploy/crontab.example
}

step_hire_installer() { cd /var/www && runuser -u www-data -- php bin/hire_installation_agent.php --by "$ADMIN_EMAIL" --plugin-dir /opt/maludb-os-integration; }
step_hire_jev()       { cd /var/www && runuser -u www-data -- php bin/hire_jev_prompt_writer.php --by "$ADMIN_EMAIL"; }

once memory-schema   step_memory_schema
once create-db       step_create_db
once migrations      step_migrations
once role-passwords  step_role_passwords
once php-check       step_php_check

# Services (enable symlinks live on the ephemeral layer — enabled+started every boot)
echo "== services"
apache2ctl configtest || die "apache configtest failed"
systemctl enable --now -q apache2 cron
systemctl enable --now -q certstudy-web certstudy-records-mcp certstudy-activity-mcp certstudy-actions-mcp certstudy-memory-mcp certstudy-activity-ingest.timer certstudy-agent-runner

for i in $(seq 1 30); do curl -fsS http://127.0.0.1:8080/api/v1/health >/dev/null 2>&1 && break; [ "$i" = 30 ] && die "PHP API on 127.0.0.1:8080 not healthy"; sleep 2; done

once organizer       step_organizer
once model-registry  step_model_registry
once cron-jobs       step_cron
once hire-installer  step_hire_installer
once hire-jev        step_hire_jev

if [ -n "${ANTHROPIC_API_KEY:-}" ] && [ ! -f "$STATE/model-probe" ]; then
    echo "== model probe"
    (cd /var/www/mcp && runuser -u bos-runner -- env RUNNER_ENV_FILE=$RENV venv/bin/python -m agent_runner.probe_model "$MODEL_KEY") \
        && touch "$STATE/model-probe" || note "model probe failed (non-fatal; fix keys and re-run)"
fi

# ======================= PHASE C — apps + verification, every boot ===============================

echo "== applications: helpdesk, spaces (apply = install or reconcile)"
app_apply() {
    php /var/www/bin/app_install.php apply "/opt/app-cache/maludb-os-$1" \
        --by "$ADMIN_EMAIL" --domain "$DOMAIN" --scheme "$SCHEME" \
        --hire-agents --grant-standing-departments
}
# app_install.php writes only keys that are missing or EMPTY in the app's config/.env, so the
# fixes below stick across reconciles. Two gaps it leaves on this topology:
#   * DB_HOST is hardcoded 127.0.0.1 (the app's PostgreSQL is the host VM's, at pg-host)
#   * a manifest that omits port_env on an MCP endpoint (Spaces, 2026-10-07) gets EMPTY
#     required *_PORT keys — the MCP server then cannot bind and the vhost proxies to ":"
# After fixing the env, one more apply re-renders the vhost from it (vhost vars come from the
# app's .env), and the app's units are restarted to pick the new values up.
fix_app_env() { # fix_app_env <app> — returns 0 when nothing needed fixing
    local app=$1 env=/srv/apps/$app/config/.env changed=1 k
    [ -f "$env" ] || return 0
    if ! grep -qE '^DB_HOST=pg-host$' "$env"; then
        set_kv "$env" DB_HOST pg-host; changed=0
    fi
    for k in $(grep -oE '^[A-Z0-9_]*_PORT=$' "$env" | tr -d '='); do
        local p=8100
        while ss -ltnH "sport = :$p" 2>/dev/null | grep -q . || grep -hqE "=${p}$" /srv/apps/*/config/.env 2>/dev/null; do p=$((p+1)); done
        note "$app: $k was empty — assigned free port $p"
        set_kv "$env" "$k" "$p"; changed=0
    done
    chown root:www-data "$env"; chmod 640 "$env"
    return $changed
}
for app in helpdesk spaces; do
    app_apply "$app" || die "app_install apply failed for $app"
    if ! fix_app_env "$app"; then
        note "$app: env fixed — re-applying to re-render the vhost, then restarting its units"
        app_apply "$app" || die "app_install re-apply failed for $app"
        systemctl restart $(systemctl --plain --no-legend list-units --all "${app}-*.service" | awk '{print $1}') 2>/dev/null || true
    fi
done

echo "== verification (install.md §13)"
REPORT=$BOS/install-report.txt
{
    echo "Business OS dockerized install — $(date -u +%FT%TZ)"
    echo "domain: $DOMAIN   app_env: $APP_ENV   admin: $ADMIN_EMAIL"
    echo
    echo "[services]"
    systemctl is-active apache2 certstudy-web certstudy-records-mcp certstudy-activity-mcp \
        certstudy-actions-mcp certstudy-memory-mcp certstudy-agent-runner certstudy-activity-ingest.timer cron | sort | uniq -c
    echo
    echo "[endpoints]"
    echo "php api:    $(curl -fsS http://127.0.0.1:8080/api/v1/health 2>/dev/null | head -c 120)"
    echo "web login:  HTTP $(curl -s -o /dev/null -w '%{http_code}' -H "Host: app.$DOMAIN" http://127.0.0.1/login)"
    echo "landing:    HTTP $(curl -s -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" http://127.0.0.1/)"
    echo "runner:     $(curl -fsS http://127.0.0.1:8815/health 2>/dev/null | head -c 160)"
    echo "mcp ports:  $(ss -ltn | grep -cE ':881[1-4] ') of 4 listening"
    echo
    echo "[database]"
    echo "applications: $(psql -d "$DB" -Atc "select string_agg(app_key||':'||status, ', ' order by id) from applications where app_key is not null")"
    echo "members:      $(psql -d "$DB" -Atc "select string_agg(display_name||' ('||business_role||')', ', ' order by id) from members")"
    echo
    if [ -f "$BOS/admin-password" ]; then
        echo "super-admin password: $BOS/admin-password (inside the container; read once, then shred)"
    else
        echo "super-admin password: chosen by the owner at install (not stored)"
    fi
} | tee "$REPORT"

APPS_OK=$(psql -d "$DB" -Atc "select count(*) from applications where app_key in ('helpdesk','spaces') and status='active'")
[ "$APPS_OK" = 2 ] || die "expected helpdesk+spaces installed, found $APPS_OK"

echo "BOS-INIT-OK"
