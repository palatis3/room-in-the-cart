/** Public operator configuration only. Never add credentials or private data.
 * The operator name and support address were supplied by the user. A destination opens a composer
 * or support page; this module never sends messages. Native contact defaults
 * come from config/public-contact.json and environment-specific metadata.
 * Policy, terms, retention and human-language review remain content gates.
 */
export type PublicSiteConfiguration = Readonly<{ operatorSupportURL: string | null; operatorName?: string | null }>;
export const publicSiteConfiguration: PublicSiteConfiguration = Object.freeze({
  operatorSupportURL: 'mailto:hello@roominthecart.com',
  operatorName: 'Venture House Group LLC'
});
