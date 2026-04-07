#!/bin/bash
# Creates the shared portfolio_user before 01-databases.sql runs.
# Files in docker-entrypoint-initdb.d/ execute in alphabetical order,
# so 00-*.sh runs before 01-*.sql.

set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE USER portfolio_user WITH PASSWORD '${PORTFOLIO_DB_PASSWORD}';
EOSQL
