#!/bin/bash
set -e

echo "==> Start of BoxBetty's MariaDB-Galera run.sh"

# remove last line of MariaDB docker-entrypoint.sh which is: 'exec "$@"' so we can inject our script
modDockerEntryPoint="/docker-entrypoint-modified.sh"
head -n -1 /docker-entrypoint.sh > $modDockerEntryPoint
chmod +x $modDockerEntryPoint
echo "exec /docker-entrypoint-bb.sh \"$@\"" >> $modDockerEntryPoint

echo "==> Running modified MariaDB Docker container's docker-entrypoint.sh with args: '$@'"
exec $modDockerEntryPoint "$@"
