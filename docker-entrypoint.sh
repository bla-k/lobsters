#!/bin/bash
set -euo pipefail

DATABASE_HOST="${DATABASE_HOST:-db}"
DATABASE_USERNAME="${DATABASE_USERNAME:-root}"
DATABASE_PASSWORD="${DATABASE_PASSWORD:-localdev}"

if [ ! -f config/database.yml ]; then
  cp config/database.yml.sample config/database.yml
fi

echo "Waiting for MariaDB at ${DATABASE_HOST}..."
until mariadb-admin ping -h "${DATABASE_HOST}" -u "${DATABASE_USERNAME}" -p"${DATABASE_PASSWORD}" --silent; do
  sleep 1
done
echo "MariaDB is ready."

bundle exec rails db:prepare

exec "$@"
