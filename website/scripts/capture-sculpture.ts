import { chromium } from "playwright-core";
import sharp from "sharp";
const browser = await chromium.launch({
  executablePath:
    process.env.CHROME_PATH ||
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
});
const page = await browser.newPage({
  viewport: { width: 1440, height: 1000 },
  deviceScaleFactor: 2,
});
await page.goto("http://127.0.0.1:4173/ballast/", { waitUntil: "networkidle" });
await page.locator(".sculpture-control").focus();
await page.locator("canvas").waitFor();
await page.addStyleTag({
  content:
    "body{background:#f8f8f5!important}.disk-shadow,.sculpture-label{visibility:hidden!important}.sculpture-control{outline:none!important}",
});
async function capture(name: string) {
  await sharp(
    await page.locator(".canvas-host").screenshot({ omitBackground: false }),
  )
    .webp({ quality: 90 })
    .toFile(new URL(`../public/${name}.webp`, import.meta.url).pathname);
}
await capture("sculpture");
await page.locator(".sculpture-control").click();
await page.waitForTimeout(800);
await capture("sculpture-open");
await browser.close();
