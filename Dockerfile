MAINTAINER Adam Craven <adam@ChannelAdam.com>

FROM mariadb:10.0

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-galera-server && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mysql_install_db

ADD galera.cnf /etc/mysql/conf.d/
ADD run.sh /
VOLUME /var/lib/mysql

ENTRYPOINT ["/run.sh"]
RUN chmod +x /run.sh

EXPOSE 3306 4567 4444
CMD ["mysqld"]
