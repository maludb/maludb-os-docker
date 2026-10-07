#!/bin/bash
# bos-set-keys.sh — set, update, or clear the Business OS provider/mail API keys after install.
# Run as root on the VM, from this directory or anywhere:
#
#   sudo ./bos-set-keys.sh                       # interactive: prompts for each key
#   sudo ./bos-set-keys.sh --anthropic-key-file PATH [--openrouter-key-file PATH] [--malumail-key-file PATH]
#
# Interactive prompts: Enter keeps the current value, a single "-" clears the key.
# Keys are written to /etc/business-os-docker/bos.env (so a container recreate keeps them) AND
# applied live inside the container: ANTHROPIC/OPENROUTER into /etc/business-os/runner.env with
# an agent-runner restart, the MaluMail key into the kernel's config/.env (PHP reads it per
# request; the applications pick it up at the next boot's reconcile).
set -uo pipefail

die()  { echo "bos-set-keys: FATAL: $*" >&2; exit 1; }
note() { echo "-- $*"; }
[ "$(id -u)" = 0 ] || die "run as root: sudo ./bos-set-keys.sh ..."
BOSENV=/etc/business-os-docker/bos.env
[ -f "$BOSENV" ] || die "$BOSENV not found — is the Business OS installed on this VM?"
docker ps --format '{{.Names}}' | grep -q '^bos$' || die "the bos container is not running"

ANTHROPIC_API_KEY__SET=0 OPENROUTER_API_KEY__SET=0 MALUMAIL_API_KEY__SET=0
ANTHROPIC_API_KEY= OPENROUTER_API_KEY= MALUMAIL_API_KEY=
from_file() { local var=$1 path=$2; [ -r "$path" ] || die "cannot read $path"; printf -v "$var" '%s' "$(tr -d '[:space:]' < "$path")"; printf -v "${var}__SET" 1; }
while [ $# -gt 0 ]; do
    case "$1" in
        --anthropic-key-file)  from_file ANTHROPIC_API_KEY  "$2"; shift 2;;
        --openrouter-key-file) from_file OPENROUTER_API_KEY "$2"; shift 2;;
        --malumail-key-file)   from_file MALUMAIL_API_KEY   "$2"; shift 2;;
        *) die "unknown option $1";;
    esac
done

# Interactive: Enter = keep current, "-" = clear. Input is hidden; values are never printed.
cur() { grep -E "^$1=" "$BOSENV" | head -1 | cut -d= -f2-; }
ask() { # ask VAR "label"
    local var=$1 label=$2 state val
    [ "$(eval echo \$${var}__SET)" = 1 ] && return 0
    [ -t 0 ] || return 0
    state=$([ -n "$(cur "$var")" ] && echo "currently SET" || echo "currently unset")
    read -rsp "$label [$state] (Enter = keep, \"-\" = clear): " val; echo
    [ -z "$val" ] && return 0
    [ "$val" = '-' ] && val=
    printf -v "$var" '%s' "$val"; printf -v "${var}__SET" 1
}
ask ANTHROPIC_API_KEY  "ANTHROPIC_API_KEY — the Installer and every Claude-harness agent"
ask OPENROUTER_API_KEY "OPENROUTER_API_KEY — evals and the system_one agents"
ask MALUMAIL_API_KEY   "MaluMail API key — invitations, password resets, notifications"

[ "$ANTHROPIC_API_KEY__SET$OPENROUTER_API_KEY__SET$MALUMAIL_API_KEY__SET" = 000 ] && { note "nothing to change"; exit 0; }

# bos.env, rewritten in place (same inode — the container bind-mounts this file; a rename
# would leave the container reading the old copy until its next recreate).
set_bosenv() { # KEY VALUE
    local content
    if grep -qE "^$1=" "$BOSENV"; then
        content=$(awk -v k="$1" -v v="$2" 'BEGIN{FS=OFS="="} index($0,k"=")==1{print k"="v; next} {print}' "$BOSENV")
    else
        content=$(cat "$BOSENV"; printf '%s=%s' "$1" "$2")
    fi
    printf '%s\n' "$content" > "$BOSENV"
}
# Inside the container: same replace-or-append, perms untouched.
set_container() { # FILE KEY VALUE
    docker exec bos bash -c 'f=$1 k=$2 v=$3
        if grep -qE "^$k=" "$f"; then
            awk -v k="$k" -v v="$v" "BEGIN{FS=OFS=\"=\"} index(\$0,k\"=\")==1{print k\"=\"v; next} {print}" "$f" > "$f.tmp" \
                && cat "$f.tmp" > "$f" && rm -f "$f.tmp"
        else
            printf "%s=%s\n" "$k" "$v" >> "$f"
        fi' _ "$1" "$2" "$3"
}

RESTART_RUNNER=0
apply() { # VAR container-file restart?
    local var=$1 file=$2
    [ "$(eval echo \$${var}__SET)" = 1 ] || return 0
    set_bosenv "$var" "${!var}"
    set_container "$file" "$var" "${!var}" || die "could not write $var into the container's $file"
    note "$var $([ -n "${!var}" ] && echo updated || echo cleared)"
}
apply ANTHROPIC_API_KEY  /etc/business-os/runner.env  && [ "$ANTHROPIC_API_KEY__SET" = 1 ]  && RESTART_RUNNER=1
apply OPENROUTER_API_KEY /etc/business-os/runner.env  && [ "$OPENROUTER_API_KEY__SET" = 1 ] && RESTART_RUNNER=1
apply MALUMAIL_API_KEY   /var/www/config/.env

if [ "$RESTART_RUNNER" = 1 ]; then
    note "restarting the agent runner"
    docker exec bos systemctl restart certstudy-agent-runner || die "runner restart failed"
    sleep 3
    docker exec bos curl -fsS http://127.0.0.1:8815/health || die "runner not healthy after restart"
    echo
fi
[ "$MALUMAIL_API_KEY__SET" = 1 ] && note "MaluMail: the kernel sends mail immediately; Help Desk and Spaces pick the key up at the next container boot (docker compose restart bos, when convenient)"
note "done"
