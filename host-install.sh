#!/bin/bash
# host-install.sh — install the dockerized MaluDB Business OS (kernel + Help Desk + Spaces)
# on a MaluDB hosting VM. Run as root from this directory:
#
#   sudo ./host-install.sh                 # interactive: prompts for admin + optional keys
#   sudo ./host-install.sh [--domain example.com] [--admin-email a@b.c] [--admin-name "Name"] \
#        [--admin-password-file PATH] [--anthropic-key-file PATH] [--openrouter-key-file PATH] \
#        [--malumail-key-file PATH] [--app-env prod|dev] [--image-tag vYYYY.MM.DD] \
#        [--build | --no-build] [--fix-host-api]
#
# The image is pulled from the registry named in docker-compose.yml (--image-tag picks the
# release); --build builds it here instead, --no-build uses whatever is already loaded.
# The domain is auto-detected from the VM's FQDN (hostname -f) and forward-confirmed against the
# VM's public IP; --domain overrides. Admin email and name are required (prompted when on a TTY).
#
# What this changes on the host, and nothing else:
#   * installs Docker CE if absent
#   * creates the PostgreSQL superuser role bos_admin + a pg_hba rule for the 172.30.0.0/24
#     container subnet (marker-delimited block, reload only)
#   * stops and disables the host Apache (frees :80 for the container; files untouched)
#   * writes /etc/business-os-docker/bos.env (root, 600) and starts the compose stack
set -uo pipefail
cd "$(dirname "$0")"

die()  { echo "host-install: FATAL: $*" >&2; exit 1; }
note() { echo "-- $*"; }
[ "$(id -u)" = 0 ] || die "run as root: sudo ./host-install.sh ..."

DOMAIN= ADMIN_EMAIL= ADMIN_NAME= ADMIN_PASSWORD= APP_ENV=prod IMAGE_MODE=pull FIX_HOST_API=0
ANTHROPIC_KEY_FILE= OPENROUTER_KEY_FILE= MALUMAIL_KEY_FILE= ADMIN_PASSWORD_FILE=
while [ $# -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN=$2; shift 2;;
        --admin-email) ADMIN_EMAIL=$2; shift 2;;
        --admin-name) ADMIN_NAME=$2; shift 2;;
        --admin-password-file) ADMIN_PASSWORD_FILE=$2; shift 2;;
        --anthropic-key-file) ANTHROPIC_KEY_FILE=$2; shift 2;;
        --openrouter-key-file) OPENROUTER_KEY_FILE=$2; shift 2;;
        --malumail-key-file) MALUMAIL_KEY_FILE=$2; shift 2;;
        --app-env) APP_ENV=$2; shift 2;;
        --build) IMAGE_MODE=build; shift;;      # developer path: build the image here
        --no-build) IMAGE_MODE=none; shift;;    # use the image already present locally
        --image-tag) export BOS_IMAGE_TAG=$2; shift 2;;
        --fix-host-api) FIX_HOST_API=1; shift;; # patch a stale maludb-python-api-server (see survey)
        *) die "unknown option $1";;
    esac
done

# ---- 1. survey the host (hosting runbook §2) ---------------------------------------------------
echo "== survey"
grep -q 'Ubuntu 24.04' /etc/os-release || die "not Ubuntu 24.04"
systemctl is-active -q 'postgresql@17-main' || systemctl is-active -q postgresql || die "PostgreSQL 17 is not active"
EXT=$(sudo -u postgres psql -Atc "select default_version from pg_available_extensions where name='maludb_core'")
[ -n "$EXT" ] || die "maludb_core extension not available — not a MaluDB hosting VM"
curl -fsS --max-time 3 http://127.0.0.1:8000/health >/dev/null || die "MaluDB API not answering on :8000"
[ -f /var/www/config/database.php ] || die "/var/www/config/database.php not found — tenant connection unknown"
note "PostgreSQL 17 + maludb_core $EXT, MaluDB API healthy, tenant config present"

# Stack-version checks against the kernel's stated floor (docs/install-on-maludb-hosting.md §2):
if ! dpkg --compare-versions "$EXT" ge 0.106.0 2>/dev/null; then
    note "WARNING: maludb_core $EXT is below the 0.106.0 the kernel's runbook expects — refresh the hosting VM image (maludb-core/scripts/maludb-upgrade)"
