CREATE TABLE ritc.request_queue_permission (
    household_id uuid NOT NULL, member_id uuid NOT NULL, device_id uuid NOT NULL,
    grant_id uuid NOT NULL, enabled_at timestamptz NOT NULL, expires_at timestamptz NOT NULL,
    PRIMARY KEY (household_id, member_id, device_id),
    FOREIGN KEY (household_id, member_id, device_id) REFERENCES ritc.device(household_id, member_id, device_id) ON DELETE CASCADE,
    CHECK (expires_at > enabled_at AND expires_at <= enabled_at + interval '24 hours')
);
ALTER TABLE ritc.request_queue_permission ENABLE ROW LEVEL SECURITY;
ALTER TABLE ritc.request_queue_permission FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON ritc.request_queue_permission
    USING (household_id::text = current_setting('app.household_id',true))
    WITH CHECK (household_id::text = current_setting('app.household_id',true));
GRANT SELECT, INSERT, DELETE ON ritc.request_queue_permission TO ritc_app;
GRANT UPDATE(grant_id, enabled_at, expires_at) ON ritc.request_queue_permission TO ritc_app;

CREATE FUNCTION ritc.clear_revoked_request_queue_permission() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
    DELETE FROM ritc.request_queue_permission
    WHERE household_id=NEW.household_id AND member_id=NEW.member_id AND device_id=NEW.device_id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER retire_request_queue_permission AFTER UPDATE OF revoked_at ON ritc.device
    FOR EACH ROW WHEN (OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL)
    EXECUTE FUNCTION ritc.clear_revoked_request_queue_permission();

CREATE FUNCTION ritc.clear_ineligible_member_queue_permissions() RETURNS trigger
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
    DELETE FROM ritc.request_queue_permission
    WHERE household_id=NEW.household_id AND member_id=NEW.member_id;
    RETURN NEW;
END;
$$;
CREATE TRIGGER retire_member_queue_permissions AFTER UPDATE OF state, can_contribute ON ritc.member
    FOR EACH ROW WHEN (NEW.state <> 'active' OR NOT NEW.can_contribute)
    EXECUTE FUNCTION ritc.clear_ineligible_member_queue_permissions();
