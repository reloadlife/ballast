export const siteUrl = (
  process.env.NEXT_PUBLIC_SITE_URL || "https://reloadlife.github.io/ballast/"
).replace(/\/$/, "");
export const basePath = new URL(siteUrl).pathname.replace(/\/$/, "");
export const asset = (path: string) => `${basePath}/${path.replace(/^\//, "")}`;
export const absolute = (path = "") => `${siteUrl}/${path.replace(/^\//, "")}`;
export const github = "https://github.com/reloadlife/ballast";
export const download = `${github}/releases/latest/download/Ballast.zip`;
export const description =
  "Free, open-source Mac disk cleanup. Find large files, clear developer caches, and reclaim storage with a native SwiftUI app that checks every cleanup.";
