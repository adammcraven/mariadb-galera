#!/bin/bash
set -e

if [ "$NODE_IP" ]; then
	echo "wsrep_node_address=$NODE_IP" >> /etc/mysql/conf.d/galera.cnf
fi

if [ "$MYSQL_CLUSTER_NAME" ]; then
	echo "wsrep_cluster_name=$MYSQL_CLUSTER_NAME" >> /etc/mysql/conf.d/galera.cnf
fi

if [ "$CLUSTER_ADDRESS" ]; then
	export MYSQL_ALLOW_EMPTY_PASSWORD="yes"
fi

echo "wsrep_cluster_address=${CLUSTER_ADDRESS-gcomm://}" >> /etc/mysql/conf.d/galera.cnf

sed '/^[\t].mysqld/s/mysqld/"$@"/' -i /docker-entrypoint.sh
exec /docker-entrypoint.sh "$@"
