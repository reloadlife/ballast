import type { Metadata } from "next";
import localFont from "next/font/local";
const manrope = localFont({
  src: "../../node_modules/@fontsource-variable/manrope/files/manrope-latin-wght-normal.woff2",
  variable: "--font-manrope",
  display: "swap",
  weight: "200 800",
  adjustFontFallback: "Arial",
});
import "./globals.css";
import { Header } from "@/components/header";
import { Footer } from "@/components/footer";
import { absolute, asset, description, siteUrl } from "@/lib/site";
export const metadata: Metadata = {
  metadataBase: new URL(`${siteUrl}/`),
  title: {
    default: "Ballast — Free, open-source Mac disk cleaner",
    template: "%s | Ballast",
  },
  description,
  applicationName: "Ballast",
  alternates: { canonical: absolute() },
  openGraph: {
    type: "website",
    locale: "en_US",
    siteName: "Ballast",
    title: "Ballast — Make room for what’s next.",
    description,
    url: absolute(),
    images: [
      {
        url: absolute("og.png"),
        width: 1200,
        height: 630,
        alt: "Ballast — Free, open-source Mac disk cleanup",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "Ballast — Make room for what’s next.",
    description,
    images: [absolute("og.png")],
  },
  robots: { index: true, follow: true },
  icons: { icon: asset("icon.png"), apple: asset("icon.png") },
};
export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={manrope.variable}>
      <body>
        <a className="skip-link" href="#main">
          Skip to content
        </a>
        <Header />
        {children}
        <Footer />
      </body>
    </html>
  );
}
