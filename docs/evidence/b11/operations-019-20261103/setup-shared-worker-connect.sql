\set ON_ERROR_STOP on
-- The unchanged S27 harness selects this existing login explicitly.
-- These are database ACL grants only; no global role/password change.
GRANT CONNECT ON DATABASE ritc_b11_ops019_20261103 TO ritc_test_worker;
GRANT CONNECT ON DATABASE ritc_b11_ops019_restore_20261103 TO ritc_test_worker;
