"use client";

import { useEffect, useState } from "react";

import { gravatarEnabledFromCookie, gravatarHash, gravatarUrl } from "@/lib/gravatar";
import { cn } from "@/lib/utils";

interface UserAvatarProps {
  email?: string | null;
  /** Display name or username, used for the initials fallback. */
  name?: string | null;
  /** Rendered size in px; also drives the Gravatar request (at 2x for retina). */
  size?: number;
  className?: string;
}

function initialsFor(name?: string | null): string {
  const parts = (name ?? "").trim().split(/[\s._-]+/).filter(Boolean);
  if (parts.length === 0) return "";
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase();
}

/**
 * Avatar for a user: their Gravatar if they have one, otherwise their initials
 * on the neutral gradient placeholder.
 */
export function UserAvatar({ email, name, size = 28, className }: UserAvatarProps) {
  const key = email ?? "";
  // Keyed by email so a user switch discards the previous avatar during render
  // rather than needing an effect to reset it.
  const [resolved, setResolved] = useState<{ email: string; url: string | null }>();
  const src = resolved?.email === key ? resolved.url : null;

  useEffect(() => {
    // Checked here rather than during render: the flag arrives on a cookie, which
    // a server render can't see, so branching on it above would mismatch on
    // hydration. Nothing has been sent to gravatar.com at this point.
    if (!key || !gravatarEnabledFromCookie(document.cookie)) return;

    let cancelled = false;
    void gravatarHash(key).then((hash) => {
      if (!cancelled && hash) setResolved({ email: key, url: gravatarUrl(hash, size * 2) });
    });
    return () => {
      cancelled = true;
    };
  }, [key, size]);

  const initials = initialsFor(name);

  return (
    <div
      className={cn(
        "relative shrink-0 overflow-hidden rounded-full bg-gradient-to-br from-muted to-border",
        "flex items-center justify-center font-semibold text-muted-foreground select-none",
        className,
      )}
      style={{ width: size, height: size, fontSize: Math.round(size * 0.38) }}
    >
      {initials}
      {src && (
        // eslint-disable-next-line @next/next/no-img-element -- external avatar host, no Next image optimization
        <img
          src={src}
          alt=""
          width={size}
          height={size}
          className="absolute inset-0 h-full w-full object-cover"
          referrerPolicy="no-referrer"
          // A 404 means the user has no Gravatar: drop back to the initials.
          onError={() => setResolved({ email: key, url: null })}
        />
      )}
    </div>
  );
}
