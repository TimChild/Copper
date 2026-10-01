# Copper — website

The static landing page for [Copper](https://github.com/copper-browser/Copper), meant to be
served by GitHub Pages at `https://copper-browser.github.io/Copper/`.

- `index.html` — the whole page: inline CSS and a little vanilla JS. No framework, no build
  step, no external fonts, CDNs or trackers.
- `assets/` — the screenshot (WebP), app icon, favicons and the 1200×630 `og.png` social card.
- `.nojekyll` — serve the files as they are.

Every path is relative, so the page works from the Pages URL, from any subpath, and straight
from `file://`.

## Preview locally

```sh
python3 -m http.server -d site
```

then open <http://localhost:8000/>.
