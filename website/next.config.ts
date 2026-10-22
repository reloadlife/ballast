import type { NextConfig } from "next";
const site = new URL(
  process.env.NEXT_PUBLIC_SITE_URL || "https://reloadlife.github.io/ballast/",
);
const basePath = site.pathname.replace(/\/$/, "");
const config: NextConfig = {
  output: "export",
  trailingSlash: true,
  basePath,
  images: { unoptimized: true },
  poweredByHeader: false,
};
export default config;
