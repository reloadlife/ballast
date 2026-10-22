import type { Metadata } from "next";
import { absolute } from "./site";
export function pageMetadata(
  title: string,
  description: string,
  path: string,
): Metadata {
  return {
    title,
    description,
    alternates: { canonical: absolute(path) },
    openGraph: {
      title: `${title} | Ballast`,
      description,
      url: absolute(path),
      images: [{ url: absolute("og.png"), width: 1200, height: 630 }],
    },
    twitter: {
      title: `${title} | Ballast`,
      description,
      images: [absolute("og.png")],
    },
  };
}
