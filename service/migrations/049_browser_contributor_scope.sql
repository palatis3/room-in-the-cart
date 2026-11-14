ALTER TABLE ritc.web_session
  ADD COLUMN own_requests_only boolean NOT NULL DEFAULT false,
  ADD CONSTRAINT web_session_own_requests_without_grant
    CHECK (NOT own_requests_only OR grant_id IS NULL);
