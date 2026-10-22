import { describe, expect, test } from "bun:test";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { guides, faqs } from "../src/lib/content";
import { absolute, basePath } from "../src/lib/site";
const root = resolve(import.meta.dir, "../out");
const routes = [
  "",
  "download/",
  "privacy/",
  "guides/",
  "cleanmymac-alternative/",
  ...guides.map((g) => `guides/${g.slug}/`),
];
describe("GitHub Pages export", () => {
  for (const route of routes)
    test(`${route || "/"} ships crawlable HTML and valid internal asset paths`, () => {
      const html = readFileSync(resolve(root, route, "index.html"), "utf8");
      expect(html.match(/<h1[ >]/g)?.length).toBe(1);
      expect(html).toContain(`rel="canonical" href="${absolute(route)}"`);
      expect(html).toContain('name="description"');
      expect(html).not.toContain('content="noindex"');
      for (const match of html
        .replace(/<link[^>]*rel="preconnect"[^>]*>/g, "")
        .matchAll(/(?:href|src)="([^"#?]+)[^"]*"/g)) {
        const path = match[1];
        if (!path.startsWith("/")) continue;
        expect(path.startsWith(`${basePath}/`)).toBe(true);
        const local = path.slice(basePath.length).replace(/^\//, "");
        expect(existsSync(resolve(root, local))).toBe(true);
      }
      for (const match of html.matchAll(
        /<script type="application\/ld\+json">(.*?)<\/script>/g,
      ))
        expect(() => JSON.parse(match[1])).not.toThrow();
    });
  test("answers and schema are available without JavaScript", () => {
    const html = readFileSync(resolve(root, "index.html"), "utf8");
    for (const [q, a] of faqs) {
      expect(html).toContain(q);
      expect(html).toContain(a);
    }
  });
  test("discovery includes every public route", () => {
    const xml = readFileSync(resolve(root, "sitemap.xml"), "utf8");
    for (const route of routes)
      expect(xml).toContain(`<loc>${absolute(route)}</loc>`);
    expect(readFileSync(resolve(root, "robots.txt"), "utf8")).toContain(
      absolute("sitemap.xml"),
    );
    expect(readFileSync(resolve(root, "llms.txt"), "utf8")).toContain(
      absolute("guides/mac-system-data/"),
    );
    expect(existsSync(resolve(root, "og.png"))).toBe(true);
  });
});
