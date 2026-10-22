# Website verification

Verified locally on 2026-10-22 against the production static export.

- Bun frozen-lockfile installation, Next.js/Turbopack production build, and TypeScript check pass.
- 11 static-export tests pass both at `/ballast/` and at a root-domain URL (`https://ballast.example/`, used only as a reserved test hostname). Default GitHub Pages configuration restored afterward.
- Desktop 1440×1000 and mobile 390×844: no horizontal overflow, no page runtime errors, no axe WCAG 2 A/AA or WCAG 2.1 AA violations. Sculpture toggles and FAQ disclosures work.
- 320px viewport: key content routes fit; keyboard activation works; deliberately unavailable WebGL falls back to the closed/open rendered images. A missing route returns a genuine 404.
- Without JavaScript: heading, product text, links, screenshot, sculpture poster, and all six native FAQ disclosures remain available. The script-only sculpture control is disabled.
- Reduced-motion preference is recognized; source snaps the sculpture to its new state and disables decorative transitions.
- Final local Lighthouse mobile run: performance 97, accessibility 100, best practices 100, SEO 100. LCP 2.6 s, TBT 20 ms, CLS 0. The preview used gzip text responses. These are lab results, not deployed-site field data or ranking/AI-citation guarantees.
- Independent Impeccable finish review: `ship`; post-fix verdict also `ship` for the scored contrast, poster-first, and font-loading changes. Website DESIGN.md and the design sidecar are present.
- Every shipped raster has embedded provenance or an adjacent metadata sidecar.

Evidence (local): `/tmp/ballast-website-review/` contains desktop/mobile captures, browser check JSON, and before/after/final Lighthouse reports. `scripts/browser-check.ts` and `scripts/resilience-check.ts` reproduce browser checks against the production preview.

Not verified: deployed GitHub Pages behavior, real-device Safari/GPU behavior, search indexing, search rankings, or AI-engine citations. GitHub Pages was not configured at implementation time. No app release was changed and no deployment was performed.

## Health release update — 2026-10-22

The checks above describe the initial website implementation. For the Health extension accompanying app v0.6.0:

- Production build and TypeScript checks pass; 12 export tests cover all 10 content routes, metadata, schema, assets and discovery files.
- `bun run scripts/health-release-qa.ts` checks the homepage and new Health guide at 1440×1000 and 390×844, follows the Health guide link, captures full pages and section details, and checks overflow, page errors and axe accessibility. Both viewports pass with zero violations.
- Guide text links initially measured 4.49:1. Text orange is now `#bc4314`; the corrected pages pass axe. Artwork orange is unchanged.
- Local captures are in the ignored `.impeccable/review/health-release/` folder. T3 snapshots returned blurred previews, so Playwright captured the readable evidence.
- Independent finish review found only documentation persistence drift. The final verdict scored that fix resolved and returned `ship`; website tokens and native product coverage now match the implementation.
- No new raster, animation dependency, or runtime request was added. Lighthouse was not rerun for this content update; the earlier lab score is not a new measurement.
- Set `BALLAST_QA_URL=https://reloadlife.github.io/ballast/` to run the same browser checks against the deployed site.
