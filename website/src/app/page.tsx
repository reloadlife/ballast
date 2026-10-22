import Link from "next/link";
import {
  IconArrowRight,
  IconArrowUpRight,
  IconBrandApple,
  IconBrandGithub,
  IconShieldCheck,
  IconTrash,
  IconArrowBackUp,
  IconCode,
  IconCheck,
} from "@tabler/icons-react";
import { Button } from "@/components/ui/button";
import { StorageSculpture } from "@/components/storage-sculpture";
import { JsonLd } from "@/components/json-ld";
import { absolute, asset, github, description } from "@/lib/site";
import { faqs } from "@/lib/content";
export default function Home() {
  return (
    <main id="main">
      <JsonLd
        data={[
          {
            "@context": "https://schema.org",
            "@type": "SoftwareApplication",
            name: "Ballast",
            description,
            applicationCategory: "UtilitiesApplication",
            operatingSystem: "macOS 26 or later",
            url: absolute(),
            downloadUrl: `${github}/releases/latest`,
            isAccessibleForFree: true,
            license: `${github}/blob/main/LICENSE`,
            sameAs: github,
            offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
            image: absolute("og.png"),
          },
          {
            "@context": "https://schema.org",
            "@type": "FAQPage",
            mainEntity: faqs.map(([question, answer]) => ({
              "@type": "Question",
              name: question,
              acceptedAnswer: { "@type": "Answer", text: answer },
            })),
          },
        ]}
      />
      <section className="hero section-width">
        <div className="hero-copy">
          <h1>
            Make room
            <br />
            for what’s <span>next.</span>
          </h1>
          <p>
            Your Mac has more to give. Find what’s taking up space, clear what
            you don’t need, and get back to it.
          </p>
          <div className="hero-actions">
            <Button asChild size="lg">
              <Link href="/download/">
                <IconBrandApple size={20} />
                Download for Mac
              </Link>
            </Button>
            <a className="text-link" href={github}>
              View source
              <IconArrowUpRight size={17} />
            </a>
          </div>
          <p className="hero-note">Free. Fully open source. macOS 26+.</p>
        </div>
        <StorageSculpture />
      </section>
      <div className="promise-strip section-width">
        <span>
          <IconBrandApple />
          Native SwiftUI
        </span>
        <span>
          <IconShieldCheck />
          Review before you remove
        </span>
        <span>
          <IconBrandGithub />
          Yours to inspect
        </span>
      </div>
      <section className="overview-section section-width" id="features">
        <div className="section-heading">
          <h2>
            From “disk full”
            <br />
            to the full picture.
          </h2>
          <p>
            A disk cleaner that starts with understanding.
            <br />
            Ballast maps your storage, explains what it finds, and helps you
            decide what can go.
          </p>
        </div>
        <figure className="app-preview">
          <div className="window-bar" aria-hidden="true">
            <div>
              <i />
              <i />
              <i />
            </div>
            <span>Ballast</span>
            <span>Overview</span>
          </div>
          <div className="app-screen">
            <aside aria-hidden="true">
              <span className="sidebar-active">Overview</span>
              <span>Explorer</span>
              <span>Suggestions</span>
              <div>Developer tools</div>
              <span>Homebrew</span>
              <span>Git Worktrees</span>
              <small>Macintosh HD</small>
            </aside>
            <img
              src={asset("overview-light.png")}
              width="830"
              height="390"
              loading="lazy"
              alt="Ballast’s real Overview screen: storage by category, 79.08 GB available, and 39.08 GB of caches and build files identified for review."
            />
          </div>
          <figcaption>
            Actual Ballast Overview, shown inside an illustrative window. Your
            disk will tell its own story.
          </figcaption>
        </figure>
        <div className="feature-notes">
          <div>
            <h3>See where it went.</h3>
            <p>
              Explore a visual map of your folders. Find large files,
              duplicates, and the folders that grew since your last visit.
            </p>
          </div>
          <div>
            <h3>Know what can go.</h3>
            <p>
              Get suggestions with plain-language reasons. Review caches, old
              installers, unused apps, and more in one cleanup list.
            </p>
          </div>
        </div>
      </section>
      <section className="speed-section">
        <div className="section-width speed-layout">
          <div
            className="index-visual"
            aria-label="Ballast measures the disk once, then updates only changed folders"
          >
            <div className="index-sheet">
              <div className="index-title">
                Your disk, remembered.
                <IconCheck size={20} />
              </div>
              {[
                "Applications",
                "Documents",
                "Projects",
                "Library",
                "Downloads",
              ].map((name, i) => (
                <div className="index-row" key={name}>
                  <span className={`folder-tile folder-${i}`} />
                  <span>{name}</span>
                  <span>{i === 2 ? "Updated" : "Unchanged"}</span>
                </div>
              ))}
              <div className="index-foot">
                Only what changed needs another look.
              </div>
            </div>
          </div>
          <div className="speed-copy">
            <h2>
              The next scan?
              <br />
              Already a step ahead.
            </h2>
            <p>
              Most of your disk hasn’t changed. Why measure it all over again?
            </p>
            <p>
              Ballast builds a full index once, then follows the change log
              macOS already keeps. Only changed folders need another look.
            </p>
            <Link className="text-link" href="/guides/how-ballast-works/">
              Meet the engine
              <IconArrowRight size={17} />
            </Link>
          </div>
        </div>
      </section>
      <section className="safety-section section-width">
        <div>
          <h2>
            It’s your disk.
            <br />
            You make the call.
          </h2>
          <p>
            Cleaning should feel considered. Every item comes with a safety
            verdict, checked again right before removal.
          </p>
          <Link className="text-link" href="/guides/safe-mac-cleanup/">
            How cleanup stays careful
            <IconArrowRight size={17} />
          </Link>
        </div>
        <div className="safety-steps">
          <article>
            <IconShieldCheck />
            <div>
              <h3>A reason, not a guess.</h3>
              <p>
                Safe to clean, quit the app first, check first, or protected.
                You can see why.
              </p>
            </div>
          </article>
          <article>
            <IconTrash />
            <div>
              <h3>The Trash comes first.</h3>
              <p>
                Regular file cleanup moves items to the Trash by default.
                Permanent deletion is a separate choice.
              </p>
            </div>
          </article>
          <article>
            <IconArrowBackUp />
            <div>
              <h3>A way back.</h3>
              <p>
                Put Back restores items still in the Trash without overwriting
                new files. Tool commands and permanent deletion cannot be
                undone.
              </p>
            </div>
          </article>
        </div>
      </section>
      <section className="developer-section section-width">
        <div className="developer-copy">
          <IconCode size={30} />
          <h2>
            For the things
            <br />
            you build, too.
          </h2>
          <p>
            That abandoned side project still has a node_modules folder. Ballast
            speaks developer, so you don’t have to hunt for every leftover.
          </p>
          <Link className="text-link" href="/guides/developer-cache-cleanup/">
            Explore developer cleanup
            <IconArrowUpRight size={17} />
          </Link>
        </div>
        <div
          className="developer-files"
          aria-label="Supported developer cleanup categories"
        >
          <div>
            <code>node_modules</code>
            <span>Project dependencies</span>
          </div>
          <div>
            <code>DerivedData</code>
            <span>Xcode build output</span>
          </div>
          <div>
            <code>.next / target / .build</code>
            <span>Recognized build folders</span>
          </div>
          <div>
            <code>brew / git worktree</code>
            <span>Managed through their own tools</span>
          </div>
          <p>Plus npm, Bun, pnpm, pip, uv, Cargo, Gradle, and more.</p>
        </div>
      </section>
      <section className="open-section section-width">
        <div className="open-symbol" aria-hidden="true">{`{ }`}</div>
        <div>
          <h2>
            Good software.
            <br />
            Nothing to hide.
          </h2>
          <p>
            Every line of Ballast is open source. Read the safety rules, build
            it yourself, or help make it better. No subscription. No locked
            features.
          </p>
          <a className="text-link" href={github}>
            Explore Ballast on GitHub
            <IconArrowUpRight size={18} />
          </a>
          <p className="small-copy">
            AGPL-3.0 licensed. App update checks and anonymous usage sharing are
            opt-in.
          </p>
        </div>
      </section>
      <section className="faq-section section-width">
        <h2>
          A little clarity
          <br />
          before you clean.
        </h2>
        <div>
          {faqs.map(([question, answer]) => (
            <details key={question}>
              <summary>
                {question}
                <span aria-hidden="true">+</span>
              </summary>
              <p>{answer}</p>
            </details>
          ))}
          <Link href="/guides/" className="text-link">
            More answers in the guides
            <IconArrowRight size={17} />
          </Link>
        </div>
      </section>
      <section className="closing-section section-width">
        <h2>
          Your next big thing
          <br />
          could use a little space.
        </h2>
        <Button asChild size="lg">
          <Link href="/download/">
            <IconBrandApple size={20} />
            Get Ballast. It’s free.
          </Link>
        </Button>
        <p>Made for macOS 26 and later.</p>
      </section>
    </main>
  );
}
