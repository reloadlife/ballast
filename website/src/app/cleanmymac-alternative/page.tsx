import Link from "next/link";
import { Button } from "@/components/ui/button";
import { github } from "@/lib/site";
import { pageMetadata } from "@/lib/metadata";
export const metadata = pageMetadata(
  "A free, open-source CleanMyMac alternative",
  "Looking for a CleanMyMac alternative for disk cleanup? Ballast offers native Mac storage analysis, reviewed cleanup, and developer tools under AGPL-3.0.",
  "cleanmymac-alternative/",
);
export default function Alternative() {
  return (
    <main id="main" className="article-shell">
      <Link href="/" className="breadcrumb">
        Ballast / Alternatives
      </Link>
      <h1>
        A Mac cleaner
        <br />
        you can look inside.
      </h1>
      <p className="lede">
        Looking for a free, open-source CleanMyMac alternative? Ballast focuses
        on understanding disk space and reviewing what you remove, with a native
        SwiftUI interface and useful depth for developers.
      </p>
      <Button asChild>
        <Link href="/download/">Try Ballast for free</Link>
      </Button>
      <h2>Is Ballast a good fit?</h2>
      <p>
        If your main question is “what is filling my Mac, and what can I
        remove?”, Ballast is built for that job. Its source is fully available
        under AGPL-3.0, with no subscription or paid feature tier.
      </p>
      <table className="comparison-table">
        <caption className="sr-only">
          Ballast’s capabilities for people choosing a Mac cleanup app
        </caption>
        <thead>
          <tr>
            <th scope="col">What you need</th>
            <th scope="col">What Ballast offers</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <th scope="row">Find storage usage</th>
            <td>Whole-disk index, folder map, largest files, growth history</td>
          </tr>
          <tr>
            <th scope="row">Review cleanup</th>
            <td>
              Safety verdicts, checks at removal, Trash by default, Put Back for
              recoverable items
            </td>
          </tr>
          <tr>
            <th scope="row">Developer tools</th>
            <td>
              Build artifacts, tool caches, Homebrew management, checked Git
              worktree removal
            </td>
          </tr>
          <tr>
            <th scope="row">Inspect the code</th>
            <td>Fully open-source Swift code under AGPL-3.0</td>
          </tr>
          <tr>
            <th scope="row">Compatibility</th>
            <td>macOS 26 and later</td>
          </tr>
        </tbody>
      </table>
      <h2>Built to avoid repeating work.</h2>
      <p>
        Ballast keeps a persistent index and follows macOS FSEvents, so repeat
        scans can focus on changed folders. This is the basis of its performance
        approach. There is no published controlled benchmark proving a speed
        advantage over CleanMyMac.
      </p>
      <p>
        <Link href="/guides/how-ballast-works/">
          Read how the indexing engine works.
        </Link>
      </p>
      <h2>A focused alternative, with clear limits.</h2>
      <p>
        Ballast is a disk analyzer and cleanup tool. It does not offer malware
        protection, promise to speed up every Mac, or claim to match every
        feature of a broader maintenance suite. Compare the features you
        actually need and your macOS version before switching.
      </p>
      <p>
        CleanMyMac is a product of MacPaw. Ballast is an independent project and
        is not affiliated with or endorsed by MacPaw. Consult{" "}
        <a href="https://macpaw.com/cleanmymac">
          CleanMyMac’s official website
        </a>{" "}
        for its current capabilities and requirements.
      </p>
      <h2>See exactly what you are getting.</h2>
      <p>
        Start with the{" "}
        <a href={github}>source and full feature documentation</a>, the{" "}
        <Link href="/privacy/">privacy explanation</Link>, or the{" "}
        <Link href="/guides/safe-mac-cleanup/">safe cleanup guide</Link>.
      </p>
    </main>
  );
}
