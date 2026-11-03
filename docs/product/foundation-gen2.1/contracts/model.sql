-- Room in the Cart / logical storage reference, Foundation 2 (fresh database)
-- Execute on a fresh SQLite 3.38+ database with JSON functions and STRICT tables.
-- Enable foreign_keys on EVERY connection before transactions. This reference
-- describes relations shared across storage tiers; it is not a client sync payload.
-- A guest iPhone creates a local household, local adult and draft without credentials.
-- A service household authenticates devices and enforces current grants before writes
-- and scoped reads. Never replicate this database wholesale to a contributor.
-- Only confirmed commands enter authoritative state. Local outbox is device-only.
-- Application-issued opaque stable IDs. UTC instants in RFC3339, named IANA zones
-- for local deadlines/slots; validate calendars, zones, amounts and currency exponents
-- at ingress. Signed integer minor units, rational quantities; NULL means unknown.
-- Restrictive FKs deliberately prevent accidental deletion of independent evidence.
-- Never use REPLACE. Authority transactions use BEGIN IMMEDIATE and conditional
-- updates against expected revision AND epoch, checking rowcount before commit.
PRAGMA foreign_keys = ON;
BEGIN;
CREATE TABLE household (
    household_id TEXT PRIMARY KEY NOT NULL,
    mode TEXT NOT NULL CHECK (mode IN ('local','service')),
    display_name TEXT NOT NULL,
    zone TEXT NOT NULL
) STRICT;


-- Identity, consent and access scopes
CREATE TABLE member (
    household_id TEXT NOT NULL,
    member_id TEXT NOT NULL,
    alias TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('adult', 'child')),
    state TEXT NOT NULL CHECK (state IN ('invited', 'active', 'revoked')),
    organizer INTEGER NOT NULL DEFAULT 0 CHECK (organizer IN (0,1)),
    verified_subject TEXT,
    PRIMARY KEY (household_id, member_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    CHECK (organizer=0 OR kind='adult'),
    UNIQUE (household_id, verified_subject)
) STRICT;

