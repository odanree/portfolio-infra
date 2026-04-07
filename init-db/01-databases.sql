-- Runs once on first postgres container start (as the POSTGRES_USER superuser).
-- Creates all portfolio databases. portfolio_user is created by 00-create-user.sh
-- which reads PORTFOLIO_DB_PASSWORD from the environment.

CREATE DATABASE compensation_ingest;
CREATE DATABASE compensation_explorer;
CREATE DATABASE order_exception_agent;
CREATE DATABASE inventory_discrepancy;

GRANT ALL PRIVILEGES ON DATABASE compensation_ingest    TO portfolio_user;
GRANT ALL PRIVILEGES ON DATABASE compensation_explorer   TO portfolio_user;
GRANT ALL PRIVILEGES ON DATABASE order_exception_agent   TO portfolio_user;
GRANT ALL PRIVILEGES ON DATABASE inventory_discrepancy   TO portfolio_user;
