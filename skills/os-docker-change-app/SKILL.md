---
name: os-docker-change-app
description: Change an application that is INSTALLED in a dockerized MaluDB Business OS (the bos container) — Help Desk, Spaces, HR, Projects or any application of ours at /srv/apps/<key> on the bos-srv-apps volume. Use for "fix/extend/change <application>", "add a field/screen/tool to Help Desk", "update Spaces to the latest", "roll the app back", or when a change needs a migration on an installed application. It says where the change is made (the repository, never the installed copy), how a schema change ships, and how the change reaches the container — bos-app.sh update: pull, new migrations, reconcile, restart — and what to verify.
---

# Changing an installed application

Read `os-docker` first. An installed application is a **git clone at `/srv/apps/<key>`** on the `bos-srv-apps` volume (cloned by
the kernel's installer from a URL, a bind-mounted checkout, or `/opt/app-cache` for Help Desk and Spaces), with its own database
`<tenant>_<key>` on the host and its `config/.env` beside it. Three facts shape the work:

1. **The installer never updates code or schema it finds installed.** `apply` on an existing `/srv/apps/<key>` says "code: done … the
   installed copy is used" and, on an existing database, "an upgrade applies the new ones by hand" (`bin/app_install.php:250`, `:325`) —
   unless the manifest ships `database.provision`, which it re-runs.
2. **bos-init re-applies Help Desk and Spaces at every boot** from `/opt/app-cache` (the image's clone, as old as the image) — a pull you
   made in `/srv/apps/helpdesk` survives (the installed copy is used), and the apply reconciles vhost, units, registry and endpoints.
3. **Nothing on the volume is in a repository** until it is pushed: an edit in `/srv/apps/<key>` is invisible to the next installer, the
   next developer and the next VM.

## The loop

1. **Find what is installed.** `sudo ./bos-app.sh status <key>` — the checkout's tag or commit and branch, its units, health, the plan.
   `sudo ./bos-app.sh list` shows every application's `origin`. Work from that ref.
2. **Change the repository** — a clone on the host (or a developer's machine), a branch, the change under the plugins that govern the
   application (`htmx-php-builder` for the code and screens, `maludb-os-integration` for anything touching sign-on, roles, MCP, the
   manifest). Read the application's own `CLAUDE.md` first: each application records its rules, its ports, its state and its tests.
3. **A schema change is a new numbered, additive migration** (`db/0NN_<what>.sql`), never an edit of an applied file; views keep
   `security_barrier`, columns are appended, grants re-checked. If the application ships `database.provision`, make sure the script
   picks the new file up (its ledger table); if not, the file ledger `bos-app.sh` keeps will.
4. **Prove it** on a scratch database (`tests/`), where the application's `CLAUDE.md` says — a developer machine, or the container with
   the checkout bind-mounted (`os-docker-new-app` §2). A change to the manifest, the action manifest or a tool surface also needs
   `bin/build_action_registry.php` re-run and `app_install.php plan` clean.
5. **Commit, push, tag.** The container pulls from the repository the installed copy's `origin` names. For a default application that is
   a fork of ours, the installed copy's `origin` is `/opt/app-cache/maludb-os-<key>` — point it at your fork once:
   `docker exec bos git -c safe.directory='*' -C /srv/apps/<key> remote set-url origin https://github.com/<you>/maludb-os-<key>.git`.
6. **Update the container:** `sudo ./bos-app.sh update <key> [--ref <tag>]`. In order: `git fetch`, then `pull --ff-only` on the branch (or
   `checkout <tag>`); `composer install` and the venv's `pip install -r` when their files exist; the new migrations — those not in the
   ledger `/etc/business-os/app-migrations/<key>`, in order, `ON_ERROR_STOP`, each recorded as it passes (or the provision script, by the
   installer) — then the installer's `apply` to reconcile vhost, units, registry (and a restart of the kernel's actions MCP), endpoints,
   roles (`app_roles` re-read), skills and approvals; `DB_HOST`/port fixes; the application's units restarted; health checked.
7. **Verify:** `sudo ./bos-app.sh status <key>` (plan all `done`, health 200); the screen or tool you changed, through the real name; for a
   tool change, an agent's grant still names it (Agent HR → the agent → tools); `sudo ./bos-app.sh logs <key> -n 50` clean.
8. **Report** the ref before and after, the migrations applied, what was restarted, what the owner still owes (a grant, a hire, DNS).

## When the change is to the installed copy by accident

Someone edited `/srv/apps/<key>` directly. `git -C /srv/apps/<key> status` shows it. Do not pull over it: bring the diff into the
repository (`docker cp bos:/srv/apps/<key>/<file> …` or `git diff` into a patch), commit it there, `git -C /srv/apps/<key> checkout -- .`
inside, then `bos-app.sh update`. Tell the owner the copy had been edited in place.

## Rolling back

`sudo ./bos-app.sh update <key> --ref <previous tag>` — the code goes back, the schema stays (migrations are additive and forward-only;
an application whose new migration breaks the old code needs a forward fix, not a rollback). `bos-app.sh` refuses a pull that is not a
fast-forward; a rewritten branch is checked out by tag.

## Non-negotiables (beyond os-docker's)

- Never edit `/srv/apps/<key>` or its `config/.env` inside the container as the way to change the application — the repository, then
  `update`. The one exception is what `bos-app.sh` itself does to `config/.env` (`DB_HOST`, empty ports) and the `mail` step's keys.
- Never run a migration against `<tenant>_<key>` that is not committed in the repository's `db/` (or applied by its provision script).
- Never re-apply with a different `--tenant` or `--domain` than the install used; it would register a second application.
- Never test on the installed database: `tests/setup_dev.sh` builds a scratch one.
