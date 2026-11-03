-- PostgreSQL SELECT FOR UPDATE requires UPDATE permission on at least one column.
-- The runtime uses this column grant only to lock the tenant's serialization row.
GRANT UPDATE(household_id) ON ritc.household TO ritc_app;
