#!/bin/bash
# Business OS docker image: there is NO PostgreSQL server in this container — the server is the
# host VM's. This shim sits at /usr/local/bin/psql (and createdb via symlink), ahead of
# /usr/bin on PATH, so every local invocation — including the kernel installers'
# `runuser -u postgres -- psql` and `sudo -u postgres psql` — reaches the host instead.
#
# postgres and root connect as the superuser role the host-side installer created (bos_admin),
# with per-user pgpass files written by bos-init. Explicit -h/-p/-U on the command line and a
# caller's own PGHOST/PGUSER/PGPASSWORD always win over these defaults.
set -u
[ -r /etc/business-os/pg-client.env ] && . /etc/business-os/pg-client.env
export PGHOST="${PGHOST:-pg-host}" PGPORT="${PGPORT:-5432}"
me=$(id -un)
if [ "$me" = postgres ] || [ "$me" = root ]; then
    export PGUSER="${PGUSER:-${BOS_PG_SUPERUSER:-bos_admin}}"
    # a bare `psql -c ...` must not fall back to a database named after the role
    export PGDATABASE="${PGDATABASE:-postgres}"
    if [ -z "${PGPASSFILE:-}" ] && [ -r "/etc/business-os/pgpass-$me" ]; then
        export PGPASSFILE="/etc/business-os/pgpass-$me"
    fi
fi
exec "/usr/bin/$(basename "$0")" "$@"
