import { createRuntime } from '../service/dist/runtime.js';
import { ClosedReview } from '../service/dist/closed-review.js';

// The private release bundle installs this as api/index.js. Missing or invalid
// configuration must never start the unrestricted runtime on this deployment.
if (!ClosedReview.configured(process.env)) throw new Error('Closed review configuration is required');
const { server } = await createRuntime();
export default server;
