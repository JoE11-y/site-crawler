# site-to-pdf

A self-contained Bash script that crawls a website with a **headless Chrome**
and converts every reachable page (same host, within a depth/page limit) into
**PDF files**, optionally merging them into a single PDF. Images found on each
page are downloaded and **slotted back into the PDF in place**, so the output
embeds your own downloaded copies of the images.

The script **downloads its own dependencies** — it does not assume Chrome is
already installed. It runs on **Linux, macOS, and Windows (Git Bash / MSYS2)**.

---

## Quick start

```bash
# Crawl a site (default: 25 pages, depth 2) and write PDFs to ./output/<host>-<timestamp>/
./site-to-pdf.sh https://example.com

# No URL? A random demo site is chosen for you.
./site-to-pdf.sh

# A bigger crawl, deeper, with a polite 1s delay between pages
./site-to-pdf.sh https://example.com --max-pages 100 --depth 3 --delay 1
```

The first run downloads a headless browser into `./.cache/` (one-time, ~150 MB);
later runs reuse it.

---

## What it produces

```
output/<host>-<timestamp>/
├── 0001_example.com.pdf          # one PDF per crawled page
├── 0002_example.com_about.pdf
├── ...
├── _ALL_example.com.pdf          # all pages merged into one PDF (if a merger is available)
├── manifest.txt                  # <pdf filename> <TAB> <source url>
├── images/                       # downloaded images (img_0001.png, ...)
├── images-manifest.txt           # <local image path> <TAB> <source url>
└── pages/                        # local HTML snapshots used to embed the images
    └── 0001_example.com.html
```

---

## How it works

1. **Browser bootstrap** — Detects your OS/arch and downloads Google's official
   [Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/)
   `chrome-headless-shell` into `./.cache/`. If that binary can't launch (e.g.
   missing system libraries on a minimal Linux box), it automatically falls back
   to any Chrome/Chromium found on your `PATH`.
2. **Crawl** — Breadth-first from the start URL, following **same-host** links
   only, up to `--max-pages` and `--depth`. Obvious asset links (images, CSS,
   JS, archives, media) are not treated as pages. A `--delay` between requests
   keeps the crawl polite. Use `--select` to follow only a chosen section's links.
