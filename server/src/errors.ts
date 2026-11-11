export type ErrorCode =
  | "stale_timestamp"
  | "bad_signature"
  | "token_expired"
  | "unauthorized"
  | "invalid_text"
  | "invalid_image"
  | "quota_exceeded"
  | "suspended"
  | "awaiting_reply"
  | "line_not_connected"
  | "line_not_ready"
  | "line_closed"
  | "not_found"
  | "internal";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: ErrorCode,
    message: string,
  ) {
    super(message);
  }
}

export function errorResponse(status: number, code: ErrorCode, message: string): Response {
  return Response.json({ error: { code, message } }, { status });
}

export const Errors = {
  staleTimestamp: () => new ApiError(401, "stale_timestamp", "timestamp is more than 5 minutes away from server time"),
  badSignature: (detail = "signature verification failed") => new ApiError(401, "bad_signature", detail),
  tokenExpired: () => new ApiError(401, "token_expired", "session token has expired"),
  unauthorized: (detail = "missing or invalid bearer token") => new ApiError(401, "unauthorized", detail),
  invalidText: (detail = "text must be 1-500 characters after trimming") => new ApiError(400, "invalid_text", detail),
  invalidImage: (detail: string) => new ApiError(400, "invalid_image", detail),
  quotaExceeded: (detail: string) => new ApiError(429, "quota_exceeded", detail),
  suspended: () => new ApiError(403, "suspended", "this device is suspended from sending"),
  awaitingReply: () => new ApiError(403, "awaiting_reply", "the recipient has not replied yet"),
  lineNotConnected: () => new ApiError(403, "line_not_connected", "images can only be sent on a connected line"),
  lineNotReady: () => new ApiError(409, "line_not_ready", "the line has no recipient yet"),
  lineClosed: () => new ApiError(409, "line_closed", "the line is closed"),
  notFound: (detail = "not found") => new ApiError(404, "not_found", detail),
};
