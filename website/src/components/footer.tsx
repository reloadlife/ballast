import Link from "next/link";
import { github } from "@/lib/site";
export function Footer() {
  return (
    <footer className="site-footer">
      <div>
        <Link className="footer-brand" href="/">
          Ballast
        </Link>
        <p>
          A little less on your disk.
          <br />A lot more room for you.
        </p>
      </div>
      <nav aria-label="Footer navigation">
        <Link href="/download/">Download</Link>
        <a href={github}>GitHub</a>
        <Link href="/guides/">Guides</Link>
        <Link href="/cleanmymac-alternative/">CleanMyMac alternative</Link>
        <Link href="/privacy/">Privacy</Link>
        <a href={`${github}/blob/main/LICENSE`}>AGPL-3.0 license</a>
      </nav>
      <div className="footer-bottom">
        <span>Made for Mac. Open to everyone.</span>
        <span>Independent, free & open source.</span>
      </div>
    </footer>
  );
}
