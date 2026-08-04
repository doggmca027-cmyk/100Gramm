import "server-only";
import type { NextRequest } from "next/server";
import { SESSION_COOKIE_NAME, verifySessionToken } from "./telegram-auth";

export class UnauthorizedError extends Error {
  constructor() {
    super("unauthorized");
  }
}

/** Reads and verifies the session cookie, returning the Supabase user id. */
export async function requireUserId(request: NextRequest): Promise<string> {
  const token = request.cookies.get(SESSION_COOKIE_NAME)?.value;
  if (!token) {
    throw new UnauthorizedError();
  }

  const userId = await verifySessionToken(token);
  if (!userId) {
    throw new UnauthorizedError();
  }

  return userId;
}
