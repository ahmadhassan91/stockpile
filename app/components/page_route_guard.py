"""Client-side route guards for Streamlit multipage navigation."""

from __future__ import annotations

import json

import streamlit.components.v1 as components

CANONICAL_PAGE_PATHS = {
    "app": "/",
    "Upload": "/Upload",
    "Processing": "/Processing",
    "Results": "/Results",
    "Debug": "/Debug",
}


def enforce_canonical_route(page_name: str) -> None:
    """Normalize the browser URL gently and patch sidebar links without forcing navigation."""
    target_path = CANONICAL_PAGE_PATHS[page_name]
    payload = json.dumps(CANONICAL_PAGE_PATHS)
    target = json.dumps(target_path)
    components.html(
        f"""
        <script>
        const routeMap = {payload};
        const targetPath = {target};

        const normalize = (pathname) => {{
          if (!pathname) return "/";
          const trimmed = pathname.replace(/\/+$/, "");
          return trimmed === "" ? "/" : trimmed;
        }};

        const patchLinks = () => {{
          const doc = window.parent.document;
          doc.querySelectorAll("a[href]").forEach((anchor) => {{
            const label = (anchor.textContent || "").trim();
            if (routeMap[label]) {{
              anchor.setAttribute("href", routeMap[label]);
              anchor.href = routeMap[label];
              return;
            }}

            const href = anchor.getAttribute("href") || "";
            if (href === "#" || href.startsWith("#")) {{
              return;
            }}

            if (href.endsWith("/Upload") || href.endsWith("/Upload/Upload")) {{
              anchor.setAttribute("href", routeMap.Upload);
              anchor.href = routeMap.Upload;
            }} else if (href.endsWith("/Processing") || href.endsWith("/Upload/Processing")) {{
              anchor.setAttribute("href", routeMap.Processing);
              anchor.href = routeMap.Processing;
            }} else if (href.endsWith("/Results") || href.endsWith("/Upload/Results")) {{
              anchor.setAttribute("href", routeMap.Results);
              anchor.href = routeMap.Results;
            }} else if (href.endsWith("/Debug") || href.endsWith("/Upload/Debug")) {{
              anchor.setAttribute("href", routeMap.Debug);
              anchor.href = routeMap.Debug;
            }}
          }});
        }};

        const currentPath = normalize(window.parent.location.pathname);
        patchLinks();

        if (currentPath !== targetPath) {{
          try {{
            window.parent.history.replaceState(window.parent.history.state, "", targetPath);
          }} catch (error) {{
            // Ignore cross-frame navigation issues and rely on server-side redirects.
          }}
        }}
        </script>
        """,
        height=0,
        width=0,
    )
