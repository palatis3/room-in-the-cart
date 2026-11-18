-- A household publication owns an immutable copy; the source reference is scoped
-- to one actor and shared shop and contains no private inventory identifier.
CREATE UNIQUE INDEX price_observation_source_revision
  ON ritc.price_observation(household_id,shop_id,actor_id,
    (record->'sourceRevision'->>'sourceId'), ((record->'sourceRevision'->>'revision')::bigint))
  WHERE record ? 'sourceRevision';
