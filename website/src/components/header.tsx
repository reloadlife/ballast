import Link from "next/link";
import { IconArrowUpRight, IconBrandGithub } from "@tabler/icons-react";
import { asset, github } from "@/lib/site";
import { Button } from "./ui/button";
export function Header() {
  return (
    <header className="site-header">
      <Link href="/" className="brand" aria-label="Ballast home">
        <img src={asset("icon.png")} width="36" height="36" alt="" />
        Ballast
      </Link>
      <nav aria-label="Main navigation">
        <Link href="/#features">Features</Link>
        <Link href="/guides/">Guides</Link>
        <a href={github} className="github-nav">
          <IconBrandGithub size={17} />
          Source
        </a>
      </nav>
      <Button asChild size="sm">
        <Link href="/download/">
          Get Ballast
          <IconArrowUpRight size={15} />
        </Link>
      </Button>
    </header>
  );
}
