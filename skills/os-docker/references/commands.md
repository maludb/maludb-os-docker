# The command book — the dockerized Business OS from the host

All of these run on the host VM as root (`sudo`), from the clone of `maludb-os-docker` where the scripts are.

## Status and logs

```bash
docker ps --filter name=bos                                   # up?
docker exec bos systemctl status --no-pager                   # the whole container
docker exec bos systemctl is-active apache2 certstudy-web certstudy-records-mcp certstudy-activity-mcp \
    certstudy-actions-mcp certstudy-memory-mcp certstudy-agent-runner certstudy-activity-ingest.timer cron
docker exec bos cat /etc/business-os/install-report.txt       # the last boot's verification (no secrets in it)
docker exec bos journalctl -u bos-init -n 200 --no-pager      # the installer/reconciler's log (also /var/log/bos-init.log)
docker exec bos journalctl -u certstudy-agent-runner -f       # any kernel unit, live
docker exec bos tail -50 /var/log/certstudy-cron.log
docker exec bos curl -fsS http://127.0.0.1:8080/api/v1/health # the PHP API
docker exec bos curl -fsS http://127.0.0.1:8815/health        # the runner: harnesses, running runs
sudo ./bos-app.sh list                                        # applications: the kernel's rows and /srv/apps
sudo ./bos-app.sh status helpdesk                             # one application: units, health, the installer's plan
sudo ./bos-app.sh logs helpdesk -n 100                        # its units' journal (any journalctl option; -f follows)
```

## The database (the host's PostgreSQL, through the container's shim)

```bash
docker exec bos psql -d certstudy -Atc "select id, app_key, status, url from applications order by id"
docker exec bos psql -d certstudy -Atc "select id, display_name, business_role, member_kind from members order by id"
docker exec bos psql -l                                       # every database on the host
docker exec bos psql -d subello_helpdesk -c '\dt'             # an application's database: <tenant>_<key>
# the same from the host, as the host's postgres user:
sudo -u postgres psql -d certstudy -Atc "select count(*) from members"
```

Never pass `-U bos_admin` with a password on a command line; the shim has the pgpass file.

## Keys (provider and mail)

```bash
sudo ./bos-set-keys.sh                                        # interactive: Enter keeps, "-" clears; never echoes a value
sudo ./bos-set-keys.sh --anthropic-key-file /root/anthropic.key --malumail-key-file /root/malumail.key
docker exec bos grep -cE '^ANTHROPIC_API_KEY=.+' /etc/business-os/runner.env   # 1 = set, 0 = not — the value stays unseen
```

A provider key restarts the runner. The MaluMail key reaches the kernel at once; the applications pick it up at the next
boot's reconcile (`docker compose restart bos` when convenient) — the kernel installer's `mail` step writes it into an
application's `config/.env` when the manifest names it and the line is missing or empty.

## Applications

```bash
# plan is read-only; read it with the owner before apply
sudo ./bos-app.sh plan  https://github.com/maludb/maludb-os-hr.git
sudo ./bos-app.sh apply https://github.com/maludb/maludb-os-hr.git --ref v2026.10.07 --hire-agents --grant-standing-departments
sudo ./bos-app.sh apply /opt/app-dev/myapp                     # a bind-mounted development checkout
sudo ./bos-app.sh apply ~/maludb-os-myapp                      # a host directory: copied into the container first (ephemeral)
sudo ./bos-app.sh update hr                                    # pull, new migrations, reconcile, restart
sudo ./bos-app.sh update hr --ref v2026.10.14                  # to a tag
sudo ./bos-app.sh status hr
# the raw equivalents, when you need an installer option bos-app.sh does not pass through:
docker exec bos php /var/www/bin/app_install.php plan  <source> --by <admin email> --domain <domain> --scheme https
docker exec bos php /var/www/bin/app_install.php apply <source> --by <admin email> --domain <domain> --scheme https [--ref TAG] [--hire-agents] [--grant-standing-departments] [--tenant PREFIX] [--no-restart]
# hiring an agent the manifest only proposed (an application that is not a default):
docker exec -u www-data bos php /var/www/bin/hire_application_agent.php --app hr --agent expert --by <admin email>
# the installer's four defaults in one go (HR, Projects, Help Desk, Spaces; Help Desk and Spaces are reconciled, not reinstalled):
docker exec bos /var/www/bin/install_default_applications.sh --by <admin email> --domain <domain> --scheme https
#   ← then, for HR and Projects: sudo ./bos-app.sh update hr && sudo ./bos-app.sh update projects   (applies DB_HOST=pg-host; bos-init fixes only Help Desk and Spaces)
```

