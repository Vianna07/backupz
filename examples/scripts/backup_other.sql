BEGIN;

CREATE TABLE IF NOT EXISTS backup_log (
    id SERIAL PRIMARY KEY,
    backup_date TIMESTAMP DEFAULT NOW(),
    status TEXT NOT NULL
);

INSERT INTO backup_log (status) VALUES ('backup_other_started');

INSERT INTO backup_log (status) VALUES ('backup_other_completed');

COMMIT;
