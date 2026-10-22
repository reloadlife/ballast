import type { MetadataRoute } from "next";
import { absolute } from "@/lib/site";
import { guides } from "@/lib/content";
export default function sitemap(): MetadataRoute.Sitemap {
  return [
    "",
    "download/",
    "privacy/",
    "cleanmymac-alternative/",
    "guides/",
    ...guides.map((g) => `guides/${g.slug}/`),
  ].map((path) => ({ url: absolute(path) }));
}
export const dynamic = "force-static";
