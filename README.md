# MaluDB Business OS — dockerized install

Installs the Business OS kernel plus the **Help Desk** and **Spaces** applications as a single
systemd container on a MaluDB hosting VM, replacing the interactive runbook
(`maludb-os-core/docs/install-on-maludb-hosting.md`) with one command:

```bash
sudo ./host-install.sh
```

Run interactively, it prompts for everything an owner must decide: the first super-admin's
email, display name and password (Enter auto-generates one, shown once after install), and the
optional provider keys — `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, MaluMail — each skippable
(agents and mail wait until a key is set later via `set-provider-key.sh`). The domain is
auto-detected from the VM's FQDN (`hostname -f`) and forward-confirmed against the VM's public
IP; provisioning should set each VM's hostname to its tenant domain so no flag is needed.

For unattended installs every answer has a flag: `--domain`, `--admin-email`, `--admin-name`,
`--admin-password-file`, `--anthropic-key-file`, `--openrouter-key-file`, `--malumail-key-file`,
`--app-env prod|dev`, `--image-tag`, `--build`/`--no-build`, `--fix-host-api`. An owner-chosen
password is scrubbed from the host's `bos.env` as soon as the bootstrap has used it.

## Distribution

The unit of distribution is **this directory plus the image**:

1. Build and push a release: `docker compose build && docker tag ... ghcr.io/maludb/maludb-business-os:vYYYY.MM.DD && docker push ...` (tags pin the kernel ref + date; never ship a bare `latest`).
2. Operators clone this repo on their MaluDB hosting VM and run `sudo ./host-install.sh` — it pulls the image (`--image-tag` picks the release), interviews the owner, and installs. A fleet upgrade is "new tag, rerun"; rollback is the previous tag.
3. Air-gapped VMs: `docker save ghcr.io/maludb/maludb-business-os:vYYYY.MM.DD | gzip > bos-image.tgz`, ship it beside the scripts, `docker load` it on the VM, then `sudo ./host-install.sh --no-build`.

The survey warns when the VM's maludb stack is behind the kernel's floor: `maludb_core` < 0.106,
or a `maludb-python-api-server` that predates the `jsonable_encoder` fix (activity-memory ingest
500s without it; `--fix-host-api` patches that one file from the API repo's origin and restarts
the service). Long-term both belong in the hosting VM golden image.

## What lands where

| Piece | Where |
|---|---|
| PostgreSQL 17 + maludb_core, MaluDB API (:8000) | **host VM** (pre-installed by hosting; untouched except a `bos_admin` role and one pg_hba block) |
| Kernel (Apache/PHP :80 + :8080, Next.js :3000), 4 MCP servers, agent runner, cron, Claude CLI 2.1.278 | **container** (`bos`), systemd-managed |
| `certstudy` + per-app databases, tenant memory | host PostgreSQL |
| Secrets, `config/.env`, `runner.env`, admin password, app checkouts, storage | named volumes (`bos-etc`, `bos-config`, `bos-storage`, `bos-srv-apps`, `bos-var-lib`) |

The container reaches the host as `pg-host` (172.30.0.1, the pinned bosnet gateway). A psql shim
at `/usr/local/bin/psql` redirects the kernel installers' local `runuser -u postgres -- psql`
calls to the host — no upstream file is patched.

## Host changes made by host-install.sh

1. Docker CE installed (if absent).
2. PostgreSQL: superuser role `bos_admin` (password in `/etc/business-os-docker/bos_admin.pw`,
   root 600) and a marker-delimited `pg_hba.conf` block allowing `172.30.0.0/24` with scram; reload.
3. Host Apache stopped + disabled to free :80. MaluAdmin's files stay in `/var/www`; to restore it,
   move it to another port in `/etc/apache2/ports.conf` and re-enable apache2.
4. `/etc/business-os-docker/bos.env` written (root 600) — the container's whole configuration,
   including the tenant memory credentials parsed from `/var/www/config/database.php`.

## First boot (bos-init)

`bos-init.service` runs `docs/install.md` §3–§13 with the hosting-VM substitutions: memory
schema check/enable, token mint, `certstudy` + 154 migrations (resumable), role passwords, the
seven keys, Apache vhosts, services, super-admin bootstrap (`--password` generated, stored at
`/etc/business-os/admin-password` inside the container), model registry, Installer + JEV agents,
then `app_install.php apply` for Help Desk and Spaces. Re-runs on every boot as a reconcile:
config is re-rendered from env + persisted secrets, services re-enabled, apps re-applied
(idempotent). Progress: `docker exec bos journalctl -u bos-init -f`.

## Operations

- **Status**: `docker exec bos systemctl status` / `docker exec bos cat /etc/business-os/install-report.txt`
- **Provider keys later**: `sudo ./bos-set-keys.sh` — prompts for each key (Enter keeps the
  current value, `-` clears it; `--*-key-file` flags for automation), persists them in `bos.env`
  so container recreates keep them, applies them live, and restarts the agent runner when a
  provider key changed.
- **Add HR/Projects later**: `docker exec bos php /var/www/bin/app_install.php apply https://github.com/maludb/maludb-os-hr.git --by <admin> --domain <domain> --scheme https --hire-agents --grant-standing-departments`
- **Upgrade**: rebuild with a new `OS_CORE_REF` (`OS_CORE_REF=<tag> docker compose build`), then
  `docker compose up -d`. Volumes keep secrets and config; bos-init reconciles.
- **Backups** (owner's duty): `pg_dump -Fc` on the host for `certstudy`, the app databases and the
  tenant memory database, plus the `bos-etc`/`bos-config` volumes (they hold the encryption keys —
  losing SECRETS_KEY/APP_TOTP_KEY makes encrypted data unreadable).
- **TLS/DNS**: the container serves plain :80 vhosts (`<name>.<domain>`); TLS terminates at the
  proxy in front, DNS A records are the owner's.

## Known trade-offs

- `privileged: true`: systemd as PID 1 plus `bos-agent-exec`'s `systemd-run` sandbox need broad
  capabilities. Acceptable on a single-tenant VM; a capability allowlist is a follow-up.
- Host MaluAdmin is off :80 after install (files intact).
- `claude_conformance` and the model probe only run when `ANTHROPIC_API_KEY` is provided.
