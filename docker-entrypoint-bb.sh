#!/bin/bash
set -e

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

configure_mariadb_replication() {
    
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
      echo "==> Could not connect to replication master"
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

########################################################################################################################
########################################################################################################################
########################################################################################################################
########################################################################################################################

configure_galera_config_file() {
  galeraConf="/etc/mysql/conf.d/galera-tmp.cnf"
  rm -f $galeraConf

  echo "==> Creating the Galera config file"
  ( cat <<"EOM"
[mysqld]
wsrep_provider=/usr/lib/galera/libgalera_smm.so
binlog_format=ROW
innodb_autoinc_lock_mode=2
innodb_doublewrite=1
query_cache_size=0
wsrep_on=ON
EOM
  ) >> $galeraConf

  if [ "$CLUSTER_START_MODE" = "new" ]; then
    echo "==> Configuring for a new galera db cluster"
    echo "wsrep_new_cluster=true" >> $galeraConf
  fi

  if [ "$CLUSTER_START_MODE" = "restart" ]; then
    echo "==> Configuring for an existing galera db cluster"
    echo "TODO - restart CLUSTER_START_MODE"
    exit -1
  fi

  if [ $NODE_IP ]; then
    echo "wsrep_node_address=$NODE_IP" >> $galeraConf
  fi

  if [ $MYSQL_CLUSTER_NAME ]; then
    echo "wsrep_cluster_name=$MYSQL_CLUSTER_NAME" >> $galeraConf
  fi

  if [ $CLUSTER_ADDRESS ] && [ ! $MYSQL_ROOT_PASSWORD ]; then
    export MYSQL_ALLOW_EMPTY_PASSWORD="yes"
  fi

  echo "wsrep_cluster_address=gcomm://${CLUSTER_ADDRESS}" >> $galeraConf
}


configure_new_instance() {
  echo "==> Configuring for a new instance"
  configure_galera_config_file
}

configure_existing_instance() {
  echo "==> Configuring for an existing instance"
  configure_galera_config_file
}


#rm -f /tmp/init_mysql.sql

#create_custom_database
#create_user
#configure_mariadb_replication

#if [ "$DB_REPLICATION_MODE" = "slave" ]; then  
#  ensure_slave_connects_to_master
#  snapshot_master_data_for_slave
#fi


verify_galera_cluster_is_started() {
  echo "==> Checking if Galera cluster is up"
  clusterSize=$(mysql -u root -se 'SELECT VARIABLE_VALUE FROM INFORMATION_SCHEMA.GLOBAL_STATUS WHERE VARIABLE_NAME="wsrep_cluster_size"')
  echo "==> Galera cluster size is now: $clusterSize"
  
  if [ "$clusterSize" = "0" ]; then
    echo "==> ERROR: Galera cluster size is 0"
    echo
    exit -1
  fi
  
  if [ "$CLUSTER_START_MODE" = "new" ] && [ "$clusterSize" != "1" ]; then
    echo "==> ERROR: Galera cluster size is not 1 - so something is wrong starting a new Galera cluster"
    echo
    exit -1
  fi
}

wait_for_db_daemon_to_respond() {
  echo "==> Waiting for database daemon to respond (60s timeout)..."
  timeout=60
  while ! mysqladmin -u root ping >/dev/null 2>&1
  do
    echo "    ==> Timeout in $timeout seconds..."  
    timeout=$(expr $timeout - 1)
    if [[ $timeout -eq 0 ]]; then
      echo "==> Database daemon not responding"
      echo
      exit -1
    fi
    sleep 1
  done
  echo "==> Database is up"
  echo
}

run_command() {
  echo "==> Starting db daemon in background - command is: '$@'"
  "$@" &
  pid="$!"
  echo "==> db daemon pid: $pid"
  
  wait_for_db_daemon_to_respond
  verify_galera_cluster_is_started
  
  echo "==> db daemon is running..."
  wait "$pid"
  echo "==> '$@' has ended - and docker container will now finish"
}


#############################################
################## Start ####################
#############################################

echo "==> Start of BoxBetty's docker-entrypoint-bb.sh with parameters: '$@'"

if [ "$IS_NEW_INSTANCE" = "true" ]; then
  # MariaDB's docker-entrypoint.sh would have initialised a new database instance by now ;)
  configure_new_instance
else 
  # MariaDB's docker-entrypoint.sh would have done absolutely nothing in this case ;)
  configure_existing_instance
fi

run_command $@
