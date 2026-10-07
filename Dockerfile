# MaluDB Business OS Core — dockerized install (kernel + Help Desk + Spaces)
#
# Single systemd container that runs the stack of docs/install.md §3–§13 (the
# hosting-VM edition, docs/install-on-maludb-hosting.md) on top of a MaluDB
# hosting VM. PostgreSQL and the MaluDB API stay on the HOST; every local
# psql/createdb call inside the container is redirected to the host by the
# shim in /usr/local/bin (see container/psql-shim.sh).
#
# Build:   docker build --build-arg OS_CORE_REF=<tag-or-branch> -t maludb-business-os .
# Run:     via docker-compose.yml, configured by host-install.sh.
#
# The image holds code and dependencies only — no secrets, no tenant data.
# All mutable state lives on named volumes and the host's PostgreSQL.

FROM ubuntu:24.04

ARG OS_CORE_REF=main
ARG CLAUDE_CLI_VERSION=2.1.278
ARG OS_CORE_REPO=https://github.com/maludb/maludb-os-core.git
ARG INTEGRATION_REPO=https://github.com/maludb/maludb-os-integration.git
ARG HELPDESK_REPO=https://github.com/maludb/maludb-os-helpdesk.git
ARG SPACES_REPO=https://github.com/maludb/maludb-os-spaces.git

ENV DEBIAN_FRONTEND=noninteractive container=docker

# --- systemd + base tooling (install.md §1 host setup, minus PostgreSQL server) -----------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus cron sudo \
        git curl ca-certificates gnupg jq unzip openssl \
        python3-venv python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    # units that make no sense in a container
    && systemctl mask systemd-udevd.service systemd-udevd-kernel.socket systemd-udevd-control.socket \
                      systemd-modules-load.service systemd-networkd.service systemd-resolved.service \
                      sys-kernel-debug.mount sys-kernel-tracing.mount

