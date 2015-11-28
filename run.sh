#!/bin/bash
set -e

echo "==> Start of BoxBetty's MariaDB-Galera run.sh"

DATADIR=$(my_print_defaults mysqld | grep -- "--datadir" | cut -f2 -d"=")
echo "==> DATADIR is '$DATADIR'"
if [ ! -d "$DATADIR/mysql" ]; then
  export IS_NEW_INSTANCE="true"
else 
  export IS_NEW_INSTANCE="false"
fi

# remove last line of MariaDB docker-entrypoint.sh which is: 'exec "$@"' so we can inject our script
modDockerEntryPoint="/docker-entrypoint-modified.sh"
head -n -1 /docker-entrypoint.sh > $modDockerEntryPoint
chmod +x $modDockerEntryPoint
echo "exec /docker-entrypoint-bb.sh \$@" >> $modDockerEntryPoint

echo "==> Running modified MariaDB Docker container's docker-entrypoint.sh with args: '$@'"
exec $modDockerEntryPoint $@
