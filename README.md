# Nutovia-Site

The marketing site and privacy policy for [Nutovia](https://nutovia.app) - a free family food scanner.

Static HTML/CSS/JS, no build step. Served by GitHub Pages from the repository root with the custom domain `nutovia.app` (see `CNAME`).

- `index.html` - landing page
- `privacy.html` - privacy policy (also the data-deletion instructions URL)
- `open/index.html` - web fallback for the `/open` deep link, shown only to visitors without the app

## Deep links

`.well-known/apple-app-site-association` and `.well-known/assetlinks.json` are
what let `https://nutovia.app/open` open the installed app instead of the
browser. Only `/open` and `/p/*` are claimed; every other page stays a web
page.

`.nojekyll` is load-bearing. GitHub Pages runs Jekyll by default and Jekyll
drops any directory starting with a dot, so without it `.well-known/` 404s
even though the files are committed.

After any change to either file, or after a Pages rebuild:

```bash
scripts/verify-applinks.sh
```

The full setup, the two certificate values those files need, and the
content-type caveat are documented in the app repo at `docs/DEEP_LINKS.md`.
