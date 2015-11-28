FROM mariadb:10.0

MAINTAINER Adam Craven <adam@ChannelAdam.com>

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-galera-server=$MARIADB_VERSION && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

VOLUME /var/lib/mysql
ADD galera.cnf /etc/mysql/conf.d/
ADD docker-entrypoint-bb.sh /
ADD run.sh /

ENTRYPOINT ["/run.sh"]
RUN chmod +x /run.sh
RUN chmod +x /docker-entrypoint-bb.sh

EXPOSE 3306 4567 4444
CMD ["mysqld"]
