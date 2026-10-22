import type { MetadataRoute } from "next";
import { absolute } from "@/lib/site";
export default function robots(): MetadataRoute.Robots {
  return {
    rules: { userAgent: "*", allow: "/" },
    sitemap: absolute("sitemap.xml"),
  };
}
export const dynamic = "force-static";