3. **Fetch** — Each page's HTML is fetched with Chrome `--dump-dom` (so
   JavaScript runs), **except** for a Basic-Auth host, which is fetched with
   `curl` (Chrome can't send Basic-Auth from the CLI — see *Authentication*).
4. **Render to PDF** — A local snapshot is built from that HTML (images
   downloaded and slotted back by id) and printed to PDF by Chrome.
5. **Merge** — If `pdfunite` (poppler) or `gs` (ghostscript) is present, all
   per-page PDFs are merged into `_ALL_<host>.pdf`. Otherwise the individual
   PDFs are left as-is.

---

## Output modes: visual copy vs content-only

By default each PDF is a **faithful visual copy** of the page (full styling,
images in place — a mirror of the site).

With **`--content-only`** (alias `--reader`) the script instead **extracts just
the information** and renders a clean document:

- Keeps the meaningful content and its structure — headings, paragraphs, lists,
  tables, blockquotes, and content images.
- Removes site **chrome and noise**: `<header>`, `<nav>`, `<footer>`, sidebars,
  forms, scripts/styles, and elements whose class/id looks like a cookie/share/
  promo/newsletter/related/pagination widget. This is what fixes the *"footer
  repeated on every page"* problem.
- Drops the site's own CSS and all class/id/inline styles, then applies a small
  readable stylesheet of its own — so the result is structured like the page's
  content but **doesn't look like the website**.
- Picks the page's `<main>`/`<article>` region when present; otherwise the body
  minus chrome.
- Content **images are still embedded** (downloaded and slotted back by id, as
  usual) unless you also pass `--no-images`.

Needs Python; without it the script falls back to the full visual copy (with a
notice). The clean per-page HTML snapshot is also saved under `pages/`.

```bash
./site-to-pdf.sh https://example.com --content-only
```

### Targeting a section: `--select`

To make the crawler **follow only the links inside a specific part of the page**
— e.g. a side nav of categories — use `--select` (alias `--section` /
`--target`) with a simple selector:

- `tagname` — e.g. `aside`, `nav`, `main`
- `.class` — element whose class contains that value, e.g. `.sidebar`
- `#id` — element whose id contains that value, e.g. `#side-menu`
- a **bare word** also matches a class or id, so `--select sidebar` matches
  `<div class="col-lg-3 sidebar">`
- several at once, comma-separated: `--select 'aside, .sidebar, #toc'`

`--select` **scopes link discovery only** — the crawler walks just the links
found inside that region (header/main/footer links elsewhere are ignored). It
does **not** change what each PDF contains: with `--content-only` each PDF still
holds that page's **main content** (e.g. the product listings), not the repeated
nav. Pages where the selector matches nothing contribute no links.

```bash
# Follow only the side-nav categories; each PDF = that page's main content
./site-to-pdf.sh https://webscraper.io/test-sites/e-commerce/allinone \
  --select sidebar --content-only
```

Needs Python; matching is forgiving (token or substring of class/id). Selectors
are limited to tag / `.class` / `#id` (no full CSS combinators).

---

## Progress output

While running, the script keeps you informed of exactly what it's doing:

- **Browser download** shows a real download progress bar.
- Each page prints a **header** with overall progress, queue size, image count
  so far, and elapsed time:
  ```
  [*] [3/25] depth 1 | queue 14 | imgs 27 | 0:42 elapsed
      https://example.com/about
  ```
  (`queue 14` = 14 URLs still pending.)
- Long Chrome operations (loading a page, rendering the PDF) show a **live
  spinner with elapsed seconds** so it never looks frozen.
- Image downloads show a running **counter** (`downloading image 5/12 ...`).
- A final **summary** reports pages, PDFs, images, and total time.

Live animations (spinner, counters, progress bar) are shown only when output is
an interactive terminal. When piped or redirected to a file, output stays as
clean, plain log lines.

### Interrupting (Ctrl-C)

- **Press Ctrl-C once** to **skip the current page** (e.g. one that's hanging on
  a slow load or download) and continue with the next — the crawl is *not*
  killed.
- **Double-tap Ctrl-C** (twice within ~1 second) to **stop the whole crawl**
  gracefully: it finishes up, keeps everything produced so far, and still merges
  the PDFs collected up to that point.

---

## Image handling

By default (`DOWNLOAD_IMAGES=yes`) the script uses **slot-back** mode:

1. The rendered DOM of each page is scanned; every `<img>` source is replaced
   with a placeholder id (`CRAWLIMG_0001`, ...) and recorded.
2. Each image is downloaded into `images/` by id.
3. The placeholder is replaced with a `file://` path to the **local** image
   (using the id), and the snapshot is saved under `pages/`.
4. Chrome prints that local snapshot to PDF — so the PDF embeds **your
   downloaded image files**, exactly where they appeared on the page.

If an individual image fails to download, that placeholder falls back to the
live URL so the page still renders. CSS/JS referenced by the page are rewritten
to absolute URLs so the snapshot still styles correctly when printed.

**Requires Python** (`python3` or `python`). If Python isn't available, the
script renders the *live* page instead — Chrome still paints the images into the
PDF, and `images/` is kept as a separate archive — but the slot-back-by-id step
is skipped. Use `--no-images` to skip image downloading entirely.

---

## Authentication (HTTP Basic Auth)

If a site pops up the browser's native username/password dialog, that's **HTTP
Basic Auth**. Supply credentials via env vars (sent **only** to the start host):

```bash
CRAWL_USER='alice' CRAWL_PASS='s3cret!' ./site-to-pdf.sh https://intranet.example.com
```

> **Important:** pass them on the **same command line** as the script (or
> `export` them first). A bare `CRAWL_USER=...` on its own line is a *shell*
> variable that the script — a child process — does **not** inherit.

**How it works:** headless Chrome can't send Basic-Auth from the command line,
so for the Basic-Auth host the script fetches the page HTML with **curl `-u`**
(which authenticates reliably), then renders a local snapshot. Images on that
host are likewise fetched with curl + credentials.

> **Caveat — JavaScript:** because the authed host is fetched with curl (no JS
> engine), it works only for **server-rendered** pages. If the page's content or
> navigation is injected by JavaScript, curl sees an empty shell. (`--debug`
> shows the fetched byte size — a tiny number means a JS-only page.)

> **Security:** the password is handed to the curl child (`-u`), so it can appear
> in the process list (`ps`) while that runs. Avoid on shared/multi-user hosts.

> Only HTTP Basic Auth is supported — **not** HTML form logins.

---

## Options

```
Usage: ./site-to-pdf.sh [URL] [options]
```

| Option                  | Default                              | Description                                                        |
|-------------------------|--------------------------------------|--------------------------------------------------------------------|
| `URL` (positional)      | random demo site                     | The site to crawl. A missing `https://` is added automatically.    |
| `-n`, `--max-pages N`   | `25`                                 | Maximum number of pages to crawl.                                  |
| `-d`, `--depth N`       | `2`                                  | Maximum crawl depth from the start URL.                            |
| `-o`, `--out DIR`       | `./output/<host>-<timestamp>`        | Output directory.                                                  |
| `--delay SEC`           | `0.5`                                | Delay between page loads, in seconds.                              |
| `--merge`               | auto                                 | Force merging the per-page PDFs into one file.                     |
| `--no-merge`            | —                                    | Keep individual per-page PDFs only.                                |
| `--use-system-chrome`   | off                                  | Skip the download; use a Chrome/Chromium found on `PATH`.          |
| `--timeout MS`          | `12000`                              | Per-page render budget in milliseconds (raise for slow/lazy pages).|
| `--no-images`           | off (images on)                      | Do not download images; leave them as live URLs in the PDF.        |
| `--content-only`, `--reader` | off                             | Reader mode: extract just the content into a clean PDF, dropping chrome & site styling. |
| `--select`, `--section`, `--target` `SEL` | off                | Follow only links inside section(s) matching `SEL` (tag, `.class`, `#id`, or bare word; comma-separated). Scopes crawling, not extraction. |
| `--proxy URL`           | off                                  | Route Chrome + curl/wget through a proxy (e.g. corporate).         |
| `--proxy-host H`        | —                                    | Proxy host (alternative to `--proxy`; env `PROXY_HOST`).           |
| `--proxy-port P`        | —                                    | Proxy port (env `PROXY_PORT`).                                     |
| `--proxy-user U`        | —                                    | Proxy username for an authenticated proxy (env `PROXY_USER`).      |
| `--proxy-pass P`        | —                                    | Proxy password (env `PROXY_PASS`). Used by curl/wget; Chrome can't take proxy creds via CLI. |
| `--insecure`, `-k`      | off                                  | Ignore TLS certificate errors (QA / intercepting proxies).         |
| `--debug`               | off                                  | Show child stderr (Chrome, Python, curl `-v`) for troubleshooting. |
| `-h`, `--help`          | —                                    | Show help and exit.                                                |

### Environment variables

| Variable     | Description                                              |
|--------------|----------------------------------------------------------|
| `CRAWL_USER` | HTTP Basic-Auth username for the target host.            |
| `CRAWL_PASS` | HTTP Basic-Auth password for the target host.            |
| `PROXY_HOST` / `PROXY_PORT` / `PROXY_USER` / `PROXY_PASS` | Authenticated-proxy parts (alternative to `--proxy`). |

> Pass `CRAWL_USER`/`CRAWL_PASS` on the **same command line** as the script (or `export` them) — a bare `VAR=value` on its own line is a shell variable the script won't inherit.

---

## Dependencies

| Capability        | Auto-downloaded? | Tools used (first available wins)                         |
|-------------------|------------------|-----------------------------------------------------------|
| Headless browser  | ✅ yes           | Chrome for Testing `chrome-headless-shell` → system Chrome/Chromium |
| Downloading       | uses what's there| `curl` → `wget`                                           |
| Unzipping         | uses what's there| `unzip` → `python` `zipfile` → `tar`/bsdtar               |
| Page/content/section processing | n/a | **Python 3** (`python3` → `python` → `py`) — **required** |
| PDF merge         | ❌ no            | `pdfunite` (poppler) → `gs` (ghostscript) (optional)      |

**Required:** **Python 3**, plus **`curl` or `wget`**. (For the one-time browser
unzip you also need one of `unzip` / `python` / `tar` — Python covers it.)
Everything else is optional.

### Dependency safety checks

The script verifies its requirements up front and never crashes with a raw
error. If **Python** or a **downloader** is missing, you get a clean message
naming the dependency and the **exact install command for your OS/package
manager** (apt, dnf, yum, pacman, zypper, apk, brew, winget, choco, scoop, or a
download link), then it exits. If no PDF **merger** is found, you're told how to
install `poppler` and the per-page PDFs are kept.

> On Windows, the script skips the Microsoft Store **`python` alias stub** (it
> only prints "Python was not found…") and picks a real interpreter.

### Installing the optional merge tools

```bash
# Debian/Ubuntu
sudo apt-get install -y poppler-utils      # provides pdfunite
# macOS (Homebrew)
brew install poppler
# Windows: install poppler or ghostscript, or just use the per-page PDFs
```

---

## Platform notes

- **Linux**: the downloaded `chrome-headless-shell` may need a few shared
  libraries. If it fails to launch, install them and re-run, e.g.:
  ```bash
  sudo apt-get install -y libnss3 libgbm1 libasound2
  ```
  (The script also auto-falls-back to a system Chrome/Chromium if one exists.)
- **macOS**: works with the stock `/bin/bash` (3.2) — the script avoids bash 4+
  features.
- **Windows (Git Bash / MSYS2)**: works out of the box. Local file paths are
  converted for Chrome via `cygpath`. If `unzip` is missing, the bundled
  `tar`/bsdtar or Python is used to extract the browser.

---

## Limitations & tips

- **Same-host only**: the crawler does not follow links to other domains
  (images are still downloaded from wherever they're hosted).
- **`--select` matching** is substring-based on tag / `.class` / `#id` (a bare
  word also matches a class/id). So `--select nav` also matches `navbar`. No CSS
  combinators (e.g. `.sidebar a`).
- **JavaScript**: normal pages are fetched with Chrome `--dump-dom`, so JS runs.
  But a **Basic-Auth host** is fetched with curl (no JS) — so it must be
  server-rendered there; a JS-only page/nav yields an empty shell.
- **Lazy-loaded images**: if some images are missing from a PDF, increase the
  render budget, e.g. `--timeout 25000`.
- **Form logins are not supported** — only HTTP Basic Auth.
- Be responsible: only crawl sites you are authorized to, and mind their
  `robots.txt` and terms of service.

---

## Examples

```bash
# Deep crawl, single merged PDF, slower to be gentle on the server
./site-to-pdf.sh https://docs.example.com -n 200 -d 4 --delay 1.5 --merge

# Authenticated site behind a corporate proxy (reader mode)
CRAWL_USER=alice CRAWL_PASS='pw' \
  ./site-to-pdf.sh https://intranet.example.com/docs/ \
  --content-only --proxy http://proxy.corp:8080 --insecure

# Authenticated proxy via separate parts
CRAWL_USER=alice CRAWL_PASS='pw' \
PROXY_HOST=proxy.corp PROXY_PORT=8080 PROXY_USER=alice PROXY_PASS=pw \
  ./site-to-pdf.sh https://intranet.example.com/docs/ --content-only --insecure

# Just the PDFs, no image downloading, into a chosen folder
./site-to-pdf.sh https://example.com --no-images -o ./pdfs

# Reuse an already-installed Chrome instead of downloading one
./site-to-pdf.sh https://example.com --use-system-chrome

# Reader mode: clean content-only PDFs (no header/nav/footer, no site styling)
./site-to-pdf.sh https://example.com --content-only

# Reader mode, text only (drop images too)
./site-to-pdf.sh https://example.com --content-only --no-images

# Follow only a side nav's links; each PDF holds that page's main content
./site-to-pdf.sh https://example.com --select sidebar --content-only
```
