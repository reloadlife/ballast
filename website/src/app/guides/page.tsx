import Link from "next/link";
import { guides } from "@/lib/content";
import { pageMetadata } from "@/lib/metadata";
export const metadata = pageMetadata(
  "Mac storage & cleanup guides",
  "Clear explanations of Mac System Data, safe cleanup, developer caches, and how Ballast’s disk index works.",
  "guides/",
);
export default function Guides() {
  return (
    <main id="main" className="article-shell">
      <Link className="breadcrumb" href="/">
        Ballast / Guides
      </Link>
      <h1>
        A clearer picture
        <br />
        of your Mac.
      </h1>
      <p className="lede">
        Understand the space before you clear it. Practical answers, with the
        limits explained.
      </p>
      <div className="guide-list">
        {guides.map((guide) => (
          <Link href={`/guides/${guide.slug}/`} key={guide.slug}>
            <h2>{guide.title}</h2>
            <p>{guide.description}</p>
          </Link>
        ))}
      </div>
    </main>
  );
}
