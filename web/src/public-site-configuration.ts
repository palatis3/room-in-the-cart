/** Public operator configuration only. Never add credentials or private data.
 * Set an actual monitored HTTPS destination after the operating owner reviews
 * it. Native release metadata is separately configured in config/release.json.
 * Policy, terms, retention and human-language review remain content gates.
 */
export type PublicSiteConfiguration = Readonly<{ operatorSupportURL: string | null }>;
export const publicSiteConfiguration: PublicSiteConfiguration = Object.freeze({ operatorSupportURL: null });
