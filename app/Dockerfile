FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Stockholm
ENV LUA_PATH="/opt/worldsim/lua/?.lua;/opt/worldsim/lua/?/init.lua;;"

RUN apt-get update &&     apt-get install -y --no-install-recommends \
        luajit \
        luarocks \
        sqlite3 \
        gnuplot-nox \
        curl \
        cron \
        build-essential \
        libsqlite3-dev && \
    luarocks --lua-version=5.1 install lsqlite3 && \
    luarocks --lua-version=5.1 install dkjson && \
    apt-get remove -y build-essential libsqlite3-dev && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

WORKDIR /opt/worldsim

COPY lua ./lua
COPY plots ./plots
COPY make_plots.sh ./
COPY crontab /etc/cron.d/worldsim
COPY entrypoint.sh ./entrypoint.sh

RUN chmod +x /opt/worldsim/make_plots.sh \
    && chmod +x /opt/worldsim/lua/*.lua \
    && chmod 0644 /etc/cron.d/worldsim \
    && mkdir -p /var/www/html/worldsim \
    && mkdir -p /opt/worldsim/backups \
    && mkdir -p /opt/worldsim/archive \
    && chmod +x /opt/worldsim/entrypoint.sh \
    && touch /var/log/cron.log

CMD ["/opt/worldsim/entrypoint.sh"]
