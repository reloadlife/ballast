import { chromium } from "playwright-core";
import assert from "node:assert/strict";
const browser = await chromium.launch({
  executablePath:
    process.env.CHROME_PATH ||
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
});
const context = await browser.newContext({
  viewport: { width: 320, height: 740 },
});
const page = await context.newPage();
await page.addInitScript(() => {
  const original = HTMLCanvasElement.prototype.getContext;
  HTMLCanvasElement.prototype.getContext = function (
    this: HTMLCanvasElement,
    kind: string,
    ...args: unknown[]
  ) {
    if (kind.includes("webgl")) return null;
    return Reflect.apply(original, this, [kind, ...args]);
  } as typeof original;
});
await page.goto("http://127.0.0.1:4173/ballast/", { waitUntil: "networkidle" });
assert.equal(
  await page.locator("canvas").count(),
  0,
  "No WebGL startup before intent",
);
assert.equal(
  await page.evaluate(() => document.documentElement.scrollWidth > innerWidth),
  false,
  "320px layout has no overflow",
);
await page.locator(".sculpture-control").focus();
await page.keyboard.press("Enter");
await page.getByRole("status").filter({ hasText: "3D unavailable" }).waitFor();
assert.match(
  (await page.locator(".sculpture-poster").getAttribute("src")) || "",
  /sculpture-open.webp$/,
);
await page.keyboard.press("Enter");
assert.match(
  (await page.locator(".sculpture-poster").getAttribute("src")) || "",
  /sculpture.webp$/,
);
for (const path of [
  "download/",
  "privacy/",
  "guides/",
  "guides/mac-system-data/",
  "cleanmymac-alternative/",
]) {
  const response = await page.goto(`http://127.0.0.1:4173/ballast/${path}`);
  assert.equal(response?.status(), 200);
  assert.equal(await page.locator("h1").count(), 1);
  assert.equal(
    await page.evaluate(
      () => document.documentElement.scrollWidth > innerWidth,
    ),
    false,
  );
}
const missing = await page.goto("http://127.0.0.1:4173/ballast/missing-page/");
assert.equal(missing?.status(), 404);
await context.close();
await browser.close();
console.log(
  "Passed: intent-only graphics, keyboard controls, WebGL fallback, 320px routes, real 404.",
);
