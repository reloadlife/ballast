import Link from "next/link";
export default function NotFound() {
  return (
    <main id="main" className="article-shell">
      <h1>
        Nothing taking up
        <br />
        space here.
      </h1>
      <p>
        This page could not be found. <Link href="/">Return to Ballast</Link> or{" "}
        <Link href="/guides/">browse the guides</Link>.
      </p>
    </main>
  );
}
