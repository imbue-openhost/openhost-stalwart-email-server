# there's also an image for just the mail server part
FROM stalwartlabs/stalwart:v0.16.2

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl caddy && \
    rm -rf /var/lib/apt/lists/* && \
    curl --proto '=https' --tlsv1.2 -LsSf \
      https://github.com/stalwartlabs/cli/releases/latest/download/stalwart-cli-installer.sh | sh && \
    cp /root/.cargo/bin/stalwart-cli /usr/local/bin/stalwart-cli

RUN mkdir -p /etc/stalwart /etc/caddy /opt/stalwart/static && \
    chown -R stalwart:stalwart /etc/stalwart /etc/caddy /opt/stalwart/static
USER stalwart

COPY --chown=stalwart:stalwart Caddyfile.template /etc/caddy/Caddyfile.template
COPY --chown=stalwart:stalwart owner-login.html /opt/stalwart/static/owner-login.html
COPY --chown=stalwart:stalwart entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 25

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
