#!/bin/bash
set -e

# Copy database config if missing
if [ ! -f config/database.yml ]; then
  cp config/database.yml.sample config/database.yml
fi

# Wait for MariaDB to be ready
echo "Waiting for MariaDB..."
until mariadb -h "$DATABASE_HOST" -u root -plocaldev -e "SELECT 1" > /dev/null 2>&1; do
  sleep 1
done
echo "MariaDB is ready."

# Create and migrate DB if it doesn't exist yet
bundle exec rails db:prepare

exec "$@"
