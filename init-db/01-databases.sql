-- Runs once on first postgres container start (as the POSTGRES_USER superuser).
-- Creates all portfolio databases. portfolio_user is created by 00-create-user.sh
-- which reads PORTFOLIO_DB_PASSWORD from the environment.

CREATE DATABASE solar_ingest;
CREATE DATABASE solar_cost_explorer;
CREATE DATABASE order_exception_agent;
CREATE DATABASE inventory_discrepancy;
CREATE DATABASE sec_financial_intelligence;
CREATE DATABASE jd_role_classifier;
CREATE DATABASE portfolio_issues_agent;

GRANT ALL PRIVILEGES ON DATABASE solar_ingest                 TO portfolio_user;
GRANT ALL PRIVILEGES ON DATABASE solar_cost_explorer           TO portfolio_user;
GRANT ALL PRIVILEGES ON DATABASE order_exception_agent         TO portfolio_user;
GRANT ALL PRIVILEGES ON DATABASE inventory_discrepancy         TO portfolio_user;
GRANT ALL PRIVILEGES ON DATABASE sec_financial_intelligence    TO portfolio_user;
GRANT ALL PRIVILEGES ON DATABASE jd_role_classifier            TO portfolio_user;
GRANT ALL PRIVILEGES ON DATABASE portfolio_issues_agent        TO portfolio_user;

-- Postgres 15+: GRANT ON DATABASE no longer implies schema public access
\c solar_ingest
GRANT ALL ON SCHEMA public TO portfolio_user;
\c solar_cost_explorer
GRANT ALL ON SCHEMA public TO portfolio_user;
\c order_exception_agent
GRANT ALL ON SCHEMA public TO portfolio_user;
\c inventory_discrepancy
GRANT ALL ON SCHEMA public TO portfolio_user;
\c sec_financial_intelligence
GRANT ALL ON SCHEMA public TO portfolio_user;
\c jd_role_classifier
GRANT ALL ON SCHEMA public TO portfolio_user;
\c portfolio_issues_agent
GRANT ALL ON SCHEMA public TO portfolio_user;