CREATE TABLE device (
    household_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    member_id TEXT NOT NULL,
    revoked_at TEXT,
    last_seen_at TEXT,
    PRIMARY KEY (household_id, device_id),
    UNIQUE (household_id, member_id, device_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, member_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE guardian_consent (
    household_id TEXT NOT NULL,
    consent_id TEXT NOT NULL,
    child_id TEXT NOT NULL,
    guardian_id TEXT NOT NULL,
    notice_version TEXT NOT NULL,
    verification_reference TEXT NOT NULL,
    granted_at TEXT NOT NULL,
    revoked_at TEXT,
    PRIMARY KEY (household_id, consent_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, child_id) REFERENCES member (household_id, member_id),
    FOREIGN KEY (household_id, guardian_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE invite (
    household_id TEXT NOT NULL,
    invite_id TEXT NOT NULL,
    creator_id TEXT NOT NULL,
    intended_member_id TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    scope TEXT NOT NULL CHECK (scope IN ('contribute', 'planner_seat')),
    expires_at TEXT NOT NULL,
    redeemed_at TEXT,
    revoked_at TEXT,
    PRIMARY KEY (household_id, invite_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, token_hash),
    FOREIGN KEY (household_id, creator_id) REFERENCES member (household_id, member_id),
    FOREIGN KEY (household_id, intended_member_id) REFERENCES member (household_id, member_id)
) STRICT;

-- Server-only verified Apple purchase ownership. Clients receive only a scoped
-- entitlement projection. A restore on another household cannot create a new owner.
CREATE TABLE apple_purchase_binding (
    environment TEXT NOT NULL CHECK (environment IN ('sandbox','production')),
    bundle_id TEXT NOT NULL,
    original_transaction_ref TEXT NOT NULL,
    household_id TEXT NOT NULL,
    purchaser_id TEXT NOT NULL,
    PRIMARY KEY (environment, bundle_id, original_transaction_ref),
    UNIQUE (environment, bundle_id, original_transaction_ref, household_id, purchaser_id),
    FOREIGN KEY (household_id, purchaser_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE apple_transaction_identity (
    environment TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    transaction_ref TEXT NOT NULL,
    original_transaction_ref TEXT NOT NULL,
    PRIMARY KEY (environment, bundle_id, transaction_ref),
    UNIQUE (environment, bundle_id, transaction_ref, original_transaction_ref),
    FOREIGN KEY (environment, bundle_id, original_transaction_ref)
        REFERENCES apple_purchase_binding (environment, bundle_id, original_transaction_ref)
) STRICT;

CREATE TABLE entitlement (
    household_id TEXT NOT NULL,
    entitlement_id TEXT NOT NULL,
    purchaser_id TEXT NOT NULL,
    product_id TEXT NOT NULL,
    transaction_ref TEXT NOT NULL,
    environment TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    original_transaction_ref TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending', 'active', 'grace', 'cancelled', 'expired', 'refunded')),
    valid_until TEXT,
    verified_at TEXT,
    PRIMARY KEY (household_id, entitlement_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (environment, bundle_id, transaction_ref),
    FOREIGN KEY (environment, bundle_id, original_transaction_ref, household_id, purchaser_id)
        REFERENCES apple_purchase_binding (environment, bundle_id, original_transaction_ref, household_id, purchaser_id),
    FOREIGN KEY (environment, bundle_id, transaction_ref, original_transaction_ref)
        REFERENCES apple_transaction_identity (environment, bundle_id, transaction_ref, original_transaction_ref),
    FOREIGN KEY (household_id, purchaser_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE seat (
    household_id TEXT NOT NULL,
    seat_id TEXT NOT NULL,
    entitlement_id TEXT NOT NULL,
    member_id TEXT NOT NULL,
    seat_number INTEGER NOT NULL CHECK (seat_number IN (1,2)),
    PRIMARY KEY (household_id, seat_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, seat_number),
    UNIQUE (household_id, member_id),
    FOREIGN KEY (household_id, entitlement_id) REFERENCES entitlement (household_id, entitlement_id),
    FOREIGN KEY (household_id, member_id) REFERENCES member (household_id, member_id)
) STRICT;


-- Typed measures, shop authority and versioned records
CREATE TABLE quantity (
    household_id TEXT NOT NULL,
    quantity_id TEXT NOT NULL,
    original_text TEXT NOT NULL,
    source_locale TEXT NOT NULL,
    source_unit TEXT,
    source_decimal TEXT,
    numerator INTEGER CHECK (numerator >= 0),
    denominator INTEGER CHECK (denominator > 0),
    unit TEXT,
    conversion_basis TEXT,
    PRIMARY KEY (household_id, quantity_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    CHECK ((numerator IS NULL) = (denominator IS NULL) AND (numerator IS NULL) = (unit IS NULL))
) STRICT;

CREATE TABLE shop (
    household_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    shopper_id TEXT NOT NULL,
    authority_epoch INTEGER NOT NULL DEFAULT 1 CHECK (authority_epoch > 0),
    revision_no INTEGER NOT NULL DEFAULT 0 CHECK (revision_no >= 0),
    phase TEXT NOT NULL DEFAULT 'draft' CHECK (phase IN ('draft', 'protected', 'placed', 'closed')),
    currency TEXT NOT NULL CHECK (currency GLOB '[A-Z][A-Z][A-Z]'),
    cap_minor INTEGER CHECK (cap_minor >= 0),
    cap_scope TEXT NOT NULL CHECK (cap_scope IN ('unknown', 'dinner', 'whole')),
    cap_firmness TEXT,
    branch TEXT,
    mode TEXT,
    zone TEXT NOT NULL,
    slot_start TEXT,
    slot_end TEXT,
    saved_at TEXT,
    last_sync_at TEXT,
    UNIQUE (household_id, shop_id, currency),
    PRIMARY KEY (household_id, shop_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, shopper_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE shop_grant (
    household_id TEXT NOT NULL,
    grant_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    member_id TEXT NOT NULL,
    scope TEXT NOT NULL CHECK (scope IN ('read', 'propose', 'budget')),
    expires_at TEXT,
    revoked_at TEXT,
    PRIMARY KEY (household_id, grant_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, shop_id) REFERENCES shop (household_id, shop_id),
    FOREIGN KEY (household_id, member_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE shop_revision (
    household_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    parent_id TEXT,
    display_no INTEGER NOT NULL CHECK (display_no >= 0),
    author_id TEXT NOT NULL,
    content_digest TEXT NOT NULL,
    snapshot_json TEXT NOT NULL CHECK (json_valid(snapshot_json)),
    committed_at TEXT NOT NULL,
    PRIMARY KEY (household_id, revision_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, revision_id),
    FOREIGN KEY (household_id, shop_id) REFERENCES shop (household_id, shop_id),
    FOREIGN KEY (household_id, shop_id, parent_id) REFERENCES shop_revision (household_id, shop_id, revision_id),
    FOREIGN KEY (household_id, author_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE shop_head (
    household_id TEXT NOT NULL,
    head_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    PRIMARY KEY (household_id, head_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id),
    FOREIGN KEY (household_id, shop_id, revision_id) REFERENCES shop_revision (household_id, shop_id, revision_id)
) STRICT;

CREATE TABLE meal (
    household_id TEXT NOT NULL,
    meal_id TEXT NOT NULL,
    title TEXT NOT NULL,
    source_url TEXT,
    notes TEXT,
    servings_id TEXT,
    dish_rules_json TEXT NOT NULL CHECK (json_valid(dish_rules_json)),
    usual_revision INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (household_id, meal_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, servings_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

CREATE TABLE meal_slot (
    household_id TEXT NOT NULL,
    slot_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    meal_id TEXT,
    template_revision_id TEXT,
    local_date TEXT, -- NULL means selected, as yet unscheduled; keep this slot_id when dated.
    zone TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('dinner', 'lunch', 'side', 'away')),
    guest_count INTEGER NOT NULL DEFAULT 0 CHECK (guest_count >= 0),
    servings_id TEXT,
    plate_commitments_json TEXT NOT NULL CHECK (json_valid(plate_commitments_json)),
    PRIMARY KEY (household_id, slot_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, slot_id),
    FOREIGN KEY (household_id, shop_id) REFERENCES shop (household_id, shop_id),
    FOREIGN KEY (household_id, meal_id) REFERENCES meal (household_id, meal_id),
    CHECK ((meal_id IS NULL) = (template_revision_id IS NULL)),
    FOREIGN KEY (household_id, meal_id, template_revision_id) REFERENCES meal_template_revision (household_id, meal_id, template_revision_id),
    FOREIGN KEY (household_id, servings_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

CREATE TABLE dinner_idea (
    household_id TEXT NOT NULL,
    idea_id TEXT NOT NULL,
    author_id TEXT NOT NULL,
    source_ref TEXT NOT NULL,
    revision_no INTEGER NOT NULL DEFAULT 1,
    title TEXT NOT NULL,
    yield_id TEXT,
    minutes INTEGER CHECK (minutes >= 0),
    assumptions_json TEXT NOT NULL CHECK (json_valid(assumptions_json)),
    state TEXT NOT NULL CHECK (state IN ('draft', 'approved', 'discarded')),
    approved_meal_id TEXT,
    PRIMARY KEY (household_id, idea_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, author_id) REFERENCES member (household_id, member_id),
    FOREIGN KEY (household_id, yield_id) REFERENCES quantity (household_id, quantity_id),
    FOREIGN KEY (household_id, approved_meal_id) REFERENCES meal (household_id, meal_id),
    CHECK ((state='approved') = (approved_meal_id IS NOT NULL))
) STRICT;

CREATE TABLE idea_ingredient (
    household_id TEXT NOT NULL,
    ingredient_id TEXT NOT NULL,
    idea_id TEXT NOT NULL,
    original_text TEXT NOT NULL,
    quantity_id TEXT,
    review TEXT NOT NULL CHECK (review IN ('pending', 'accepted', 'excluded')),
    PRIMARY KEY (household_id, ingredient_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, idea_id) REFERENCES dinner_idea (household_id, idea_id),
    FOREIGN KEY (household_id, quantity_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

CREATE TABLE shop_line (
    household_id TEXT NOT NULL,
    line_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    original_text TEXT NOT NULL,
    source_locale TEXT NOT NULL,
    package_id TEXT,
    aisle TEXT,
    note TEXT,
    list_state TEXT NOT NULL DEFAULT 'active' CHECK (list_state IN ('active','checked','handled','trash')),
    source_sequence INTEGER NOT NULL DEFAULT 0 CHECK (source_sequence >= 0),
    presentation_sequence INTEGER CHECK (presentation_sequence >= 0),
    UNIQUE (household_id, shop_id, source_sequence),
    PRIMARY KEY (household_id, line_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, line_id),
    FOREIGN KEY (household_id, shop_id) REFERENCES shop (household_id, shop_id),
    FOREIGN KEY (household_id, package_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

-- Assign source_sequence once in the shop write transaction (first line is 0).
-- Presentation can sort by aisle, presentation_sequence, then source_sequence;
-- source-order display always sorts by source_sequence alone.
CREATE TRIGGER preserve_source_sequence BEFORE UPDATE OF source_sequence, shop_id, household_id ON shop_line
WHEN NEW.source_sequence != OLD.source_sequence OR NEW.shop_id != OLD.shop_id OR NEW.household_id != OLD.household_id
BEGIN SELECT RAISE(ABORT,'original sequence belongs to the original shop'); END;

CREATE TABLE need (
    household_id TEXT NOT NULL,
    need_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    line_id TEXT NOT NULL,
    slot_id TEXT,
    quantity_id TEXT NOT NULL,
    purpose TEXT NOT NULL CHECK (purpose IN ('manual', 'meal', 'lunch', 'staple', 'nonfood', 'request')),
    priority TEXT NOT NULL CHECK (priority IN ('required', 'flexible', 'undecided')),
    due_at TEXT,
    deferred_at TEXT,
    handled_at TEXT,
    PRIMARY KEY (household_id, need_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, need_id),
    FOREIGN KEY (household_id, shop_id, line_id) REFERENCES shop_line (household_id, shop_id, line_id),
    FOREIGN KEY (household_id, shop_id, slot_id) REFERENCES meal_slot (household_id, shop_id, slot_id),
    FOREIGN KEY (household_id, quantity_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;


-- Request transport, decision history and device retries
CREATE TABLE request (
    household_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    author_id TEXT NOT NULL,
    target_shop_id TEXT,
    text_original TEXT NOT NULL,
    quantity_id TEXT,
    revision_no INTEGER NOT NULL CHECK (revision_no > 0),
    route TEXT NOT NULL CHECK (route IN ('current', 'next')),
    status TEXT NOT NULL CHECK (status IN ('pending', 'clarified', 'added', 'deferred', 'handled', 'dismissed', 'withdrawn')),
    authored_at TEXT NOT NULL,
    received_at TEXT,
    followup_to TEXT,
    PRIMARY KEY (household_id, request_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, author_id) REFERENCES member (household_id, member_id),
    FOREIGN KEY (household_id, target_shop_id) REFERENCES shop (household_id, shop_id),
    FOREIGN KEY (household_id, quantity_id) REFERENCES quantity (household_id, quantity_id),
    FOREIGN KEY (household_id, followup_to) REFERENCES request (household_id, request_id)
) STRICT;

CREATE TABLE request_link (
    household_id TEXT NOT NULL,
    link_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    line_id TEXT NOT NULL,
    reviewed_request_rev INTEGER NOT NULL CHECK (reviewed_request_rev > 0),
    PRIMARY KEY (household_id, link_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, request_id, shop_id, line_id),
    FOREIGN KEY (household_id, request_id) REFERENCES request (household_id, request_id),
    FOREIGN KEY (household_id, shop_id, line_id) REFERENCES shop_line (household_id, shop_id, line_id)
) STRICT;

CREATE TABLE operation (
    household_id TEXT NOT NULL,
    operation_id TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    client_key TEXT NOT NULL,
    device_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    payload_digest TEXT NOT NULL,
    expected_revision TEXT,
    expected_epoch INTEGER,
    committed_at TEXT NOT NULL,
    PRIMARY KEY (household_id, operation_id),
    UNIQUE (household_id, actor_id, client_key),
    UNIQUE (household_id, actor_id, operation_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, actor_id) REFERENCES member (household_id, member_id),
    FOREIGN KEY (household_id, actor_id, device_id) REFERENCES device (household_id, member_id, device_id)
) STRICT;

-- Durable operation IDs remain valid foreign-key targets after the private response is removed.
CREATE TABLE operation_response (
    household_id TEXT NOT NULL,
    operation_id TEXT NOT NULL,
    outcome_json TEXT NOT NULL CHECK (json_valid(outcome_json)),
    PRIMARY KEY (household_id, operation_id),
    FOREIGN KEY (household_id, operation_id) REFERENCES operation (household_id, operation_id)
) STRICT;

CREATE TABLE outbox (
    household_id TEXT NOT NULL,
    client_key TEXT NOT NULL,
    device_id TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    payload_digest TEXT NOT NULL,
    draft_payload_json TEXT NOT NULL CHECK (json_valid(draft_payload_json)),
    state TEXT NOT NULL CHECK (state IN ('queued', 'sent', 'review', 'rejected')),
    acknowledged_at TEXT,
    PRIMARY KEY (household_id, actor_id, client_key),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, actor_id, device_id) REFERENCES device (household_id, member_id, device_id),
    FOREIGN KEY (household_id, actor_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE event (
    household_id TEXT NOT NULL,
    event_id TEXT NOT NULL,
    operation_id TEXT,
    actor_id TEXT NOT NULL,
    shop_id TEXT,
    request_id TEXT,
    kind TEXT NOT NULL,
    evidence_json TEXT NOT NULL CHECK (json_valid(evidence_json)),
    observed_at TEXT NOT NULL,
    PRIMARY KEY (household_id, event_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, actor_id, operation_id) REFERENCES operation (household_id, actor_id, operation_id),
    FOREIGN KEY (household_id, actor_id) REFERENCES member (household_id, member_id),
    FOREIGN KEY (household_id, shop_id) REFERENCES shop (household_id, shop_id),
    FOREIGN KEY (household_id, request_id) REFERENCES request (household_id, request_id)
) STRICT;

CREATE TABLE inbox_cursor (
    household_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    last_server_cursor TEXT,
    last_successful_sync TEXT,
    PRIMARY KEY (household_id, device_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, device_id) REFERENCES device (household_id, device_id)
) STRICT;


-- Manual price observations and privately compared scenarios
CREATE TABLE price_quote (
    household_id TEXT NOT NULL,
    quote_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    line_id TEXT,
    source TEXT NOT NULL,
    branch TEXT NOT NULL,
    mode TEXT NOT NULL,
    slot_at TEXT,
    zone TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    eligibility TEXT,
    pack_quantity_id TEXT,
    currency TEXT NOT NULL CHECK (currency GLOB '[A-Z][A-Z][A-Z]'),
    price_minor INTEGER CHECK (price_minor >= 0),
    included_charges_json TEXT NOT NULL CHECK (json_valid(included_charges_json)),
    PRIMARY KEY (household_id, quote_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, quote_id),
    UNIQUE (household_id, shop_id, line_id, quote_id),
    FOREIGN KEY (household_id, shop_id) REFERENCES shop (household_id, shop_id),
    FOREIGN KEY (household_id, shop_id, line_id) REFERENCES shop_line (household_id, shop_id, line_id),
    FOREIGN KEY (household_id, pack_quantity_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

CREATE TABLE quote_pair (
    household_id TEXT NOT NULL,
    pair_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    base_revision_id TEXT NOT NULL,
    author_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (household_id, pair_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, pair_id),
    FOREIGN KEY (household_id, shop_id, base_revision_id) REFERENCES shop_revision (household_id, shop_id, revision_id),
    FOREIGN KEY (household_id, author_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE quote_option (
    household_id TEXT NOT NULL,
    option_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    pair_id TEXT NOT NULL,
    side INTEGER NOT NULL CHECK (side IN (1,2)),
    branch TEXT NOT NULL,
    mode TEXT NOT NULL,
    source TEXT NOT NULL,
    slot_at TEXT,
    observed_at TEXT NOT NULL,
    eligibility TEXT,
    currency TEXT NOT NULL CHECK (currency GLOB '[A-Z][A-Z][A-Z]'),
    basket_minor INTEGER CHECK (basket_minor >= 0),
    fees_minor INTEGER CHECK (fees_minor >= 0),
    incremental_trip_minor INTEGER CHECK (incremental_trip_minor >= 0),
    incremental_trip_minutes INTEGER CHECK (incremental_trip_minutes >= 0),
    availability TEXT NOT NULL CHECK (availability IN ('known', 'partial', 'unknown')),
    PRIMARY KEY (household_id, option_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, pair_id, side),
    UNIQUE (household_id, shop_id, option_id),
    FOREIGN KEY (household_id, shop_id, pair_id) REFERENCES quote_pair (household_id, shop_id, pair_id)
) STRICT;

CREATE TABLE period_budget (
    household_id TEXT NOT NULL,
    period_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    start_local_date TEXT NOT NULL,
    end_local_date TEXT NOT NULL,
    currency TEXT NOT NULL CHECK (currency GLOB '[A-Z][A-Z][A-Z]'),
    limit_minor INTEGER CHECK (limit_minor >= 0),
    UNIQUE (household_id, period_id, currency),
    PRIMARY KEY (household_id, period_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, owner_id) REFERENCES member (household_id, member_id),
    CHECK (start_local_date <= end_local_date)
) STRICT;

CREATE TABLE period_reservation (
    household_id TEXT NOT NULL,
    reservation_id TEXT NOT NULL,
    period_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    expected_minor INTEGER CHECK (expected_minor >= 0),
    currency TEXT NOT NULL,
    PRIMARY KEY (household_id, reservation_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, period_id, shop_id),
    FOREIGN KEY (household_id, period_id, currency) REFERENCES period_budget (household_id, period_id, currency),
    FOREIGN KEY (household_id, shop_id, currency) REFERENCES shop (household_id, shop_id, currency)
) STRICT;


-- Snapshots, fulfillment and accounting
CREATE TABLE handoff (
    household_id TEXT NOT NULL,
    handoff_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    recipient_ref TEXT,
    recipient_locale TEXT NOT NULL,
    text_snapshot TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (household_id, handoff_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, shop_id, revision_id) REFERENCES shop_revision (household_id, shop_id, revision_id)
) STRICT;

CREATE TABLE handoff_action (
    household_id TEXT NOT NULL,
    action_id TEXT NOT NULL,
    handoff_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('copied', 'shared', 'opened', 'marked_sent', 'acknowledged')),
    observed_recipient_ref TEXT,
    observed_at TEXT NOT NULL,
    PRIMARY KEY (household_id, action_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, handoff_id) REFERENCES handoff (household_id, handoff_id)
) STRICT;

CREATE TABLE placed_order (
    household_id TEXT NOT NULL,
    order_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    reporter_id TEXT NOT NULL,
    evidence_source TEXT NOT NULL,
    reported_at TEXT NOT NULL,
    PRIMARY KEY (household_id, order_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, order_id),
    FOREIGN KEY (household_id, shop_id, revision_id) REFERENCES shop_revision (household_id, shop_id, revision_id),
    FOREIGN KEY (household_id, reporter_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE order_line (
    household_id TEXT NOT NULL,
    order_line_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    order_id TEXT NOT NULL,
    line_id TEXT NOT NULL,
    confirmed_quantity_id TEXT NOT NULL,
    PRIMARY KEY (household_id, order_line_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, order_line_id),
    FOREIGN KEY (household_id, shop_id, order_id) REFERENCES placed_order (household_id, shop_id, order_id)
        DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY (household_id, shop_id, line_id) REFERENCES shop_line (household_id, shop_id, line_id),
    FOREIGN KEY (household_id, confirmed_quantity_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

-- Original placement command: BEGIN IMMEDIATE; validate shopper, expected head/epoch
-- and all reviewed quantities; INSERT order_line records for the new order ID;
-- then INSERT placed_order as the seal, append operation/event and COMMIT.
-- Roll back the WHOLE command on any failure (including deferred FK at commit).
-- The ordinary connection denies DELETE/REPLACE of placed_order and order_line.
CREATE TRIGGER reject_late_order_line BEFORE INSERT ON order_line
WHEN EXISTS (SELECT 1 FROM placed_order WHERE household_id=NEW.household_id AND order_id=NEW.order_id)
BEGIN SELECT RAISE(ABORT,'original order is sealed; append an amendment'); END;
CREATE TRIGGER preserve_placed_membership BEFORE DELETE ON order_line
WHEN EXISTS (SELECT 1 FROM placed_order WHERE household_id=OLD.household_id AND order_id=OLD.order_id)
BEGIN SELECT RAISE(ABORT,'original order is sealed; append an amendment'); END;

CREATE TABLE amendment (
    household_id TEXT NOT NULL,
    amendment_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    order_id TEXT NOT NULL,
    proposed_revision_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('proposed', 'submitted', 'confirmed', 'refused', 'expired')),
    retailer_confirmation_ref TEXT,
    PRIMARY KEY (household_id, amendment_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, shop_id, order_id) REFERENCES placed_order (household_id, shop_id, order_id),
    FOREIGN KEY (household_id, shop_id, proposed_revision_id) REFERENCES shop_revision (household_id, shop_id, revision_id),
    CHECK (state != 'confirmed' OR retailer_confirmation_ref IS NOT NULL)
) STRICT;

CREATE TABLE store_offer (
    household_id TEXT NOT NULL,
    offer_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    order_line_id TEXT NOT NULL,
    remaining_original_id TEXT,
    offered_quantity_id TEXT,
    quote_id TEXT,
    cutoff_at TEXT,
    zone TEXT NOT NULL,
    decision TEXT NOT NULL CHECK (decision IN ('pending', 'prefer', 'decline', 'expired')),
    retailer_response TEXT,
    PRIMARY KEY (household_id, offer_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, shop_id, order_line_id) REFERENCES order_line (household_id, shop_id, order_line_id),
    FOREIGN KEY (household_id, remaining_original_id) REFERENCES quantity (household_id, quantity_id),
    FOREIGN KEY (household_id, offered_quantity_id) REFERENCES quantity (household_id, quantity_id),
    FOREIGN KEY (household_id, shop_id, quote_id) REFERENCES price_quote (household_id, shop_id, quote_id)
) STRICT;

CREATE TABLE delivery (
    household_id TEXT NOT NULL,
    delivery_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    order_line_id TEXT NOT NULL,
    source_record_key TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('received', 'partial', 'no_fill', 'wrong', 'late', 'split')),
    received_quantity_id TEXT,
    observed_at TEXT NOT NULL,
    PRIMARY KEY (household_id, delivery_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, source_record_key),
    UNIQUE (household_id, shop_id, delivery_id),
    FOREIGN KEY (household_id, shop_id, order_line_id) REFERENCES order_line (household_id, shop_id, order_line_id),
    FOREIGN KEY (household_id, received_quantity_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

CREATE TABLE lot (
    household_id TEXT NOT NULL,
    lot_id TEXT NOT NULL,
    delivery_id TEXT,
    stored_at TEXT,
    location TEXT,
    use_first_at TEXT,
    unit TEXT NOT NULL,
    food_label TEXT, -- manual food identity, or a supplement to delivery evidence
    note TEXT,
    CHECK (delivery_id IS NOT NULL OR (food_label IS NOT NULL AND length(trim(food_label)) > 0)),
    PRIMARY KEY (household_id, lot_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, delivery_id) REFERENCES delivery (household_id, delivery_id)
) STRICT;

CREATE TABLE usable_observation (
    household_id TEXT NOT NULL,
    observation_id TEXT NOT NULL,
    lot_id TEXT NOT NULL,
    supersedes_id TEXT,
    usable_id TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    PRIMARY KEY (household_id, observation_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, lot_id, observation_id),
    UNIQUE (household_id, lot_id, supersedes_id),
    FOREIGN KEY (household_id, lot_id) REFERENCES lot (household_id, lot_id),
    FOREIGN KEY (household_id, lot_id, supersedes_id) REFERENCES usable_observation (household_id, lot_id, observation_id),
    FOREIGN KEY (household_id, usable_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

-- Explicit review attests that this particular food is suitable for this need.
-- Service checks current grants, usable stock, amounts and compatible measures.
-- Unit equality, shared aisle and approximate text matches cannot create a match.
CREATE TABLE reviewed_lot_need_match (
    household_id TEXT NOT NULL,
    lot_id TEXT NOT NULL,
    need_id TEXT NOT NULL,
    reviewer_id TEXT NOT NULL,
    reviewed_at TEXT NOT NULL,
    PRIMARY KEY (household_id, lot_id, need_id),
    FOREIGN KEY (household_id, lot_id) REFERENCES lot (household_id, lot_id),
    FOREIGN KEY (household_id, need_id) REFERENCES need (household_id, need_id),
    FOREIGN KEY (household_id, reviewer_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE allocation (
    household_id TEXT NOT NULL,
    allocation_id TEXT NOT NULL,
    lot_id TEXT NOT NULL,
    need_id TEXT NOT NULL,
    quantity_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('reserved', 'assigned', 'used')),
    PRIMARY KEY (household_id, allocation_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, lot_id, need_id, kind),
    FOREIGN KEY (household_id, lot_id, need_id) REFERENCES reviewed_lot_need_match (household_id, lot_id, need_id),
    FOREIGN KEY (household_id, quantity_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

CREATE TABLE ledger_entry (
    household_id TEXT NOT NULL,
    entry_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    source_record_key TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('charge', 'credit', 'top_up', 'hold')),
    status TEXT NOT NULL CHECK (status IN ('pending', 'posted', 'included')),
    signed_minor INTEGER,
    currency TEXT NOT NULL CHECK (currency GLOB '[A-Z][A-Z][A-Z]'),
    linked_charge_id TEXT,
    basis TEXT NOT NULL,
    observed_at TEXT NOT NULL,
    PRIMARY KEY (household_id, entry_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, source_record_key),
    UNIQUE (household_id, shop_id, entry_id),
    FOREIGN KEY (household_id, shop_id) REFERENCES shop (household_id, shop_id),
    FOREIGN KEY (household_id, shop_id, linked_charge_id) REFERENCES ledger_entry (household_id, shop_id, entry_id),
    CHECK (kind != 'hold' OR status='pending'),
    CHECK (linked_charge_id IS NULL OR linked_charge_id != entry_id),
    CHECK (status != 'included' OR (kind='credit' AND linked_charge_id IS NOT NULL)),
      CHECK (status = 'pending' OR signed_minor IS NOT NULL),
    CHECK (signed_minor IS NULL OR (kind='credit' AND signed_minor<=0) OR (kind!='credit' AND signed_minor>=0))
) STRICT;


-- Local input, settings, disclosure and recovery
CREATE TABLE capture (
    household_id TEXT NOT NULL,
    capture_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    shop_id TEXT,
    kind TEXT NOT NULL CHECK (kind IN ('package_photo', 'recipe_ocr', 'barcode', 'receipt_line', 'speech')),
    private_media_ref TEXT,
    original_text TEXT,
    locale TEXT NOT NULL,
    proposed_fields_json TEXT NOT NULL CHECK (json_valid(proposed_fields_json)),
    state TEXT NOT NULL CHECK (state IN ('draft', 'reviewed', 'discarded')),
    PRIMARY KEY (household_id, capture_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, device_id) REFERENCES device (household_id, device_id),
    FOREIGN KEY (household_id, shop_id) REFERENCES shop (household_id, shop_id)
) STRICT;

CREATE TABLE speech_alias (
    household_id TEXT NOT NULL,
    alias_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    locale TEXT NOT NULL,
    recognized TEXT NOT NULL,
    replacement TEXT NOT NULL,
    PRIMARY KEY (household_id, alias_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, device_id, locale, recognized),
    FOREIGN KEY (household_id, device_id) REFERENCES device (household_id, device_id)
) STRICT;

CREATE TABLE device_setting (
    household_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    settings_json TEXT NOT NULL CHECK (json_valid(settings_json)),
    PRIMARY KEY (household_id, device_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, device_id) REFERENCES device (household_id, device_id)
) STRICT;

CREATE TABLE reminder (
    household_id TEXT NOT NULL,
    reminder_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    need_id TEXT,
    offer_id TEXT,
    fire_at TEXT NOT NULL,
    zone TEXT NOT NULL,
    quiet_hours TEXT,
    expires_at TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0,1)),
    PRIMARY KEY (household_id, reminder_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, device_id) REFERENCES device (household_id, device_id),
    FOREIGN KEY (household_id, need_id) REFERENCES need (household_id, need_id),
    FOREIGN KEY (household_id, offer_id) REFERENCES store_offer (household_id, offer_id),
    CHECK ((need_id IS NULL) != (offer_id IS NULL))
) STRICT;

CREATE TABLE shared_view (
    household_id TEXT NOT NULL,
    view_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    token_hash TEXT NOT NULL,
    scope TEXT NOT NULL CHECK (scope IN ('read', 'propose')),
    expires_at TEXT NOT NULL,
    revoked_at TEXT,
    allowlist_json TEXT NOT NULL CHECK (json_valid(allowlist_json)),
    PRIMARY KEY (household_id, view_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, token_hash),
    FOREIGN KEY (household_id, shop_id) REFERENCES shop (household_id, shop_id)
) STRICT;

CREATE TABLE file_projection (
    household_id TEXT NOT NULL,
    file_id TEXT NOT NULL,
    origin_ref TEXT NOT NULL,
    source_record_ref TEXT NOT NULL,
    source_revision_ref TEXT NOT NULL,
    projection_digest TEXT NOT NULL,
    content_digest TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('backup', 'helper', 'recipe_library', 'readable')),
    format_version INTEGER NOT NULL CHECK (format_version > 0),
    saved_at TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('preview', 'imported', 'quarantined', 'cancelled', 'exported')),
    manifest_json TEXT NOT NULL CHECK (json_valid(manifest_json)),
    PRIMARY KEY (household_id, file_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, origin_ref, source_record_ref, source_revision_ref, projection_digest, content_digest)
) STRICT;

CREATE TABLE tombstone (
    household_id TEXT NOT NULL,
    deletion_id TEXT NOT NULL,
    entity_kind TEXT NOT NULL,
    opaque_entity_ref TEXT NOT NULL,
    deleted_at TEXT NOT NULL,
    deletion_cursor TEXT NOT NULL,
    PRIMARY KEY (household_id, deletion_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, entity_kind, opaque_entity_ref)
) STRICT;

CREATE TABLE feedback (
    household_id TEXT NOT NULL,
    feedback_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    consent_version TEXT NOT NULL,
    eligible_week TEXT NOT NULL,
    outcome TEXT NOT NULL CHECK (outcome IN ('acted', 'unchanged', 'late', 'unknown', 'already_knew', 'wrong')),
    comparator_code TEXT,
    PRIMARY KEY (household_id, feedback_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, eligible_week),
    FOREIGN KEY (household_id, shop_id) REFERENCES shop (household_id, shop_id)
) STRICT;


-- Immutable audit facts; signed corrections append events/revisions.
CREATE TRIGGER immutable_event BEFORE UPDATE ON event
BEGIN SELECT RAISE(ABORT, 'append a new event record'); END;
CREATE TRIGGER immutable_operation BEFORE UPDATE ON operation
BEGIN SELECT RAISE(ABORT, 'append a new operation record'); END;
CREATE TRIGGER immutable_shop_revision BEFORE UPDATE ON shop_revision
BEGIN SELECT RAISE(ABORT, 'append a new shop_revision record'); END;
CREATE TRIGGER immutable_handoff BEFORE UPDATE ON handoff
BEGIN SELECT RAISE(ABORT, 'append a new handoff record'); END;
CREATE TRIGGER immutable_handoff_action BEFORE UPDATE ON handoff_action
BEGIN SELECT RAISE(ABORT, 'append a new handoff_action record'); END;
CREATE TRIGGER immutable_usable_observation BEFORE UPDATE ON usable_observation
BEGIN SELECT RAISE(ABORT, 'append a new usable_observation record'); END;

-- The scalar active shopper is unique by construction. Increment the epoch even
-- when a former holder regains authority (ABA). Grant validation also occurs at
-- request time, not just when creating the shop row.
CREATE TRIGGER shop_insert_adult BEFORE INSERT ON shop
WHEN NOT EXISTS (SELECT 1 FROM member WHERE household_id=NEW.household_id
    AND member_id=NEW.shopper_id AND kind='adult' AND state='active')
BEGIN SELECT RAISE(ABORT,'active adult shopper required'); END;
CREATE TRIGGER shop_update_authority BEFORE UPDATE OF shopper_id, authority_epoch ON shop
WHEN NOT EXISTS (SELECT 1 FROM member WHERE household_id=NEW.household_id
    AND member_id=NEW.shopper_id AND kind='adult' AND state='active')
 OR (NEW.shopper_id <> OLD.shopper_id AND NEW.authority_epoch <> OLD.authority_epoch+1)
 OR NEW.authority_epoch < OLD.authority_epoch
BEGIN SELECT RAISE(ABORT,'invalid authority transition'); END;

CREATE INDEX open_requests ON request(household_id, target_shop_id, status, received_at);
CREATE INDEX dated_meals ON meal_slot(household_id, local_date, slot_id);
CREATE INDEX quote_history ON price_quote(household_id, branch, mode, observed_at);
CREATE UNIQUE INDEX usable_root ON usable_observation(household_id, lot_id)
    WHERE supersedes_id IS NULL;

-- Reusable definitions. The meal row is the current display projection. Copy a committed template when planning a week.
CREATE TABLE meal_template_revision (
    household_id TEXT NOT NULL,
    template_revision_id TEXT NOT NULL,
    meal_id TEXT NOT NULL,
    parent_template_revision_id TEXT,
    version_no INTEGER NOT NULL CHECK (version_no > 0),
    author_id TEXT NOT NULL,
    title TEXT NOT NULL,
    source_kind TEXT NOT NULL CHECK (source_kind IN ('manual', 'library', 'idea', 'ocr')),
    source_ref TEXT,
    notes TEXT,
    yield_id TEXT,
    prep_minutes INTEGER CHECK (prep_minutes >= 0),
    rules_json TEXT NOT NULL CHECK (json_valid(rules_json)),
    created_at TEXT NOT NULL,
    PRIMARY KEY (household_id, template_revision_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, meal_id, template_revision_id),
    UNIQUE (household_id, meal_id, version_no),
    FOREIGN KEY (household_id, meal_id) REFERENCES meal (household_id, meal_id),
    FOREIGN KEY (household_id, meal_id, parent_template_revision_id) REFERENCES meal_template_revision (household_id, meal_id, template_revision_id),
    FOREIGN KEY (household_id, author_id) REFERENCES member (household_id, member_id),
    FOREIGN KEY (household_id, yield_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

CREATE TABLE meal_ingredient (
    household_id TEXT NOT NULL,
    ingredient_version_id TEXT NOT NULL,
    template_revision_id TEXT NOT NULL,
    ingredient_key TEXT NOT NULL,
    position INTEGER NOT NULL CHECK (position > 0),
    original_text TEXT NOT NULL,
    source_locale TEXT NOT NULL,
    quantity_id TEXT NOT NULL,
    purpose TEXT NOT NULL,
    dish_specific_rules_json TEXT NOT NULL CHECK (json_valid(dish_specific_rules_json)),
    PRIMARY KEY (household_id, ingredient_version_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, template_revision_id, ingredient_key),
    UNIQUE (household_id, template_revision_id, position),
    FOREIGN KEY (household_id, template_revision_id) REFERENCES meal_template_revision (household_id, template_revision_id),
    FOREIGN KEY (household_id, quantity_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

CREATE TABLE rotation (
    household_id TEXT NOT NULL,
    rotation_id TEXT NOT NULL,
    title TEXT NOT NULL,
    cycle_days INTEGER NOT NULL CHECK (cycle_days > 0),
    revision_no INTEGER NOT NULL CHECK (revision_no > 0),
    PRIMARY KEY (household_id, rotation_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id)
) STRICT;

CREATE TABLE rotation_slot (
    household_id TEXT NOT NULL,
    rotation_slot_id TEXT NOT NULL,
    rotation_id TEXT NOT NULL,
    day_offset INTEGER NOT NULL CHECK (day_offset >= 0),
    meal_id TEXT NOT NULL,
    template_revision_id TEXT NOT NULL,
    servings_id TEXT,
    purpose TEXT NOT NULL,
    PRIMARY KEY (household_id, rotation_slot_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, rotation_id) REFERENCES rotation (household_id, rotation_id),
    FOREIGN KEY (household_id, meal_id, template_revision_id) REFERENCES meal_template_revision (household_id, meal_id, template_revision_id),
    FOREIGN KEY (household_id, servings_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

CREATE TABLE staple (
    household_id TEXT NOT NULL,
    staple_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    original_text TEXT NOT NULL,
    purpose TEXT NOT NULL,
    usual_branch TEXT,
    usual_quantity_id TEXT,
    approved_at TEXT,
    retired_at TEXT,
    PRIMARY KEY (household_id, staple_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, owner_id) REFERENCES member (household_id, member_id),
    FOREIGN KEY (household_id, usual_quantity_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;

CREATE TABLE deferral (
    household_id TEXT NOT NULL,
    deferral_id TEXT NOT NULL,
    staple_id TEXT,
    request_id TEXT,
    origin_shop_id TEXT NOT NULL,
    origin_revision_id TEXT NOT NULL,
    origin_line_ref TEXT,
    original_text TEXT NOT NULL,
    quantity_id TEXT,
    purpose TEXT NOT NULL,
    branch TEXT,
    due_at TEXT,
    target_shop_id TEXT,
    state TEXT NOT NULL CHECK (state IN ('deferred', 'review', 'accepted', 'handled', 'dismissed')),
    decision_actor_id TEXT,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (household_id, deferral_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    FOREIGN KEY (household_id, staple_id) REFERENCES staple (household_id, staple_id),
    FOREIGN KEY (household_id, request_id) REFERENCES request (household_id, request_id),
    FOREIGN KEY (household_id, origin_shop_id, origin_revision_id) REFERENCES shop_revision (household_id, shop_id, revision_id),
    FOREIGN KEY (household_id, target_shop_id) REFERENCES shop (household_id, shop_id),
    FOREIGN KEY (household_id, quantity_id) REFERENCES quantity (household_id, quantity_id),
    FOREIGN KEY (household_id, decision_actor_id) REFERENCES member (household_id, member_id)
) STRICT;


-- A line in each branch retains its own offer and evidence. Stored totals are reviewed projections of these lines and charges.
CREATE TABLE quote_option_line (
    household_id TEXT NOT NULL,
    option_line_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    option_id TEXT NOT NULL,
    line_id TEXT NOT NULL,
    quote_id TEXT,
    required_quantity_id TEXT NOT NULL,
    pack_count INTEGER CHECK (pack_count >= 0),
    availability TEXT NOT NULL CHECK (availability IN ('available', 'unavailable', 'partial', 'unknown')),
    note TEXT,
    PRIMARY KEY (household_id, option_line_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, option_id, line_id),
    FOREIGN KEY (household_id, shop_id, option_id) REFERENCES quote_option (household_id, shop_id, option_id),
    FOREIGN KEY (household_id, shop_id, line_id) REFERENCES shop_line (household_id, shop_id, line_id),
    FOREIGN KEY (household_id, shop_id, line_id, quote_id) REFERENCES price_quote (household_id, shop_id, line_id, quote_id),
    FOREIGN KEY (household_id, required_quantity_id) REFERENCES quantity (household_id, quantity_id)
) STRICT;


-- Reusable proposals. Each revision records the author, originating shop head and authority epoch under review.
CREATE TABLE proposal (
    household_id TEXT NOT NULL,
    proposal_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    owner_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('guest', 'away', 'pairing', 'meal_week', 'idea', 'store_change', 'repair')),
    state TEXT NOT NULL CHECK (state IN ('draft', 'submitted', 'stale', 'applied', 'dismissed')),
    created_at TEXT NOT NULL,
    PRIMARY KEY (household_id, proposal_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, shop_id, proposal_id),
    FOREIGN KEY (household_id, shop_id) REFERENCES shop (household_id, shop_id),
    FOREIGN KEY (household_id, owner_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE proposal_revision (
    household_id TEXT NOT NULL,
    proposal_revision_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    proposal_id TEXT NOT NULL,
    revision_no INTEGER NOT NULL CHECK (revision_no > 0),
    base_revision_id TEXT NOT NULL,
    base_authority_epoch INTEGER NOT NULL CHECK (base_authority_epoch > 0),
    editor_id TEXT NOT NULL,
    inputs_json TEXT NOT NULL CHECK (json_valid(inputs_json)),
    effects_json TEXT NOT NULL CHECK (json_valid(effects_json)),
    reviewed_at TEXT NOT NULL,
    PRIMARY KEY (household_id, proposal_revision_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, proposal_id, revision_no),
    UNIQUE (household_id, shop_id, proposal_id, proposal_revision_id),
    FOREIGN KEY (household_id, shop_id, proposal_id) REFERENCES proposal (household_id, shop_id, proposal_id),
    FOREIGN KEY (household_id, shop_id, base_revision_id) REFERENCES shop_revision (household_id, shop_id, revision_id),
    FOREIGN KEY (household_id, editor_id) REFERENCES member (household_id, member_id)
) STRICT;

CREATE TABLE proposal_application (
    household_id TEXT NOT NULL,
    application_id TEXT NOT NULL,
    shop_id TEXT NOT NULL,
    proposal_id TEXT NOT NULL,
    proposal_revision_id TEXT NOT NULL,
    shopper_id TEXT NOT NULL,
    operation_id TEXT NOT NULL,
    result_revision_id TEXT NOT NULL,
    applied_at TEXT NOT NULL,
    PRIMARY KEY (household_id, application_id),
    FOREIGN KEY (household_id) REFERENCES household (household_id),
    UNIQUE (household_id, proposal_id),
    UNIQUE (household_id, operation_id),
    FOREIGN KEY (household_id, shop_id, proposal_id, proposal_revision_id) REFERENCES proposal_revision (household_id, shop_id, proposal_id, proposal_revision_id),
    FOREIGN KEY (household_id, shopper_id, operation_id) REFERENCES operation (household_id, actor_id, operation_id),
    FOREIGN KEY (household_id, shop_id, result_revision_id) REFERENCES shop_revision (household_id, shop_id, revision_id)
) STRICT;

CREATE TRIGGER guard_proposal_application BEFORE INSERT ON proposal_application
WHEN NOT EXISTS (
    SELECT 1 FROM proposal_revision r
    JOIN shop s USING (household_id, shop_id)
    JOIN shop_head h USING (household_id, shop_id)
    JOIN proposal p USING (household_id, shop_id, proposal_id)
    JOIN shop_revision result ON result.household_id=s.household_id
        AND result.shop_id=s.shop_id AND result.revision_id=NEW.result_revision_id
    WHERE r.household_id=NEW.household_id AND r.proposal_revision_id=NEW.proposal_revision_id
        AND r.proposal_id=NEW.proposal_id AND s.shop_id=NEW.shop_id AND p.state IN ('draft','submitted')
        AND r.base_authority_epoch=s.authority_epoch AND s.phase='draft'
        AND r.base_revision_id=h.revision_id AND result.parent_id=h.revision_id
        AND r.revision_no=(SELECT MAX(latest.revision_no) FROM proposal_revision latest
            WHERE latest.household_id=p.household_id AND latest.proposal_id=p.proposal_id)
        AND s.shopper_id=NEW.shopper_id)
BEGIN SELECT RAISE(ABORT,'proposal requires current shopper, head, proposal revision and epoch'); END;

CREATE TRIGGER immutable_quantity BEFORE UPDATE ON quantity
BEGIN SELECT RAISE(ABORT, 'append a new quantity record'); END;
CREATE TRIGGER immutable_price_quote BEFORE UPDATE ON price_quote
BEGIN SELECT RAISE(ABORT, 'append a new price_quote record'); END;
CREATE TRIGGER immutable_meal_template_revision BEFORE UPDATE ON meal_template_revision
BEGIN SELECT RAISE(ABORT, 'append a new meal_template_revision record'); END;
CREATE TRIGGER immutable_meal_ingredient BEFORE UPDATE ON meal_ingredient
BEGIN SELECT RAISE(ABORT, 'append a new meal_ingredient record'); END;
CREATE TRIGGER immutable_proposal_revision BEFORE UPDATE ON proposal_revision
BEGIN SELECT RAISE(ABORT, 'append a new proposal_revision record'); END;
CREATE TRIGGER immutable_proposal_application BEFORE UPDATE ON proposal_application
BEGIN SELECT RAISE(ABORT, 'append a new proposal_application record'); END;
COMMIT;


-- Gen 2 structural guarantees. Service sessions additionally enforce current rights,
-- verified evidence, trusted time and transitions; FKs are not authorization.
CREATE TABLE planning_access (
    household_id TEXT NOT NULL, member_id TEXT NOT NULL,
    PRIMARY KEY (household_id, member_id),
    FOREIGN KEY (household_id, member_id) REFERENCES member (household_id, member_id)
) STRICT;
CREATE TABLE guardian_relationship (
    household_id TEXT NOT NULL, child_id TEXT NOT NULL, guardian_id TEXT NOT NULL,
    proof_ref TEXT NOT NULL CHECK(length(trim(proof_ref))>0),
    CHECK(child_id != guardian_id),
    PRIMARY KEY (household_id, child_id, guardian_id),
    FOREIGN KEY (household_id, child_id) REFERENCES member (household_id, member_id),
    FOREIGN KEY (household_id, guardian_id) REFERENCES member (household_id, member_id)
) STRICT;
CREATE TRIGGER verified_relationship BEFORE INSERT ON guardian_relationship
WHEN NOT EXISTS (SELECT 1 FROM member g JOIN member c USING (household_id)
 WHERE g.household_id=NEW.household_id AND g.member_id=NEW.guardian_id AND c.member_id=NEW.child_id
 AND g.kind='adult' AND g.state='active' AND g.verified_subject IS NOT NULL AND c.kind='child'
 AND c.state IN ('invited','active'))
BEGIN SELECT RAISE(ABORT,'verified guardian and eligible child required'); END;
CREATE TRIGGER consent_eligibility BEFORE INSERT ON guardian_consent
WHEN NOT EXISTS (SELECT 1 FROM guardian_relationship r JOIN member g ON
 g.household_id=r.household_id AND g.member_id=r.guardian_id JOIN member c ON
 c.household_id=r.household_id AND c.member_id=r.child_id WHERE r.household_id=NEW.household_id
 AND r.child_id=NEW.child_id AND r.guardian_id=NEW.guardian_id AND g.kind='adult'
 AND g.state='active' AND g.verified_subject IS NOT NULL AND c.kind='child' AND c.state IN ('invited','active'))
 OR length(trim(NEW.verification_reference))=0 OR length(trim(NEW.notice_version))=0
BEGIN SELECT RAISE(ABORT,'current relationship and consent evidence required'); END;
CREATE TRIGGER consent_once BEFORE UPDATE ON guardian_consent
WHEN OLD.revoked_at IS NOT NULL OR NEW.revoked_at IS NULL OR
 (OLD.household_id,OLD.consent_id,OLD.child_id,OLD.guardian_id,OLD.granted_at,OLD.notice_version,OLD.verification_reference)
 IS NOT (NEW.household_id,NEW.consent_id,NEW.child_id,NEW.guardian_id,NEW.granted_at,NEW.notice_version,NEW.verification_reference)
BEGIN SELECT RAISE(ABORT,'revoke once; a new grant needs fresh evidence'); END;
CREATE TRIGGER member_kind_fixed BEFORE UPDATE OF kind ON member WHEN OLD.kind!=NEW.kind
BEGIN SELECT RAISE(ABORT,'replace identity under verified enrollment'); END;
CREATE TRIGGER transfer_before_revoking BEFORE UPDATE OF state ON member WHEN NEW.state!='active'
 AND EXISTS (SELECT 1 FROM shop WHERE household_id=OLD.household_id AND shopper_id=OLD.member_id AND phase!='closed')
BEGIN SELECT RAISE(ABORT,'transfer or close active shops first'); END;
CREATE TRIGGER planning_eligibility BEFORE INSERT ON planning_access
WHEN NOT EXISTS (SELECT 1 FROM member WHERE household_id=NEW.household_id AND member_id=NEW.member_id AND kind='adult' AND state='active')
BEGIN SELECT RAISE(ABORT,'planning grant requires active adult'); END;
CREATE TRIGGER after_access_ends AFTER UPDATE OF state ON member WHEN NEW.state!='active'
BEGIN
 DELETE FROM seat WHERE household_id=OLD.household_id AND member_id=OLD.member_id;
 DELETE FROM planning_access WHERE household_id=OLD.household_id AND member_id=OLD.member_id;
 UPDATE guardian_consent SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE household_id=OLD.household_id
 AND (child_id=OLD.member_id OR guardian_id=OLD.member_id) AND revoked_at IS NULL;
END;
CREATE TRIGGER on_relationship_removed BEFORE DELETE ON guardian_relationship
BEGIN
 UPDATE guardian_consent SET revoked_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')
 WHERE household_id=OLD.household_id AND child_id=OLD.child_id AND guardian_id=OLD.guardian_id AND revoked_at IS NULL;
END;
CREATE UNIQUE INDEX accepted_file_identity ON file_projection
 (household_id,origin_ref,source_record_ref,source_revision_ref,projection_digest)
 WHERE state='imported';
CREATE TRIGGER preserve_import_decision BEFORE UPDATE ON file_projection
WHEN OLD.state IN ('imported','quarantined') OR
 (OLD.household_id,OLD.file_id,OLD.origin_ref,OLD.source_record_ref,OLD.source_revision_ref,OLD.projection_digest,OLD.content_digest)
 IS NOT (NEW.household_id,NEW.file_id,NEW.origin_ref,NEW.source_record_ref,NEW.source_revision_ref,NEW.projection_digest,NEW.content_digest)
BEGIN SELECT RAISE(ABORT,'stage separately; canonical import evidence is immutable'); END;

-- Compact receipts retain only retry identity, not response, note, request text or prices.
CREATE TABLE retired_operation (
 household_id TEXT NOT NULL, actor_id TEXT NOT NULL, client_key TEXT NOT NULL,
 PRIMARY KEY (household_id,actor_id,client_key)
) STRICT;
CREATE TRIGGER retire_receipt AFTER DELETE ON operation BEGIN
 INSERT INTO retired_operation VALUES (OLD.household_id,OLD.actor_id,OLD.client_key) ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER compact_response AFTER DELETE ON operation_response BEGIN
 INSERT INTO retired_operation SELECT household_id,actor_id,client_key FROM operation
 WHERE household_id=OLD.household_id AND operation_id=OLD.operation_id ON CONFLICT DO NOTHING;
END;
CREATE TRIGGER immutable_response BEFORE UPDATE ON operation_response
BEGIN SELECT RAISE(ABORT,'never rewrite the original response'); END;
CREATE TRIGGER no_response_recreation BEFORE INSERT ON operation_response
WHEN EXISTS(SELECT 1 FROM operation o JOIN retired_operation r USING (household_id,actor_id,client_key)
 WHERE o.household_id=NEW.household_id AND o.operation_id=NEW.operation_id)
BEGIN SELECT RAISE(ABORT,'compacted response cannot be recreated'); END;
CREATE TRIGGER no_retired_replay BEFORE INSERT ON operation
WHEN EXISTS(SELECT 1 FROM retired_operation WHERE household_id=NEW.household_id AND actor_id=NEW.actor_id AND client_key=NEW.client_key)
BEGIN SELECT RAISE(ABORT,'receipt retired: refresh; never repeat the effect'); END;
CREATE TRIGGER no_posted_rewrite BEFORE UPDATE ON ledger_entry WHEN OLD.status!='pending'
BEGIN SELECT RAISE(ABORT,'append an evidenced correction'); END;
CREATE TRIGGER immutable_seat BEFORE UPDATE ON seat BEGIN SELECT RAISE(ABORT,'append evidence or explicitly reassign'); END;
CREATE TRIGGER immutable_planning_access BEFORE UPDATE ON planning_access BEGIN SELECT RAISE(ABORT,'append evidence or explicitly reassign'); END;
CREATE TRIGGER immutable_guardian_relationship BEFORE UPDATE ON guardian_relationship BEGIN SELECT RAISE(ABORT,'append evidence or explicitly reassign'); END;
CREATE TRIGGER immutable_placed_order BEFORE UPDATE ON placed_order BEGIN SELECT RAISE(ABORT,'append evidence or explicitly reassign'); END;
CREATE TRIGGER immutable_order_line BEFORE UPDATE ON order_line BEGIN SELECT RAISE(ABORT,'append evidence or explicitly reassign'); END;
CREATE TRIGGER immutable_retired_operation BEFORE UPDATE ON retired_operation BEGIN SELECT RAISE(ABORT,'append evidence or explicitly reassign'); END;

CREATE TRIGGER seat_eligible BEFORE INSERT ON seat
WHEN NOT EXISTS (SELECT 1 FROM member a JOIN entitlement e USING (household_id)
 WHERE a.household_id=NEW.household_id AND a.member_id=NEW.member_id AND a.kind='adult' AND a.state='active'
 AND e.entitlement_id=NEW.entitlement_id AND e.state IN ('active','grace','cancelled')
 AND e.verified_at IS NOT NULL AND e.valid_until IS NOT NULL)
BEGIN SELECT RAISE(ABORT,'assignment requires active adult and verified paid period'); END;
CREATE TRIGGER ledger_parent_INSERT BEFORE INSERT ON ledger_entry
WHEN NEW.linked_charge_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ledger_entry p
 WHERE p.household_id=NEW.household_id AND p.shop_id=NEW.shop_id AND p.currency=NEW.currency
 AND p.entry_id=NEW.linked_charge_id AND p.kind='charge' AND p.status='posted')
BEGIN SELECT RAISE(ABORT,'link a posted charge in the same shop and currency'); END;
CREATE TRIGGER ledger_parent_UPDATE BEFORE UPDATE ON ledger_entry
WHEN NEW.linked_charge_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ledger_entry p
 WHERE p.household_id=NEW.household_id AND p.shop_id=NEW.shop_id AND p.currency=NEW.currency
 AND p.entry_id=NEW.linked_charge_id AND p.kind='charge' AND p.status='posted')
BEGIN SELECT RAISE(ABORT,'link a posted charge in the same shop and currency'); END;

-- Command/authorization rules (FKs validate namespace, not actor permissions)
-- • Redeem invite once using an atomic unexpired, unredeemed, unrevoked update.
--   Verify adult guardian and child identities + current consent for service access.
--   Require active paid entitlement, target adult, two distinct seats, verified
--   billing identity, correct shop grant and current actor independently. Cancelled
--   membership stays effective only through its verified paid-through time.
-- • Authenticate actor/device binding and assert non-revocation in the transaction.
--   Look up (household_id, authenticated actor_id, client_key) before applying.
--   The stable server operation_id identifies one result across retries/devices.
--   After checking current read access, identical digest returns stored result;
--   changed body/actor fails. Commit event, revision/head, projections, request
--   outcome and operation together. Outbox delivery and response loss are retryable.
--   Contributor read DTO is allowlisted by authenticated author; never join quotes
--   or budgets into it. Lock/placement freezes reviewed lines. Unresolved and late
--   requests route next; a stale offline placement is an attributed external report.
-- • For every planning write use the active base head and compare expected shop,
--   request, preview and authority revisions as applicable. Advance revision_no
--   together with the head. Sibling imports may share display numbers; never use
--   one as an identity. Record reversals as new commits. Only the designated
--   shopper controls checkout. Require an authorized handover before deactivating
--   the current shopper. Offline local drafts may remain pending indefinitely.
-- • Persist the selected shop-specific meal occurrences, protected lunches,
--   partial plate/side portions and alone/guest counts independently of usuals.
--   Only a reviewed idea whose ingredients pass household rules is approvable.
--   Unknown yield prevents coverage. Approval, scheduling and applying changes
--   have separate commands. Save meal_template_revision and its complete
--   ingredient set in one transaction; then update the meal projection and
--   usual_revision. Disallow later ingredient inserts on a published revision.
--   A rotation_slot day_offset must be below its rotation.cycle_days. Materialize
--   independent meal_slot copies, retaining the exact template revision used.
--   Deferral origin_line_ref identifies the historical line in the immutable
--   origin revision. Deleting a draft line cannot remove this independent record.
--   Never infer a
--   permanent substitution from a successful one-week repair.
-- • Compare quotes from exactly two options and one commitment/base revision.
--   Require both options before ranking. quote_option_line links each line to
--   store-specific price_quote evidence. Check branch, mode, slot, currency
--   and eligibility against its option; missing evidence stays unresolved. Confirm like
--   quantities, same currency, fee applicability and relevance before comparing.
--   Keep store-only, travel money and minutes distinct. Unknowns prevent a winner.
--   Adopting starts a review; invalidates prior store prices and pending offers.
--   For proposal apply, verify active grants/entitlement, stage child result
--   revision and operation, record proposal_application BEFORE advancing head,
--   mark proposal applied and advance the head in the same transaction. Reject
--   any stale/replayed input without leaking a partial operation or result.
--   Preview and proposal edits append authored proposal revisions; they do not
--   mutate any shop line. The current shopper alone commits reviewed effects.
-- • Quantities aggregate only in compatible units on an explicit basis. Reserve
--   from confirmed usable lots; in a single transaction cap allocations by usable
--   stock and demand and recalculate on corrections. Record a new observation,
--   never a new delivery, for an updated usable count. For a partial original,
--   compare alternatives with all other committed lines and applicable fees.
-- • Each posted ledger movement contributes once. Pending/included entries never
--   reduce posted cash. Match charge, currency and net basis before linking credit.
--   Mark a pickup settled only with complete verified movements and known top-ups.
-- • Helper export starts with a fresh allowlist, optional fields per disclosure.
--   For imports validate schema/version, scope, digest and deletions before writes;
--   quarantine mismatched content for the same origin/revision/projection. Preserve
--   siblings and missing fields. Never import billing, device/guardian grants or
--   authority from backup. Store validated payloads in a protected local file
--   store; source_ref fields in manifests are provenance, not live foreign keys.
-- • Operational deletes execute scoped erasure and media cleanup with tombstones.
--   Ordinary runtime cannot delete or replace immutable audit facts. Purge is a
--   separately authorized transaction. Operational API authorization, time checks,
--   field encryption/key handling, retention and rate limits live outside SQLite.
-- • Persist no audio by default. Readback derives the visible dated note in the
--   selected language, independently of system dictation/VoiceOver. Widget, print,
--   helper and measurement projections each use their own allowlist; feedback
--   contains no grocery text. Never use this schema as a public query interface.

