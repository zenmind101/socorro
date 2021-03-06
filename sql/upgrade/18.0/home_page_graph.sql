\set ON_ERROR_STOP 1

-- create new table for home page graph

SELECT create_table_if_not_exists('home_page_graph',
$t$
CREATE TABLE home_page_graph (
  product_version_id int not null,
  report_date date not null,
  report_count int not null default 0,
  adu int not null default 0,
  crash_hadu numeric not null default 0.0,
  constraint home_page_graph_key primary key ( product_version_id, report_date )
);$t$, 'breakpad_rw' );

-- create view

CREATE OR REPLACE VIEW home_page_graph_view
AS
SELECT product_version_id,
  product_name,
  version_string,
  report_date,
  report_count,
  adu,
  crash_hadu
FROM home_page_graph
  JOIN product_versions USING (product_version_id);

ALTER VIEW home_page_graph_view OWNER TO breakpad_rw;

-- daily update function
CREATE OR REPLACE FUNCTION update_home_page_graph (
    updateday DATE,
    checkdata BOOLEAN default TRUE,
    check_period INTERVAL default interval '1 hour' )
RETURNS BOOLEAN
LANGUAGE plpgsql
SET work_mem = '512MB'
SET temp_buffers = '512MB'
SET client_min_messages = 'ERROR'
SET timezone = 'UTC'
AS $f$
BEGIN
-- this function populates a daily matview
-- for **new_matview_description**
-- depends on the new reports_clean

-- check if we've been run
IF checkdata THEN
    PERFORM 1 FROM home_page_graph
    WHERE report_date = updateday
    LIMIT 1;
    IF FOUND THEN
        RAISE NOTICE 'home_page_graph has already been run for %.',updateday;
        RETURN FALSE;
    END IF;
END IF;

-- check if reports_clean is complete
IF NOT reports_clean_done(updateday, check_period) THEN
    IF checkdata THEN
        RAISE EXCEPTION 'Reports_clean has not been updated to the end of %',updateday;
    ELSE
        RETURN FALSE;
    END IF;
END IF;

-- check for product_adu

PERFORM 1 FROM product_adu
WHERE adu_date = updateday
LIMIT 1;
IF NOT FOUND THEN
  IF checkdata THEN
    RAISE EXCEPTION 'product_adu has not been updated for %', updateday;
  ELSE
    RETURN FALSE;
  END IF;
END IF;

-- now insert the new records
INSERT INTO home_page_graph
    ( product_version_id, report_date,
      report_count, adu, crash_hadu )
SELECT product_version_id, updateday,
    report_count, adu_sum,
    crash_hadu(report_count, adu_sum, throttle)
FROM ( select product_version_id,
            count(*) as report_count
      from reports_clean
      	JOIN product_versions USING ( product_version_id )
      	JOIN crash_types ON
      		reports_clean.process_type = crash_types.process_type
      		AND ( reports_clean.hang_id IS NOT NULL ) = crash_types.has_hang_id
      WHERE
          utc_day_is(date_processed, updateday)
          -- exclude browser hangs from total counts
          AND crash_types.include_agg
          AND updateday BETWEEN build_date AND sunset_date
      group by product_version_id ) as count_reports
      JOIN
    ( select product_version_id,
        sum(adu_count) as adu_sum
        from product_adu
        where adu_date = updateday
        group by product_version_id ) as sum_adu
      USING ( product_version_id )
      JOIN product_versions USING ( product_version_id )
      JOIN product_release_channels ON
          product_versions.product_name = product_release_channels.product_name
          AND product_versions.build_type = product_release_channels.release_channel
WHERE sunset_date > ( current_date - interval '1 year' )
ORDER BY product_version_id;

-- insert summary records for rapid_beta parents
INSERT INTO home_page_graph
    ( product_version_id, report_date,
      report_count, adu, crash_hadu )
SELECT rapid_beta_id, updateday,
    sum(report_count), sum(adu),
    crash_hadu(sum(report_count), sum(adu))
FROM home_page_graph
	JOIN product_versions USING ( product_version_id )
WHERE rapid_beta_id IS NOT NULL
	AND report_date = updateday
GROUP BY rapid_beta_id, updateday;

RETURN TRUE;
END; $f$;

-- now create a backfill function
-- so that we can backfill missing data
CREATE OR REPLACE FUNCTION backfill_home_page_graph(
    updateday DATE, check_period INTERVAL DEFAULT INTERVAL '1 hour' )
RETURNS BOOLEAN
LANGUAGE plpgsql AS
$f$
BEGIN

DELETE FROM home_page_graph WHERE report_date = updateday;
PERFORM update_home_page_graph(updateday, false, check_period);

RETURN TRUE;
END; $f$;

