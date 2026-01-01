CREATE SCHEMA IF NOT EXISTS staging;

DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'public'
  LOOP
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS staging.%I (LIKE public.%I INCLUDING ALL);',
      r.tablename, r.tablename
    );
  END LOOP;
END $$;

