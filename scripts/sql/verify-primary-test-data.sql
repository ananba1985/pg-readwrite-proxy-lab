\set ON_ERROR_STOP on

SET statement_timeout = 0;
SET timezone = 'Asia/Shanghai';

DO $validation$
BEGIN
  IF current_database() <> 'rw_proxy_lab' THEN
    RAISE EXCEPTION 'verification must run in rw_proxy_lab';
  END IF;
  IF pg_is_in_recovery() THEN
    RAISE EXCEPTION 'test database is not on an independent writable Primary';
  END IF;
  IF (SELECT count(*) FROM business.customers) <> 30000 THEN
    RAISE EXCEPTION 'unexpected customer row count';
  END IF;
  IF (SELECT count(*) FROM business.products) <> 2000 THEN
    RAISE EXCEPTION 'unexpected product row count';
  END IF;
  IF (SELECT count(*) FROM business.orders) <> 150000 THEN
    RAISE EXCEPTION 'unexpected order row count';
  END IF;
  IF (SELECT count(*) FROM business.order_items) <> 450000 THEN
    RAISE EXCEPTION 'unexpected order-item row count';
  END IF;
  IF (SELECT count(*) FROM business.rw_probe) <> 0 THEN
    RAISE EXCEPTION 'rw_probe is not empty';
  END IF;
  IF (SELECT count(*) FROM business.dataset_manifest) <> 1 THEN
    RAISE EXCEPTION 'dataset manifest is missing or duplicated';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM business.dataset_manifest
    WHERE dataset_version <> 'business-v1'
       OR generator_sha256 !~ '^[0-9a-f]{64}$'
       OR customer_rows <> 30000
       OR product_rows <> 2000
       OR order_rows <> 150000
       OR order_item_rows <> 450000
       OR NOT deterministic
  ) THEN
    RAISE EXCEPTION 'dataset manifest content is invalid';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM business.orders AS o
    LEFT JOIN business.customers AS c ON c.customer_id = o.customer_id
    WHERE c.customer_id IS NULL
  ) THEN
    RAISE EXCEPTION 'order with missing customer found';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM business.order_items AS i
    LEFT JOIN business.orders AS o ON o.order_id = i.order_id
    WHERE o.order_id IS NULL
  ) THEN
    RAISE EXCEPTION 'order item with missing order found';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM business.order_items AS i
    LEFT JOIN business.products AS p ON p.product_id = i.product_id
    WHERE p.product_id IS NULL
  ) THEN
    RAISE EXCEPTION 'order item with missing product found';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM business.orders AS o
    JOIN (
      SELECT order_id, sum(line_amount)::numeric(16,2) AS item_total
      FROM business.order_items
      GROUP BY order_id
    ) AS totals USING (order_id)
    WHERE o.total_amount <> totals.item_total
  ) THEN
    RAISE EXCEPTION 'order total does not match item total';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_constraint AS c
    JOIN pg_class AS t ON t.oid = c.conrelid
    JOIN pg_namespace AS n ON n.oid = t.relnamespace
    WHERE n.nspname = 'business'
      AND c.contype IN ('c', 'f', 'p', 'u')
      AND NOT c.convalidated
  ) THEN
    RAISE EXCEPTION 'unvalidated business constraint found';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM pg_index AS i
    JOIN pg_class AS c ON c.oid = i.indexrelid
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'business'
      AND (NOT i.indisvalid OR NOT i.indisready)
  ) THEN
    RAISE EXCEPTION 'invalid or unready business index found';
  END IF;
END
$validation$;

SELECT dataset_version,
       generator_sha256,
       generated_at,
       deterministic
FROM business.dataset_manifest;

SELECT 'customers' AS table_name, count(*) AS row_count
FROM business.customers
UNION ALL
SELECT 'products', count(*) FROM business.products
UNION ALL
SELECT 'orders', count(*) FROM business.orders
UNION ALL
SELECT 'order_items', count(*) FROM business.order_items
UNION ALL
SELECT 'rw_probe', count(*) FROM business.rw_probe
ORDER BY table_name;

SELECT order_status, count(*) AS row_count
FROM business.orders
GROUP BY order_status
ORDER BY order_status;

SELECT min(ordered_at) AS first_order_at,
       max(ordered_at) AS last_order_at,
       min(total_amount) AS min_order_amount,
       max(total_amount) AS max_order_amount,
       pg_size_pretty(pg_database_size(current_database())) AS database_size
FROM business.orders;

SELECT pg_get_userbyid(datdba) AS database_owner,
       pg_encoding_to_char(encoding) AS encoding,
       datcollate,
       datctype
FROM pg_database
WHERE datname = current_database();
