FROM stalwartlabs/stalwart:latest

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl caddy && \
    rm -rf /var/lib/apt/lists/*
USER stalwart

COPY stalwart.toml /opt/stalwart/etc/config.toml
COPY Caddyfile.template /etc/caddy/Caddyfile.template
COPY owner-login.html /opt/stalwart/static/owner-login.html
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN ls -lah /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 25

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
