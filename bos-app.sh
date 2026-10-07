#!/bin/bash
# bos-app.sh — install, update and inspect an application of the Business OS inside the bos container.
# Run as root on the host VM, from this directory or anywhere:
#
#   sudo ./bos-app.sh plan   <source> [--ref TAG]                   read-only: the kernel installer's plan
#   sudo ./bos-app.sh apply  <source> [--ref TAG] [--hire-agents] [--grant-standing-departments]
#   sudo ./bos-app.sh update <key> [--ref TAG]                      pull the installed checkout, apply its new
#                                                                   migrations, reconcile, restart its units
#   sudo ./bos-app.sh status <key>                                  units, health, the installer's plan
#   sudo ./bos-app.sh logs   <key> [journalctl options, e.g. -f or -n 200]
#   sudo ./bos-app.sh list                                          what the kernel knows and what /srv/apps holds
#
# <source> is a git URL (the normal case: https://github.com/maludb/maludb-os-hr.git), a directory on this host
# (copied into the container at /opt/app-dev/<name> first — ephemeral, gone at the next recreate), or a path
# that already exists inside the container (a bind mount from docker-compose.override.yml, or /opt/app-cache/…).
#
# Everything the kernel's own installer does, it still does — `php /var/www/bin/app_install.php plan|apply`
# runs inside the container as the super-admin named in bos.env. This wrapper adds what the container's
# topology needs and the installer does not know (the same fixes bos-init applies to Help Desk and Spaces):
#   * DB_HOST=pg-host in the application's config/.env — the installer writes 127.0.0.1, where no PostgreSQL
#     listens in the container (the server is the host VM's);
#   * a free port for any *_PORT key the installer left empty (a manifest endpoint without port_env);
#   * one more apply after either fix (the vhost is rendered from the env), then a restart of the application's units;
#   * a ledger of applied migrations on the bos-etc volume (/etc/business-os/app-migrations/<key>), because
#     the installer runs migrations only on a NEW database — `update` applies the files not yet in the ledger,
#     in order, unless the manifest ships database.provision (then the installer's re-run does it).
# It never prints a secret: config/.env is read for DB_HOST, DB_NAME and the port keys only.
set -uo pipefail

die()  { echo "bos-app: FATAL: $*" >&2; exit 1; }
note() { echo "-- $*"; }
[ "$(id -u)" = 0 ] || die "run as root: sudo ./bos-app.sh ..."
BOSENV=${BOS_ENV_FILE:-/etc/business-os-docker/bos.env}   # the override is for tests only
[ -f "$BOSENV" ] || die "$BOSENV not found — is the Business OS installed on this VM (host-install.sh)?"
command -v docker >/dev/null || die "docker is not installed"
docker ps --format '{{.Names}}' | grep -q '^bos$' || die "the bos container is not running"

cfg() { grep -E "^$1=" "$BOSENV" | head -1 | cut -d= -f2-; }
DOMAIN=$(cfg DOMAIN); ADMIN_EMAIL=$(cfg ADMIN_EMAIL); SCHEME=$(cfg SCHEME); SCHEME=${SCHEME:-https}
[ -n "$DOMAIN" ] && [ -n "$ADMIN_EMAIL" ] || die "DOMAIN or ADMIN_EMAIL missing from $BOSENV"

dx()  { docker exec bos "$@"; }                        # a command inside the container, as root
dxq() { local s=$1; shift; docker exec bos bash -c "$s" _ "$@"; }   # a shell line inside the container (+ args as $1…)
LEDGER_DIR=/etc/business-os/app-migrations               # on the bos-etc volume: survives image upgrades

MODE=${1:-}; shift || true
ARG=${1:-}; [ -n "$ARG" ] && [ "${ARG#--}" = "$ARG" ] && shift
REF= EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --ref) REF=$2; shift 2;;
        --hire-agents|--grant-standing-departments|--no-restart) EXTRA+=("$1"); shift;;
        --tenant) EXTRA+=("$1" "$2"); shift 2;;
        *) break;;
    esac
done

