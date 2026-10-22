import { resolve, sep } from "node:path";
import { stat } from "node:fs/promises";
const root = resolve(import.meta.dir, "../out");
const basePath = new URL(
  process.env.NEXT_PUBLIC_SITE_URL || "https://reloadlife.github.io/ballast/",
).pathname.replace(/\/$/, "");
Bun.serve({
  port: Number(process.env.PORT || 4173),
  hostname: "127.0.0.1",
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === basePath && basePath)
      return Response.redirect(`${url.origin}${basePath}/`, 308);
    if (!url.pathname.startsWith(`${basePath}/`))
      return new Response("Not found", { status: 404 });
    let path: string;
    try {
      path = resolve(
        root,
        `.${decodeURIComponent(url.pathname.slice(basePath.length))}`,
      );
    } catch {
      return new Response("Bad request", { status: 400 });
    }
    if (path !== root && !path.startsWith(root + sep))
      return new Response("Not found", { status: 404 });
    try {
      if ((await stat(path)).isDirectory()) path = resolve(path, "index.html");
    } catch {}
    const file = Bun.file(path);
    if (await file.exists()) {
      const headers = new Headers({
        "Content-Type": file.type,
        "Cache-Control": "public, max-age=600",
      });
      if (
        /\.(html|css|js|json|txt|xml)$/.test(path) &&
        request.headers.get("Accept-Encoding")?.includes("gzip")
      ) {
        headers.set("Content-Encoding", "gzip");
        headers.set("Vary", "Accept-Encoding");
        return new Response(Bun.gzipSync(await file.arrayBuffer()), {
          headers,
        });
      }
      return new Response(file, { headers });
    }
    return new Response(Bun.file(resolve(root, "404.html")), {
      status: 404,
      headers: { "Content-Type": "text/html" },
    });
  },
});
console.log(
  `Ballast static preview: http://127.0.0.1:${process.env.PORT || 4173}${basePath}/`,
);
