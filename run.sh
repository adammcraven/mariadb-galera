#!/bin/bash
set -e

configure_galera_config_file() {
  rm -f /etc/mysql/conf.d/galera-tmp.cnf
  echo "[mysqld]" > /etc/mysql/conf.d/galera-tmp.cnf 

  if [ "$CLUSTER_START_MODE" = "new" ]; then
    echo "==> Starting a new db cluster"
    echo "wsrep_new_cluster=true" >> /etc/mysql/conf.d/galera-tmp.cnf
  fi

  if [ "$CLUSTER_START_MODE" = "restart" ]; then
    echo "==> Starting an existing db cluster"
    echo "TODO - restart CLUSTER_START_MODE"
    exit -1
  fi

  if [ $NODE_IP ]; then
    echo "wsrep_node_address=$NODE_IP" >> /etc/mysql/conf.d/galera-tmp.cnf
  fi

  if [ $MYSQL_CLUSTER_NAME ]; then
    echo "wsrep_cluster_name=$MYSQL_CLUSTER_NAME" >> /etc/mysql/conf.d/galera-tmp.cnf
  fi

  if [ $CLUSTER_ADDRESS ] && [ ! $MYSQL_ROOT_PASSWORD ]; then
    export MYSQL_ALLOW_EMPTY_PASSWORD="yes"
  fi

  echo "wsrep_cluster_address=gcomm://${CLUSTER_ADDRESS}" >> /etc/mysql/conf.d/galera-tmp.cnf
}

