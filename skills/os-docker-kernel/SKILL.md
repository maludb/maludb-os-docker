---
name: os-docker-kernel
description: Change the MaluDB Business OS KERNEL (maludb-os-core — anything under /var/www in the image: PHP, the React app, the MCP servers, the agent runner, the installer, a kernel migration) for an install that runs as the bos container. Use for "change the kernel", "fix something in os./app.", "the installer needs …", "add a kernel migration", "upgrade the kernel", "build a new image", "pin OS_CORE_REF", or when a change an application needs must land in the kernel (a K-item). A kernel change is a new image; this skill says how to build, roll out, apply the migrations bos-init will not, verify and roll back.
---

# Changing the kernel: a new image

Read `os-docker` first. The kernel inside the container is the image's `/var/www`, checked out from `maludb-os-core` at the build
argument `OS_CORE_REF` (`Dockerfile`), with `composer install`, `npm ci && npm run build` and the MCP venv done at build time.
There is no live kernel code to edit: **a kernel change is a commit in `maludb-os-core`, then an image built from it, then
`docker compose up -d`**. The volumes keep the secrets, `config/.env`, the applications and the agent workspaces; bos-init reconciles.

## The loop

1. **Change `maludb-os-core`** in a clone on the host or a developer's machine, under the kernel's own `CLAUDE.md` (React is the only UI,
   PHP a JSON API, additive migrations, specs in `docs/build-specs/`, the proofs it names). A fork is fine: the image can be built from
   any repository and ref. Prove what can be proven without a kernel install (unit tests, `php -l`, `npm run build`, the migration on a
   scratch database: `docker exec bos psql -c 'CREATE DATABASE scratch'`, apply `db/*.sql` to it through the shim, drop it).
2. **Build the image** on the VM (minutes: composer, `npm ci`, `next build`):
   ```bash
   OS_CORE_REF=<branch or tag> docker compose build
   docker compose build --build-arg OS_CORE_REPO=https://github.com/<you>/maludb-os-core.git --build-arg OS_CORE_REF=<branch>
   ```
   For a fleet, tag and push a release instead (`README.md`, "Distribution"): tags pin the kernel ref and the date; never a bare `latest`.
3. **Roll it out:** `docker compose up -d` (or `BOS_IMAGE_TAG=<tag> docker compose up -d` for a pulled release). Watch
   `docker exec bos journalctl -u bos-init -f` to `BOS-INIT-OK`; read `docker exec bos cat /etc/business-os/install-report.txt`.
4. **The kernel's new migrations** are applied by bos-init at that boot: the step runs every boot, skips every file listed in
   `init-state/migrations-applied`, applies the rest in order with `ON_ERROR_STOP` and records each (since 2026-10-07). Check the
   log for `== migrations` and the files it names. An image built before that date applied them once only, behind the
   `init-state/migrations` marker: `docker exec bos rm -f /etc/business-os/init-state/migrations && docker exec bos systemctl restart bos-init`.
5. **A new `config/.env` key** the change introduces: bos-init writes only the keys it knows (`set_kv` list in `container/bos-init.sh`)
   and copies `.env.example` only on the first boot. Add the key to `container/bos-init.sh` (from `bos.env` or a generated secret) in the
   same change, or document the by-hand line; the same for `runner.env` and `web.env.local`.
6. **A change to `docs/deploy/`** (the Apache site, the units, the cron lines) reaches the container through bos-init's rendering at every
   boot (`apache-react-cutover.conf`, `certstudy-web.service.d-cutover.conf`, `crontab.example` — the last only in phase B, once) or at
   image build (the `certstudy-*.service` copies). A new unit needs a line in the `Dockerfile`'s copy step and in bos-init's enable list.
7. **Verify**: the report; `docker exec bos curl -fsS http://127.0.0.1:8080/api/v1/health`; the runner's `/health`; a sign-in at
   `app.<domain>`; what the change was for. Then `sudo ./bos-app.sh status <key>` for one application — the installer's plan must still read
   `done` (a kernel change to `app_install.php` or the registration shows here first).
8. **Roll back**: `BOS_IMAGE_TAG=<previous> docker compose up -d` (or rebuild at the previous ref). The schema stays; a migration that the
   previous code cannot live with needs a forward fix.

## What a kernel developer can and cannot do faster

- The image build is the dev loop's cost. For iterative kernel work (a React screen, a handler), a non-docker development install of
  the kernel (`maludb-os-core` `docs/install.md`, or the reference server) is faster; the container is where the change is proven to
  install and run, not where it is written.
- `docker compose restart bos` reruns phases A and C only (config rendering, services, the two default applications' reconcile): useful
  after a `bos.env` change, useless for code.
- The Next.js app is built into the image with no `NEXT_PUBLIC_*` values; `API_BASE_URL`, `LOGIN_URL`, `WEB_INTERNAL_KEY` are read at
  runtime from `web/.env.local` on the volume — a domain change is a `bos.env` change and a restart, not a rebuild.
- The Claude CLI version is `CLAUDE_CLI_VERSION` in the `Dockerfile`; the Installer agent and every Claude-harness agent run it. Bump it
  there, never `npm install` inside.

## Non-negotiables (beyond os-docker's)

- Never edit `/var/www` inside the container as a way to change the kernel. Never `git pull` there: it is the image.
- Never run the kernel's `web/scripts/deploy.sh` inside the container; the image is the deploy.
- Never apply a kernel migration by hand without recording it in `init-state/migrations-applied` — the next marker reset would re-run it.
- Never build an image that embeds a secret or a tenant's data (`Dockerfile`: "code and dependencies only").
- A change the dockerized install needs in `maludb-os-docker` itself (`bos-init.sh`, the `Dockerfile`, the scripts) is a commit there,
  reviewed like the kernel's — it runs as root in every tenant's container.
