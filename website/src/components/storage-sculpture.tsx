"use client";
import { useEffect, useRef, useState } from "react";
import { IconArrowUpRight, IconRotateClockwise } from "@tabler/icons-react";
import { asset } from "@/lib/site";
import type { createStorageScene } from "./storage-scene";
import type { animate } from "motion";

type Scene = ReturnType<typeof createStorageScene>;
export function StorageSculpture() {
  const host = useRef<HTMLDivElement>(null);
  const scene = useRef<Scene | null>(null);
  const animateRef = useRef<typeof animate | null>(null);
  const animation = useRef<{ stop: () => void } | null>(null);
  const mounted = useRef(false);
  const initializing = useRef(false);
  const target = useRef(false);
  const progress = useRef(0);
  const [hydrated, setHydrated] = useState(false);
  const [ready, setReady] = useState(false);
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [failed, setFailed] = useState(false);
  const reduce = () =>
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  function transition(next: boolean) {
    animation.current?.stop();
    if (!scene.current || !animateRef.current) return;
    if (reduce()) {
      progress.current = next ? 1 : 0;
      scene.current.update(progress.current);
      return;
    }
    animation.current = animateRef.current(progress.current, next ? 1 : 0, {
      type: "spring",
      bounce: 0,
      duration: 0.65,
      onUpdate(value) {
        progress.current = value;
        scene.current?.update(value);
      },
    });
  }
  async function activate() {
    if (initializing.current || scene.current || failed) return;
    initializing.current = true;
    setLoading(true);
    try {
      const [{ createStorageScene }, { animate }] = await Promise.all([
        import("./storage-scene"),
        import("motion"),
      ]);
      if (!mounted.current || !host.current) return;
      scene.current = createStorageScene(host.current);
      animateRef.current = animate;
      scene.current.update(progress.current);
      setReady(true);
      transition(target.current);
    } catch {
      if (mounted.current) setFailed(true);
    } finally {
      if (mounted.current) setLoading(false);
      initializing.current = false;
    }
  }
  useEffect(() => {
    mounted.current = true;
    setHydrated(true);
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    const onChange = () => {
      if (media.matches) {
        animation.current?.stop();
        progress.current = target.current ? 1 : 0;
        scene.current?.update(progress.current);
      }
    };
    media.addEventListener("change", onChange);
    return () => {
      mounted.current = false;
      media.removeEventListener("change", onChange);
      animation.current?.stop();
      scene.current?.dispose();
      scene.current = null;
    };
  }, []);
  return (
    <div className={`sculpture ${open ? "is-open" : ""}`}>
      <div
        className="sculpture-stage"
        onPointerEnter={(event) => {
          if (event.pointerType === "mouse" && !reduce()) void activate();
        }}
        onPointerMove={(event) => {
          if (reduce() || event.pointerType !== "mouse" || !scene.current)
            return;
          const box = event.currentTarget.getBoundingClientRect();
          scene.current.pointer(
            (event.clientX - box.left) / box.width - 0.5,
            (event.clientY - box.top) / box.height - 0.5,
          );
        }}
        onPointerLeave={() => scene.current?.pointer(0, 0)}
      >
        <img
          className={`sculpture-poster ${ready ? "hidden" : ""}`}
          src={asset(open && failed ? "sculpture-open.webp" : "sculpture.webp")}
          width="906"
          height="675"
          alt=""
          aria-hidden="true"
          fetchPriority="high"
        />
        <div ref={host} className="canvas-host" aria-hidden="true" />
        <div className="disk-shadow" />
        <span className="sculpture-label label-top">
          Less weight.
          <br />
          <strong>More possibility.</strong>
        </span>
        <span className="sculpture-label label-bottom">
          <span className="color-key" />
          Caches & build files
        </span>
      </div>
      <button
        className="sculpture-control"
        disabled={!hydrated}
        onFocus={() => {
          void activate();
        }}
        onClick={() => {
          const next = !target.current;
          target.current = next;
          setOpen(next);
          void activate();
          transition(next);
        }}
        aria-pressed={open}
        aria-describedby="sculpture-status"
      >
        {open ? (
          <IconRotateClockwise size={16} />
        ) : (
          <IconArrowUpRight size={16} />
        )}
        {open ? "Bring it back together" : "A little room to breathe"}
      </button>
      <span id="sculpture-status" className="demo-caption" role="status">
        {loading
          ? "Loading the interactive illustration…"
          : failed
            ? "Static illustration · 3D unavailable on this device"
            : "Interactive illustration · not your disk"}
      </span>
    </div>
  );
}