After `apply`, the raw installer leaves `DB_HOST=127.0.0.1` and possibly empty `*_PORT` keys in the application's `config/.env`;
`bos-app.sh apply`/`update` fix both, apply again (the vhost is rendered from the env) and restart the units. Doing it by hand:

```bash
docker exec bos sed -i 's/^DB_HOST=.*/DB_HOST=pg-host/' /srv/apps/<key>/config/.env
docker exec bos grep -E '^[A-Z0-9_]*_PORT=$' /srv/apps/<key>/config/.env         # any empty port? pick a free one: ss -ltn
docker exec bos php /var/www/bin/app_install.php apply /srv/apps/<key> --by <admin email> --domain <domain> --scheme https
docker exec bos bash -c 'systemctl restart $(systemctl --plain --no-legend list-units --all "<key>-*.service" | awk "{print \$1}")'
```

An application's migrations by hand (what `bos-app.sh update` automates; the installer never runs them on an existing database):

```bash
docker exec bos psql -v ON_ERROR_STOP=1 -d <tenant>_<key> -f /srv/apps/<key>/db/017_whatever.sql
docker exec bos bash -c 'echo 017_whatever.sql >> /etc/business-os/app-migrations/<key>'     # keep the ledger honest
```

## The kernel image

```bash
docker compose pull                                           # the release named in docker-compose.yml (BOS_IMAGE_TAG overrides)
BOS_IMAGE_TAG=v2026.10.14 docker compose pull && BOS_IMAGE_TAG=v2026.10.14 docker compose up -d
OS_CORE_REF=main docker compose build                         # build here from maludb-os-core at a ref (minutes: composer, npm ci, next build)
docker compose build --build-arg OS_CORE_REPO=https://github.com/<you>/maludb-os-core.git --build-arg OS_CORE_REF=my-branch
docker compose up -d                                          # recreate on the new image; bos-init reconciles; volumes untouched
docker exec bos journalctl -u bos-init -f                     # watch it; ends with BOS-INIT-OK
# NEW KERNEL MIGRATIONS ARE NOT APPLIED BY bos-init (the step is behind a once-marker). After an upgrade that adds db/*.sql:
docker exec bos rm -f /etc/business-os/init-state/migrations && docker exec bos systemctl restart bos-init
#   (safe: the step skips every file already listed in init-state/migrations-applied, applies the rest in order, re-marks)
docker compose restart bos                                    # a plain restart (no image change): phases A and C run again
docker compose down && docker compose up -d                   # recreate the container (never `down -v`)
```

A rollback is the previous tag (`BOS_IMAGE_TAG=<previous> docker compose up -d`) with the schema left as it is — migrations are additive.

## Inside, when you must look

```bash
docker exec -it bos bash                                      # a root shell; leave nothing behind
docker exec bos ls -la /srv/apps /opt/app-cache /opt/app-dev
docker exec bos git -c safe.directory='*' -C /srv/apps/helpdesk log --oneline -3
docker exec bos apache2ctl -S                                 # the vhosts as rendered
docker exec bos ss -ltnp                                      # every listener
docker exec bos getent hosts helpdesk.<domain>                # what a name resolves to inside
docker cp bos:/etc/business-os/install-report.txt ./report.txt
```

## Backups (the owner's duty; nothing here automates them)

```bash
sudo -u postgres pg_dump -Fc certstudy            > certstudy.dump        # the kernel
sudo -u postgres pg_dump -Fc <tenant>_helpdesk    > helpdesk.dump         # each application (psql -l lists them)
sudo -u postgres pg_dump -Fc <the memory database> > memory.dump          # MEM_DB in bos.env
docker run --rm -v bos-etc:/v -v "$PWD":/b ubuntu tar czf /b/bos-etc.tgz -C /v .        # the keys — without them the data is unreadable
docker run --rm -v bos-config:/v -v "$PWD":/b ubuntu tar czf /b/bos-config.tgz -C /v .
```
