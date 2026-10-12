-- Zed's workspaces table as Zed makes it since mid-2025 (crates/workspace/src/persistence.rs), cut to the columns
-- that matter here, beside two tables the import must never read. The tests put it in
-- Library/Application Support/Zed/db/0-stable/db.sqlite, with HOME replaced by the test's home folder.
CREATE TABLE remote_connections(id INTEGER PRIMARY KEY, kind TEXT NOT NULL, host TEXT, port INTEGER, user TEXT);
CREATE TABLE workspaces(
    workspace_id INTEGER PRIMARY KEY,
    paths TEXT,
    paths_order TEXT,
    remote_connection_id INTEGER REFERENCES remote_connections(id),
    timestamp TEXT DEFAULT CURRENT_TIMESTAMP NOT NULL,
    window_state TEXT,
    session_id TEXT,
    window_id INTEGER
);
CREATE TABLE editors(item_id INTEGER, workspace_id INTEGER, buffer_path TEXT, contents TEXT, language TEXT, PRIMARY KEY(item_id, workspace_id));
CREATE TABLE kv_store(key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO remote_connections VALUES (1, 'ssh', 'build.example.invalid', 22, 'deploy');
INSERT INTO workspaces(workspace_id, paths, paths_order, remote_connection_id, timestamp) VALUES
  (1, 'HOME/Code/app', '0', NULL, '2026-10-09 10:00:00'),
  (2, 'HOME/Code/both-a' || char(10) || 'HOME/Code/both-b', '1,0', NULL, '2026-10-10 09:00:00'),
  (3, '/srv/deploy/site', '0', 1, '2026-10-10 12:00:00'),
  (4, 'HOME/Code/gone', '0', NULL, '2026-10-08 10:00:00'),
  (5, 'HOME/Code/app', '0', NULL, '2026-10-01 10:00:00'),
  (6, '', '', NULL, '2026-10-10 13:00:00'),
  (7, 'HOME/Code/FixtureSecretAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', '0', NULL, '2026-10-07 10:00:00');
INSERT INTO editors VALUES (1, 1, 'HOME/Code/app/.env', 'TOKEN=eyJhbGciOiJIUzI1NiJ9.eyJmaXh0dXJlIjoic2VjcmV0In0.bm90LWEtcmVhbC1zaWduYXR1cmU', 'Dotenv');
INSERT INTO kv_store VALUES ('agent_token', 'FixtureSecretAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
