#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Create Keycloak database
    SELECT 'CREATE DATABASE keycloak'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec

    -- Create Sockbowl users database
    SELECT 'CREATE DATABASE sockbowl_users'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'sockbowl_users')\gexec
EOSQL

echo "Databases created successfully: keycloak, sockbowl_users"
