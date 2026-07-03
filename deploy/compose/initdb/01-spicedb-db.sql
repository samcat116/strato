-- Runs once on first PostgreSQL initialization. SpiceDB gets its own
-- database so its migrations never collide with the control plane's tables.
CREATE DATABASE spicedb OWNER vapor_username;
