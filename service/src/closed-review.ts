import { z } from 'zod';
import { unavailable } from './errors.js';

const configuration = z.object({
  startsAt: z.iso.datetime(),
  endsAt: z.iso.datetime(),
  householdId: z.uuid(),
  subjects: z.tuple([z.uuid(), z.uuid()]),
}).strict();

const accountRoutes = new Set([
  'GET /v1/me/workspaces',
  'POST /v1/invites/preview',
  'POST /v1/invites/redeem',
  'POST /v1/billing/verify',
]);

const householdRoutes = new Set([
  'POST /devices',
  'DELETE /devices/current',
  'GET /bootstrap',
  'GET /requests/mine',
  'GET /requests/pickups',
  'POST /replay-windows',
  'GET /members',
  'GET /invites',
  'POST /invites',
  'GET /entitlements',
  'POST /billing/purchase-context',
  'GET /billing/seat-candidates',
  'PUT /billing/seats',
]);

export class ClosedReview {
  private constructor(
    readonly householdId: string,
    private readonly subjects: ReadonlySet<string>,
    private readonly startsAt: number,
    readonly endsAt: number,
  ) {}

  static configured(env: NodeJS.ProcessEnv): ClosedReview | undefined {
    if (env.CLOSED_REVIEW_WINDOW_JSON === undefined) return undefined;
    const review = configuration.parse(JSON.parse(env.CLOSED_REVIEW_WINDOW_JSON));
    const start = Date.parse(review.startsAt);
    const end = Date.parse(review.endsAt);
    const subjects = new Set(review.subjects);
    if (subjects.size !== 2 || end <= start || end - start > 86_400_000 ||
        env.APPLE_ENVIRONMENT !== 'Production' || env.APPLE_REVIEW_HOUSEHOLD_IDS !== review.householdId) {
      throw new Error('Closed review requires two adults, one Sandbox review household and at most 24 hours');
    }
    return new ClosedReview(review.householdId, subjects, start, end);
  }

  checkRequest(method: string, path: string, hasBearer: boolean, now = Date.now()): void {
    if (now < this.startsAt || now >= this.endsAt) throw unavailable();
    if (method === 'POST' && path === '/v1/apple/notifications/sandbox') return;
    if (!hasBearer) throw unavailable();
    if (accountRoutes.has(method + ' ' + path)) return;
    const prefix = '/v1/households/' + this.householdId + '/';
    if (path.startsWith(prefix) && householdRoutes.has(method + ' /' + path.slice(prefix.length))) return;
    throw unavailable();
  }

  checkSubject(subject: string): void {
    if (!this.subjects.has(subject)) throw unavailable();
  }

  checkHousehold(householdId: string): void {
    if (householdId !== this.householdId) throw unavailable();
  }
}
