FROM stalwartlabs/stalwart:latest

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl caddy && \
    rm -rf /var/lib/apt/lists/*

COPY stalwart.toml /opt/stalwart/etc/config.toml
COPY Caddyfile /etc/caddy/Caddyfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 25

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
