#!/bin/bash
set -e

configure_galera_config_file() {
  rm -f /etc/mysql/conf.d/galera-tmp.cnf

  if [ "$CLUSTER_START_MODE" = "new" ]; then
    echo "wsrep_new_cluster=true" >> /etc/mysql/conf.d/galera-tmp.cnf
  fi

  if [ "$CLUSTER_START_MODE" = "restart" ]; then
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
  if [ $DB_DATABASE ]; then
    echo "==> Creating database $DB_DATABASE..."
    echo ""
    echo "CREATE DATABASE IF NOT EXISTS \`$DB_DATABASE\`;" >> /tmp/init_mysql.sql
  fi
}

create_user() {
#  if [ "$DB_REPLICATION_MODE" == "slave" ]; then
#    if [ ! "$DB_USER" ] || [ ! "${DB_PASSWORD}" ] || [ ! "$DB_DATABASE" ]; then
#      echo "==> Trying to fetch MariaDB user/password from the master link..."
#      DB_USER=${DB_USER:-$MASTER_ENV_DB_USER}
#      DB_PASSWORD=${DB_PASSWORD:-$MASTER_ENV_DB_PASSWORD}
#      DB_DATABASE=${DB_DATABASE:-$MASTER_ENV_DB_DATABASE}
#    fi
#  fi

  if [ ! $DB_USER ]; then
    DB_USER=root
  fi

  if [ "$DB_USER" = "root" ] && [ ! $MYSQL_ROOT_PASSWORD ]; then
    echo "In order to use a root DB_USER you need to provide the MYSQL_ROOT_PASSWORD as well"
    echo ""
    exit -1
  fi

  if [ "$DB_USER" != "root" ] && [ ! $DB_DATABASE ]; then
    echo "In order to use a custom DB_USER you need to provide the DB_DATABASE as well"
    echo ""
    exit -1
  fi

  echo "==> Creating user $DB_USER..."
  echo ""

  echo "DELETE FROM mysql.user ;" >> /tmp/init_mysql.sql
  echo "CREATE USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}' ;" >> /tmp/init_mysql.sql

  if [ "$DB_USER" = "root" ]; then
    echo "==> Creating root user with unrestricted access..."
    echo "GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;" >> /tmp/init_mysql.sql
  else
    echo "==> Granting access to $DB_USER to the database $DB_DATABASE..."
    echo ""
    echo "GRANT ALL ON \`${DB_DATABASE}\`.* TO \`${DB_USER}\`@'%' ;" >> /tmp/init_mysql.sql
    echo "GRANT RELOAD, REPLICATION CLIENT ON *.* TO \`${DB_USER}\`@'%' ;" >> /tmp/init_mysql.sql
  fi

  echo "FLUSH PRIVILEGES ;" >> /tmp/init_mysql.sql
#  echo "DROP DATABASE IF EXISTS test ; " >> /tmp/init_mysql.sql
}

validate_db_database() {
  if [ ! $DB_DATABASE ]; then
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
#      DB_MASTER_USER=${DB_MASTER_USER:-$MASTER_ENV_MARIADB_USER}
#      DB_MASTER_PASSWORD=${DB_MASTER_PASSWORD:-$MASTER_ENV_MARIADB_PASSWORD}
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
    --databases $DB_DATABASE --skip-lock-tables --single-transaction --flush-logs --hex-blob --master-data --apply-slave-statements --comments=false | tr -d '\012' | sed -e 's/;/;\n/g' >> /tmp/init_mysql.sql
  echo ""
}


#############################################
################## Start ####################
#############################################
rm -f /tmp/init_mysql.sql

create_custom_database
create_user

configure_galera_config_file
configure_replication

if [ "$DB_REPLICATION_MODE" = "slave" ]; then  
  ensure_slave_connects_to_master
  snapshot_master_data_for_slave
fi

exec /docker-entrypoint.sh "$@"