fi
# A maludb-python-api-server from before the jsonable_encoder fix 500s on every episode POST
# (TypeError: datetime is not JSON serializable), breaking activity-memory ingest for the kernel
# and every application. Detect it; patch only when the owner passes --fix-host-api.
API_DIR=$(systemctl show -p WorkingDirectory maludb-api 2>/dev/null | cut -d= -f2)
[ -d "$API_DIR" ] || API_DIR=$(ls -d /home/*/maludb-python-api-server 2>/dev/null | head -1)
if [ -d "$API_DIR" ] && [ -f "$API_DIR/app/routers/episodes.py" ] \
   && ! grep -q jsonable_encoder "$API_DIR/app/routers/episodes.py"; then
    if [ "$FIX_HOST_API" = 1 ]; then
        note "patching stale MaluDB API at $API_DIR (episodes.py from its origin/main) and restarting maludb-api"
        API_OWNER=$(stat -c %U "$API_DIR")
        runuser -u "$API_OWNER" -- git -C "$API_DIR" fetch -q origin \
            && runuser -u "$API_OWNER" -- git -C "$API_DIR" checkout origin/main -- app/routers/episodes.py \
            && systemctl restart maludb-api \
            || die "--fix-host-api failed; restore with: git -C $API_DIR checkout HEAD -- app/routers/episodes.py && systemctl restart maludb-api"
        for i in $(seq 1 15); do curl -fsS --max-time 2 http://127.0.0.1:8000/health >/dev/null 2>&1 && break
            [ "$i" = 15 ] && die "maludb-api did not come back healthy after the patch"; sleep 2; done
        note "MaluDB API patched and healthy"
    else
        note "WARNING: the MaluDB API at $API_DIR predates the jsonable_encoder fix — activity-memory ingest WILL fail with 500s. Re-run with --fix-host-api, or update the API server / hosting VM image."
    fi
fi

# ---- 2. the interview's answers ----------------------------------------------------------------
PUBLIC_IP=$(curl -fsS --max-time 5 https://api.ipify.org || true)
if [ -z "$DOMAIN" ]; then
    FQDN=$(hostname -f 2>/dev/null || true)
    if [[ "$FQDN" == *.* && "$FQDN" != *.local ]]; then
        # real DNS via an external resolver — the local stub (systemd-resolved) synthesizes
        # the machine's own hostname from /etc/hosts (127.0.1.1) and would poison the check
        A=''
        for ns in 1.1.1.1 8.8.8.8; do
            A=$(dig +short +time=3 "@$ns" "$FQDN" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
            [ -n "$A" ] && break
        done
        if [ -n "$A" ] && [ "$A" = "$PUBLIC_IP" ]; then
            DOMAIN=$FQDN
            note "domain auto-detected from FQDN and forward-confirmed: $DOMAIN -> $PUBLIC_IP"
        else
            die "FQDN $FQDN does not resolve to this VM's public IP ($PUBLIC_IP) — pass --domain"
        fi
    else
        die "no FQDN set on this VM (hostname -f = '$FQDN') — pass --domain, or set the hostname to the tenant domain in provisioning"
    fi
fi
# The super-admin: asked interactively (flags serve automation). The password is the owner's
# choice; left blank, a strong one is generated inside the container and shown once.
while [ -z "$ADMIN_EMAIL" ] || [[ "$ADMIN_EMAIL" != *@*.* ]]; do
    [ -t 0 ] || die "--admin-email is required (a real address: sign-in identity and recovery)"
    read -rp "First super-admin email: " ADMIN_EMAIL
done
while [ -z "$ADMIN_NAME" ]; do
    [ -t 0 ] || die "--admin-name is required"
    read -rp "First super-admin display name: " ADMIN_NAME
done
[ -n "$ADMIN_PASSWORD_FILE" ] && ADMIN_PASSWORD=$(tr -d '\n' < "$ADMIN_PASSWORD_FILE")
if [ -z "$ADMIN_PASSWORD" ] && [ -t 0 ]; then
    while :; do
        read -rsp "Super-admin password, 12-72 chars (Enter = auto-generate, shown once after install): " pw1; echo
        [ -z "$pw1" ] && break
        if [ "${#pw1}" -lt 12 ] || [ "${#pw1}" -gt 72 ]; then echo "  must be 12-72 characters"; continue; fi
        read -rsp "Confirm password: " pw2; echo
        [ "$pw1" = "$pw2" ] && { ADMIN_PASSWORD=$pw1; break; }
        echo "  passwords differ — try again"
    done
    unset pw1 pw2
fi
if [ -n "$ADMIN_PASSWORD" ] && { [ "${#ADMIN_PASSWORD}" -lt 12 ] || [ "${#ADMIN_PASSWORD}" -gt 72 ]; }; then
    die "admin password must be 12-72 characters"
fi

# Provider keys: optional, skippable — agents wait until a key is set (set-provider-key.sh later).
ask_key() { # VAR "label" — hidden prompt, Enter skips; a --*-key-file flag wins
    local var=$1 label=$2 val
    [ -n "${!var}" ] && return 0
    [ -t 0 ] || return 0
    read -rsp "$label (Enter to skip): " val; echo
    printf -v "$var" '%s' "$val"
}
ANTHROPIC_API_KEY=;  [ -n "$ANTHROPIC_KEY_FILE" ]  && ANTHROPIC_API_KEY=$(tr -d '[:space:]' < "$ANTHROPIC_KEY_FILE")
OPENROUTER_API_KEY=; [ -n "$OPENROUTER_KEY_FILE" ] && OPENROUTER_API_KEY=$(tr -d '[:space:]' < "$OPENROUTER_KEY_FILE")
MALUMAIL_API_KEY=;   [ -n "$MALUMAIL_KEY_FILE" ]   && MALUMAIL_API_KEY=$(tr -d '[:space:]' < "$MALUMAIL_KEY_FILE")
ask_key ANTHROPIC_API_KEY  "ANTHROPIC_API_KEY — the Installer and every Claude-harness agent"
ask_key OPENROUTER_API_KEY "OPENROUTER_API_KEY — evals and the system_one agents"
ask_key MALUMAIL_API_KEY   "MaluMail API key — invitations, password resets, notifications"

cat <<EOF

DNS reminder — these names need A records pointing at $PUBLIC_IP (TLS at the proxy in front):
    $DOMAIN  www.$DOMAIN        the landing page
    app.$DOMAIN                 sign-in and the launcher
    os.$DOMAIN                  the operating system (super-admins)
    helpdesk.$DOMAIN            Help Desk
    spaces.$DOMAIN              Spaces

EOF

# ---- 3. Docker CE ------------------------------------------------------------------------------
if ! command -v docker >/dev/null; then
    echo "== installing Docker CE"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get -q update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
        || die "docker install failed"
else
    note "docker already installed: $(docker --version)"
fi

# ---- 4. PostgreSQL access for the container ----------------------------------------------------
echo "== postgresql: bos_admin role + pg_hba for 172.30.0.0/24"
install -d -m 700 /etc/business-os-docker
PW_FILE=/etc/business-os-docker/bos_admin.pw
if [ ! -s "$PW_FILE" ]; then (umask 077; openssl rand -hex 24 > "$PW_FILE"); fi
BOS_PG_PW=$(cat "$PW_FILE")
if [ "$(sudo -u postgres psql -Atc "select count(*) from pg_roles where rolname='bos_admin'")" = 0 ]; then
    sudo -u postgres psql -qc "CREATE ROLE bos_admin LOGIN SUPERUSER PASSWORD '$BOS_PG_PW'" || die "CREATE ROLE bos_admin failed"
else
    sudo -u postgres psql -qc "ALTER ROLE bos_admin PASSWORD '$BOS_PG_PW'" || die "ALTER ROLE bos_admin failed"
fi
HBA=$(sudo -u postgres psql -Atc "show hba_file")
if ! grep -q 'BEGIN business-os-docker' "$HBA"; then
    cat >> "$HBA" <<'EOF'
# BEGIN business-os-docker — the Business OS container subnet (bosnet); do not edit by hand
host    all    all    172.30.0.0/24    scram-sha-256
# END business-os-docker
EOF
    sudo -u postgres psql -qc "select pg_reload_conf()" >/dev/null
    note "pg_hba rule added and reloaded"
fi
LISTEN=$(sudo -u postgres psql -Atc "show listen_addresses")
case "$LISTEN" in *\**|*0.0.0.0*) : ;; *) die "listen_addresses='$LISTEN' does not cover the docker bridge — fix postgresql.conf first";; esac

# ---- 5. tenant memory connection from /var/www/config/database.php -----------------------------
echo "== tenant memory connection"
MEMJSON=$(php -r '$c = require "/var/www/config/database.php"; echo json_encode($c);') || die "could not parse database.php"
MEM_DB=$(jq -r .database <<<"$MEMJSON"); MEM_USER=$(jq -r .username <<<"$MEMJSON")
MEM_PASSWORD=$(jq -r .password <<<"$MEMJSON"); MEM_SCHEMA=${MEM_SCHEMA:-$MEM_USER}
[ -n "$MEM_DB" ] && [ -n "$MEM_USER" ] && [ -n "$MEM_PASSWORD" ] || die "database.php lacks database/username/password"
note "memory: db=$MEM_DB user=$MEM_USER schema=$MEM_SCHEMA (password withheld)"
PGPASSWORD="$MEM_PASSWORD" psql -h 127.0.0.1 -U "$MEM_USER" -d "$MEM_DB" -Atc 'select 1' >/dev/null || die "tenant memory login failed"

# ---- 6. free :80 -------------------------------------------------------------------------------
if systemctl is-active -q apache2; then
    echo "== stopping host Apache (frees :80 for the container; /var/www untouched)"
    systemctl disable --now apache2
    note "restore MaluAdmin later: edit /etc/apache2/ports.conf to another port, then systemctl enable --now apache2"
fi

# ---- 7. configuration + launch -----------------------------------------------------------------
echo "== writing /etc/business-os-docker/bos.env"
(umask 077; cat > /etc/business-os-docker/bos.env <<EOF
DOMAIN=$DOMAIN
ADMIN_EMAIL=$ADMIN_EMAIL
ADMIN_NAME=$ADMIN_NAME
ADMIN_PASSWORD=$ADMIN_PASSWORD
APP_ENV=$APP_ENV
SCHEME=https
PG_SUPERUSER=bos_admin
PG_SUPERUSER_PASSWORD=$BOS_PG_PW
MEM_DB=$MEM_DB
MEM_USER=$MEM_USER
MEM_PASSWORD=$MEM_PASSWORD
MEM_SCHEMA=$MEM_SCHEMA
MALUDB_API_URL=http://pg-host:8000
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
OPENROUTER_API_KEY=$OPENROUTER_API_KEY
MALUMAIL_API_KEY=$MALUMAIL_API_KEY
EOF
)

case "$IMAGE_MODE" in
    pull)
        echo "== pulling image"
        if ! docker compose pull; then
            IMG=$(docker compose config --images | head -1)
            docker image inspect "$IMG" >/dev/null 2>&1 \
                && note "pull failed but $IMG exists locally — using it" \
                || die "could not pull $IMG and no local copy exists (registry credentials? --build to build here)"
        fi;;
    build)
        echo "== building image (this takes a while: composer, npm ci, next build)"
        docker compose build || die "image build failed";;
    none)
        note "using the image already present locally (--no-build)";;
esac
echo "== starting"
docker compose up -d || die "compose up failed"

# ---- 8. wait for bos-init and show the report ---------------------------------------------------
echo "== waiting for bos-init inside the container (up to 30 min on first boot)"
for i in $(seq 1 180); do
    STATEV=$(docker exec bos systemctl show -p ActiveState -p Result bos-init 2>/dev/null | tr '\n' ' ')
    case "$STATEV" in
        *ActiveState=active*)  break;;
        *ActiveState=failed*)  docker exec bos journalctl -u bos-init -n 50 --no-pager; die "bos-init failed — see log above";;
    esac
    sleep 10
    [ $((i % 6)) = 0 ] && docker exec bos tail -2 /var/log/bos-init.log 2>/dev/null
done
docker exec bos cat /etc/business-os/install-report.txt || die "bos-init did not produce an install report in time"

# The chosen password is only needed once, by the organizer bootstrap — scrub it from bos.env.
# In place (same inode): the container bind-mounts this file, and sed -i's rename would leave
# the container reading the old, password-bearing inode until its next recreate.
BOSENV_SCRUBBED=$(sed 's/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD=/' /etc/business-os-docker/bos.env)
printf '%s\n' "$BOSENV_SCRUBBED" > /etc/business-os-docker/bos.env

cat <<EOF

Done. Next steps for the owner:
EOF
if [ -n "$ADMIN_PASSWORD" ]; then
    echo "  * Sign in as $ADMIN_EMAIL with the password you chose during setup."
else
    cat <<'EOF'
  * Super-admin password (generated; shown once, then shred it):
        docker exec bos cat /etc/business-os/admin-password
        docker exec bos shred -u /etc/business-os/admin-password
EOF
fi
cat <<EOF
  * Sign in at https://app.$DOMAIN (DNS + TLS proxy are yours; see the table above).
  * Provider keys not set at install:
        docker exec bos /var/www/docs/deploy/set-provider-key.sh   (see its usage)
  * Backups: pg_dump -Fc on the host for: certstudy, app_helpdesk/app_spaces databases, and $MEM_DB.
    Docker volumes bos-etc + bos-config hold the encryption keys — back them up too.
EOF
