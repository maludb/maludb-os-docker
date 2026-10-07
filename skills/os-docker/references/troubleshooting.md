# Troubleshooting — symptom, cause, fix

Each entry names the evidence it was written from. Check the cause before applying the fix: a symptom that matches may have
another cause on a given VM.

## An application's pages or MCP tools fail with a database connection error
- **Cause:** `DB_HOST=127.0.0.1` in `/srv/apps/<key>/config/.env` — the kernel's installer writes it (`bin/app_install.php:383`)
  and no PostgreSQL listens in the container. bos-init fixes it for Help Desk and Spaces only (`fix_app_env`).
- **Check:** `docker exec bos grep -E '^DB_HOST=' /srv/apps/<key>/config/.env`
- **Fix:** `sudo ./bos-app.sh update <key>` (sets `pg-host`, re-applies, restarts), or the by-hand lines in `commands.md`.

## Apache fails `configtest`, or a vhost proxies to `:` — an MCP unit cannot bind
- **Cause:** a manifest endpoint without `port_env` leaves a required `*_PORT` key EMPTY in `config/.env`; the vhost is rendered from it
  (bos-init's comment on Spaces, 2026-10-07; txtSchedules took Apache down the same way on 2026-10-02).
- **Check:** `docker exec bos grep -E '^[A-Z0-9_]*_PORT=$' /srv/apps/<key>/config/.env`; `docker exec bos apache2ctl configtest`
- **Fix:** `sudo ./bos-app.sh update <key>` assigns a free port, re-applies and restarts. In the application: declare `port_env` on every
  MCP endpoint and list every port key in `env.required` (`os-docker-new-app`).

## Agents cannot reach an application (tool calls refused, "connection refused", entity resolution fails)
- **Cause:** the harness dials the endpoint's registered URL, `https://<label>.<domain>/mcp/…` (`mcp/agent_runner/claude_render.py:39`);
  inside the container that name either resolves through the owner's DNS to the proxy (works), does not resolve at all (the owner's
  A record is missing), or resolves through a loopback line in `/etc/hosts` to `127.0.0.1:443`, where nothing listens. The kernel's
  installer adds such a line for a name that does not resolve at `apply`; bos-init (for Help Desk and Spaces) and `bos-app.sh`
  (for any application) strip it under `https` since 2026-10-07 — an image built before then writes it at every boot.
- **Check:** `docker exec bos getent hosts <label>.<domain>` (127.0.0.1 = shadowed) and `docker exec bos curl -sS -o /dev/null -w '%{http_code}\n' https://<label>.<domain>/mcp/records`
- **Fix:** the owner's A record and TLS proxy for the name. If a loopback line is there (an older image, or a raw `app_install.php
  apply`), remove it: `docker exec bos sed -i '/[[:space:]]<label>.<domain>$/d' /etc/hosts`, or run `sudo ./bos-app.sh update <key>`.
  Running the install with `SCHEME=http` makes loopback work but registers plain-http URLs the browser will be sent to; not a fix.

## After a kernel image upgrade a screen or tool fails on a missing column or table
- **Cause:** the image carries new `db/*.sql` and bos-init did not apply them. Since 2026-10-07 the migrations step runs at every boot
  and applies what `init-state/migrations-applied` lacks; an image built before then ran it once, behind the `init-state/migrations`
  marker. Or bos-init failed before reaching the step (`journalctl -u bos-init`).
- **Check:** `docker exec bos bash -c 'ls /var/www/db/*.sql | xargs -n1 basename | sort > /tmp/have; sort /etc/business-os/init-state/migrations-applied > /tmp/done; comm -23 /tmp/have /tmp/done'`
- **Fix:** `docker exec bos systemctl restart bos-init` (a current image); on an older image first
  `docker exec bos rm -f /etc/business-os/init-state/migrations`. The step skips what `migrations-applied` lists and applies the rest in order.

## `app_install.php` says "exists but holds no maludb-os.json — not overwriting"
- **Cause:** `/srv/apps/<key>` exists on the volume from a failed or partial earlier attempt.
- **Fix:** look first (`docker exec bos ls -la /srv/apps/<key>`); if it is junk, `docker exec bos rm -rf /srv/apps/<key>` and apply again.
  Never remove a directory that holds an application someone uses.

## `apply` ran but the change I pushed is not in the container
- **Cause:** an installed copy is used as it is ("code: done … the installed copy is used", `bin/app_install.php:250`); `apply` never
  pulls. Also: bos-init's phase C applies Help Desk and Spaces from `/opt/app-cache` (the image's clone), which is older than GitHub.
- **Fix:** `sudo ./bos-app.sh update <key> [--ref TAG]` — a fetch/pull in `/srv/apps/<key>`, then the new migrations, then apply.

## A new key the kernel introduced in `config/.env.example` is missing from the container's `config/.env`
- **Cause:** bos-init renders `config/.env` with `set_kv` on the keys it knows; it copies `.env.example` only when the file does not
  exist yet (the volume keeps the first boot's file).
- **Fix:** add the key by hand (`docker exec bos bash -c 'echo NEW_KEY=value >> /var/www/config/.env'`, owner `root:www-data` 640), then
  restart what reads it (`certstudy-web`, or `apache2` for PHP — PHP reads per request). Propose the key to bos-init in maludb-os-docker.

## The installer's port picker loops forever
- **Cause:** `ss` missing (the picker treats any output, including "command not found", as "port taken"). The image installs `iproute2`
  in its last layer; an image built before that layer existed lacks it.
- **Fix:** rebuild the image from current `maludb-os-docker`.

## `bos-init` failed at first boot
- **Check:** `docker exec bos journalctl -u bos-init -n 100 --no-pager`; the step name is in the `FATAL: step '<name>' failed` line.
- **Fix:** every phase-B step is resumable: fix the cause (a host PostgreSQL not listening on the bridge, a wrong memory login in
  `bos.env`, no route to `pg-host:8000`), then `docker exec bos systemctl restart bos-init`. Markers of finished steps are kept.

## The super-admin cannot sign in / the password is unknown
- A generated password is at `/etc/business-os/admin-password` inside the container until shredded (`host-install.sh`'s closing
  lines say how to read it once). An owner-chosen one was never stored. Never print it in a session; tell the owner where it is.

## MaluMail mail is not sent by an application
- **Check:** `docker exec bos grep -cE '^MALUMAIL_API_KEY=.+' /srv/apps/<key>/config/.env` (0 = unset).
- **Fix:** `sudo ./bos-set-keys.sh` (sets the kernel's key), then `sudo ./bos-app.sh update <key>` or a container restart: the
  installer's `mail` step writes the key into the application's env when the line is missing or empty.

## The proofs of an application (`tests/phase*/run.sh`) will not run inside the container
- `sudo -n -u postgres psql` works there (the shim) and PHP 8.3, node and python are present; but the Playwright browser proof needs
  `npx playwright install --with-deps chromium` (not in the image) and some harnesses hard-code another application's venv
  (`/srv/apps/projects/mcp/venv` in Help Desk's). Run the PHP proofs; say which proof you skipped and why; install Playwright in a
  development image, never in production.

## Activity-memory ingest returns 500 for everything
- **Cause:** a `maludb-python-api-server` on the host from before the `jsonable_encoder` fix (`host-install.sh`'s survey warns).
- **Fix:** the owner's: `sudo ./host-install.sh --fix-host-api` (patches one file from the API repo's origin and restarts `maludb-api`),
  or an updated hosting image.
