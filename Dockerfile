# there's also an image for just the mail server part
FROM stalwartlabs/stalwart:v0.16.3

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl caddy xz-utils python3 ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    curl --proto '=https' --tlsv1.2 -LsSf \
      https://github.com/stalwartlabs/cli/releases/latest/download/stalwart-cli-installer.sh | sh && \
    cp /root/.cargo/bin/stalwart-cli /usr/local/bin/stalwart-cli && \
    curl --proto '=https' --tlsv1.2 -LsSf https://astral.sh/uv/install.sh | \
      env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh

RUN mkdir -p /etc/stalwart /etc/caddy /opt/stalwart/static /opt/jmap_proxy

# Install JMAP proxy dependencies into a venv at /opt/jmap_proxy/.venv.
COPY jmap_proxy/pyproject.toml /opt/jmap_proxy/pyproject.toml
COPY jmap_proxy/src /opt/jmap_proxy/src
RUN cd /opt/jmap_proxy && uv sync --no-dev

COPY Caddyfile.template /etc/caddy/Caddyfile.template
COPY owner-login.html /opt/stalwart/static/owner-login.html
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 25

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
