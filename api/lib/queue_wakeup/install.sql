-- Install on the QUEUE database, not necessarily the application's primary.
-- Statement triggers cover bulk inserts and concurrency releases. PostgreSQL
-- delivers notifications only after commit; rollback never wakes a worker.
CREATE OR REPLACE FUNCTION vera_queue_notify() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('vera_queue_ready', '');
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS vera_queue_ready ON solid_queue_ready_executions;
CREATE TRIGGER vera_queue_ready AFTER INSERT ON solid_queue_ready_executions
FOR EACH STATEMENT EXECUTE FUNCTION vera_queue_notify();
DROP TRIGGER IF EXISTS vera_queue_scheduled ON solid_queue_scheduled_executions;
CREATE TRIGGER vera_queue_scheduled AFTER INSERT OR UPDATE ON solid_queue_scheduled_executions
FOR EACH STATEMENT EXECUTE FUNCTION vera_queue_notify();
