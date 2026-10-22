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
