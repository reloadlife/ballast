import { chromium } from "playwright-core";
import AxeBuilder from "@axe-core/playwright";
import { mkdir } from "node:fs/promises";
const output = "/tmp/ballast-website-review";
await mkdir(output, { recursive: true });
const browser = await chromium.launch({
  executablePath:
    process.env.CHROME_PATH ||
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
});
const results: unknown[] = [];
for (const [name, width, height] of [
  ["desktop", 1440, 1000],
  ["mobile", 390, 844],
] as const) {
  const context = await browser.newContext({
    viewport: { width, height },
    deviceScaleFactor: 1,
  });
  const page = await context.newPage();
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto("http://127.0.0.1:4173/ballast/", {
    waitUntil: "networkidle",
  });
  await page.screenshot({ path: `${output}/${name}.png`, fullPage: true });
  await page.screenshot({ path: `${output}/${name}-hero.png` });
  const check = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21aa"])
    .analyze();
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth > innerWidth,
  );
  const button = page.getByRole("button", { name: "A little room to breathe" });
  await button.click();
  await page.locator("canvas").waitFor();
  await page.waitForFunction(
    () =>
      !document
        .getElementById("sculpture-status")
        ?.textContent?.includes("Loading"),
  );
  await page.waitForTimeout(800);
  const toggled = await page
    .getByRole("button", { name: "Bring it back together" })
    .getAttribute("aria-pressed");
  if (name === "desktop")
    await page.screenshot({ path: `${output}/desktop-open.png` });
  await page.locator("details summary").first().click();
  const disclosure = await page.locator("details").first().getAttribute("open");
  results.push({
    name,
    overflow,
    errors,
    toggled,
    disclosure,
    violations: check.violations.map((v) => ({
      id: v.id,
      impact: v.impact,
      nodes: v.nodes.map((n) => ({
        target: n.target,
        summary: n.failureSummary,
      })),
    })),
  });
  await context.close();
}
const reduced = await browser.newPage({
  viewport: { width: 390, height: 844 },
  reducedMotion: "reduce",
});
await reduced.goto("http://127.0.0.1:4173/ballast/", {
  waitUntil: "networkidle",
});
results.push({
  reducedMotion: await reduced.evaluate(
    () => matchMedia("(prefers-reduced-motion: reduce)").matches,
  ),
});
const noJS = await browser.newPage({ javaScriptEnabled: false });
await noJS.goto("http://127.0.0.1:4173/ballast/");
results.push({
  noJSHeading: await noJS.locator("h1").textContent(),
  noJSFAQs: await noJS.locator("details").count(),
});
await Bun.write(`${output}/checks.json`, JSON.stringify(results, null, 2));
console.log(JSON.stringify(results, null, 2));
await browser.close();
