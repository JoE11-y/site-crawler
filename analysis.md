# Review: `site-to-pdf.sh` (1,450 lines)

Reviewed against the current script, which has grown well beyond the first pass —
it now has **content / reader mode** (`--content-only`/`--reader`), **section
scoping** (`--select`/`--section`/`--target`), and a **two-stage Ctrl-C handler**.
Syntax is clean (`bash -n` passes).

This file is **analysis only** — no code changes were applied.

## What's good (new since the rewrite)
- The Ctrl-C design sets flags instead of hard-killing: one tap skips the current
  page, a quick double-tap aborts the crawl, partial results are kept
  (`on_interrupt`, `:172-183`).
- `trap` is correctly split into an `EXIT` cleanup vs an `INT` handler
  (`:1181-1184`), and the image-download loops honor the abort flags
  (`:1025`, `:1103`). Temp files are cleaned on abort.

---

## New, higher-impact findings

### N1 — ⚠️ Security: credentials land in the Chrome / curl process arg list (contradicts the README)
`auth_url` embeds `user:pass@` into the URL (`:436-442`), and that URL is passed
to Chrome on the command line in `render_pdf` (`:974`) and `dump_dom` (`:1057`).
Image downloads use `curl -u "$u:$p"` (`:309`) / `wget --password=` (`:311`). All
of these are visible in `ps` / `/proc/<pid>/cmdline` while the subprocess runs.

The README (`README.md:233-235`) and the header comment (`:80-81`) claim that
using env vars "keeps the password out of the process list." That is only true of
*this script's* own argv — it is re-exposed via the Chrome and curl/wget children.
Fix one of:
- soften the README/Header claim to be accurate, **or**
- feed Chrome via `--header="Authorization: Basic <b64>"` and curl via a stdin
  config (`-K -`) / `wget` via a `.netrc` in the temp profile dir.

### N2 — ⚠️ Portability: `set -u` + empty array breaks the stated bash 3.2 / macOS support
`queued()` (`:919`):
```bash
case " ${C_URL[*]} ${N_URL[*]} " in ...
```
On bash **< 4.4** (macOS ships stock 3.2 — explicitly targeted at `:15`),
expanding an *empty* array under `set -u` raises `N_URL[*]: unbound variable`.
`N_URL` is empty on the first page until a nav link is found, so the first
`enqueue_links → queued` call aborts the whole script on macOS's default bash.
Git Bash (4.4+) and modern Linux are unaffected, which is why it slips through.

Fix: guard the expansion — `case " ${C_URL[*]:-} ${N_URL[*]:-} "` — or test the
count `${#N_URL[@]}` (always safe) before expanding the contents.

### N3 — Dead capability: the content extractor's `selected` path is unreachable
`build_pdf_snapshot` declares `selected="${5:-0}"` (`:1001`), but **neither call
site passes a 5th argument** (`:1345`, `:1347`), so `selected` is always `0`. The
content extractor's `if not selected:` branch (`:737-744`) and the `selected`
plumbing (`:655`) can therefore never run — `--select` deliberately only scopes
crawling, not extraction (`:1341-1342`). It's ~10 lines of Python plus arg
plumbing implying a feature that isn't wired up. Either wire `--select` into
content extraction (pass `region_dom` + `selected=1`) or drop the unused param.

---

## New, lower-impact findings

### N4 — Unquoted user `$SELECT` is glob-expanded
`"$PYBIN" "$SELECT_PY" $SELECT` (`:1336`) relies on word-splitting (intended, to
pass multiple selectors) but is also subject to globbing. A selector with `*`
(e.g. `--select '*sidebar*'`) would be expanded against the CWD. Unlike the
fixed internal `$STRIP_SPEC` (`:1379`), `$SELECT` is user input. Wrap the call in
`set -f` / `set +f`, or split on commas into an array.

### N5 — Ctrl-C interruption depends on Chrome sharing the foreground process group
The handler only sets flags; the in-flight Chrome render is actually interrupted
because, in a TTY, Ctrl-C hits the whole foreground process group (so the
backgrounded Chrome from `run_spin` dies too). Correct for the interactive case,
but if driven non-interactively a single Ctrl-C won't stop the current render —
only the next flag check. Worth a one-line comment documenting the dependency.

---

## Earlier findings that still stand

- **Dead code** — the no-op `if ! echo "<html><body>ok</body></html>" ...; then :; fi`
  is still at `:1190` (its comment belongs to the real smoke-test on the next line).
- **`slot_replace` rewrites the whole HTML once per image** (`:1042`) — now used by
  *both* mirror and content modes, so the O(N×filesize) cost hits more runs. Batch
  the substitutions into a single `sed -f` pass after the download loop.
- **Windows / space fragility** — `--user-data-dir=$PROFILE_DIR` baked into the
  unquoted `$CHROME_FLAGS` (`:958`), and `$PDF_LIST` expanded unquoted in the merge
  step (`:1426`, `:1431`), both break if a path contains spaces — most likely via
  `-o "My Out Dir"`. `slugify` filenames are space-free, so only user-supplied dirs
  are at risk.
- **`extract_images` over-broad `src=`** (`:1079`) grabs `<script>/<iframe>/<source>`
  srcs, not just images — only reached in the no-Python live archive path, where it
  can download `.js` into `images/`.
- **No URL normalization** — trailing-slash, query-order, and `../` variants are
  treated as distinct by `seen`/`queued`, so the same page can be crawled twice and
  consume the page budget.
- **`extract_zip` duplicates the python branch** (`:322-325`) — `$PYBIN` is already
  resolved; collapse to `elif [ -n "$PYBIN" ]; then "$PYBIN" -c ...`.
- **`usage()` line-range coupling** (`:207`, `sed -n '2,60p'`) — the header now runs
  to line 61; the range still lines up but is silently breakable on the next header
  edit.

---

## Priority summary

| # | Finding | Type | Severity |
|---|---------|------|----------|
| N2 | Empty-array under `set -u` crashes bash 3.2 / macOS | Portability | **high** (breaks a stated platform) |
| N1 | Creds exposed in Chrome/curl argv vs README claim | Security / docs | **high** |
| — | `slot_replace` N-pass per image | Perf | medium |
| N3 | Dead `selected` extraction path | Bloat / mismatch | medium |
| — | Unquoted `$CHROME_FLAGS` / `$PDF_LIST` on spaces | Windows / robustness | medium |
| N4 | Unquoted user `$SELECT` globs | Robustness | low |
| — | Dead `echo` smoke-test line; `extract_zip` dup | Bloat | low |
| N5 | Ctrl-C relies on process-group delivery | Robustness | low |

**Top three to act on:** N2 (quickest fix, biggest correctness impact), N1
(fix cred handling or correct the README), and the `slot_replace` batching (the
one real speedup, now on the hot path for two modes).
