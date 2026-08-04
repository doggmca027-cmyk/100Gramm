import "server-only";
import { createClient } from "@supabase/supabase-js";

/**
 * Service-role Supabase client. Server-only — bypasses RLS, so it must never
 * be imported from client components or leak into the browser bundle.
 */
export function supabaseServer() {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !key) {
    throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env vars");
  }

  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
