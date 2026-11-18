-- Use these views only for shared wording shown to the authenticated member.
-- Immutable basket totals, source digests and erasure continue to use their originals.
CREATE FUNCTION ritc.content_viewer() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.content_viewer',true),'')::uuid
$$;

CREATE VIEW ritc.visible_request_origin WITH (security_invoker=true) AS
SELECT o.household_id,o.request_id,o.author_id,o.client_request_id,o.shop_id,o.original_item,
       o.own_quantity,o.revision,o.route,o.status,o.authored_at,o.received_at,
       CASE WHEN ritc.shared_content_visible(r.household_id,ritc.content_viewer(),r.clarification_author_id,
            'clarification',r.request_id,coalesce(r.clarification_revision,1),r.revision)
            THEN o.clarification END AS clarification,
       o.followup_to,o.author_consent_id,o.carried_forward,o.from_previous_shop,o.author_alias,
       o.author_kind,o.author_active,o.live_notice,r.clarification_author_id
FROM ritc.request_origin o JOIN ritc.request r USING(household_id,request_id)
WHERE ritc.content_viewer() IS NOT NULL AND
  ritc.shared_content_visible(r.household_id,ritc.content_viewer(),r.author_id,
      'request',r.request_id,r.wording_revision,r.revision)
  AND (NOT o.from_previous_shop OR NOT EXISTS (
    WITH RECURSIVE originals(id) AS (
      SELECT r.request_id
      UNION
      SELECT c.source_request_id FROM originals o2
      JOIN ritc.request_carry c ON c.household_id=r.household_id AND c.target_request_id=o2.id
      JOIN ritc.request child ON child.household_id=c.household_id AND child.request_id=c.target_request_id
      WHERE child.wording_revision=1
    )
    SELECT 1 FROM originals JOIN ritc.request src ON src.household_id=r.household_id AND src.request_id=originals.id
    WHERE NOT ritc.shared_content_visible(src.household_id,ritc.content_viewer(),src.author_id,
      'request',src.request_id,src.wording_revision,src.revision)
  ));

CREATE VIEW ritc.visible_view_grant WITH (security_invoker=true) AS
SELECT g.* FROM ritc.view_grant g WHERE ritc.content_viewer() IS NOT NULL AND
  ritc.shared_content_visible(g.household_id,ritc.content_viewer(),g.projection_author_id,
    'instruction',g.grant_id,g.projection_wording_revision,g.revision);
CREATE VIEW ritc.visible_helper_proposal WITH (security_invoker=true) AS
SELECT p.* FROM ritc.helper_proposal p WHERE ritc.content_viewer() IS NOT NULL AND
  ritc.shared_content_visible(p.household_id,ritc.content_viewer(),p.actor_id,
    'suggestion',p.proposal_id,1,p.revision);
CREATE VIEW ritc.visible_dated_cook_copy WITH (security_invoker=true) AS
SELECT c.* FROM ritc.dated_cook_copy c WHERE ritc.content_viewer() IS NOT NULL AND
  ritc.shared_content_visible(c.household_id,ritc.content_viewer(),c.actor_id,
    'cookCopy',c.copy_id,c.version,c.version);

GRANT SELECT ON ritc.visible_request_origin,ritc.visible_view_grant,ritc.visible_helper_proposal,
  ritc.visible_dated_cook_copy TO ritc_app;
