/** Public deployment configuration. Browser requests use a same-origin BFF. */
export type Environment = "debug" | "staging" | "production";
export type PublicConfiguration = Readonly<{
  environment: Environment;
  apiOrigin: string | null;
}>;

export function publicConfiguration(input: Readonly<Record<string, unknown>>): PublicConfiguration {
  const environment = input.environment;
  if (environment !== "debug" && environment !== "staging" && environment !== "production") {
    throw new Error("Unknown environment");
  }
  if (input.apiOrigin === null && environment === "debug") {
    return Object.freeze({ environment, apiOrigin: null });
  }
  if (typeof input.apiOrigin !== "string") throw new Error("API origin required");
  const url = new URL(input.apiOrigin);
  const localDebug = environment === "debug" && url.protocol === "http:" &&
    (url.hostname === "localhost" || url.hostname === "127.0.0.1");
  if (url.protocol !== "https:" && !localDebug) throw new Error("HTTPS API origin required");
  if (url.username || url.password || url.pathname !== "/" || url.search || url.hash) {
    throw new Error("API origin must contain only scheme, host, and port");
  }
  // Explicit allowlist prevents accidentally serializing service secrets into public config.
  return Object.freeze({ environment, apiOrigin: url.origin });
}
