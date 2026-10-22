import Link from "next/link";
import { notFound } from "next/navigation";
import { guides } from "@/lib/content";
import { pageMetadata } from "@/lib/metadata";
import { absolute, github } from "@/lib/site";
import { JsonLd } from "@/components/json-ld";
export const dynamicParams = false;
export function generateStaticParams() {
  return guides.map(({ slug }) => ({ slug }));
}
export async function generateMetadata({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const guide = guides.find((g) => g.slug === slug);
  return guide
    ? pageMetadata(guide.title, guide.description, `guides/${slug}/`)
    : {};
}
export default async function GuidePage({
  params,
}: {
  params: Promise<{ slug: string }>;
}) {
  const { slug } = await params;
  const guide = guides.find((g) => g.slug === slug);
  if (!guide) notFound();
  return (
    <main id="main" className="article-shell">
      <JsonLd
        data={[
          {
            "@context": "https://schema.org",
            "@type": "Article",
            headline: guide.title,
            description: guide.description,
            mainEntityOfPage: absolute(`guides/${slug}/`),
            author: { "@type": "Organization", name: "Ballast", url: github },
            publisher: {
              "@type": "Organization",
              name: "Ballast",
              url: absolute(),
            },
            image: absolute("og.png"),
          },
          {
            "@context": "https://schema.org",
            "@type": "BreadcrumbList",
            itemListElement: [
              {
                "@type": "ListItem",
                position: 1,
                name: "Ballast",
                item: absolute(),
              },
              {
                "@type": "ListItem",
                position: 2,
                name: "Guides",
                item: absolute("guides/"),
              },
              {
                "@type": "ListItem",
                position: 3,
                name: guide.title,
                item: absolute(`guides/${slug}/`),
              },
            ],
          },
        ]}
      />
      <Link href="/guides/" className="breadcrumb">
        Ballast / Guides
      </Link>
      <h1>{guide.title}</h1>
      <p className="lede">{guide.description}</p>
      <p className="article-meta">
        By the Ballast project · Based on the public app documentation
      </p>
      {guide.sections.map((section) => (
        <section key={section.title}>
          <h2>{section.title}</h2>
          {section.paragraphs.map((paragraph) => (
            <p key={paragraph}>{paragraph}</p>
          ))}
        </section>
      ))}
      <p className="article-source">
        Source: <a href={`${github}#readme`}>Ballast’s README</a> and{" "}
        <a href={`${github}/tree/main/Sources/Ballast/Engine`}>
          open-source engine
        </a>
        . <Link href="/download/">Download Ballast</Link> for macOS 26 and
        later.
      </p>
      <h2>Keep exploring</h2>
      <ul>
        {guides
          .filter((g) => g.slug !== slug)
          .map((g) => (
            <li key={g.slug}>
              <Link href={`/guides/${g.slug}/`}>{g.title}</Link>
            </li>
          ))}
      </ul>
    </main>
  );
}
