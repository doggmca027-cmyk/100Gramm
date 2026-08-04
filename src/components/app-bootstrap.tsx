"use client";

import { useEffect, useState } from "react";
import { init, isTMA, mockTelegramEnv, retrieveRawInitData } from "@telegram-apps/sdk-react";

type Status = "pending" | "ready" | "error";

/**
 * Single startup sequence for the Mini App, in order:
 * 1. Boot the Telegram SDK (mocked outside of Telegram in dev).
 * 2. Exchange raw initData for our own session cookie via /api/auth/telegram.
 * Kept as one component/effect so step 2 never races step 1 — splitting this
 * into nested provider + gate components would run the child's effect first.
 */
export function AppBootstrap({ children }: { children: React.ReactNode }) {
  const [status, setStatus] = useState<Status>("pending");

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        if (!isTMA() && process.env.NODE_ENV !== "production") {
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
          });
        }

        init();

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
    };
  }, []);

  if (status === "pending") {
    return (
      <div className="flex flex-1 items-center justify-center">
        <p className="text-nav-inactive">Загрузка...</p>
      </div>
    );
  }

  if (status === "error") {
    return (
      <div className="flex flex-1 items-center justify-center p-6 text-center">
        <p className="text-nav-inactive">
          Не удалось подключиться. Открой приложение через Telegram.
        </p>
      </div>
    );
  }

  return <>{children}</>;
}
