FROM alpine:3.19

RUN apk add --no-cache \
    bash \
    bash-doc \
    curl \
    whois \
    sqlite \
    sqlite-doc \
    certbot \
    apache2 \
    apache2-utils \
    openssl \
    socat \
    logrotate \
    dcron \
    tzdata \
    && rm -rf /var/cache/apk/*

RUN mkdir -p \
    /usr/local/bin \
    /etc/fqdntools \
    /etc/fqdnmgr/providers \
    /var/log/fqdnmgr \
    /var/log/apache-collector \
    /tmp/a2tools.cache \
    /run \
    /etc/cron.daily \
    /etc/cron.weekly \
    /etc/logrotate.d \
    /etc/letsencrypt/accounts \
    /etc/letsencrypt/renewal \
    /etc/letsencrypt/archive \
    /var/lib/letsencrypt \
    /var/log/letsencrypt

COPY scripts/ /usr/local/bin/

RUN cd /usr/local/bin && \
    for dir in */; do \
      cmd="${dir%/}"; \
      if [ -f "${dir}${cmd}.sh" ]; then \
        ln -sf "/usr/local/bin/${dir}${cmd}.sh" "/usr/local/bin/${cmd}"; \
        chmod +x "/usr/local/bin/${dir}${cmd}.sh"; \
      fi; \
    done && \
    chown -R root:root /usr/local/bin && \
    chmod 0550 /usr/local/bin && \
    find /usr/local/bin -type d -name '*.d' -exec chmod -R 0550 {} + 2>/dev/null || true

RUN sqlite3 /etc/fqdntools/domains.db < /usr/local/bin/fqdnmgr.d/schema.sql && \
    sqlite3 /etc/fqdntools/creds.db < /usr/local/bin/fqdncredmgr.d/schema.sql && \
    chown -R root:root /etc/fqdntools && \
    chmod 0750 /etc/fqdntools && \
    chmod 0640 /etc/fqdntools/*.db

RUN mkdir -p /etc/fqdnmgr/providers && \
    cp -r /usr/local/bin/fqdnmgr.d/providers/* /etc/fqdnmgr/providers/ 2>/dev/null || true && \
    chown -R root:root /etc/fqdnmgr/providers && \
    chmod 0750 /etc/fqdnmgr/providers

RUN cp /usr/local/bin/fqdnmgr.d/domain.conf.tpl /etc/fqdnmgr/domain.conf.tpl && \
    cp /usr/local/bin/fqdnmgr.d/domain.conf.tpl /etc/fqdnmgr/domain.conf && \
    chown root:root /etc/fqdnmgr/*.tpl /etc/fqdnmgr/domain.conf && \
    chmod 0640 /etc/fqdnmgr/*.tpl /etc/fqdnmgr/domain.conf

RUN cp /usr/local/bin/a2sitemgr.d/apache-collector.logrotate /etc/logrotate.d/apache-collector && \
    chown root:root /etc/logrotate.d/apache-collector && \
    chmod 0644 /etc/logrotate.d/apache-collector

RUN ln -sf /usr/share/zoneinfo/UTC /etc/localtime

RUN mkdir -p /etc/crontabs && \
    echo '0 0,12 * * * sleep $((RANDOM % 3600)) && certbot renew -q' > /etc/crontabs/root && \
    chmod 0600 /etc/crontabs/root

# Keep Alpine's packaged crond binary untouched; do not repoint it.
RUN test -x /usr/sbin/crond

COPY Docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/etc/apache2/sites-available", "/etc/letsencrypt/live"]
WORKDIR /
ENTRYPOINT ["/entrypoint.sh"]
CMD ["busybox", "crond", "-f", "-l", "8", "-c", "/etc/crontabs"]
