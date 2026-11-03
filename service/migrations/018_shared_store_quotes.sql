-- Manual two-store comparison is Free. Budget access is a distinct per-adult,
-- per-shop permission; an organizer, contributor, cook or paid seat cannot imply it.
ALTER TABLE ritc.shop ADD COLUMN store_basis_revision integer CHECK(store_basis_revision>0);
ALTER TABLE ritc.shop ADD COLUMN store_review_required boolean NOT NULL DEFAULT false;

CREATE TABLE ritc.shop_budget_grant (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, member_id uuid NOT NULL,
 authority_epoch integer NOT NULL CHECK(authority_epoch>0),
 revision integer NOT NULL CHECK(revision>0), enabled boolean NOT NULL,
 PRIMARY KEY(household_id,shop_id,member_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,member_id) REFERENCES ritc.member
);
CREATE INDEX shop_budget_grant_member ON ritc.shop_budget_grant(household_id,member_id,shop_id) WHERE enabled;

CREATE TABLE ritc.store_quote_pair (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, pair_id uuid NOT NULL, actor_id uuid NOT NULL,
 shop_revision integer NOT NULL CHECK(shop_revision>0), authority_epoch integer NOT NULL CHECK(authority_epoch>0),
 grant_revision integer NOT NULL CHECK(grant_revision>=0),
 commitments jsonb NOT NULL CHECK(jsonb_typeof(commitments)='array' AND jsonb_array_length(commitments)>0),
 options jsonb NOT NULL CHECK(jsonb_typeof(options)='object' AND options ? 'first' AND options ? 'second'
   AND options - 'first' - 'second' = '{}'::jsonb),
 created_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,shop_id,pair_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
CREATE INDEX store_quote_pair_owner ON ritc.store_quote_pair(household_id,shop_id,actor_id,created_at DESC,pair_id DESC);

-- An explicit proposal grants the assigned shopper access to this one immutable
-- pair while its author still holds the original permission. Saving does not.
CREATE TABLE ritc.store_quote_proposal (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, proposal_id uuid NOT NULL, pair_id uuid NOT NULL,
 choice text NOT NULL CHECK(choice IN ('first','second')), created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(household_id,shop_id,proposal_id),
 UNIQUE(household_id,shop_id,pair_id),
 FOREIGN KEY(household_id,shop_id,pair_id) REFERENCES ritc.store_quote_pair ON DELETE CASCADE
);
CREATE TABLE ritc.store_quote_adoption (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, revision integer NOT NULL CHECK(revision>0), pair_id uuid NOT NULL,
 choice text NOT NULL CHECK(choice IN ('first','second')), actor_id uuid NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(household_id,shop_id,revision),
 FOREIGN KEY(household_id,shop_id,pair_id) REFERENCES ritc.store_quote_pair ON DELETE CASCADE,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
-- Content-free receipts are retained for the lifetime of this actor's shop data.
-- They cannot re-create a deleted pair and are removed on account erasure.
CREATE TABLE ritc.store_quote_mutation (
 household_id uuid NOT NULL, shop_id uuid NOT NULL, actor_id uuid NOT NULL, operation_id uuid NOT NULL,
 fingerprint text NOT NULL CHECK(length(fingerprint)=64), receipt jsonb NOT NULL,
 PRIMARY KEY(household_id,shop_id,actor_id,operation_id),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,
 FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member
);
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['shop_budget_grant','store_quote_pair','store_quote_proposal','store_quote_adoption','store_quote_mutation'] LOOP
  EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',t);
  EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',t);
  EXECUTE format('GRANT SELECT,INSERT ON ritc.%I TO ritc_app',t);
 END LOOP;
END $$;
GRANT UPDATE ON ritc.shop_budget_grant TO ritc_app;

ALTER FUNCTION ritc.privacy_erase_extension(uuid,uuid) RENAME TO privacy_erase_shared_ideas;
CREATE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 -- Keep the content-free last-adoption revision as the explicit reprice token.
 -- Its proof can disappear on erasure; clearing the token would strand a draft
 -- that still requires a price review. Invalidated prices remain unknown.
 DELETE FROM ritc.store_quote_mutation WHERE household_id=target_household AND actor_id=target_member;
 DELETE FROM ritc.store_quote_adoption WHERE household_id=target_household AND actor_id=target_member;
 DELETE FROM ritc.store_quote_pair WHERE household_id=target_household AND actor_id=target_member;
 DELETE FROM ritc.shop_budget_grant WHERE household_id=target_household AND member_id=target_member;
 PERFORM ritc.privacy_erase_shared_ideas(target_household,target_member);
END $$;
REVOKE ALL ON FUNCTION ritc.privacy_erase_extension(uuid,uuid) FROM PUBLIC;
