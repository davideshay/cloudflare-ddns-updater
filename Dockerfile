FROM debian:stable-slim

RUN apt-get update && \ 
    apt-get install -y --no-install-recommends jq ca-certificates curl && \
    apt-get clean && \
    rm -fr /var/lib/apt/lists 

COPY cloudflare-ddns-updater.sh /usr/local/bin/cloudflare-ddns-updater.sh

RUN chmod 755 /usr/local/bin/cloudflare-ddns-updater.sh

CMD [ "/usr/local/bin/cloudflare-ddns-updater.sh" ]