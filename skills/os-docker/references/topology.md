# Topology — what is where, who dials whom, what happens at boot

Written from `maludb-os-docker` at commit 92e5322 (2026-10-07: `Dockerfile`, `docker-compose.yml`,
`container/bos-init.sh`, `container/psql-shim.sh`, `host-install.sh`, `bos-set-keys.sh`) and the kernel's
`bin/app_install.php` and `mcp/agent_runner/` as of the same day.

## Paths

| Inside the container | What | Layer |
|---|---|---|
| `/var/www` | the kernel (`maludb-os-core` at `OS_CORE_REF`), `composer install --no-dev` done, `web/.next` built at image build | image |
| `/var/www/config` | `config/.env` — written by bos-init from `bos.env` + the persisted secrets at every boot (`set_kv`: known keys only) | volume `bos-config` |
| `/var/www/storage` | uploads | volume `bos-storage` |
| `/var/www/mcp/venv` | the four MCP servers' and the runner's venv | image |
| `/var/www/web/.env.local` → `/etc/business-os/web.env.local` | `API_BASE_URL`, `LOGIN_URL`, `WEB_INTERNAL_KEY` | volume `bos-etc` |
| `/etc/business-os/` | `secrets/` (every generated key and role password), `runner.env`, `pg-client.env`, `pgpass-root`, `pgpass-postgres`, `admin-password` (until shredded), `init-state/` (phase-B markers, `migrations-applied`), `install-report.txt`, `app-migrations/<key>` (bos-app.sh's ledgers) | volume `bos-etc` |
| `/srv/apps/<key>` | an installed application: a git clone (from a URL or a directory with `.git`) or a copy; its `config/.env`, its `mcp/venv` | volume `bos-srv-apps` |
| `/var/lib/business-os/agents/<id>` | agent workspaces (`bos-agent-exec` sandbox) | volume `bos-var-lib` |
| `/opt/app-cache/maludb-os-{helpdesk,spaces}` | the two default applications, cloned at image build; bos-init applies from here | image |
| `/opt/maludb-os-integration` | the integration plugin, for the Installer agent's `--plugin-dir` | image |
| `/opt/claude-agent/bin/claude` | the pinned Claude Code CLI (`CLAUDE_CLI_VERSION`) | image |
| `/opt/app-dev/<name>` | a developer's checkout: `docker cp`'d by bos-app.sh (ephemeral) or bind-mounted by `docker-compose.override.yml` (persistent) | ephemeral / host |
| `/usr/local/bin/psql`, `createdb` | the shim: root and `postgres` → `bos_admin@pg-host`; explicit `-h/-U` and a caller's `PG*` win | image |
| `/etc/bos.env` (ro) | the bind mount of the host's `/etc/business-os-docker/bos.env`; `bos-init.service`'s `EnvironmentFile` | host |
| `/host-config/database.php` (ro) | the tenant's original MaluDB connection file, for audit | host |

| On the host | What |
|---|---|
| `/etc/business-os-docker/bos.env` (root 600) | `DOMAIN`, `ADMIN_EMAIL`, `ADMIN_NAME`, `APP_ENV`, `SCHEME`, `PG_SUPERUSER(_PASSWORD)`, `MEM_DB/USER/PASSWORD/SCHEMA`, `MALUDB_API_URL`, the three provider/mail keys; `ADMIN_PASSWORD` scrubbed after first boot |
| `/etc/business-os-docker/bos_admin.pw` (root 600) | the `bos_admin` superuser's password |
| PostgreSQL | `certstudy` (the kernel), `<tenant>_<key>` per application, the tenant's memory database (`MEM_DB`, schema `MEM_SCHEMA`) |
| `pg_hba.conf` | one marker-delimited block: `host all all 172.30.0.0/24 scram-sha-256` |
| `/var/www` | the hosting VM's previous application (MaluAdmin), files intact, its Apache stopped and disabled |
| the clone of `maludb-os-docker` | `host-install.sh`, `bos-set-keys.sh`, `bos-app.sh`, `docker-compose.yml`, this plugin |

## Ports and names

- Published: **`80` only** (`ports: "80:80"`). Every other port is reachable from inside the container alone:
  `127.0.0.1:8080` (the PHP JSON API), `3000` (Next.js), `8811–8814` (records, activity, actions, memory MCP), `8815/8816`
  (runner, ledger proxy), and each application's `APP_INTERNAL_PORT` (81xx) and MCP ports (88xx), chosen by the installer.
  A check of any of them is `docker exec bos curl -s http://127.0.0.1:<port>/...`.
- The host answers the container at `pg-host` = `172.30.0.1` (the pinned `bosnet` gateway): PostgreSQL `5432`, the MaluDB API `8000`.
- Names: `<domain>` and `www.` (the landing page), `app.<domain>` (sign-in, the launcher), `os.<domain>` (super-admins), and one
  `<label>.<domain>` per application. All are vhosts on the container's `:80`; **TLS terminates at the owner's proxy in front**; the
  registered URLs carry `SCHEME` (`https` by default — `bos.env`).
- At every boot bos-init writes `127.0.0.1 <name>` lines into the container's `/etc/hosts` for the bare name, `www.`, `os.`, `app.`,
  `helpdesk.` and `spaces.` (docker rewrites the file at each start). The kernel's installer adds such a line for any application
  whose name does not resolve at `apply`; it is lost at the next restart.

## Who dials whom (this is why DNS matters)

| Caller | Dials | Where that goes inside the container |
|---|---|---|
| Next.js → PHP | `http://127.0.0.1:8080` | fine |
| the kernel's actions server → an application's action handlers | `base_url` = `http://127.0.0.1:<APP_INTERNAL_PORT>` (`mcp/registries/<key>.json`) | fine |
| the actions server resolving an entity → the application's records MCP | `records_url` = `<SCHEME>://<label>.<domain>/mcp/records` | by name |
| an agent's harness → an application's MCP tools | the endpoint's registered `url` = `<SCHEME>://<label>.<domain>/mcp/…` (`mcp/agent_runner/claude_render.py:39`, `store.py:137`) | by name |
| an application → the kernel | `OS_INTERNAL_URL=http://127.0.0.1:8080`; `OS_LAUNCHER_URL=https://app.<domain>/` (a browser redirect) | fine |
| an application → PostgreSQL / MaluDB | `DB_HOST=pg-host`, `MALUDB_API_URL=http://pg-host:8000` | fine once `DB_HOST` is fixed |
| a browser | `https://app.<domain>`, `https://<label>.<domain>` | the owner's proxy → `:80` |

"By name" with `SCHEME=https` means: with the owner's DNS A record and TLS proxy in place, the call leaves the container, reaches the
proxy, and comes back to `:80` — it works. With a loopback line in `/etc/hosts` for that name, the call goes to `127.0.0.1:443`
inside the container, where nothing listens — it fails. So **agents' tool calls to an application work only once the owner's DNS
and TLS exist and no loopback line shadows the name** (`troubleshooting.md`, "agents cannot reach an application").

## The boot sequence (`bos-init`, every start of the container)

- **Phase A, every boot:** pg-client env and pgpass files; volume permissions re-asserted; the `/etc/hosts` lines; wait for the host's
  PostgreSQL and MaluDB API; secrets loaded or generated under `/etc/business-os/secrets/`; the MaluDB token reused or minted;
  `config/.env`, `web.env.local`, `runner.env` rendered (`set_kv` on the known keys — a key the kernel adds later is NOT merged from
  `.env.example`); the Apache site, the landing page and the web drop-in rendered from `docs/deploy/` with the domain filled in.
- **Phase B, once (markers in `init-state/`):** memory schema, `CREATE DATABASE certstudy`, **all migrations** (recorded per file in
  `migrations-applied`), role passwords, a PHP check; services enabled and started; the super-admin, the model registry row, cron,
  the Installer and the JEV prompt writer hired; a model probe when `ANTHROPIC_API_KEY` is set.
- **Phase C, every boot:** `app_install.php apply` for Help Desk and Spaces from `/opt/app-cache` (an installed copy at `/srv/apps/<key>`
  is used as it is — "code: done" — so a pull you made there survives), then `fix_app_env` for those two only, then the verification
  battery and `install-report.txt`.

Consequences worth knowing:
- An image with **new kernel migrations** does not get them applied by bos-init: the `migrations` step is behind a once-marker
  (`once migrations step_migrations`). See `os-docker-kernel` for how to apply them.
- `bos-init` reconciles Help Desk and Spaces every boot; **any other application** is reconciled only when you run `apply` again
  (`bos-app.sh update <key>` does).
- `app_install.php apply` on an existing database **does not run new migrations** ("an upgrade applies the new ones by hand, in
  order", `bin/app_install.php:325`) unless the manifest ships `database.provision`, which it re-runs. `bos-app.sh update` keeps a
  ledger and applies the new files.

## The psql shim

`/usr/local/bin/psql` (and `createdb`) sits ahead of `/usr/bin` on `PATH`. For `root` and `postgres` it sets `PGHOST=pg-host`,
`PGUSER=bos_admin`, `PGDATABASE=postgres` and the matching `PGPASSFILE` unless the caller set them; then it execs the real client.
That is how the kernel's `runuser -u postgres -- psql` calls, the installers and your own `docker exec bos psql -d certstudy …`
all reach the host. An application's PHP and Python do not go through it — they connect with `DB_HOST` from their `config/.env`,
which is why that key must be `pg-host`.
