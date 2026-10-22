import Link from "next/link";
import { IconBrandApple, IconArrowUpRight } from "@tabler/icons-react";
import { Button } from "@/components/ui/button";
import { download, github } from "@/lib/site";
import { pageMetadata } from "@/lib/metadata";
export const metadata = pageMetadata(
  "Download Ballast for Mac",
  "Download the free, open-source Ballast disk cleaner for macOS 26+. Installation steps, release notes, and first-launch guidance.",
  "download/",
);
export default function Download() {
  return (
    <main id="main" className="article-shell">
      <Link href="/" className="breadcrumb">
        Ballast / Download
      </Link>
      <h1>
        A fresh start
        <br />
        for your storage.
      </h1>
      <p className="lede">
        Get the full app. Free, open source, and ready to help you understand
        your disk.
      </p>
      <div className="download-callout">
        <Button asChild size="lg">
          <a href={download}>
            <IconBrandApple size={20} />
            Download Ballast.zip
          </a>
        </Button>
        <p>
          Requires macOS 26 or later. Downloads the latest release from GitHub.
        </p>
        <a className="text-link" href={`${github}/releases/latest`}>
          Release notes & checksum
          <IconArrowUpRight size={16} />
        </a>
      </div>
      <h2>Install in a few steps</h2>
      <ol>
        <li>Download Ballast.zip and unzip it.</li>
        <li>Move Ballast to your Applications folder.</li>
        <li>
          Open Ballast. Current release instructions describe ad-hoc signing,
          without Apple notarization. If macOS blocks the first launch, review
          the release source, then go to System Settings → Privacy & Security →
          Open Anyway.
        </li>
        <li>
          Let the initial disk scan finish. If you want to measure
          privacy-protected folders, follow Ballast’s Full Disk Access guidance.
        </li>
      </ol>
      <p>
        Check the release notes for the current signing status and requirements.
        Ballast explains folders it cannot read; you can start exploring without
        granting every optional permission.
      </p>
      <h2>Updates stay your choice.</h2>
      <p>
        Ballast asks before enabling automatic update checks. You can also
        choose Check for Updates from the app. Downloaded updates are verified
        against the signing key built into the app.
      </p>
      <h2>Prefer to build it yourself?</h2>
      <p>
        The Swift source, build instructions, and safety checks are public in
        the <a href={github}>Ballast repository</a>. Ballast is licensed under
        AGPL-3.0.
      </p>
      <p>
        <Link href="/guides/safe-mac-cleanup/">
          Read the safe cleanup guide
        </Link>{" "}
        before your first cleanup.
      </p>
    </main>
  );
}
