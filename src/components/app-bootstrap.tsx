"use client";

import { useEffect, useRef, useState } from "react";
import { init, isTMA, mockTelegramEnv, retrieveRawInitData } from "@telegram-apps/sdk-react";
import { useLanguage } from "@/lib/i18n/context";

type Status = "pending" | "iframe" | "ready" | "error";

/**
 * Mirrors the environment check @telegram-apps/bridge's postEvent does
 * internally (its isIframe/hasWebviewProxy/"external.notify" checks) — init()
 * always fires an `iframe_ready` event through that same postEvent on
 * startup, so if none of these three channels exist it throws
 * UnknownEnvError immediately, before mockTelegramEnv gets a chance to help:
 * the mock only fakes launch params and the postMessage *implementation*, it
 * doesn't make window.self !== window.top true. Real Telegram always
 * satisfies one of these (Telegram Web embeds Mini Apps in an iframe, native
 * clients expose TelegramWebviewProxy/external.notify) — the only case that
 * fails all three is our own dev server opened as a plain top-level browser
 * tab, which is exactly the case handled below.
 */
function hasTelegramBridge(): boolean {
  if (typeof window === "undefined") return false;
  try {
    if (window.self !== window.top) return true;
  } catch {
    // Cross-origin frame access throws — that failure itself means we're framed.
    return true;
  }
  const w = window as Window & {
    TelegramWebviewProxy?: { postEvent?: unknown };
    external?: { notify?: unknown };
  };
  return typeof w.TelegramWebviewProxy?.postEvent === "function" || typeof w.external?.notify === "function";
}

/**
 * Single startup sequence for the Mini App, in order:
 * 1. Boot the Telegram SDK (mocked outside of Telegram in dev).
 * 2. Exchange raw initData for our own session cookie via /api/auth/telegram.
 * Kept as one component/effect so step 2 never races step 1 — splitting this
 * into nested provider + gate components would run the child's effect first.
 */
export function AppBootstrap({ children }: { children: React.ReactNode }) {
  const [status, setStatus] = useState<Status>("pending");
  const { t } = useLanguage();
  // Whether we're inside a *real* Telegram client, decided once per
  // component instance and cached here — not re-derived from isTMA() on
  // every effect run. mockTelegramEnv() below saves its fake launch params
  // to storage, which makes isTMA() return true afterwards too, so it can no
  // longer tell "real Telegram" apart from "us, having already mocked it".
  // React's dev-only Strict Mode double-invoke (mount -> cleanup -> mount
  // again) would otherwise re-run this effect and see that now-true isTMA(),
  // skip re-mocking on the second mount, and call init() with no postMessage
  // bridge in place — which is exactly what throws UnknownEnvError. A ref
  // survives that cleanup/remount cycle (same component instance), so the
  // decision made before any mocking happened stays authoritative for both
  // invokes.
  const isRealTmaRef = useRef<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    // init() returns its own teardown function — without calling it on
    // unmount, Strict Mode's double-invoke leaves the SDK's internal state
    // from the first init() call still standing when the second one runs.
    // Discarding the returned function (as this used to) "works" outside of
    // Strict Mode's double-invoke, i.e. in production, which is why this
    // went unnoticed until testing the plain-browser dev flow.
    let cleanupSdk: VoidFunction | undefined;

    (async () => {
      try {
        if (process.env.NODE_ENV !== "production" && !hasTelegramBridge()) {
          // Re-open this same URL inside an iframe instead of bootstrapping
          // here — see hasTelegramBridge's comment for why running naked in
          // a top-level dev tab always throws UnknownEnvError regardless of
          // mockTelegramEnv. The iframed copy re-runs this component fresh
          // and, from inside the iframe, passes the bridge check.
          if (!cancelled) setStatus("iframe");
          return;
        }

        if (isRealTmaRef.current === null) {
          isRealTmaRef.current = isTMA();
        }

        if (!isRealTmaRef.current && process.env.NODE_ENV !== "production") {
          mockTelegramEnv({
            launchParams: {
              tgWebAppData: new URLSearchParams([
                [
                  "user",
                  JSON.stringify({
                    id: 1,
                    first_name: "Dev",
                    username: "dev_user",
                    photo_url: "https://i.pravatar.cc/150?img=12",
                  }),
                ],
                ["auth_date", String(Math.floor(Date.now() / 1000))],
                ["signature", "dev-mock-signature"],
                ["hash", "dev-mock-hash"],
              ]),
              tgWebAppThemeParams: { bg_color: "#171827" },
              tgWebAppVersion: "8",
              tgWebAppPlatform: "tdesktop",
            },
            // Re-mocking on Strict Mode's second invoke would otherwise
            // wrap window.parent.postMessage again on top of the first
            // mock's wrapper instead of replacing it — harmless in this
            // app (nothing depends on postMessage interception here) but
            // exactly what the SDK's own docs warn against for repeated
            // mockTelegramEnv calls in one lifecycle.
            resetPostMessage: true,
          });
        }

        cleanupSdk = init();

        const initData = retrieveRawInitData();
        if (!initData) {
          throw new Error("no_init_data");
        }

        const res = await fetch("/api/auth/telegram", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ initData }),
          credentials: "include",
        });

        if (!res.ok) {
          throw new Error("auth_failed");
        }

        if (!cancelled) setStatus("ready");
      } catch (err) {
        console.error("App bootstrap failed:", err);
        if (!cancelled) setStatus("error");
      }
    })();

    return () => {
      cancelled = true;
      cleanupSdk?.();
    };
  }, []);

  if (status === "pending") {
    return (
      <div className="flex flex-1 items-center justify-center">
        <p className="text-nav-inactive">{t("common.loading")}</p>
      </div>
    );
  }

  if (status === "iframe") {
    return (
      <iframe
        src={typeof window !== "undefined" ? window.location.href : undefined}
        title="100ГРАМ (dev)"
        className="h-full w-full flex-1 border-0"
      />
    );
  }

  if (status === "error") {
    return (
      <div className="flex flex-1 items-center justify-center p-6 text-center">
        <p className="text-nav-inactive">{t("connectError.text")}</p>
      </div>
    );
  }

  return <>{children}</>;
}
