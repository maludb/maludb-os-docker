---
name: os-docker-new-app
description: Build a NEW application for a MaluDB Business OS that runs as the dockerized install (the bos container) and install it there. Use when the user wants a new application, module or "app" for their Business OS on Docker — "build me an app for …", "add an application to the OS", "new application in the container" — or asks how to develop one against a dockerized kernel. The application is its own repository built with htmx-php-builder (new-app, os-application) and fitted with maludb-os-integration (os-integration); this skill adds what the container changes: where to develop, what the manifest must declare so the container's installer works, where the proofs run, and how the application gets into the container and stays updatable.
---

# A new application, installed into the bos container

Read `os-docker` first (the three layers, the non-negotiables). An application of the Business OS is **its own repository**
(`maludb-os-<key>` by convention), a separate Apache/PHP/HTMX application with its own database, its own two MCP servers and
a `maludb-os.json` manifest, installed beside the kernel by the kernel's installer. None of that changes in Docker. What changes:
the kernel lives in a container whose code layer is disposable, the database is the host's, and the only way in is `docker exec`.

## 0. Decide and name (with the owner)

- **The catalog key** — `[a-z0-9_]` only (the installer admits nothing else): it is the install path `/srv/apps/<key>`, the database
  `<tenant>_<key>` (`--tenant` defaults to the domain's first label), the roles `<key>_rw`, `<key>_records_ro`, `<key>_activity_ro`.
- **The DNS label** (`vhost.label`, may differ from the key: `consulting` for `consultant_tracking`): the name `<label>.<domain>` the
  owner must create an A record and TLS for before the kernel's agents can reach the application (topology.md, "who dials whom").
- **The repository** first: `maludb-os-<key>` on GitHub (or the owner's forge), before any code.
- Scope kind, roles and rights, the expert and any other shipped agent, which tables the estate already has — all per `os-application`
  Phase 0 and `shared-schema.md`. The sibling schemas to survey are in the container: `docker exec bos ls /srv/apps/*/db/` and
  `/opt/app-cache/*/db/`, or the `maludb-os-<key>` repositories.

## 1. Develop on the host (or a developer's machine), never inside the container

Clone the new repository on the host VM beside `maludb-os-docker` (or on any machine with Claude Code). Install the two governing
plugins and build in their order — `htmx-php-builder` `new-app` (Phase 0 → 1 → 2 → 3 → 4, with `os-application` deciding what differs
for an OS application) and `maludb-os-integration` `os-integration` (the contract) — nothing of that is Docker-specific.

```
/plugin marketplace add maludb/maludb-os-htmx-php-guidelines   → /plugin install htmx-php-builder@…
/plugin marketplace add maludb/maludb-os-integration            → /plugin install maludb-os-integration@maludb-os
```

**What the manifest and the code must do for the container's installer** (each is a defect the dockerized install surfaces at once):

1. **Every port key in `env.required`** — `APP_INTERNAL_PORT`, `MCP_RECORDS_PORT`, `MCP_ACTIVITY_PORT` and any other — **and `port_env`
   on every MCP endpoint** in `endpoints[]`. A port the installer did not assign is an empty key, an unbound MCP server and a vhost
   proxying to `:` (Spaces, 2026-10-07; txtSchedules, 2026-10-02). Pin none in `config/.env.example`; the installer chooses free ones.
2. **`DB_HOST` read from the environment everywhere** — PHP (`env('DB_HOST')`), the MCP servers' `db.py`, the ingest, the worker, the
   tests' `setup_dev.sh`. The container's PostgreSQL is the host's, reached as `pg-host`; `127.0.0.1` is a constant that fails there.
   Same for `MALUDB_API_URL` (`http://pg-host:8000` in the container).
3. **Upgrades applied by the installer:** ship `deploy/os-provision.sh` and name it `database.provision` — an idempotent script that
   creates the three roles' grants if missing and applies every `db/*.sql` not yet recorded in a ledger table of your own
   (`schema_migrations(filename, applied_at)`) in order, as the environment the installer gives it (`DB_NAME`, `DB_RW_ROLE`, …). The
   installer runs it on a new database and again on every `apply`, so `bos-app.sh update` upgrades the schema with no by-hand step.
   Without it, the installer never runs a migration on an existing database and `bos-app.sh` keeps a file ledger instead — it works,
   but the provision script is the contract that survives a reinstall from scratch.
4. **`deploy/` files are templates** with `{{DOMAIN}}`, `{{APP_DIR}}`, `{{APP_KEY}}`, `{{APP_FQDN}}`, `{{APP_INTERNAL_PORT}}`,
   `{{MCP_RECORDS_PORT}}` …; never one host's ports or names. The vhost listens on `*:80` only — TLS is the proxy's.
5. **`runtime.python`** when the venv is not `mcp/venv` or needs more than `mcp/requirements.txt` — the installer builds it inside the
   container; nothing is pre-built there for your application.
6. **`auth_kind` of an endpoint is `bearer` or `none`** — the kernel admits no `token` (Spaces' manifest was refused at apply, 2026-10-05).
7. **The expert's and every agent's tool grants name tools that exist** on the endpoints named; a tool renamed later is a silent
   grant to nothing. `hired_on_install: true` only for an application that is a default of the install; otherwise the agent is proposed and
   the owner hires it (`bos-app.sh apply` prints the command).
8. **Proofs on a scratch database, never the installed one** (`tests/setup_dev.sh` pattern); `/api/v1/health` answers 200 with the
   database checked; `php /var/www/bin/app_install.php plan` reads clean at the end of every phase (step 2 says where to run it).

## 2. Prove it — where the proofs run

The application's proofs need PHP 8.3, the extensions, python, node and a PostgreSQL to make a scratch database on. Three places:

- **A developer's own machine or VM** with the standard stack (`docs/install.md` §1 of the kernel for the packages) — the usual way;
  `testing-without-a-kernel.md` proves sign-on with `bin/dev_handoff.php` and a dev directory, no kernel needed.
- **Inside the container, against a bind-mounted checkout** — the most faithful: the same PHP, Apache, venv packages and PostgreSQL the
  installed copy will use. Copy `docker-compose.override.example.yml` to `docker-compose.override.yml`, point the volume at the
  checkout, `docker compose up -d` (a recreate; bos-init reconciles), then
  `docker exec -w /opt/app-dev/<key> bos tests/phase2/run.sh`. The shim makes `sudo -n -u postgres psql` reach the host. The Playwright
  browser proof needs Chromium the image lacks (`troubleshooting.md`); say which proof you skipped.
- **On the host VM directly** — only if the host has PHP 8.3 with the extensions; a MaluDB hosting VM carries a PHP for MaluAdmin, not
  necessarily 8.3. Check `php -v` before assuming.

The installer's read-only plan is the last proof of every phase and runs only inside the container:
`sudo ./bos-app.sh plan /opt/app-dev/<key>` (bind mount) or `sudo ./bos-app.sh plan ~/maludb-os-<key>` (copied in, ephemeral).

## 3. Install it into the container

1. Commit and push; tag a release (`v2026.10.07`). The container installs from the repository, not from a working tree.
2. `sudo ./bos-app.sh plan https://github.com/<org>/maludb-os-<key>.git --ref <tag>` — read every line with the owner: what is created,
   which ports, which agents are hired or proposed, which grants.
3. **Collect what only the owner knows** before `apply`: the sites or departments a scoped application serves, who gets which role, whether
   the standing departments get the member role (`--grant-standing-departments`), whether agents are hired now (`--hire-agents`).
4. `sudo ./bos-app.sh apply https://github.com/<org>/maludb-os-<key>.git --ref <tag> [--hire-agents] [--grant-standing-departments]`.
   It runs the kernel's installer (clone to `/srv/apps/<key>` on the volume, database and roles on the host, migrations, `config/.env`
   with the application token minted straight into it, ports, vhost, units, venv, registration, registry, skills, approvals, the admin
   grant, the proofs), then fixes `DB_HOST` and any empty port, applies again, restarts the units, seeds the migration ledger, checks
   health, and prints the owner's remaining steps.
5. For development against a local checkout instead: `sudo ./bos-app.sh apply /opt/app-dev/<key>` (the installer clones the checkout's
   committed state); after each commit on the host, `sudo ./bos-app.sh update <key>` pulls it (the installed copy's `origin` is the
   mounted path). Commits drive deploys, in development too.

## 4. After apply — what remains, and whose it is

- **The owner's:** the A record for `<label>.<domain>` and TLS at the proxy; until then the application is reachable by nobody and the
  kernel's agents cannot call its MCP (topology.md). Grants beyond those named. Hiring a proposed agent:
  `docker exec -u www-data bos php /var/www/bin/hire_application_agent.php --app <key> --agent <agent> --by <admin email>`.
- **Yours to check and report:** `sudo ./bos-app.sh status <key>` (units active, health 200, the plan all `done`); a real launch from
  `app.<domain>` once DNS exists; the application page in `os.<domain>` showing the endpoints, roles and sign-on paths; the kernel
  ids (application, endpoints); where the secrets are (the application's `config/.env` on `bos-srv-apps`), without their values.
- **A loopback `/etc/hosts` line** the installer added because the name did not resolve yet would shadow the name under `SCHEME=https`
  (the kernel's agents dial `https://<label>.<domain>/mcp/…`); `bos-app.sh apply`/`update` remove it and say why. Never add such a line yourself.

## Non-negotiables (beyond os-docker's)

- Never develop in `/srv/apps/<key>` inside the container, never `docker cp` edited files into it: the repository is the only source.
- Never put a host's ports, names or `127.0.0.1` into the manifest, `deploy/` or `config/.env.example`.
- Never skip `plan` before `apply`, and never `apply` without the owner's answers on grants and agents.
- Never install an application whose repository you have not read — manifest, migrations, units, vhost (`os-install` "Before anything").
