export const MAX_JOURNAL_RECORDS=10_000;
export const MAX_JOURNAL_BYTES=32*1024*1024;
export const MAX_SOURCE_EVENT_BYTES=1024*1024;

// PostgreSQL's JSONB text adds whitespace to the compact event projection.
// Keep its transport bound separate from the signed canonical archive bound.
export const MAX_RESTORE_JSON_BYTES=2*MAX_JOURNAL_BYTES;

// A resolved intent has the same event bytes. The sequence can gain four
// digits and the word "rollback" is two bytes longer than "intent".
export const MAX_INTENT_RESOLUTION_OVERHEAD=6;
