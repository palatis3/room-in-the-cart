ALTER TABLE ritc.shop ADD COLUMN history_retired_at timestamptz;
CREATE TABLE ritc.financial_head(household_id uuid NOT NULL,shop_id uuid NOT NULL,revision integer NOT NULL DEFAULT 0 CHECK(revision>=0),PRIMARY KEY(household_id,shop_id),FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop);
CREATE TABLE ritc.financial_entry(
 household_id uuid NOT NULL,shop_id uuid NOT NULL,entry_id uuid NOT NULL,evidence_key uuid NOT NULL,actor_id uuid NOT NULL,
 kind text NOT NULL CHECK(kind IN ('postedCharge','postedTopUp','pendingCredit','postedCredit','includedCredit','paymentHold','holdRelease')),
 amount_minor bigint NOT NULL CHECK(amount_minor BETWEEN 0 AND 1000000000000),occurred_at timestamptz NOT NULL,
 credit_id uuid,charge_evidence_key uuid,hold_evidence_key uuid,source_text text NOT NULL CHECK(length(source_text) BETWEEN 1 AND 8192),
 created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(household_id,shop_id,entry_id),UNIQUE(household_id,shop_id,evidence_key),
 FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member,
 FOREIGN KEY(household_id,shop_id,charge_evidence_key) REFERENCES ritc.financial_entry(household_id,shop_id,evidence_key),
 FOREIGN KEY(household_id,shop_id,hold_evidence_key) REFERENCES ritc.financial_entry(household_id,shop_id,evidence_key)
);
CREATE INDEX financial_entry_actor ON ritc.financial_entry(household_id,actor_id);
CREATE INDEX financial_entry_charge ON ritc.financial_entry(household_id,shop_id,charge_evidence_key);
CREATE INDEX financial_entry_hold ON ritc.financial_entry(household_id,shop_id,hold_evidence_key);
CREATE TABLE ritc.financial_review(household_id uuid NOT NULL,shop_id uuid NOT NULL,review_id uuid NOT NULL,actor_id uuid NOT NULL,source_version jsonb NOT NULL,reviewed_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,shop_id),FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member);
CREATE INDEX financial_review_actor ON ritc.financial_review(household_id,actor_id);
CREATE TABLE ritc.price_observation(household_id uuid NOT NULL,observation_id uuid NOT NULL,shop_id uuid NOT NULL,actor_id uuid NOT NULL,record jsonb NOT NULL,observed_at timestamptz NOT NULL,retired_at timestamptz,
 PRIMARY KEY(household_id,observation_id),FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop,FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member);
CREATE INDEX price_observation_shop ON ritc.price_observation(household_id,shop_id,observed_at,observation_id);
CREATE INDEX price_observation_actor ON ritc.price_observation(household_id,actor_id);
CREATE TABLE ritc.budget_period(household_id uuid NOT NULL,period_id uuid NOT NULL,owner_id uuid NOT NULL,revision integer NOT NULL CHECK(revision>0),record jsonb NOT NULL,updated_at timestamptz NOT NULL,
 PRIMARY KEY(household_id,period_id),FOREIGN KEY(household_id,owner_id) REFERENCES ritc.member);
CREATE INDEX budget_period_owner ON ritc.budget_period(household_id,owner_id);
CREATE TABLE ritc.budget_period_shop(household_id uuid NOT NULL,period_id uuid NOT NULL,shop_id uuid NOT NULL,
 PRIMARY KEY(household_id,period_id,shop_id),FOREIGN KEY(household_id,period_id) REFERENCES ritc.budget_period,FOREIGN KEY(household_id,shop_id) REFERENCES ritc.shop);
CREATE INDEX budget_period_shop_source ON ritc.budget_period_shop(household_id,shop_id);
CREATE TABLE ritc.history_mutation(household_id uuid NOT NULL,actor_id uuid NOT NULL,client_key uuid NOT NULL,kind text NOT NULL,target_id uuid NOT NULL,payload_digest text NOT NULL,response jsonb NOT NULL,
 PRIMARY KEY(household_id,actor_id,client_key),FOREIGN KEY(household_id,actor_id) REFERENCES ritc.member);
DO $$ DECLARE item text;BEGIN FOREACH item IN ARRAY ARRAY['financial_head','financial_entry','financial_review','price_observation','budget_period','budget_period_shop','history_mutation'] LOOP
 EXECUTE format('ALTER TABLE ritc.%I ENABLE ROW LEVEL SECURITY',item);EXECUTE format('ALTER TABLE ritc.%I FORCE ROW LEVEL SECURITY',item);
 EXECUTE format('CREATE POLICY tenant_scope ON ritc.%I USING(household_id::text=(SELECT current_setting(''app.household_id'',true))) WITH CHECK(household_id::text=(SELECT current_setting(''app.household_id'',true)))',item);
 EXECUTE format('GRANT SELECT,INSERT ON ritc.%I TO ritc_app',item);
END LOOP;END $$;
GRANT UPDATE ON ritc.financial_head,ritc.financial_review,ritc.budget_period TO ritc_app;
GRANT UPDATE(retired_at) ON ritc.price_observation TO ritc_app;
GRANT DELETE ON ritc.financial_review,ritc.budget_period_shop TO ritc_app;
CREATE TRIGGER financial_evidence_immutable BEFORE UPDATE OR DELETE ON ritc.financial_entry FOR EACH ROW EXECUTE FUNCTION ritc.immutable_row();

CREATE OR REPLACE FUNCTION ritc.privacy_erase_extension(target_household uuid,target_member uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 DELETE FROM ritc.helper_mutation WHERE household_id=target_household AND actor_id=target_member;
 DELETE FROM ritc.history_mutation WHERE household_id=target_household AND actor_id=target_member;
 DELETE FROM ritc.price_observation WHERE household_id=target_household AND actor_id=target_member;
 -- Preserve another current shopper's de-identified accounting facts and linked credit/hold IDs.
 -- Remove the erased author's free text and invalidate review of the changed source.
 UPDATE ritc.financial_head h SET revision=revision+1 WHERE household_id=target_household AND EXISTS(SELECT 1 FROM ritc.financial_entry e WHERE e.household_id=target_household AND e.shop_id=h.shop_id AND e.actor_id=target_member);
 UPDATE ritc.financial_entry SET source_text='Removed financial evidence' WHERE household_id=target_household AND actor_id=target_member;
 DELETE FROM ritc.financial_review WHERE household_id=target_household AND actor_id=target_member;
 DELETE FROM ritc.budget_period_shop s USING ritc.budget_period p WHERE s.household_id=target_household AND p.household_id=s.household_id AND p.period_id=s.period_id AND p.owner_id=target_member;
 DELETE FROM ritc.budget_period WHERE household_id=target_household AND owner_id=target_member;
END $$;