# ---- helpers ----------------------------------------------------------------------------------
# installer SOURCE plan|apply — the kernel's installer inside the container; output to the terminal and to $OUT
OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT
installer() {
    local src=$1 mode=$2; shift 2
    local args=(php /var/www/bin/app_install.php "$mode" "$src" --by "$ADMIN_EMAIL" --domain "$DOMAIN" --scheme "$SCHEME")
    [ -n "$REF" ] && args+=(--ref "$REF")
    dx "${args[@]}" "$@" | tee "$OUT"
    return "${PIPESTATUS[0]}"
}
key_from_output() { sed -nE 's/^(Applying|Plan for) .* \(([a-z0-9_]+)\) at \/srv\/apps\/[a-z0-9_]+,.*/\2/p' "$OUT" | head -1; }
manifest_value() { dxq "jq -r '$2 // empty' /srv/apps/$1/maludb-os.json 2>/dev/null"; }

# fix_env KEY — DB_HOST and empty *_PORT keys, inside the container; prints "changed" when it changed something
fix_env() {
    dxq 'app=$1; env=/srv/apps/$app/config/.env; changed=0
        [ -f "$env" ] || exit 0
        set_kv() { if grep -qE "^$2=" "$1"; then awk -v k="$2" -v v="$3" "BEGIN{FS=OFS=\"=\"} index(\$0,k\"=\")==1{print k\"=\"v; next} {print}" "$1" > "$1.tmp" && cat "$1.tmp" > "$1" && rm -f "$1.tmp"; else printf "%s=%s\n" "$2" "$3" >> "$1"; fi; }
        if grep -qE "^DB_HOST=" "$env" && ! grep -qE "^DB_HOST=pg-host$" "$env"; then set_kv "$env" DB_HOST pg-host; changed=1; echo "-- $app: DB_HOST -> pg-host (the container has no PostgreSQL; the host VM answers as pg-host)"; fi
        for k in $(grep -oE "^[A-Z0-9_]*_PORT=$" "$env" | tr -d =); do
            p=8100
            while ss -ltnH "sport = :$p" 2>/dev/null | grep -q . || grep -hqE "=${p}$" /srv/apps/*/config/.env 2>/dev/null; do p=$((p+1)); done
            set_kv "$env" "$k" "$p"; changed=1; echo "-- $app: $k was empty — assigned free port $p (declare port_env on that endpoint in maludb-os.json)"
        done
        [ "$changed" = 1 ] && echo changed; exit 0' _ "$1"
}
restart_units() {
    local units
    units=$(dxq "systemctl --plain --no-legend list-units --all '$1-*.service' | awk '{print \$1}'")
    [ -n "$units" ] || { note "$1: no units named $1-*.service"; return 0; }
    # shellcheck disable=SC2086
    dx systemctl restart $units && note "$1: restarted $(echo $units | tr '\n' ' ')"
}
health() { # health KEY — the loopback port from config/.env (not a secret)
    local port
    port=$(dxq "grep -E '^APP_INTERNAL_PORT=' /srv/apps/$1/config/.env | cut -d= -f2-")
    [ -n "$port" ] || { note "$1: no APP_INTERNAL_PORT in config/.env"; return 1; }
    local code
    code=$(dxq "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$port/api/v1/health")
    echo "health:  http://127.0.0.1:$port/api/v1/health -> HTTP $code"
    [ "$code" = 200 ]
}
ledger_seed() { # ledger_seed KEY — every migration file now in the checkout counts as applied (a fresh apply ran them all)
    local dir; dir=$(manifest_value "$1" .database.migrations); dir=${dir:-db}
    dxq "install -d -m 700 $LEDGER_DIR && [ -s $LEDGER_DIR/$1 ] || (cd /srv/apps/$1/$dir 2>/dev/null && ls *.sql 2>/dev/null | sort > $LEDGER_DIR/$1 && echo '-- $1: migration ledger seeded with '\$(wc -l < $LEDGER_DIR/$1)' files')"
}
migrate_new() { # migrate_new KEY — files not in the ledger, in order, through the psql shim (root → bos_admin on the host)
    local dir db; dir=$(manifest_value "$1" .database.migrations); dir=${dir:-db}
    db=$(dxq "grep -E '^DB_NAME=' /srv/apps/$1/config/.env | cut -d= -f2-")
    [ -n "$db" ] || die "$1: DB_NAME missing from its config/.env"
    dxq "cd /srv/apps/$1/$dir || exit 1; n=0
        for f in \$(ls *.sql | sort); do
            grep -qxF \"\$f\" $LEDGER_DIR/$1 && continue
            echo \"   migration \$f\"
            psql -v ON_ERROR_STOP=1 -q -d '$db' -f \"\$f\" >/dev/null || { echo \"bos-app: FAILED at \$f — fix it, then run update again (the files before it are recorded)\" >&2; exit 1; }
            echo \"\$f\" >> $LEDGER_DIR/$1; n=\$((n+1))
        done; echo \"-- $1: \$n new migration(s) applied to $db\""
}
hosts_fix() { # the loopback line the installer adds while the name does not resolve shadows it for the kernel's https calls
    [ -n "${1:-}" ] || return 0
    local fqdn="$1.$DOMAIN"
    [ "$SCHEME" = https ] || return 0
    if dxq "grep -qE '^127\\.0\\.0\\.1[[:space:]]+$fqdn\$' /etc/hosts"; then
        dxq "sed -i '/^127\\.0\\.0\\.1[[:space:]]\\+$fqdn\$/d' /etc/hosts"
        cat <<EOT
NOTE: removed the loopback /etc/hosts line for $fqdn inside the container. The kernel's agents and its entity resolver
      dial https://$fqdn/mcp/... — a loopback line sends that to 127.0.0.1:443, where nothing listens. The name must
      resolve through the owner's DNS A record to the TLS proxy in front; until it does, agents cannot reach this application.
EOT
    fi
}

# resolve_source ARG — a git URL as it is; a host directory copied to /opt/app-dev/<name>; a container path as it is
resolve_source() {
    local s=$1
    if [[ "$s" =~ ^(https?://|git@|ssh://) ]]; then echo "$s"; return 0; fi
    if [[ "$s" = /* ]] && dx test -f "$s/maludb-os.json"; then echo "$s"; return 0; fi     # already inside: a bind mount, /opt/app-cache, /srv/apps
    if [ -d "$s" ]; then
        local name; name=$(basename "$(cd "$s" && pwd)")
        [ -f "$s/maludb-os.json" ] || die "$s holds no maludb-os.json"
        note "copying $s into the container at /opt/app-dev/$name (ephemeral; a bind mount in docker-compose.override.yml persists)" >&2
        dx rm -rf "/opt/app-dev/$name" && dx mkdir -p /opt/app-dev && docker cp "$s" "bos:/opt/app-dev/$name" >/dev/null || die "docker cp failed"
        echo "/opt/app-dev/$name"; return 0
    fi
    die "source '$s' is neither a git URL, a directory on this host, nor a path in the container holding maludb-os.json"
}

# ---- modes ------------------------------------------------------------------------------------
case "$MODE" in
plan)
    [ -n "$ARG" ] || die "usage: bos-app.sh plan <source> [--ref TAG]"
    SRC=$(resolve_source "$ARG") || exit 1
    installer "$SRC" plan ${EXTRA[@]+"${EXTRA[@]}"}; rc=$?
    exit $rc;;
apply)
    [ -n "$ARG" ] || die "usage: bos-app.sh apply <source> [--ref TAG] [--hire-agents] [--grant-standing-departments]"
    SRC=$(resolve_source "$ARG") || exit 1
    echo "== apply"
    installer "$SRC" apply ${EXTRA[@]+"${EXTRA[@]}"} || die "the kernel's installer stopped — read its last line"
    KEY=$(key_from_output); [ -n "$KEY" ] || die "could not read the catalog key from the installer's output"
    echo "== topology"
    FX=$(fix_env "$KEY"); grep -v '^changed$' <<<"$FX" || true
    if grep -q '^changed$' <<<"$FX"; then
        note "$KEY: env fixed — applying again to re-render the vhost, then restarting its units"
        installer "$SRC" apply ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null || die "the second apply stopped"
        restart_units "$KEY"
    fi
    ledger_seed "$KEY"
    echo "== check"
    health "$KEY" || note "$KEY: health is not 200 yet — bos-app.sh logs $KEY"
    LABEL=$(manifest_value "$KEY" .vhost.label); LABEL=${LABEL:-$KEY}
    hosts_fix "$LABEL"
    cat <<EOT
Installed: $KEY at /srv/apps/$KEY (bos-srv-apps volume), $SCHEME://$LABEL.$DOMAIN
The owner's: a DNS A record for $LABEL.$DOMAIN and TLS at the proxy in front; grants beyond those named;
             hiring any agent that was only proposed:  docker exec -u www-data bos php /var/www/bin/hire_application_agent.php --app $KEY --agent <key> --by $ADMIN_EMAIL
EOT
    ;;
update)
    KEY=$ARG; [ -n "$KEY" ] || die "usage: bos-app.sh update <key> [--ref TAG]"
    A=/srv/apps/$KEY
    dx test -f "$A/maludb-os.json" || die "$A holds no application"
    dx test -d "$A/.git" || die "$A is not a git checkout (installed by copy) — reinstall from a repository"
    echo "== code"
    OWNER=$(dxq "stat -c %U:%G $A")
    G="git -c safe.directory='*' -C $A"
    dxq "$G fetch -q --tags origin" || die "git fetch failed (origin: $(dxq "$G remote get-url origin"))"
    BEFORE=$(dxq "$G rev-parse --short HEAD")
    if [ -n "$REF" ]; then
        dxq "$G checkout -q $REF" || die "git checkout $REF failed"
    elif [ "$(dxq "$G symbolic-ref -q --short HEAD || true")" = "" ]; then
        die "$A is checked out at a tag or commit, not a branch — pass --ref <tag>"
    else
        dxq "$G pull -q --ff-only" || die "git pull --ff-only failed — the installed copy has local commits or the branch was rewritten"
    fi
    AFTER=$(dxq "$G rev-parse --short HEAD")
    note "$KEY: $BEFORE -> $AFTER ($(dxq "$G log -1 --format=%s"))"
    dx test -f "$A/composer.json" && { dxq "cd $A && composer install --no-dev --no-interaction --quiet 2>&1 | tail -3"; note "composer install ran"; }
    dx test -f "$A/mcp/requirements.txt" && dx test -x "$A/mcp/venv/bin/pip" && { dxq "$A/mcp/venv/bin/pip install -q -r $A/mcp/requirements.txt"; note "pip install ran"; }
    dx chown -R "$OWNER" "$A"
    echo "== database"
    if [ -n "$(manifest_value "$KEY" .database.provision)" ]; then
        note "$KEY ships database.provision — the installer's apply re-runs it"
    else
        ledger_seed "$KEY"
        migrate_new "$KEY" || die "migration failed"
    fi
    echo "== reconcile"
    installer "$A" apply ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null || die "the kernel's installer stopped on reconcile — run: bos-app.sh status $KEY"
    fix_env "$KEY" | grep -v '^changed$' || true
    restart_units "$KEY"
    echo "== check"
    sleep 2
    health "$KEY" || note "$KEY: health is not 200 — bos-app.sh logs $KEY"
    ;;
status)
    KEY=$ARG; [ -n "$KEY" ] || die "usage: bos-app.sh status <key>"
    dx test -f "/srv/apps/$KEY/maludb-os.json" || die "/srv/apps/$KEY holds no application"
    echo "checkout: $(dxq "git -c safe.directory='*' -C /srv/apps/$KEY describe --tags --always 2>/dev/null") on $(dxq "git -c safe.directory='*' -C /srv/apps/$KEY symbolic-ref -q --short HEAD 2>/dev/null || echo '(detached)'")"
    echo "units:"; dxq "systemctl --plain --no-legend list-units --all '$KEY-*' | awk '{printf \"   %-40s %s %s\n\", \$1, \$3, \$4}'"
    health "$KEY" || true
    echo "kernel:  $(dxq "psql -d certstudy -Atc \"select 'application '||id||' '||status||' '||url from applications where app_key='$KEY'\"")"
    echo "plan:"; installer "/srv/apps/$KEY" plan | awk 'NR>2 && NF {printf "   %s\n", $0}' | grep -vE '^\s+\$ ' | head -40
    ;;
logs)
    KEY=$ARG; [ -n "$KEY" ] || die "usage: bos-app.sh logs <key> [journalctl options]"
    dx journalctl -u "$KEY-*" --no-pager "$@";;
list)
    echo "kernel applications:"
    dxq "psql -d certstudy -Atc \"select '   '||coalesce(app_key,'-')||'  '||status||'  '||coalesce(url,'') from applications order by id\""
    echo "/srv/apps (bos-srv-apps volume):"
    dxq "for d in /srv/apps/*/; do k=\$(basename \$d); [ -f \$d/maludb-os.json ] && echo \"   \$k  \$(git -c safe.directory='*' -C \$d describe --tags --always 2>/dev/null)  \$(git -c safe.directory='*' -C \$d remote get-url origin 2>/dev/null)\"; done"
    echo "migration ledgers: $(dxq "ls $LEDGER_DIR 2>/dev/null | tr '\n' ' '")";;
*)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 1;;
esac
