-- Keep only the original key and basis until expiry, so a delayed repeat of an
-- accepted ask cannot recreate a withdrawn answer after permission is restored.
CREATE FUNCTION ritc.withdraw_ineligible_adult_checks() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  UPDATE ritc.adult_check SET withdrawn=true,answer=NULL,quantity=NULL,answered_at=NULL,reviewed=false
  WHERE household_id=NEW.household_id AND NOT withdrawn
    AND (recipient_id=NEW.member_id OR (shopper_id=NEW.member_id AND (NEW.state<>'active' OR NEW.kind<>'adult')));
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.withdraw_ineligible_adult_checks() FROM PUBLIC;
CREATE TRIGGER withdraw_ineligible_adult_checks AFTER UPDATE OF kind,state,can_contribute,organizer ON ritc.member
  FOR EACH ROW WHEN (OLD.kind='adult' AND OLD.state='active' AND
    (NEW.kind<>'adult' OR NEW.state<>'active' OR
     ((OLD.can_contribute OR OLD.organizer) AND NOT NEW.can_contribute AND NOT NEW.organizer)))
  EXECUTE FUNCTION ritc.withdraw_ineligible_adult_checks();

CREATE FUNCTION ritc.withdraw_blocked_adult_checks() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  UPDATE ritc.adult_check SET withdrawn=true,answer=NULL,quantity=NULL,answered_at=NULL,reviewed=false
  WHERE household_id=NEW.household_id AND NOT withdrawn
    AND ((shopper_id,recipient_id)=(NEW.viewer_id,NEW.author_id) OR
         (shopper_id,recipient_id)=(NEW.author_id,NEW.viewer_id));
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ritc.withdraw_blocked_adult_checks() FROM PUBLIC;
CREATE TRIGGER withdraw_blocked_adult_checks AFTER INSERT ON ritc.moderation_block
  FOR EACH ROW EXECUTE FUNCTION ritc.withdraw_blocked_adult_checks();

CREATE OR REPLACE FUNCTION ritc.clear_unpaid_adult_checks() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  UPDATE ritc.adult_check SET withdrawn=true,answer=NULL,quantity=NULL,answered_at=NULL,reviewed=false
  WHERE household_id=NEW.household_id AND NOT withdrawn;
  RETURN NULL;
END $$;
