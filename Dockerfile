FROM mariadb:10.0

MAINTAINER Adam Craven <adam@ChannelAdam.com>

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && \
    apt-get install -y mariadb-galera-server=$MARIADB_VERSION && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

VOLUME /var/lib/mysql

EXPOSE 3306 4567 4444

COPY docker-entrypoint-2.sh /
RUN chmod +x /docker-entrypoint-2.sh

COPY run.sh /
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
CMD ["mysqld"]
