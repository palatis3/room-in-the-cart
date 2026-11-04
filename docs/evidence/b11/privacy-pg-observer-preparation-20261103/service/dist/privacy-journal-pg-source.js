import { createHash, createPublicKey } from 'node:crypto';
import { createRequire } from 'node:module';
import { Pool } from 'pg';
import { z } from 'zod';
import { journalHash, validatePrivacyRestoreEvents } from './privacy-journal.js';
import { durableJournalPublicKeyFingerprint, durableJournalScopeDigest, verifyDurableAdmissionReceipt } from './privacy-journal-durable.js';
const MAX_EVENTS = 10000, MAX_EVENT_BYTES = 1048576, MAX_TIMER = 2147483647;
const hash = z.string().regex(/^[0-9a-f]{64}$/);
const uuid = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
const identifier = z.string().min(1).max(63).regex(/^[^\x00-\x1f\x7f]+$/);
const oid = z.string().regex(/^[1-9][0-9]{0,9}$/).refine(v => Number(v) <= 4294967295);
const connectionSchema = z.object({ host: z.string().min(1).max(300).regex(/^[^\x00-\x1f\x7f]+$/), port: z.number().int().min(1).max(65535), database: identifier, user: identifier, password: z.string().max(16384).optional(), tls: z.object({ ca: z.string().min(1).max(262144), servername: identifier }).strict().optional() }).strict();
const eventSchema = z.object({ eventId: uuid, payloadDigest: hash, payload: z.object({ version: z.literal(1), eventId: uuid, lineage: uuid, schemaDigest: hash, configurationId: z.string().min(1).max(100), jobId: uuid, kind: z.enum(['acceptance', 'target_erased', 'source_completed', 'source_pending']), data: z.record(z.string(), z.unknown()) }).strict() }).strict();
const bindingSchema = z.object({ sourceIdentity: z.string().min(1).max(300), databaseName: identifier, databaseOid: oid, observerRole: identifier, ownerRole: identifier, lineage: uuid, schemaDigest: hash, configurationId: z.string().min(1).max(100), fenced: z.boolean() }).strict();
const catalogSchema = z.object({ databaseName: identifier, databaseOid: oid, sessionRole: identifier, currentRole: identifier, roleOid: oid, roleCanLogin: z.boolean(), dangerousReachableRole: z.boolean(), ownsUserObject: z.boolean(), databaseCreate: z.boolean(), databaseTemporary: z.boolean(), databaseConnect: z.boolean(), schemaCreate: z.boolean(), sourceSchemaUsage: z.boolean(), rawRelationPrivilege: z.boolean(), extraFunctionExecute: z.boolean(), functionsValid: z.boolean() }).strict();
/** A failed COMMIT response never proves that a previously issued ack rolled back. */
export class PostgresCommittedSourceCallError extends Error {
    acknowledgementMayHaveCommitted;
    sqlDispatched;
    constructor(message, sqlDispatched, acknowledgementMayHaveCommitted, cause) {
        super(message, { cause });
        this.name = 'PostgresCommittedSourceCallError';
        this.sqlDispatched = sqlDispatched;
        this.acknowledgementMayHaveCommitted = acknowledgementMayHaveCommitted;
    }
}
const signatures = Object.freeze([
    'ritc.privacy_journal_source_binding(text,uuid,text,text,oid)',
    'ritc.privacy_journal_source_event(text,uuid,text,text,oid,uuid)',
    'ritc.privacy_journal_source_acceptance(text,uuid,text,text,oid,uuid)',
    'ritc.privacy_journal_source_unacknowledged(text,uuid,text,text,oid,uuid,integer)',
    'ritc.privacy_journal_source_acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text)',
]);
// Effective privileges are checked, including column grants and inherited groups.
// A harmless group is allowed; a reachable privileged/app/worker/owner role is not.
const CATALOG_SQL = `WITH actor AS (
 SELECT * FROM pg_catalog.pg_roles WHERE rolname=session_user
), expected AS (
 SELECT pg_catalog.to_regprocedure(signature)::oid AS oid FROM pg_catalog.unnest($1::text[]) signature
), user_schema AS (
 SELECT * FROM pg_catalog.pg_namespace WHERE nspname !~ '^pg_' AND nspname<>'information_schema'
)
SELECT pg_catalog.jsonb_build_object(
 'databaseName',pg_catalog.current_database(),
 'databaseOid',(SELECT oid::text FROM pg_catalog.pg_database WHERE datname=pg_catalog.current_database()),
 'sessionRole',session_user,'currentRole',current_user,'roleOid',a.oid::text,'roleCanLogin',a.rolcanlogin,
 'dangerousReachableRole',EXISTS(SELECT 1 FROM pg_catalog.pg_roles r WHERE pg_catalog.pg_has_role(a.oid,r.oid,'MEMBER') AND
  (r.rolsuper OR r.rolbypassrls OR r.rolcreatedb OR r.rolcreaterole OR r.rolreplication OR r.oid=$2::oid OR r.rolname IN('ritc_app','ritc_worker'))),
 'ownsUserObject',EXISTS(SELECT 1 FROM user_schema n WHERE pg_catalog.pg_has_role(a.oid,n.nspowner,'MEMBER'))
  OR EXISTS(SELECT 1 FROM pg_catalog.pg_class r JOIN user_schema n ON n.oid=r.relnamespace WHERE pg_catalog.pg_has_role(a.oid,r.relowner,'MEMBER'))
  OR EXISTS(SELECT 1 FROM pg_catalog.pg_proc p JOIN user_schema n ON n.oid=p.pronamespace WHERE pg_catalog.pg_has_role(a.oid,p.proowner,'MEMBER')),
 'databaseCreate',pg_catalog.has_database_privilege(a.oid,pg_catalog.current_database(),'CREATE'),
 'databaseTemporary',pg_catalog.has_database_privilege(a.oid,pg_catalog.current_database(),'TEMPORARY'),
 'databaseConnect',pg_catalog.has_database_privilege(a.oid,pg_catalog.current_database(),'CONNECT'),
 'schemaCreate',EXISTS(SELECT 1 FROM user_schema n WHERE pg_catalog.has_schema_privilege(a.oid,n.oid,'CREATE')),
 'sourceSchemaUsage',pg_catalog.has_schema_privilege(a.oid,'ritc','USAGE'),
 'rawRelationPrivilege',EXISTS(SELECT 1 FROM pg_catalog.pg_class r JOIN user_schema n ON n.oid=r.relnamespace WHERE
  (r.relkind IN('r','p','v','m','f') AND (pg_catalog.has_table_privilege(a.oid,r.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
   OR pg_catalog.has_any_column_privilege(a.oid,r.oid,'SELECT,INSERT,UPDATE,REFERENCES')))
  OR (r.relkind='S' AND pg_catalog.has_sequence_privilege(a.oid,r.oid,'USAGE,SELECT,UPDATE'))),
 'extraFunctionExecute',EXISTS(SELECT 1 FROM pg_catalog.pg_proc p JOIN user_schema n ON n.oid=p.pronamespace
  WHERE pg_catalog.has_function_privilege(a.oid,p.oid,'EXECUTE') AND NOT EXISTS(SELECT 1 FROM expected e WHERE e.oid=p.oid)),
 'functionsValid',(SELECT count(*)=5 AND pg_catalog.bool_and(p.oid IS NOT NULL AND p.prosecdef AND p.proowner=$2::oid
  AND pg_catalog.pg_get_userbyid(p.proowner)=$3::text AND p.proconfig=ARRAY['search_path=pg_catalog']::text[]
  AND pg_catalog.has_function_privilege(a.oid,p.oid,'EXECUTE')
  AND NOT pg_catalog.has_function_privilege('ritc_app',p.oid,'EXECUTE')
  AND NOT pg_catalog.has_function_privilege('ritc_worker',p.oid,'EXECUTE')
  AND NOT EXISTS(SELECT 1 FROM pg_catalog.aclexplode(COALESCE(p.proacl,pg_catalog.acldefault('f',p.proowner))) acl
   WHERE acl.grantee=0 AND acl.privilege_type='EXECUTE')) FROM expected e LEFT JOIN pg_catalog.pg_proc p ON p.oid=e.oid)
)::text AS value FROM actor a`;
function freeze(value) { if (value && typeof value === 'object') {
    for (const child of Object.values(value))
        freeze(child);
    Object.freeze(value);
} return value; }
function assertCall(call) {
    if (!call || typeof call.attemptId !== 'string' || call.attemptId.length < 1 || call.attemptId.length > 100 || !Number.isSafeInteger(call.deadlineUnixMs) || !(call.signal instanceof AbortSignal))
        throw Error('Call-owned journal deadline and AbortSignal required');
    call.signal.throwIfAborted();
    if (Date.now() >= call.deadlineUnixMs)
        throw Error('Journal source deadline exceeded');
}
function jsonResult(rows, maxBytes) {
    if (rows.length !== 1 || !rows[0] || Object.keys(rows[0]).length !== 1 || typeof rows[0].value !== 'string' || Buffer.byteLength(rows[0].value, 'utf8') > maxBytes)
        throw Error('Committed source result shape or size conflict');
    return JSON.parse(rows[0].value);
}
/**
 * Uncomposed private source capability. It owns actual pg8 connections, and never
 * relies on query.signal or query_timeout to cancel PostgreSQL work. No app or
 * worker role receives raw table access or an unauthenticated acknowledgement API.
 */
