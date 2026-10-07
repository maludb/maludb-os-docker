---
name: os-docker
description: Working on a MaluDB Business OS that runs as the dockerized install — the `bos` container from maludb-os-docker (host-install.sh) on a MaluDB hosting VM, with PostgreSQL 17 and the MaluDB API on the host. Use before ANY work on such an install — building or changing an application, changing the kernel, adding an application, setting keys, reading logs, upgrading — and whenever the user mentions the bos container, docker compose, bos-init, bos.env, host-install.sh, bos-set-keys.sh or bos-app.sh. It says what lives in the image, on the volumes and on the host, which of those a change must land in, how every kernel command is run (docker exec), and what never to do.
---

# The Business OS in a container — how to work on it

The dockerized install (`github.com/maludb/maludb-os-docker`) runs the whole kernel stack of `maludb-os-core`
`docs/install.md` §3–§13 as **one systemd container named `bos`** on a MaluDB hosting VM. PostgreSQL 17 (with
`maludb_core`) and the MaluDB API (`:8000`) stay on the **host**; the container reaches them as `pg-host`
(172.30.0.1). Everything else — Apache/PHP, the Next.js front end, the four MCP servers, the agent runner, cron,
the pinned Claude Code CLI — runs inside. Help Desk and Spaces are installed at first boot; every other
application is installed later from its repository.

Claude Code runs **on the host VM** (where `maludb-os-docker` is cloned and `docker` is available), or on a
developer's machine for an application's own repository. It does not run inside the container: the container's
code layer is disposable and its only shells are `docker exec`.

## The one fact that decides everything: three layers

| Layer | Holds | Lifetime | A change lands here by |
|---|---|---|---|
| **The image** (`ghcr.io/maludb/maludb-business-os:<tag>`, or built here) | the kernel at `/var/www` (checked out at `OS_CORE_REF`), its venv, the built Next.js app, the Claude CLI, the integration plugin at `/opt/maludb-os-integration`, pre-fetched Help Desk and Spaces at `/opt/app-cache/` | until the next `docker compose up -d` with a new image | **a new image** (`os-docker-kernel`) — never by editing inside |
| **The volumes** (`bos-etc` → `/etc/business-os`, `bos-config` → `/var/www/config`, `bos-storage`, `bos-srv-apps` → `/srv/apps`, `bos-var-lib` → `/var/lib/business-os`) | secrets, `config/.env`, `runner.env`, the init markers, the installed applications' checkouts and their `config/.env`, agent workspaces | across image upgrades and container recreates | `git` in `/srv/apps/<key>` + the kernel's installer (`os-docker-change-app`), `bos-set-keys.sh` for keys |
| **The host** | PostgreSQL: `certstudy`, every application's database, the tenant's memory database; `/etc/business-os-docker/bos.env` (the container's whole configuration, root 600) and `bos_admin.pw` | the VM's | migrations run through the container's psql shim; `host-install.sh` / `bos-set-keys.sh` for `bos.env` |

Read [references/topology.md](references/topology.md) for the paths, ports, names, who dials whom and the
boot sequence (`bos-init`: phase A every boot, phase B once, phase C every boot). The command book is
[references/commands.md](references/commands.md); symptoms and their causes are in
[references/troubleshooting.md](references/troubleshooting.md).

## How to run anything of the kernel

Every kernel command is the documented command, inside the container, as root:

```bash
docker exec bos php /var/www/bin/app_install.php plan https://github.com/maludb/maludb-os-hr.git --by <admin email> --domain <domain> --scheme https
docker exec -u www-data bos php /var/www/bin/hire_application_agent.php --app hr --agent expert --by <admin email>
docker exec bos systemctl status certstudy-agent-runner
docker exec bos journalctl -u bos-init -n 100 --no-pager
docker exec bos psql -d certstudy -Atc "select app_key, status from applications"     # the shim: root → bos_admin on the host
```

For an application, prefer the wrapper in this repository, `sudo ./bos-app.sh plan|apply|update|status|logs|list`:
it runs the kernel's installer and then applies the two fixes the container's topology needs and the installer
does not know — `DB_HOST=pg-host` (the installer writes `127.0.0.1`, where no PostgreSQL listens inside) and a port
for any `*_PORT` key left empty — re-applies so the vhost is rendered from the fixed env, restarts the application's
units, keeps a ledger of applied migrations so `update` can apply new ones, and never prints a secret.

## Which skill next

- **A new application** (its own repository, installed into the container): `os-docker-new-app`.
- **A change to an installed application** (Help Desk, Spaces, HR, one of ours): `os-docker-change-app`.
- **A change to the kernel** (anything under `/var/www` in the image): `os-docker-kernel`.
- **Operations** — keys, logs, upgrade, backup, adding a default application: `references/commands.md`.

The two plugins that govern the code itself still govern it here: `htmx-php-builder` (how an application is built:
`new-app`, `os-application`, `php-patterns`, `design-system`, `mcp-servers`) and `maludb-os-integration` (how it
fits the kernel: `os-integration`, `os-adopt`, `os-install`). This plugin says only what the container changes.

## Non-negotiables

- **Never edit code inside the container.** `/var/www` is the image: an edit there is gone at the next image. `/srv/apps/<key>` is a
  git clone of the application's repository on a volume: an edit there is a change nobody has in a repository. Change the repository,
  then pull or rebuild.
- **Never print a secret.** `bos.env`, `/etc/business-os/secrets/*`, `/etc/business-os/admin-password`, every `config/.env` and
  `runner.env` hold keys and passwords; `docker exec` as root reads them all. `grep -c '^KEY='` tells whether a key is set; its value
  never reaches the terminal, a log or a commit. Keys are set with `bos-set-keys.sh`.
- **Never `docker compose down -v`, never `docker volume rm bos-*`.** `bos-etc` and `bos-config` hold `SECRETS_KEY` and `APP_TOTP_KEY`;
  without them the encrypted data in PostgreSQL is unreadable. `docker compose down` (no `-v`) and `up -d` are safe: bos-init reconciles.
- **Never run `docker compose up` before `host-install.sh` has run** on a VM — it writes `bos.env` and prepares the host's PostgreSQL.
- **Never connect to the host's PostgreSQL as `postgres` from the container** or paste `bos_admin`'s password anywhere: the psql shim
  (`/usr/local/bin/psql`) already connects root and `postgres` as `bos_admin` with the pgpass files bos-init writes.
- **Migrations are forward-only and additive** — the kernel's and the applications'. A rollback is the previous image tag or the
  previous application tag with the schema left as it is.
- **DNS and TLS are the owner's.** The container serves plain `:80` vhosts; a name the kernel's agents must dial (`<label>.<domain>`)
  works only once the owner's A record and TLS proxy exist (topology.md, "who dials whom"). Say so in every report; never fake it with
  `/etc/hosts`.
- What `host-install.sh` changed on the host (Docker CE, the `bos_admin` role and one `pg_hba.conf` block, the host Apache stopped,
  `/etc/business-os-docker/`) is the whole list. Nothing else on the host is this install's to touch.
