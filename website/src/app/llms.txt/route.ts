import { absolute, github } from "@/lib/site";
import { guides } from "@/lib/content";
export const dynamic = "force-static";
export function GET() {
  return new Response(
    `# Ballast\n\n> Free, open-source disk analyzer and cleaner for macOS 26 and later. Native SwiftUI app, licensed AGPL-3.0.\n\nBallast maps the disk once and updates changed folders using macOS FSEvents. Every cleanup item has a safety verdict checked again at removal. Regular file cleanup uses Trash by default; tool commands and permanent deletion cannot be undone. Update checks and anonymous usage sharing are opt-in. There is no published controlled competitor performance benchmark.\n\n## Product\n- [Home](${absolute()})\n- [Download and requirements](${absolute("download/")})\n- [Privacy](${absolute("privacy/")})\n- [CleanMyMac alternative: fit and limits](${absolute("cleanmymac-alternative/")})\n- [Source code and README](${github})\n\n## Guides\n${guides.map((g) => `- [${g.title}](${absolute(`guides/${g.slug}/`)}): ${g.description}`).join("\n")}\n`,
    { headers: { "Content-Type": "text/plain; charset=utf-8" } },
  );
}
