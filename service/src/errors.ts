export class ServiceError extends Error {
  constructor(readonly status: number, readonly code: string, readonly recovery: string) { super(code); }
}
export const unavailable = () => new ServiceError(404, 'unavailable', 'Return to your current workspace.');
export const accessEnded = () => new ServiceError(403, 'access_ended', 'Stop queued work and clear protected local data.');
export const refresh = () => new ServiceError(409, 'refresh_required', 'Refresh current facts and review a new intent.');
export const invalid = () => new ServiceError(422, 'invalid_command', 'Review the submitted fields.');