export function createPostgresCommittedSource(input) {
    if (process.env.NODE_PG_FORCE_NATIVE)
        throw Error('Pure JavaScript PostgreSQL driver required');
    // pg's package entry point may bind Pool to a different Client. Supplying our
    // private, exact JS Client keeps the reviewed socket-destruction semantics.
    const JavaScriptClient = createRequire(import.meta.url)('pg/lib/client.js');
    const pins = freeze(structuredClone(input.pins));
    durableJournalScopeDigest(pins);
    const connection = freeze(connectionSchema.parse(input.connection));
    if (!connection.tls && !connection.host.startsWith('/') && !['localhost', '127.0.0.1', '::1'].includes(connection.host))
        throw Error('Verified pinned TLS required for a remote committed source');
    const databaseOid = oid.parse(input.databaseOid), observerRoleOid = oid.parse(input.observerRoleOid), ownerRole = identifier.parse(input.ownerRole), ownerRoleOid = oid.parse(input.ownerRoleOid);
    const applicationName = identifier.parse(input.applicationName), maxConnections = z.number().int().min(1).max(4).parse(input.maxConnections ?? 1);
    if (connection.user === ownerRole || observerRoleOid === ownerRoleOid || ['ritc_app', 'ritc_worker'].includes(connection.user))
        throw Error('Separate committed observer role required');
    let authorityPublicKey;
    if (typeof input.authorityPublicKey === 'string') {
        if (!/^-----BEGIN PUBLIC KEY-----\r?\n(?:[A-Za-z0-9+/=]+\r?\n)+-----END PUBLIC KEY-----\r?\n?$/.test(input.authorityPublicKey))
            throw Error('Public authority SPKI PEM required');
        authorityPublicKey = createPublicKey(input.authorityPublicKey);
    }
    else {
        if (input.authorityPublicKey.type !== 'public')
            throw Error('Public authority key required');
        authorityPublicKey = input.authorityPublicKey;
    }
    if (durableJournalPublicKeyFingerprint(authorityPublicKey) !== pins.authorityPublicKeyFingerprint || pins.authorityPublicKeyFingerprint === pins.publicKeyFingerprint)
        throw Error('Independent committed-source authority key conflict');
    // Truthy fixed values also suppress pg's PGOPTIONS/PGREPLICATION/PGPASSWORD
    // environment fallback (an empty password string alone does not do that).
    const poolConfiguration = { Client: JavaScriptClient, host: connection.host, port: connection.port, database: connection.database, user: connection.user, password: () => connection.password ?? '', ssl: connection.tls ? { ca: connection.tls.ca, servername: connection.tls.servername, rejectUnauthorized: true } : false, sslnegotiation: 'postgres', replication: 'false', options: '-c search_path=pg_catalog', client_encoding: 'UTF8', application_name: applicationName, max: maxConnections, connectionTimeoutMillis: 5000, statement_timeout: 5000, lock_timeout: 5000, idle_in_transaction_session_timeout: 5000, idleTimeoutMillis: 1000, allowExitOnIdle: true, pipeline: false, binary: false };
    const pool = new Pool(poolConfiguration);
    // pg removes idle errored connections before emitting. No credential-bearing log.
    pool.on('error', () => { });
    const common = Object.freeze([pins.sourceIdentity, pins.lineage, pins.schemaDigest, pins.configurationId, databaseOid]);
    let closed = false;
    const activeCalls = new Set();
    async function transaction(original, acknowledgement, work) {
        assertCall(original);
        if (closed)
            throw Error('Committed source is closed');
        const call = Object.freeze({ attemptId: original.attemptId, deadlineUnixMs: original.deadlineUnixMs, signal: original.signal });
        let client, released = false, finished = false, abortReason, sqlDispatched = false, ackCommitDispatched = false;
        const comment = `/* ritc-journal-source:${createHash('sha256').update(call.attemptId).digest('hex')} */ `;
        const failure = (reason) => new PostgresCommittedSourceCallError('Committed source call failed', sqlDispatched, ackCommitDispatched, reason);
        const release = (destroy) => { if (client && !released) {
            released = true;
            client.release(destroy);
        } };
        let rejectCancelled;
        const cancelled = new Promise((_, reject) => { rejectCancelled = reject; });
        const abort = (reason) => {
            if (finished || abortReason !== undefined)
                return;
            abortReason = reason ?? Error('Journal source call aborted');
            // In the fixed non-pipeline pg8 client, release(true) removes the client and
            // client.end() destroys its active socket. No later COMMIT is ever queued.
            release(true);
            rejectCancelled(failure(abortReason));
        };
        const onAbort = () => abort(call.signal.reason);
        activeCalls.add(abort);
        call.signal.addEventListener('abort', onAbort, { once: true });
        // Long deadlines re-arm; timers above the Node limit must never fire early.
        let timer;
        const arm = () => { timer = setTimeout(() => { if (Date.now() >= call.deadlineUnixMs)
            abort(Error('Journal source deadline exceeded'));
        else
            arm(); }, Math.min(MAX_TIMER, Math.max(1, call.deadlineUnixMs - Date.now()))); };
        arm();
        const assertLive = () => { assertCall(call); if (abortReason !== undefined)
            throw abortReason; if (closed)
            throw Error('Committed source is closed'); };
        const dispatch = async (text, values = [], commit = false) => {
            // There is no await or callback between the final call check and real pg I/O.
            assertLive();
            if (!client || released)
                throw Error('Committed source connection unavailable');
            sqlDispatched = true;
            if (commit && acknowledgement)
                ackCommitDispatched = true;
            const queryConfiguration = { text: comment + text, values: [...values], binary: false };
            const result = await client.query(queryConfiguration);
            assertLive();
            return result.rows;
        };
        const budget = async () => {
            assertLive();
            const remaining = Math.max(1, Math.min(MAX_TIMER, call.deadlineUnixMs - Date.now()));
            await dispatch("SELECT pg_catalog.set_config('statement_timeout',$1,true),pg_catalog.set_config('lock_timeout',$1,true),pg_catalog.set_config('idle_in_transaction_session_timeout',$1,true)", [String(remaining)]);
        };
        const run = (async () => {
            // pg does not cancel pool.connect. If cancellation wins, its eventual acquired
            // connection is destroyed here without issuing even BEGIN or a catalog read.
            const acquired = await pool.connect();
            if (abortReason !== undefined || call.signal.aborted || Date.now() >= call.deadlineUnixMs || closed) {
                acquired.release(true);
                assertLive();
                throw Error('Committed source call expired while waiting for pool');
            }
            client = acquired;
            assertLive();
            await dispatch('BEGIN');
            await budget();
            await dispatch("SELECT pg_catalog.set_config('search_path','pg_catalog',true)");
            const catalog = catalogSchema.parse(jsonResult(await dispatch(CATALOG_SQL, [signatures, ownerRoleOid, ownerRole]), 8192));
            if (catalog.databaseName !== connection.database || catalog.databaseOid !== databaseOid || catalog.sessionRole !== connection.user || catalog.currentRole !== connection.user || catalog.roleOid !== observerRoleOid || !catalog.roleCanLogin || catalog.dangerousReachableRole || catalog.ownsUserObject || catalog.databaseCreate || catalog.databaseTemporary || !catalog.databaseConnect || catalog.schemaCreate || !catalog.sourceSchemaUsage || catalog.rawRelationPrivilege || catalog.extraFunctionExecute || !catalog.functionsValid)
                throw Error('Restricted committed-source role or database capability conflict');
            await budget();
            const binding = bindingSchema.parse(jsonResult(await dispatch('SELECT ritc.privacy_journal_source_binding($1,$2,$3,$4,$5)::text AS value', common), 8192));
            if (binding.sourceIdentity !== pins.sourceIdentity || binding.databaseName !== connection.database || binding.databaseOid !== databaseOid || binding.observerRole !== connection.user || binding.ownerRole !== ownerRole || binding.lineage !== pins.lineage || binding.schemaDigest !== pins.schemaDigest || binding.configurationId !== pins.configurationId || binding.fenced)
                throw Error('Fixed committed-source origin binding conflict');
            const session = {
                async query(text, values, beforeDispatch) { await budget(); beforeDispatch?.(); return dispatch(text, values); },
                async commit() { await budget(); await dispatch('COMMIT', [], true); },
            };
            const value = await work(session);
            await session.commit();
            return value;
        })();
        try {
            return await Promise.race([run, cancelled]);
        }
        catch (error) {
            release(true);
            if (error instanceof PostgresCommittedSourceCallError)
                throw error;
            throw failure(error);
        }
        finally {
            finished = true;
            activeCalls.delete(abort);
            clearTimeout(timer);
            call.signal.removeEventListener('abort', onAbort);
            release(abortReason !== undefined);
        }
    }
    function event(input) {
        const value = eventSchema.parse(input);
        if (value.eventId !== value.payload.eventId || value.payloadDigest !== journalHash(value.payload) || value.payload.lineage !== pins.lineage || value.payload.schemaDigest !== pins.schemaDigest || value.payload.configurationId !== pins.configurationId)
            throw Error('Committed source event digest or origin conflict');
        return freeze(value);
    }
    async function committedEvent(session, eventId) {
        const value = event(jsonResult(await session.query('SELECT ritc.privacy_journal_source_event($1,$2,$3,$4,$5,$6)::text AS value', [...common, eventId]), MAX_EVENT_BYTES + 8192));
        if (value.eventId !== eventId)
            throw Error('Exact committed event binding conflict');
        return value;
    }
    async function committedAcceptance(session, jobId) {
        const value = event(jsonResult(await session.query('SELECT ritc.privacy_journal_source_acceptance($1,$2,$3,$4,$5,$6)::text AS value', [...common, jobId]), MAX_EVENT_BYTES + 8192));
        if (value.payload.kind !== 'acceptance' || value.payload.jobId !== jobId)
            throw Error('Original committed acceptance binding conflict');
        validatePrivacyRestoreEvents([value]);
        return value;
    }
    function receipt(input, eventId, digest, seq, recordHash) {
        const proof = verifyDurableAdmissionReceipt(input, pins, authorityPublicKey);
        if (proof.record.transition !== 'commit' || proof.record.eventId !== eventId || proof.record.payloadDigest !== digest || proof.record.seq !== seq || proof.record.recordHash !== recordHash)
            throw Error('Committed-source acknowledgement receipt binding conflict');
        return proof;
    }
    const source = Object.freeze({
        async readOrigin(call) { return transaction(call, false, async () => Object.freeze({ lineage: pins.lineage, schemaDigest: pins.schemaDigest, configurationId: pins.configurationId, sourceIdentity: pins.sourceIdentity, fenced: false })); },
        async readCommittedEvent(eventId, call) { uuid.parse(eventId); return transaction(call, false, session => committedEvent(session, eventId)); },
        async readCommittedAcceptance(jobId, call) { uuid.parse(jobId); return transaction(call, false, session => committedAcceptance(session, jobId)); },
        async listUnacknowledgedJobEvents(jobId, call) {
            uuid.parse(jobId);
            return transaction(call, false, async (session) => {
                const ids = z.array(uuid).max(MAX_EVENTS).parse(jsonResult(await session.query('SELECT pg_catalog.to_json(ritc.privacy_journal_source_unacknowledged($1,$2,$3,$4,$5,$6,$7))::text AS value', [...common, jobId, MAX_EVENTS]), MAX_EVENTS * 40 + 8192));
                if (new Set(ids).size !== ids.length)
                    throw Error('Duplicate committed-source event');
                return Object.freeze(ids);
            });
        },
        async acknowledge(eventId, payloadDigest, commitRecordSeq, commitRecordHash, verifiedReceipt, call) {
            uuid.parse(eventId);
            hash.parse(payloadDigest);
            hash.parse(commitRecordHash);
            z.number().int().min(1).max(MAX_EVENTS).parse(commitRecordSeq);
            // Snapshot and authenticate before pool acquisition: forged/unrelated proofs
            // dispatch no SQL. Reverification below is immediately before the ack call.
            const proof = receipt(structuredClone(verifiedReceipt), eventId, payloadDigest, commitRecordSeq, commitRecordHash);
            return transaction(call, true, async (session) => {
                const value = await committedEvent(session, eventId);
                if (value.payloadDigest !== payloadDigest || value.payload.jobId !== proof.record.jobId)
                    throw Error('Acknowledgement exact committed payload or job conflict');
                if (value.payload.kind === 'acceptance')
                    validatePrivacyRestoreEvents([value]);
                else
                    validatePrivacyRestoreEvents([await committedAcceptance(session, value.payload.jobId), value]);
                // Session.query updates SQL timeouts before dispatch. The receipt is verified
                // again inside its final pre-dispatch callback, after that asynchronous I/O.
                await session.query('SELECT ritc.privacy_journal_source_acknowledge($1,$2,$3,$4,$5,$6,$7,$8,$9)', [...common, eventId, payloadDigest, commitRecordSeq, commitRecordHash], () => {
                    const checked = receipt(proof, eventId, payloadDigest, commitRecordSeq, commitRecordHash);
                    if (checked.record.jobId !== value.payload.jobId)
                        throw Error('Acknowledgement receipt job conflict');
                });
            });
        },
    });
    return Object.freeze({ source, async close() { if (!closed) {
            closed = true;
            for (const abort of activeCalls)
                abort(Error('Committed source is closed'));
            await pool.end();
        } } });
}
