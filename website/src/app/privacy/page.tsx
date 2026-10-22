import Link from "next/link";
import { github } from "@/lib/site";
import { pageMetadata } from "@/lib/metadata";
export const metadata = pageMetadata(
  "Privacy",
  "How Ballast handles local disk data, optional usage sharing, update checks, and website requests.",
  "privacy/",
);
export default function Privacy() {
  return (
    <main id="main" className="article-shell">
      <Link className="breadcrumb" href="/">
        Ballast / Privacy
      </Link>
      <h1>
        Your files.
        <br />
        On your Mac.
      </h1>
      <p className="lede">
        Ballast’s disk index and cleanup work stay local. Network features are
        explained separately so you can choose what to enable.
      </p>
      <h2>Disk data</h2>
      <p>
        The index, settings, cleanup history, and growth records are stored in
        Ballast’s Application Support folder on your Mac. Disk indexing does not
        upload your file names, paths, or disk contents.
      </p>
      <h2>Optional usage sharing</h2>
      <p>
        Anonymous usage sharing is off until you agree. If enabled, Ballast uses
        PostHog for defined usage events with fixed-list values, booleans, and
        ranges. File names, paths, and exact sizes are excluded. Settings →
        Privacy shows what can be sent and the queued events, and lets you turn
        sharing off.
      </p>
      <h2>Update checks and developer tools</h2>
      <p>
        Automatic app update checks are opt-in. A manual update check contacts
        the release service when you request it. Homebrew update checks and
        package operations contact Homebrew and relevant package sources when
        requested.
      </p>
      <h2>This website</h2>
      <p>
        This site does not add analytics scripts, advertising trackers, or
        tracking cookies. Fonts and visual assets are served with the site.
        GitHub Pages hosts the website and may process standard request
        information under{" "}
        <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement">
          GitHub’s privacy statement
        </a>
        . Following a GitHub or other external link opens a service with its own
        policies.
      </p>
      <h2>Inspect the implementation</h2>
      <p>
        The <a href={`${github}#privacy`}>app’s privacy documentation</a> and{" "}
        <a href={`${github}/blob/main/Sources/Ballast/Telemetry.swift`}>
          public repository
        </a>{" "}
        explain the events and controls. If you spot a mismatch, please{" "}
        <a href={`${github}/issues`}>open an issue</a>.
      </p>
    </main>
  );
}
