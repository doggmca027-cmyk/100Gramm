import type { Metadata, Viewport } from "next";
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
      </body>
    </html>
  );
}
