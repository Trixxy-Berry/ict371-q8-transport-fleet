-- ============================================================================
-- ICT371 Advanced Database
-- Question 8: Transport Fleet Maintenance (PostgreSQL / PL/pgSQL)
-- ============================================================================

-- (a) Database and seed data
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(30) NOT NULL UNIQUE,
    current_odometer      NUMERIC(12, 1) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12, 1) NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_le_current CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer NUMERIC(12, 1) NOT NULL CHECK (start_odometer >= 0),
    end_odometer   NUMERIC(12, 1) NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12, 1) NOT NULL CHECK (km_since_service >= 0),
    flagged_on       DATE NOT NULL
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABZ 1001', 15200.0, 10000.0),
    ('ABZ 2002', 22000.0, 20000.0),
    ('ABZ 3003',  4800.0,     0.0);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr NUMERIC(12, 1);
    v_last NUMERIC(12, 1);
BEGIN
    SELECT current_odometer, last_service_odometer
    INTO v_curr, v_last
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_curr - v_last) >= 5000;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INT,
    p_trip_on    DATE,
    p_start      NUMERIC(12, 1),
    p_end        NUMERIC(12, 1)
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_end IS NULL OR p_start IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_validate_and_advance_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr_odo NUMERIC(12, 1);
BEGIN
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end_odometer (%) must exceed start_odometer (%)',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    SELECT current_odometer INTO v_curr_odo
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_curr_odo THEN
        RAISE EXCEPTION 'start_odometer (%) must match current_odometer (%) for vehicle %',
            NEW.start_odometer, v_curr_odo, NEW.vehicle_id;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION fn_validate_and_advance_odometer();

-- Add 6 trips through the procedure after the trigger is installed
CALL pr_record_trip(1, CURRENT_DATE - 3, 15200.0, 15450.0);
CALL pr_record_trip(1, CURRENT_DATE - 1, 15450.0, 15600.0);
CALL pr_record_trip(2, CURRENT_DATE - 4, 22000.0, 22300.0);
CALL pr_record_trip(2, CURRENT_DATE - 2, 22300.0, 22500.0);
CALL pr_record_trip(3, CURRENT_DATE - 2,  4800.0,  5100.0);
CALL pr_record_trip(3, CURRENT_DATE - 1,  5100.0,  5250.0);

-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

-- (f) Index, Query, Plan, and Justification
-- Justification: Composite index on (vehicle_id, trip_on) supports equality lookup on vehicle_id followed by range scan on trip_on.
CREATE INDEX idx_trips_vehicle_trip_on
ON trips (vehicle_id, trip_on);

EXPLAIN
SELECT trip_id, start_odometer, end_odometer, trip_on
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        vehicle_id,
        (current_odometer - last_service_odometer),
        CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on       = EXCLUDED.flagged_on;

    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1
        FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND (v.current_odometer - v.last_service_odometer) >= 5000
    );
END;
$$;

-- Every Monday at 06:00 (pg_cron)
SELECT cron.schedule(
    'refresh_service_alerts',
    '0 6 * * 1',
    $$CALL pr_refresh_service_alerts();$$
);