create_custom_database() {
  if [ $MYSQL_DATABASE ]; then
    echo "==> Creating database $MYSQL_DATABASE..."
    echo ""
    echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\`;" >> /tmp/init_mysql.sql
  fi
}

create_user() {
#  if [ "$DB_REPLICATION_MODE" == "slave" ]; then
#    if [ ! "$MYSQL_USER" ] || [ ! "${MYSQL_PASSWORD}" ] || [ ! "$MYSQL_DATABASE" ]; then
#      echo "==> Trying to fetch MariaDB user/password from the master link..."
#      MYSQL_USER=${MYSQL_USER:-$MASTER_ENV_MYSQL_USER}
#      MYSQL_PASSWORD=${MYSQL_PASSWORD:-$MASTER_ENV_MYSQL_PASSWORD}
#      DB_DATABASE=${DB_DATABASE:-$MASTER_ENV_DB_DATABASE}
#    fi
#  fi

  if [ ! $MYSQL_USER ]; then
    MYSQL_USER=root
  fi

  if [ "$MYSQL_USER" = "root" ] && [ ! $MYSQL_ROOT_PASSWORD ]; then
    echo "In order to use a root MYSQL_USER you need to provide the MYSQL_ROOT_PASSWORD as well"
    echo ""
    exit -1
  fi

  if [ "$MYSQL_USER" != "root" ] && [ ! $MYSQL_DATABASE ]; then
    echo "In order to use a custom MYSQL_USER you need to provide the DB_DATABASE as well"
    echo ""
    exit -1
  fi

  echo "==> Creating user $MYSQL_USER..."
  echo ""

  echo "DELETE FROM mysql.user ;" >> /tmp/init_mysql.sql
  echo "CREATE USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}' ;" >> /tmp/init_mysql.sql

  if [ "$MYSQL_USER" = "root" ]; then
    echo "==> Creating root user with unrestricted access..."
    echo "GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;" >> /tmp/init_mysql.sql
  else
    echo "==> Granting access to $MYSQL_USER to the database $MYSQL_DATABASE..."
    echo ""
    echo "GRANT ALL ON \`${DB_DATABASE}\`.* TO \`${MYSQL_USER}\`@'%' ;" >> /tmp/init_mysql.sql
    echo "GRANT RELOAD, REPLICATION CLIENT ON *.* TO \`${MYSQL_USER}\`@'%' ;" >> /tmp/init_mysql.sql
  fi

  echo "FLUSH PRIVILEGES ;" >> /tmp/init_mysql.sql
  echo "DROP DATABASE IF EXISTS test ;" >> /tmp/init_mysql.sql
}

validate_db_database() {
  if [ ! $MYSQL_DATABASE ]; then
    echo "You need to provide the DB_DATABASE"
    echo ""
    exit -1
  fi
}

validate_db_master_host() {
  if [ ! $DB_MASTER_HOST ]; then
    echo "You need to provide the DB_MASTER_HOST"
    echo ""
    exit -1
  fi
}

validate_db_master_user() {
  if [ ! $DB_MASTER_USER ]; then
    echo "You need to provide the DB_MASTER_USER"
    echo ""
    exit -1
  fi
}

validate_db_master_password() {
  if [ ! $DB_MASTER_PASSWORD ]; then
    echo "You need to provide the DB_MASTER_PASSWORD"
    echo ""
    exit -1
  fi
}

configure_replication() {
    
  case "$DB_REPLICATION_MODE" in
    master)
      if [ "$DB_REPLICATION_USER" ]; then
        echo "==> Creating replication user $DB_REPLICATION_USER..."
        echo ""

        echo "GRANT REPLICATION SLAVE ON *.* TO '$DB_REPLICATION_USER'@'%' IDENTIFIED BY '$DB_REPLICATION_PASSWORD';" >> /tmp/init_mysql.sql
        echo "FLUSH PRIVILEGES ;" >> /tmp/init_mysql.sql
      else
        echo "In order to setup a replication master you need to provide the DB_REPLICATION_USER as well"
        echo ""
        exit -1
      fi
      ;;
    slave)
      echo "==> Setting up MariaDB slave..."

      echo "==> Trying to fetch MariaDB replication parameters from the master link..."
#      DB_MASTER_HOST=${DB_MASTER_HOST:-$MASTER_PORT_3306_TCP_ADDR}
#      DB_MASTER_USER=${DB_MASTER_USER:-$MASTER_ENV_MARIAMYSQL_USER}
#      DB_MASTER_PASSWORD=${DB_MASTER_PASSWORD:-$MASTER_ENV_MARIAMYSQL_PASSWORD}
#      DB_REPLICATION_USER=${DB_REPLICATION_USER:-$MASTER_ENV_MARIADB_REPLICATION_USER}
#      DB_REPLICATION_PASSWORD=${DB_REPLICATION_PASSWORD:-$MASTER_ENV_MARIADB_REPLICATION_PASSWORD}

      validate_db_master_host
      validate_db_master_user
      validate_db_database

      if [ ! $DB_REPLICATION_USER ]; then
        echo "In order to setup a replication slave you need to provide the DB_REPLICATION_USER as well"
        echo ""
        exit -1
      fi
      echo "==> Setting the master configuration..."
      echo "CHANGE MASTER TO MASTER_HOST='$DB_MASTER_HOST', MASTER_USER='$DB_REPLICATION_USER', MASTER_PASSWORD='$DB_REPLICATION_PASSWORD';" >> /tmp/init_mysql.sql
      ;;
  esac
}

ensure_slave_connects_to_master() {
  validate_db_master_host
  validate_db_master_user
  validate_db_master_password    

  echo "==> Checking if replication master is ready to accept connection (60s timeout)..."
  timeout=60
  while ! mysqladmin -u$DB_MASTER_USER ${DB_MASTER_PASSWORD:+-p$DB_MASTER_PASSWORD} -h $DB_MASTER_HOST status >/dev/null 2>&1
  do
    timeout=$(expr $timeout - 1)
    if [[ $timeout -eq 0 ]]; then
      echo "Could not connect to replication master"
      echo ""
      exit -1
    fi
    sleep 1
  done
  echo
}

snapshot_master_data_for_slave() {
  validate_db_master_host
  validate_db_master_user
  validate_db_master_password
  validate_db_database
  
  echo "==> Creating a data snapshot..."
  mysqldump -u$DB_MASTER_USER ${DB_MASTER_PASSWORD:+-p$DB_MASTER_PASSWORD} -h $DB_MASTER_HOST \
    --databases $MYSQL_DATABASE --skip-lock-tables --single-transaction --flush-logs --hex-blob --master-data --apply-slave-statements --comments=false | tr -d '\012' | sed -e 's/;/;\n/g' >> /tmp/init_mysql.sql
  echo ""
}

wait_for_db_daemon_to_respond() {
  echo "==> Waiting for database daemon to respond (60s timeout)..."
  timeout=60
  while ! mysqladmin status >/dev/null 2>&1
  do
    echo "    ==> Timeout in $timeout seconds..."  
    timeout=$(expr $timeout - 1)
    if [[ $timeout -eq 0 ]]; then
      echo "Database daemon not responding"
      echo ""
      exit -1
    fi
    sleep 1
  done
  echo
}


#############################################
################## Start ####################
#############################################

echo "==> Start of run.sh"

configure_galera_config_file

rm -f /tmp/init_mysql.sql

#create_custom_database
#create_user
configure_replication

if [ "$DB_REPLICATION_MODE" = "slave" ]; then  
  ensure_slave_connects_to_master
  snapshot_master_data_for_slave
fi

# remove last line which is: exec "$@" so we can inject our script
head -n -1 /docker-entrypoint.sh > /docker-entrypoint2.sh
mv /docker-entrypoint2.sh /docker-entrypoint.sh

IFS=
read -r -d '' script <<EOM
  echo "==> Starting db daemon in background"
  $@ &

  echo "==> Waiting for database daemon to respond (60s timeout)..." 
  timeout=60
  while ! mysql status >/dev/null 2>&1
  do
    echo "    ==> Timeout in $timeout seconds..."  
    timeout=$(expr $timeout - 1)
    if [[ $timeout -eq 0 ]]; then
      echo "Database daemon not responding"
      echo ""
      exit -1
    fi
    sleep 1
  done
  echo

  echo "==> Running the init_mysql commands" 
  mysql source /tmp/init_mysql.sql
EOM

echo $script >> /docker-entrypoint.sh

echo "==> Running MariaDB Docker container's docker-entrypoint.sh with args: '$@'"
exec /docker-entrypoint.sh "$@"
