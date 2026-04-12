FROM stalwartlabs/stalwart:latest

COPY stalwart.toml /opt/stalwart/etc/config.toml
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 25

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
