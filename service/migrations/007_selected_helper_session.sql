-- A browser opened from one helper link must stay bound to that exact grant.
ALTER TABLE ritc.web_session ADD COLUMN grant_id uuid;
ALTER TABLE ritc.web_session ADD CONSTRAINT web_session_grant_fk FOREIGN KEY(household_id,grant_id) REFERENCES ritc.view_grant;
CREATE INDEX web_session_grant ON ritc.web_session(household_id,grant_id);
