-- Baseline health check for SQL Server on arc-sql-lab-linux
-- Run via sqlcmd or SRE Agent Run Command
--
-- Usage:
--   sqlcmd -S localhost -U sa -P <password> -C -i db-health-check.sql
--
-- Thresholds (adjust as needed):
--   @BlockingThresholdSec : flag sessions blocked longer than this (default 30s)
--   @LongQueryThresholdMs : flag queries running longer than this (default 5000ms)

SET NOCOUNT ON;

-- ============================================================================
-- 1. BLOCKING SESSION DETECTION (alert-ready)
--    Surfaces the full blocking chain: head blocker -> blocked sessions,
--    including the SQL text on both sides and how long the block has lasted.
--    Ref: Incident #1 — Orders table UPDATE timeouts (2026-10-24)
-- ============================================================================
DECLARE @BlockingThresholdSec INT = 30;

PRINT '=== BLOCKING CHAIN ALERT (threshold: ' + CAST(@BlockingThresholdSec AS VARCHAR) + 's) ===';

-- Identify head blockers (sessions that block others but are not themselves blocked)
WITH BlockingChain AS (
    SELECT
        r.session_id           AS blocked_session_id,
        r.blocking_session_id  AS blocking_session_id,
        r.wait_type,
        r.wait_time,
        r.wait_resource,
        r.status,
        r.command,
        r.total_elapsed_time,
        DB_NAME(r.database_id) AS db_name
    FROM sys.dm_exec_requests r
    WHERE r.blocking_session_id <> 0
)
SELECT
    bc.blocking_session_id,
    bc.blocked_session_id,
    bc.wait_type,
    bc.wait_time / 1000                      AS wait_time_sec,
    bc.wait_resource,
    bc.status                                AS blocked_status,
    bc.command                               AS blocked_command,
    bc.db_name,
    -- Blocker info
    bs.login_name                            AS blocker_login,
    bs.host_name                             AS blocker_host,
    bs.program_name                          AS blocker_program,
    bs.status                                AS blocker_status,
    bs.open_transaction_count                AS blocker_open_tran,
    bs.last_request_start_time               AS blocker_last_request_start,
    -- Blocker SQL text (if connection still active)
    SUBSTRING(bt.text, 1, 200)               AS blocker_sql_text,
    -- Blocked SQL text
    SUBSTRING(wt.text, 1, 200)               AS blocked_sql_text,
    CASE
        WHEN bc.wait_time / 1000 >= @BlockingThresholdSec
        THEN '** ALERT: blocked >= ' + CAST(@BlockingThresholdSec AS VARCHAR) + 's **'
        ELSE 'monitoring'
    END                                      AS alert_status
FROM BlockingChain bc
JOIN sys.dm_exec_sessions bs
    ON bc.blocking_session_id = bs.session_id
LEFT JOIN sys.dm_exec_connections bc2
    ON bc.blocking_session_id = bc2.session_id
LEFT JOIN sys.dm_exec_connections wc
    ON bc.blocked_session_id = wc.session_id
OUTER APPLY sys.dm_exec_sql_text(bc2.most_recent_sql_handle) bt
OUTER APPLY sys.dm_exec_sql_text(wc.most_recent_sql_handle) wt
ORDER BY bc.wait_time DESC;

-- Count of sessions currently blocked beyond threshold (useful for monitoring/alerting)
PRINT '=== BLOCKING SUMMARY ===';
SELECT
    COUNT(*)                                                              AS total_blocked_sessions,
    SUM(CASE WHEN wait_time / 1000 >= @BlockingThresholdSec THEN 1 ELSE 0 END) AS sessions_over_threshold,
    MAX(wait_time / 1000)                                                 AS max_wait_sec
FROM sys.dm_exec_requests
WHERE blocking_session_id <> 0;

-- ============================================================================
-- 2. OPEN TRANSACTIONS
--    Long-running uncommitted transactions are the #1 cause of blocking.
-- ============================================================================
PRINT '=== OPEN USER TRANSACTIONS ===';
SELECT
    s.session_id,
    s.login_name,
    s.host_name,
    s.program_name,
    s.status                        AS session_status,
    t.name                          AS tran_name,
    t.transaction_begin_time,
    DATEDIFF(SECOND, t.transaction_begin_time, GETDATE()) AS tran_duration_sec,
    s.open_transaction_count
FROM sys.dm_tran_active_transactions t
JOIN sys.dm_tran_session_transactions st ON t.transaction_id = st.transaction_id
JOIN sys.dm_exec_sessions s              ON st.session_id    = s.session_id
WHERE t.transaction_type = 1  -- user transactions only
ORDER BY t.transaction_begin_time ASC;

-- ============================================================================
-- 3. DATABASE SIZES
-- ============================================================================
PRINT '=== DATABASE FILE SIZES ===';
SELECT name, size * 8 / 1024 AS size_mb
FROM sys.master_files;

-- ============================================================================
-- 4. LONG-RUNNING QUERIES
-- ============================================================================
DECLARE @LongQueryThresholdMs INT = 5000;

PRINT '=== LONG-RUNNING QUERIES (threshold: ' + CAST(@LongQueryThresholdMs AS VARCHAR) + 'ms) ===';
SELECT r.session_id, r.status, r.command, r.wait_type, r.total_elapsed_time, t.text
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.total_elapsed_time > @LongQueryThresholdMs;

-- ============================================================================
-- 5. RECOMMENDED: Lock & query timeout settings
--    Prevent indefinite blocking in application / maintenance queries.
--
--    Per-session (add to app connection init or maintenance scripts):
--      SET LOCK_TIMEOUT 30000;   -- fail after 30s waiting for a lock
--
--    Server-level blocked process alert (run once by DBA):
--      EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
--      EXEC sp_configure 'blocked process threshold', 30; RECONFIGURE;
--      -- Then create an Extended Events session or SQL Agent alert on
--      -- the "blocked process report" event to notify the on-call DBA.
-- ============================================================================
PRINT '=== LOCK TIMEOUT CONFIG CHECK ===';
SELECT
    name,
    CAST(value_in_use AS INT) AS value_in_use,
    CASE
        WHEN name = 'blocked process threshold (s)' AND CAST(value_in_use AS INT) = 0
        THEN '** WARNING: blocked process threshold not set — no alerts will fire for blocking **'
        ELSE 'OK'
    END AS recommendation
FROM sys.configurations
WHERE name IN ('blocked process threshold (s)');
