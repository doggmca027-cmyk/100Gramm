import type { Metadata, Viewport } from "next";
import Script from "next/script";
import { Geist, Geist_Mono, Tajawal } from "next/font/google";
import { AppBootstrap } from "@/components/app-bootstrap";
import { TonConnectProvider } from "@/components/ton-connect-provider";
import { LanguageProvider } from "@/lib/i18n/context";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin", "cyrillic"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin", "cyrillic"],
});

// Geist has no Arabic glyphs (latin/cyrillic subsets only) — Tajawal covers
// Arabic script and swaps in for --font-sans whenever <html dir="rtl">, see
// the html[dir="rtl"] override in globals.css. Always loaded (not just for
// ar users) since the language can be switched at runtime after this
// server component has already rendered.
const tajawal = Tajawal({
  variable: "--font-tajawal",
  subsets: ["arabic"],
  weight: ["400", "500", "700"],
});

export const metadata: Metadata = {
  title: "100ГРАМ",
  description: "Твой путь от улицы до империи",
};

export const viewport: Viewport = {
  themeColor: "#171827",
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  userScalable: false,
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="ru"
      // lang/dir get corrected client-side once LanguageProvider mounts and
      // reads the stored preference (see the effect in lib/i18n/context.tsx)
      // — "ru"/ltr here is just the pre-hydration default.
      className={`${geistSans.variable} ${geistMono.variable} ${tajawal.variable} h-full antialiased`}
    >
      <body className="flex h-dvh flex-col overflow-hidden bg-bg">
        <LanguageProvider>
          <TonConnectProvider>
            <AppBootstrap>{children}</AppBootstrap>
          </TonConnectProvider>
        </LanguageProvider>
        {/*
          Taddy ad/monetization SDK (https://taddy.gitbook.io/docs/sdk/web).
          Loaded site-wide on purpose, per an explicit decision after a
          security review flagged the tradeoff: this app has no route split
          between player and admin content (admin-screen.tsx renders inside
          the same client tree), and the CSRF cookie is deliberately
          non-httpOnly so the app's own JS can read it (see assertCsrfToken
          in lib/session.ts) — any script sharing the page, this one
          included, has that same read access. `strategy="afterInteractive"`
          keeps it off the critical render path; ordered after AppBootstrap
          so it loads once the Telegram bridge (@telegram-apps/sdk-react,
          not a classic telegram-web-app.js <script> tag in this project)
          has already initialized.
        */}
        <Script
          src="https://sdk.taddy.pro/web/taddy.min.js"
          data-pub-id="ae36b389e4466760a9476a1a6894457f"
          strategy="afterInteractive"
        />
      </body>
    </html>
  );
}
