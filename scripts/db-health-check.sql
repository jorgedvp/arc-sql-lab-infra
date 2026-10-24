-- Baseline health check for SQL Server on arc-sql-lab-linux
-- Run via sqlcmd or SRE Agent Run Command

-- Check for blocking sessions
SELECT blocking_session_id, session_id, wait_type, wait_time, wait_resource
FROM sys.dm_exec_requests
WHERE blocking_session_id <> 0;

-- Check database sizes
SELECT name, size * 8 / 1024 AS size_mb
FROM sys.master_files;

-- Check for long-running queries
SELECT r.session_id, r.status, r.command, r.wait_type, r.total_elapsed_time, t.text
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.total_elapsed_time > 5000;