# --- Apache, PHP 8.3, Composer (install.md §1.2) ------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        apache2 libapache2-mod-php8.3 php8.3-cli php8.3-pgsql php8.3-curl php8.3-gd \
        php8.3-mbstring php8.3-xml php8.3-zip php8.3-opcache php8.3-readline composer \
    && a2enmod -q proxy proxy_http rewrite headers \
    && systemctl disable apache2 cron \
    && rm -rf /var/lib/apt/lists/*

# --- Node 24 (install.md §1.2) ------------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- PostgreSQL 17 CLIENT only, from PGDG (the server is the host VM's) -------------------------
RUN install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
         https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends postgresql-client-17 \
    && rm -rf /var/lib/apt/lists/*

# --- Kernel code at /var/www (install.md §3) ----------------------------------------------------
RUN rm -rf /var/www \
    && git clone "$OS_CORE_REPO" /var/www \
    && cd /var/www && git checkout --quiet "$OS_CORE_REF" \
    && composer install --no-dev --no-interaction --quiet \
    && install -d -o www-data -g www-data -m 750 /var/www/storage

# --- Next.js front end, built into the image (install.md §7) ------------------------------------
# Safe at build time: web/.env.example defines no NEXT_PUBLIC_* values; API_BASE_URL, LOGIN_URL
# and WEB_INTERNAL_KEY are read server-side at runtime from web/.env.local, which is a symlink to
# the bos-etc volume so it survives container recreation.
RUN cd /var/www/web && npm ci --no-fund --no-audit && npm run build \
    && chown -R www-data:www-data /var/www/web/.next \
    && ln -s /etc/business-os/web.env.local /var/www/web/.env.local

# --- MCP servers' shared venv (install.md §8) ---------------------------------------------------
RUN python3 -m venv /var/www/mcp/venv \
    && /var/www/mcp/venv/bin/pip install --quiet -r /var/www/mcp/requirements.txt

# --- Claude Code CLI, pinned (docs/deploy/claude-agent-install.md step 1) -----------------------
RUN install -d -m 0755 -o root -g root /opt/claude-agent \
    && npm install --prefix /opt/claude-agent "@anthropic-ai/claude-code@${CLAUDE_CLI_VERSION}" --no-fund --no-audit \
    && install -d -m 0755 /opt/claude-agent/bin \
    && ln -sfn /opt/claude-agent/node_modules/@anthropic-ai/claude-code/bin/claude.exe /opt/claude-agent/bin/claude \
    && chmod -R go-w /opt/claude-agent \
    && /opt/claude-agent/bin/claude --version

# --- Runner + sandbox users and launcher (install.md §9.1) --------------------------------------
# The `postgres` OS user exists only so the kernel's `runuser -u postgres -- psql` calls work;
# it has no privileges — the psql shim sends its queries to the host's PostgreSQL.
RUN useradd --system --no-create-home --shell /usr/sbin/nologin bos-runner \
    && useradd --system --no-create-home --shell /usr/sbin/nologin bos-agent \
    && usermod -a -G bos-agent,adm,systemd-journal bos-runner \
    && useradd --system --create-home --home-dir /var/lib/postgres-client --shell /bin/bash postgres \
    && install -d -o bos-runner -g bos-agent -m 2770 /var/lib/business-os /var/lib/business-os/agents \
    && install -o root -g root -m 0755 /var/www/docs/deploy/bos-agent-exec /usr/local/sbin/bos-agent-exec \
    && install -o root -g root -m 0440 /var/www/docs/deploy/bos-runner.sudoers /etc/sudoers.d/bos-runner \
    && visudo -cf /etc/sudoers.d/bos-runner

# --- psql/createdb shim: local-postgres calls go to the host VM ---------------------------------
COPY container/psql-shim.sh /usr/local/bin/psql
RUN chmod 0755 /usr/local/bin/psql && ln -s psql /usr/local/bin/createdb

# --- Kernel systemd units (installed, NOT enabled — bos-init enables them once configured) ------
RUN cp /var/www/docs/deploy/certstudy-web.service \
       /var/www/docs/deploy/certstudy-records-mcp.service \
       /var/www/docs/deploy/certstudy-activity-mcp.service \
       /var/www/docs/deploy/certstudy-actions-mcp.service \
       /var/www/docs/deploy/certstudy-memory-mcp.service \
       /var/www/docs/deploy/certstudy-agent-runner.service \
       /var/www/docs/deploy/certstudy-activity-ingest.service \
       /var/www/docs/deploy/certstudy-activity-ingest.timer \
       /etc/systemd/system/

# --- Apache internals that need no domain (install.md §6) ---------------------------------------
RUN echo 'Listen 127.0.0.1:8080' >> /etc/apache2/ports.conf \
    && install -m 644 /var/www/docs/deploy/php-99-business-os.ini /etc/php/8.3/apache2/conf.d/99-business-os.ini

# --- The integration plugin and the two applications, pre-fetched (install.md §11.1, §12) -------
RUN git clone --depth 1 "$INTEGRATION_REPO" /opt/maludb-os-integration \
    && git clone "$HELPDESK_REPO" /opt/app-cache/maludb-os-helpdesk \
    && git clone "$SPACES_REPO"  /opt/app-cache/maludb-os-spaces

# --- First-boot initializer ---------------------------------------------------------------------
COPY container/bos-init.sh /usr/local/sbin/bos-init
COPY container/bos-init.service /etc/systemd/system/bos-init.service
RUN chmod 0755 /usr/local/sbin/bos-init \
    && install -d /etc/business-os \
    && ln -s /etc/systemd/system/bos-init.service /etc/systemd/system/multi-user.target.wants/bos-init.service

# Tools the kernel's installers shell out to that minimal ubuntu lacks: app_install.php's
# port picker runs `ss` per candidate port and treats ANY output — including "command not
# found" on stderr — as "port taken", which loops forever. Trailing layer to keep cache warm.
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/*

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
