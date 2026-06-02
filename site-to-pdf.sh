#!/usr/bin/env bash
#
# site-to-pdf.sh
# -----------------------------------------------------------------------------
# Crawl a site with headless Chrome and save its pages as PDFs (optional merge).
# Self-contained: downloads its own Chrome for Testing into .cache/. Runs on
# Linux, macOS and Windows (Git Bash); avoids bash 4+ features (macOS bash 3.2).
#
# Usage: ./site-to-pdf.sh [URL] [options]    (no URL -> a random demo site)
# Env (HTTP Basic-Auth popup): CRAWL_USER, CRAWL_PASS -- sent only to start host.
#
# Options:
#   -n, --max-pages N      Max pages to crawl (default 25)
#   -d, --depth N          Max crawl depth (default 2)
#   -o, --out DIR          Output dir (default ./output/<host>-<timestamp>)
#       --delay SEC        Delay between page loads (default 0.5)
#       --merge            Merge page PDFs into one file (default if a merger exists)
#       --no-merge         Keep individual per-page PDFs only
#       --use-system-chrome  Use a Chrome/Chromium on PATH instead of downloading
#       --timeout MS       Per-page render budget in ms (default 12000)
#       --no-images        Do not download images / skip image slot-back
#       --images-same-host Only download images served by the start host
#       --body-first       Crawl content links before header/nav/footer (default; needs Python)
#       --no-body-first    Plain breadth-first crawl
#       --content-only     Reader mode: extract main content, drop chrome/styling (needs Python)
#       --select SEL       Follow only links inside section(s) SEL: tag/.class/#id/bare (needs Python)
#       --debug            Show child stderr (Chrome, Python helpers) for troubleshooting
#   -h, --help             Show this help and exit
# -----------------------------------------------------------------------------

set -u

# --------------------------- configuration / defaults ------------------------
MAX_PAGES=25
MAX_DEPTH=2
DELAY="0.5"
OUT_DIR=""
DO_MERGE="auto"          # auto | yes | no
USE_SYSTEM_CHROME="no"
RENDER_BUDGET_MS=12000
DOWNLOAD_IMAGES="yes"
IMAGES_SAME_HOST="no"
BODY_FIRST="yes"
CONTENT_ONLY="no"
SELECT=""
DEBUG="no"
ERR_SINK="/dev/null"      # where child stderr goes; /dev/stderr under --debug
START_URL=""

# Basic-Auth creds from env (not flags); NOTE: still visible in `ps` via Chrome/curl children.
AUTH_USER="${CRAWL_USER:-}"
AUTH_PASS="${CRAWL_PASS:-}"

# Used when no URL is supplied ("random site").
RANDOM_SITES="https://example.com https://books.toscrape.com https://quotes.toscrape.com https://www.iana.org"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/.cache"
CFT_JSON_URL="https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"

# Python powers image slot-back, content/reader mode and section select; optional.
PYBIN=""
command -v python3 >/dev/null 2>&1 && PYBIN="python3"
[ -z "$PYBIN" ] && command -v python >/dev/null 2>&1 && PYBIN="python"
REWRITER_PY="$CACHE_DIR/rewrite_images.py"
STRIPPER_PY="$CACHE_DIR/strip_tags.py"
CONTENT_PY="$CACHE_DIR/extract_content.py"
SELECT_PY="$CACHE_DIR/select_region.py"

# ------------------------------- helpers -------------------------------------
log()  { printf '\033[36m[*]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }
die()  { err "$@"; exit 1; }

# Best install command for a dependency, per detected package manager.
install_hint() {  # install_hint <dep: python|curl|wget|unzip|poppler>
  local dep="$1" apt dnf pac brew win
  case "$dep" in
    python)  apt="python3"; dnf="python3"; pac="python"; brew="python"; win="Python.Python.3" ;;
    curl)    apt="curl";    dnf="curl";    pac="curl";   brew="curl";   win="cURL.cURL" ;;
    wget)    apt="wget";    dnf="wget";    pac="wget";   brew="wget";   win="" ;;
    unzip)   apt="unzip";   dnf="unzip";   pac="unzip";  brew="unzip";  win="" ;;
    poppler) apt="poppler-utils"; dnf="poppler-utils"; pac="poppler"; brew="poppler"; win="" ;;
    *)       apt="$dep"; dnf="$dep"; pac="$dep"; brew="$dep"; win="" ;;
  esac
  if   command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y $apt"
  elif command -v dnf     >/dev/null 2>&1; then echo "sudo dnf install -y $dnf"
  elif command -v yum     >/dev/null 2>&1; then echo "sudo yum install -y $dnf"
  elif command -v pacman  >/dev/null 2>&1; then echo "sudo pacman -S --noconfirm $pac"
  elif command -v zypper  >/dev/null 2>&1; then echo "sudo zypper install -y $dnf"
  elif command -v apk     >/dev/null 2>&1; then echo "sudo apk add $apt"
  elif command -v brew    >/dev/null 2>&1; then echo "brew install $brew"
  elif command -v winget  >/dev/null 2>&1 && [ -n "$win" ]; then echo "winget install $win"
  elif command -v choco   >/dev/null 2>&1; then echo "choco install -y $dep"
  elif command -v scoop   >/dev/null 2>&1; then echo "scoop install $dep"
  else
    case "${PLATFORM:-}" in
      mac-*) echo "Install '$dep' via Homebrew (https://brew.sh) or your OS package manager" ;;
      win64) [ "$dep" = python ] \
               && echo "Install Python from https://www.python.org/downloads/ (tick 'Add Python to PATH')" \
               || echo "Install '$dep' via winget/choco/scoop or its official site" ;;
      *)     echo "Install '$dep' via your OS package manager" ;;
    esac
  fi
}

# A required dependency is missing and we can't auto-install it: explain and exit.
missing_required() {  # missing_required <dep> <why>
  err "Required dependency not found: '$1' (and it can't be installed automatically)."
  printf '    %s\n' "$2" >&2
  printf '    Install it, then re-run this script:\n' >&2
  printf '        %s\n' "$(install_hint "$1")" >&2
  exit 1
}

# --- progress / live status (animate only on an interactive terminal) --------
is_tty() { [ -t 2 ]; }

# Transient single-line status, overwritten by the next status/clear (TTY only).
status() {  # status <text>
  is_tty && printf '\r\033[K\033[2m%s\033[0m' "$*" >&2
}
status_clear() { is_tty && printf '\r\033[K' >&2; }

# mm:ss from a number of seconds
fmt_time() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

# SIGINT: one tap sets SKIP_CURRENT, quick double-tap sets ABORT (loop acts on flags).
on_interrupt() {
  if [ "$(( SECONDS - LAST_INT ))" -le 1 ]; then
    ABORT=1
    printf '\r\033[K' >&2
    warn "Stopping crawl (finishing up; partial results are kept)..."
  else
    SKIP_CURRENT=1
    printf '\r\033[K' >&2
    warn "Skipping current page (double-tap Ctrl-C to stop the whole crawl)"
  fi
  LAST_INT=$SECONDS
}

# Run a command showing a spinner + elapsed seconds; returns its exit code.
run_spin() {  # run_spin <message> <command> [args...]
  local msg="$1"; shift
  if ! is_tty; then
    "$@"
    return $?
  fi
  "$@" &
  local pid=$! i=0 start=$SECONDS frames='|/-\' f
  while kill -0 "$pid" 2>/dev/null; do
    f=$(printf '%s' "$frames" | cut -c $(( (i % 4) + 1 )))
    printf '\r\033[K\033[36m[%s]\033[0m %s \033[2m(%ds)\033[0m' "$f" "$msg" "$(( SECONDS - start ))" >&2
    i=$(( i + 1 ))
    sleep 0.2 2>/dev/null || sleep 1
  done
  wait "$pid"; local rc=$?
  printf '\r\033[K' >&2
  return $rc
}

usage() {
  # Print the header block between the two "# -----" rules, minus the "# ".
  awk '
    /^# -{5,}/ { n++; next }
    n == 1     { line = $0; sub(/^# ?/, "", line); print line }
    n >= 2     { exit }
  ' "$0"
  exit 0
}

# ------------------------------ arg parsing ----------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--max-pages)        MAX_PAGES="$2"; shift 2 ;;
    -d|--depth)            MAX_DEPTH="$2"; shift 2 ;;
    -o|--out)              OUT_DIR="$2"; shift 2 ;;
    --delay)               DELAY="$2"; shift 2 ;;
    --merge)               DO_MERGE="yes"; shift ;;
    --no-merge)            DO_MERGE="no"; shift ;;
    --use-system-chrome)   USE_SYSTEM_CHROME="yes"; shift ;;
    --timeout)             RENDER_BUDGET_MS="$2"; shift 2 ;;
    --no-images)           DOWNLOAD_IMAGES="no"; shift ;;
    --images-same-host)    IMAGES_SAME_HOST="yes"; shift ;;
    --body-first)          BODY_FIRST="yes"; shift ;;
    --no-body-first)       BODY_FIRST="no"; shift ;;
    --content-only|--reader) CONTENT_ONLY="yes"; shift ;;
    --select|--section|--target) SELECT="$2"; shift 2 ;;
    --debug)               DEBUG="yes"; shift ;;
    -h|--help)             usage ;;
    -*)                    die "Unknown option: $1 (try --help)" ;;
    *)                     [ -z "$START_URL" ] && START_URL="$1" || die "Unexpected argument: $1"; shift ;;
  esac
done

[ "$DEBUG" = "yes" ] && ERR_SINK="/dev/stderr"   # --debug: surface child stderr

# ----------------------- pick a random start URL if none ---------------------
if [ -z "$START_URL" ]; then
  # shellcheck disable=SC2086
  set -- $RANDOM_SITES
  idx=$(( (RANDOM % $#) + 1 ))
  eval "START_URL=\${$idx}"
  log "No URL supplied; randomly chose: $START_URL"
fi

# Make sure the URL has a scheme.
case "$START_URL" in
  http://*|https://*) : ;;
  *) START_URL="https://$START_URL" ;;
esac

# ----------------------------- platform detect -------------------------------
detect_platform() {
  local s m
  s="$(uname -s 2>/dev/null || echo unknown)"
  m="$(uname -m 2>/dev/null || echo x86_64)"
  case "$s" in
    Linux*)                       echo "linux64" ;;
    Darwin*)
      case "$m" in
        arm64|aarch64) echo "mac-arm64" ;;
        *)             echo "mac-x64" ;;
      esac ;;
    MINGW*|MSYS*|CYGWIN*|Windows*) echo "win64" ;;
    *) die "Unsupported OS: $s" ;;
  esac
}

PLATFORM="$(detect_platform)"
case "$PLATFORM" in
  win64) CHROME_BIN_NAME="chrome-headless-shell.exe" ;;
  *)     CHROME_BIN_NAME="chrome-headless-shell" ;;
esac

# ---------------------- download / unzip abstractions ------------------------
fetch() {  # fetch <url> <outfile>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    die "Need curl or wget to download dependencies, found neither."
  fi
}

# Like fetch() but shows a download progress bar (for large files).
fetch_progress() {  # fetch_progress <url> <outfile>
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --progress-bar -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget --progress=bar:force -O "$2" "$1"
  else
    die "Need curl or wget to download dependencies, found neither."
  fi
}

fetch_stdout() {  # fetch_stdout <url>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O - "$1"
  else
    die "Need curl or wget to download dependencies, found neither."
  fi
}

# Fetch a URL, optionally with HTTP Basic-Auth credentials.
fetch_auth() {  # fetch_auth <url> <outfile> <user> <pass>
  local url="$1" out="$2" u="$3" p="$4"
  if [ -n "$u" ]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --retry 3 -u "$u:$p" -o "$out" "$url"; return
    elif command -v wget >/dev/null 2>&1; then
      wget -q --user="$u" --password="$p" -O "$out" "$url"; return
    fi
  fi
  fetch "$url" "$out"
}

extract_zip() {  # extract_zip <zipfile> <destdir>
  local zip="$1" dest="$2"
  mkdir -p "$dest"
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$zip" -d "$dest"
  elif [ -n "$PYBIN" ]; then
    "$PYBIN" -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$(pypath "$zip")" "$(pypath "$dest")"
  elif command -v tar >/dev/null 2>&1; then
    # Windows' built-in tar (bsdtar) and macOS tar can extract .zip archives.
    tar -xf "$zip" -C "$dest"
  else
    die "No way to unzip (need one of: unzip, python, tar/bsdtar)."
  fi
}

# ---------------------- locate or download Chrome ----------------------------
find_system_chrome() {
  local c
  for c in google-chrome-stable google-chrome chromium chromium-browser \
           chrome chrome-headless-shell "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           "/c/Program Files/Google/Chrome/Application/chrome.exe" \
           "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe"; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

download_chrome() {
  local installed="$CACHE_DIR/chrome-headless-shell-$PLATFORM"
  local bin
  bin="$(find "$installed" -name "$CHROME_BIN_NAME" -type f 2>/dev/null | head -n1)"
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    echo "$bin"; return 0
  fi

  log "Downloading Chrome for Testing (chrome-headless-shell, $PLATFORM)..."
  mkdir -p "$CACHE_DIR"
  local json url zip
  json="$(fetch_stdout "$CFT_JSON_URL")" || die "Could not fetch Chrome for Testing version index."

  # URLs embed platform + binary name, so grep avoids a jq dependency (first = Stable).
  url="$(printf '%s' "$json" \
        | grep -oE 'https://[^"]*chrome-headless-shell-'"$PLATFORM"'\.zip' \
        | head -n1)"
  [ -n "$url" ] || die "Could not find a chrome-headless-shell download for platform '$PLATFORM'."

  zip="$CACHE_DIR/chrome-$PLATFORM.zip"
  log "Downloading browser (~150 MB) from: $url"
  fetch_progress "$url" "$zip" || die "Download failed."
  log "Extracting browser..."
  extract_zip "$zip" "$installed"
  rm -f "$zip"

  bin="$(find "$installed" -name "$CHROME_BIN_NAME" -type f 2>/dev/null | head -n1)"
  [ -n "$bin" ] || die "Chrome binary not found after extraction."
  chmod +x "$bin" 2>/dev/null || true
  ok "Chrome ready: $bin"
  echo "$bin"
}

# ----------------------------- url utilities ---------------------------------
url_scheme() { case "$1" in https://*) echo https ;; http://*) echo http ;; *) echo https ;; esac; }

# host[:port] of a full URL
url_host() {
  printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://([^/]+).*#\1#'
}

# scheme://host part of a full URL
url_origin() {
  printf '%s' "$1" | sed -E 's#^([a-zA-Z]+://[^/]+).*#\1#'
}

# directory part of a URL path (used to resolve relative links), keeps trailing /
url_dir() {
  local u="$1"
  u="${u%%#*}"            # drop fragment
  u="${u%%\?*}"           # drop query
  case "$u" in
    */) echo "$u" ;;
    *)  echo "${u%/*}/" ;;
  esac
}

# Resolve a possibly-relative href against a base URL -> absolute URL (or empty).
resolve_url() {
  local base="$1" href="$2"
  href="${href%%#*}"                       # strip fragment
  [ -z "$href" ] && { echo ""; return; }
  case "$href" in
    mailto:*|tel:*|javascript:*|data:*|ftp:*) echo "" ; return ;;
    http://*|https://*) echo "$href" ; return ;;
    //*)  echo "$(url_scheme "$base"):$href" ; return ;;     # protocol-relative
    /*)   echo "$(url_origin "$base")$href" ; return ;;      # root-relative
    *)    echo "$(url_dir "$base")$href" ; return ;;         # document-relative
  esac
}

# Canonicalise a URL so variants dedupe (drop fragment, lowercase host, strip default port/trailing slash).
normalize_url() {  # normalize_url <abs_url>
  local u="$1" base query scheme rest host path
  u="${u%%#*}"
  case "$u" in *\?*) base="${u%%\?*}"; query="?${u#*\?}" ;; *) base="$u"; query="" ;; esac
  case "$base" in
    http://*)  scheme="http://";  rest="${base#http://}" ;;
    https://*) scheme="https://"; rest="${base#https://}" ;;
    *) printf '%s' "$1"; return ;;
  esac
  case "$rest" in
    */*) host="${rest%%/*}"; path="/${rest#*/}" ;;
    *)   host="$rest"; path="/" ;;
  esac
  host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"
  case "$scheme$host" in
    http://*:80)   host="${host%:80}" ;;
    https://*:443) host="${host%:443}" ;;
  esac
  [ "$path" != "/" ] && path="${path%/}"
  printf '%s%s%s%s' "$scheme" "$host" "$path" "$query"
}

# Percent-encode a string so it is safe to embed in a URL (for credentials).
urlencode() {
  local s="$1" out="" c i=0
  while [ "$i" -lt "${#s}" ]; do
    c="${s:$i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out="$out$c" ;;
      *) out="$out$(printf '%%%02X' "'$c")" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# Embed Basic-Auth creds in the URL, but only when set and targeting the start host.
auth_url() {  # auth_url <url>
  local u="$1"
  [ -z "$AUTH_USER" ] && { printf '%s' "$u"; return; }
  [ "$(url_host "$u")" = "$host" ] || { printf '%s' "$u"; return; }
  printf '%s' "$u" \
    | sed -E "s#^([a-zA-Z]+://)#\1$(urlencode "$AUTH_USER"):$(urlencode "$AUTH_PASS")@#"
}

# Make a filesystem-safe slug from a URL.
slugify() {
  printf '%s' "$1" \
    | sed -E 's#^[a-zA-Z]+://##; s#[?].*$##; s#/+$##' \
    | sed -E 's#[^A-Za-z0-9._-]+#_#g' \
    | cut -c1-80
}

# Absolute filesystem path -> file:// URL Chrome understands (cygpath on Windows).
to_file_url() {  # to_file_url <abs_path>
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    printf 'file:///%s' "$(cygpath -m "$p")"   # /c/x -> C:/x -> file:///C:/x
  else
    printf 'file://%s' "$p"                     # /home/x -> file:///home/x
  fi
}

# Native path for paths handed to Python (native Windows python can't open MSYS
# /c/... paths). No-op off Windows. Bash redirections (< >) don't need this.
pypath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Python helper (mirror mode): tokenise <img> src to CRAWLIMG_ ids; absolutise other resource URLs.
write_rewriter() {  # write_rewriter <path>
  cat > "$1" <<'PYEOF'
import sys, re, os
try:
    from urllib.parse import urljoin, urlsplit
except ImportError:                      # Python 2
    from urlparse import urljoin, urlsplit

clean_base = sys.argv[1]   # no credentials -> used for image urls / manifest
cred_base  = sys.argv[2]   # may carry user:pass@ -> used for css/js/etc.
mapping    = sys.argv[3]
html = sys.stdin.read()

imgmap, order, counter = {}, [], [0]

def get_ext(u):
    ext = os.path.splitext(urlsplit(u).path)[1]
    ext = re.sub(r'[^A-Za-z0-9.]', '', ext).lower()
    return ext if (ext and len(ext) <= 6) else '.img'

def assign(absu):
    if absu in imgmap:
        return imgmap[absu]
    counter[0] += 1
    i = '%04d' % counter[0]
    imgmap[absu] = i
    order.append((i, absu, get_ext(absu)))
    return i

def attr_re(name):
    return re.compile(r'(?is)\b' + name + r'\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)')

def val_of(raw):
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] in '"\'' and raw[-1] == raw[0]:
        return raw[1:-1]
    return raw

def skip(u):
    u = u.strip()
    return (not u) or u.startswith('#') or u.lower().startswith(
        ('data:', 'javascript:', 'mailto:', 'tel:', 'blob:'))

src_re    = attr_re('src')
srcset_re = attr_re('srcset')

def rewrite_img(m):
    tag = m.group(0)
    sm = src_re.search(tag)
    if sm:
        v = val_of(sm.group(1))
        if not skip(v):
            absu = urljoin(clean_base, v)
            if absu.lower().startswith(('http://', 'https://')):
                tok = 'CRAWLIMG_' + assign(absu)
                tag = tag[:sm.start(1)] + '"' + tok + '"' + tag[sm.end(1):]
    return srcset_re.sub('', tag)        # drop srcset so our src wins

html = re.sub(r'(?is)<img\b[^>]*>', rewrite_img, html)

def absolutize(html, tagname, attr):
    are = attr_re(attr)
    def repl(m):
        tag = m.group(0)
        am = are.search(tag)
        if am:
            v = val_of(am.group(1))
            if not skip(v) and not v.lower().startswith(('http://', 'https://')):
                tag = tag[:am.start(1)] + '"' + urljoin(cred_base, v) + '"' + tag[am.end(1):]
        return tag
    return re.compile(r'(?is)<' + tagname + r'\b[^>]*>').sub(repl, html)

for tn, at in (('link', 'href'), ('script', 'src'), ('source', 'src')):
    html = absolutize(html, tn, at)

with open(mapping, 'w') as f:
    for i, absu, ext in order:
        f.write('%s\t%s\t%s\n' % (i, absu, ext))

sys.stdout.write(html)
PYEOF
}

# Python helper: nesting-aware element removal by tag (before "--") and class/id keyword (after "--").
write_stripper() {  # write_stripper <tags...> -- <class/id keywords...>
  cat > "$1" <<'PYEOF'
import sys, re

html = sys.stdin.read()
args = sys.argv[1:]
if '--' in args:
    k = args.index('--')
    tags, keywords = args[:k], [w.lower() for w in args[k + 1:]]
else:
    tags, keywords = args, []

# HTML void elements have no closing tag; never try to "remove" through them.
VOID = set('img br hr input meta link source area base col embed param track wbr'.split())

def end_of_element(html, low, open_re, close, start):
    """Index just past the close tag matching an opened element (nesting-aware)."""
    depth, j = 1, start
    while depth > 0:
        no = open_re.search(html, j)
        nc = low.find(close, j)
        if nc == -1:
            return len(html)
        if no and no.start() < nc:
            depth += 1; j = no.end()
        else:
            depth -= 1; j = nc + len(close)
    return j

def drop_tag(html, tag):
    open_re = re.compile(r'(?is)<' + re.escape(tag) + r'\b[^>]*>')
    close = ('</' + tag + '>').lower()
    low = html.lower()
    out, i = [], 0
    while True:
        m = open_re.search(html, i)
        if not m:
            out.append(html[i:]); break
        out.append(html[i:m.start()])
        i = end_of_element(html, low, open_re, close, m.end())
    return ''.join(out)

for tag in tags:
    html = drop_tag(html, tag)

if keywords:
    start_re = re.compile(r'(?is)<([a-zA-Z][a-zA-Z0-9:-]*)\b[^>]*>')
    attr_re  = re.compile(r'(?is)\b(?:class|id)\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)')
    def matches(opentag):
        for am in attr_re.finditer(opentag):
            v = am.group(1).strip('"\'').lower()
            if any(kw in v for kw in keywords):
                return True
        return False
    low = html.lower()
    out, i = [], 0
    while True:
        m = start_re.search(html, i)
        if not m:
            out.append(html[i:]); break
        opentag, name = m.group(0), m.group(1).lower()
        if name in VOID or opentag.rstrip().endswith('/>') or not matches(opentag):
            out.append(html[i:m.end()]); i = m.end(); continue   # keep, scan inside
        open_re = re.compile(r'(?is)<' + re.escape(name) + r'\b[^>]*>')
        close = ('</' + name + '>').lower()
        out.append(html[i:m.start()])
        i = end_of_element(html, low, open_re, close, m.end())
    html = ''.join(out)

sys.stdout.write(html)
PYEOF
}

# Python helper (reader mode): extract content into a clean styled doc, drop chrome/ads (CRAWLIMG_ map).
write_content_extractor() {  # write_content_extractor <path>
  cat > "$1" <<'PYEOF'
import sys, re, os
try:
    from urllib.parse import urljoin, urlsplit
except ImportError:
    from urlparse import urljoin, urlsplit

clean_base   = sys.argv[1]
mapping_path = sys.argv[2]
with_images  = (len(sys.argv) > 3 and sys.argv[3] == '1')

html = sys.stdin.read()
html = re.sub(r'(?is)<!--.*?-->', '', html)              # strip comments

mt = re.search(r'(?is)<title[^>]*>(.*?)</title>', html)
title = re.sub(r'\s+', ' ', mt.group(1)).strip() if mt else ''

VOID = set('img br hr input meta link source area base col embed param track wbr'.split())

def end_of_element(s, low, open_re, close, start):
    depth, j = 1, start
    while depth > 0:
        no = open_re.search(s, j)
        nc = low.find(close, j)
        if nc == -1:
            return len(s)
        if no and no.start() < nc:
            depth += 1; j = no.end()
        else:
            depth -= 1; j = nc + len(close)
    return j

def drop_tag(s, tag):
    open_re = re.compile(r'(?is)<' + re.escape(tag) + r'\b[^>]*>')
    close = ('</' + tag + '>').lower()
    low = s.lower(); out = []; i = 0
    while True:
        m = open_re.search(s, i)
        if not m:
            out.append(s[i:]); break
        out.append(s[i:m.start()])
        i = end_of_element(s, low, open_re, close, m.end())
    return ''.join(out)

attr_kw_re = re.compile(r'(?is)\b(?:class|id)\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)')
def drop_by_keyword(s, keywords):
    start_re = re.compile(r'(?is)<([a-zA-Z][a-zA-Z0-9:-]*)\b[^>]*>')
    low = s.lower(); out = []; i = 0
    while True:
        m = start_re.search(s, i)
        if not m:
            out.append(s[i:]); break
        opentag, name = m.group(0), m.group(1).lower()
        hit = False
        for am in attr_kw_re.finditer(opentag):
            v = am.group(1).strip('"\'').lower()
            if any(kw in v for kw in keywords):
                hit = True; break
        if name in VOID or opentag.rstrip().endswith('/>') or not hit:
            out.append(s[i:m.end()]); i = m.end(); continue
        open_re = re.compile(r'(?is)<' + re.escape(name) + r'\b[^>]*>')
        close = ('</' + name + '>').lower()
        out.append(s[i:m.start()])
        i = end_of_element(s, low, open_re, close, m.end())
    return ''.join(out)

def inner(s, tag):
    open_re = re.compile(r'(?is)<' + tag + r'\b[^>]*>')
    m = open_re.search(s)
    if not m:
        return None
    close = ('</' + tag + '>').lower()
    end = end_of_element(s, s.lower(), open_re, close, m.end())
    return s[m.end():max(m.end(), end - len(close))]

# 1) Pick the main content region.
content = inner(html, 'main')
if content is None:
    content = inner(html, 'article')
if content is None:
    content = inner(html, 'body')
if content is None:
    content = re.sub(r'(?is)<head\b[^>]*>.*?</head>', '', html)

# 2) Remove non-content subtrees: scripts/styles/forms, then site chrome.
for t in ('script', 'style', 'noscript', 'template', 'svg', 'iframe', 'object',
          'form', 'button', 'select', 'textarea', 'dialog'):
    content = drop_tag(content, t)

for t in ('header', 'nav', 'footer', 'aside'):
    content = drop_tag(content, t)
content = drop_by_keyword(content, [
    'footer', 'navbar', 'masthead', 'sidebar', 'side-bar', 'site-header',
    'cookie', 'consent', 'advert', 'promo', 'popup', 'modal', 'subscribe',
    'newsletter', 'social', 'share', 'breadcrumb', 'pagination', 'related',
    'skip-link'])

# 3) Images: slot ours via tokens, or drop entirely.
imgmap, order, cnt = {}, [], [0]
def get_ext(u):
    ext = os.path.splitext(urlsplit(u).path)[1]
    ext = re.sub(r'[^A-Za-z0-9.]', '', ext).lower()
    return ext if (ext and len(ext) <= 6) else '.img'
def assign(absu):
    if absu in imgmap:
        return imgmap[absu]
    cnt[0] += 1; i = '%04d' % cnt[0]
    imgmap[absu] = i; order.append((i, absu, get_ext(absu))); return i

src_re = re.compile(r'(?is)\bsrc\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)')
alt_re = re.compile(r'(?is)\balt\s*=\s*"([^"]*)"')
def val_of(raw):
    raw = raw.strip()
    if len(raw) >= 2 and raw[0] in '"\'' and raw[-1] == raw[0]:
        return raw[1:-1]
    return raw
def rewrite_img(m):
    tag = m.group(0)
    if not with_images:
        return ''
    sm = src_re.search(tag)
    if not sm:
        return ''
    v = val_of(sm.group(1))
    if not v or v.lower().startswith('data:'):
        return ''
    absu = urljoin(clean_base, v)
    if not absu.lower().startswith(('http://', 'https://')):
        return ''
    am = alt_re.search(tag)
    alt = am.group(1) if am else ''
    return '<img src="CRAWLIMG_%s" alt="%s">' % (assign(absu), alt)
content = re.sub(r'(?is)<img\b[^>]*>', rewrite_img, content)
content = re.sub(r'(?is)<source\b[^>]*>', '', content)

# 4) Absolutize <a href>, then strip class/id/style/on* from every tag.
def abs_href(m):
    tag = m.group(0)
    hm = re.search(r'(?is)\bhref\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)', tag)
    if hm:
        v = val_of(hm.group(1))
        if v and not v.lower().startswith(('javascript:', '#')):
            tag = tag[:hm.start(1)] + '"' + urljoin(clean_base, v) + '"' + tag[hm.end(1):]
    return tag
content = re.sub(r'(?is)<a\b[^>]*>', abs_href, content)

def clean_attrs(m):
    tag = m.group(0)
    tag = re.sub(r'(?is)\s+(?:class|id|style)\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)', '', tag)
    tag = re.sub(r'(?is)\s+on[a-z]+\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)', '', tag)
    return tag
content = re.sub(r'(?is)<[a-zA-Z][^>]*>', clean_attrs, content)

with open(mapping_path, 'w') as f:
    for i, absu, ext in order:
        f.write('%s\t%s\t%s\n' % (i, absu, ext))

CSS = ("body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;"
       "line-height:1.55;color:#1a1a1a;max-width:46rem;margin:2rem auto;padding:0 1rem;}"
       "h1,h2,h3,h4{line-height:1.25;margin:1.4em 0 .5em;}"
       "img{max-width:100%;height:auto;}"
       "table{border-collapse:collapse;margin:1em 0;}td,th{border:1px solid #ccc;padding:4px 8px;}"
       "pre{background:#f5f5f5;padding:8px;overflow:auto;}code{background:#f5f5f5;padding:1px 3px;}"
       "blockquote{border-left:3px solid #ddd;margin:0;padding-left:1rem;color:#555;}"
       "a{color:#0645ad;text-decoration:none;}hr{border:none;border-top:1px solid #ddd;}")

def esc(t):
    return t.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

doc = ['<!doctype html><html><head><meta charset="utf-8"><style>', CSS, '</style></head><body>']
# Add the page title as a heading only if the content doesn't already have one.
if title and not re.search(r'(?is)<h1\b', content):
    doc.append('<h1>' + esc(title) + '</h1>')
doc.append(content)
doc.append('</body></html>')
sys.stdout.write(''.join(doc))
PYEOF
}

# Python helper: isolate regions matching selectors (tag/.class/#id), output their outer HTML.
write_selector() {  # write_selector <path>;  invoked as: select_region.py <selectors...>
  cat > "$1" <<'PYEOF'
import sys, re

html = sys.stdin.read()
# Accept comma- or space-separated selectors across all argv.
raw = ' '.join(sys.argv[1:]).replace(',', ' ')
selectors = [s for s in raw.split() if s]

VOID = set('img br hr input meta link source area base col embed param track wbr'.split())

def attr_val(opentag, attr):
    m = re.search(r'(?is)\b' + attr + r'\s*=\s*("[^"]*"|\'[^\']*\'|[^\s>]+)', opentag)
    if not m:
        return None
    v = m.group(1)
    if len(v) >= 2 and v[0] in '"\'' and v[-1] == v[0]:
        v = v[1:-1]
    return v.lower()

def matches(opentag, name, sel):
    if sel.startswith('.'):
        v = attr_val(opentag, 'class')
        kw = sel[1:].lower()
        return v is not None and (kw in v.split() or kw in v)
    if sel.startswith('#'):
        v = attr_val(opentag, 'id')
        kw = sel[1:].lower()
        return v is not None and (v == kw or kw in v)
    # Bare word matches tag name, class token/substring, or id.
    kw = sel.lower()
    if name == kw:
        return True
    cv = attr_val(opentag, 'class')
    if cv is not None and (kw in cv.split() or kw in cv):
        return True
    iv = attr_val(opentag, 'id')
    if iv is not None and (iv == kw or kw in iv):
        return True
    return False

def end_of_element(s, low, open_re, close, start):
    depth, j = 1, start
    while depth > 0:
        no = open_re.search(s, j)
        nc = low.find(close, j)
        if nc == -1:
            return len(s)
        if no and no.start() < nc:
            depth += 1; j = no.end()
        else:
            depth -= 1; j = nc + len(close)
    return j

start_re = re.compile(r'(?is)<([a-zA-Z][a-zA-Z0-9:-]*)\b[^>]*>')
low = html.lower()
out, i = [], 0
while True:
    m = start_re.search(html, i)
    if not m:
        break
    opentag, name = m.group(0), m.group(1).lower()
    if name in VOID or opentag.rstrip().endswith('/>') or not any(matches(opentag, name, s) for s in selectors):
        i = m.end(); continue
    open_re = re.compile(r'(?is)<' + re.escape(name) + r'\b[^>]*>')
    close = ('</' + name + '>').lower()
    end = end_of_element(html, low, open_re, close, m.end())
    out.append(html[m.start():end])   # keep the matched element's outer HTML
    i = end                           # skip past so we don't re-match nested

sys.stdout.write(''.join(out))
PYEOF
}

# ------------------------------- crawl core ----------------------------------
VISITED=""   # space-joined list of visited URLs (bash 3.2 compatible)
seen() { case " $VISITED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
mark()  { VISITED="$VISITED $1"; }

# Priority frontiers (FIFO arrays): CONTENT drained before NAV (header/nav/footer).
C_URL=(); C_DEPTH=(); N_URL=(); N_DEPTH=()

# Already pending in either frontier? (`:-` guards empty arrays on bash 3.2.)
queued() { case " ${C_URL[*]:-} ${N_URL[*]:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Resolve/filter hrefs on stdin and enqueue new same-host pages (nav -> low-priority frontier).
enqueue_links() {  # enqueue_links <kind> <base_url> <depth>
  local kind="$1" base="$2" d="$3" raw abs lhost
  while IFS= read -r raw; do
    [ -z "$raw" ] && continue
    abs="$(resolve_url "$base" "$raw")"
    [ -z "$abs" ] && continue
    abs="$(normalize_url "$abs")"                   # dedupe trivial variants
    lhost="$(url_host "$abs")"
    [ "$lhost" = "$host" ] || continue              # same host only
    # Skip non-page assets (match path only, so "/app.css?id=abc" is caught).
    local apath="${abs%%\?*}"; apath="${apath%%#*}"
    case "$apath" in
      *.css|*.js|*.mjs|*.cjs|*.map|*.json|*.xml|*.rss|*.txt|*.wasm|\
      *.jpg|*.jpeg|*.png|*.gif|*.svg|*.webp|*.avif|*.bmp|*.ico|*.tif|*.tiff|\
      *.woff|*.woff2|*.ttf|*.otf|*.eot|\
      *.zip|*.gz|*.tgz|*.bz2|*.tar|*.7z|*.rar|\
      *.pdf|*.doc|*.docx|*.xls|*.xlsx|*.ppt|*.pptx|\
      *.mp4|*.webm|*.mov|*.avi|*.mkv|*.mp3|*.wav|*.ogg|*.flac) continue ;;
    esac
    seen "$abs" && continue
    queued "$abs" && continue
    if [ "$BODY_FIRST" = "yes" ] && [ "$kind" = "nav" ]; then
      N_URL+=("$abs"); N_DEPTH+=("$d")
    else
      C_URL+=("$abs"); C_DEPTH+=("$d")
    fi
  done
}

# Chrome flags as an array (profile path may contain spaces); add --headless for full Chrome.
build_flags() {
  CHROME_FLAGS=(
    --disable-gpu --no-sandbox --disable-dev-shm-usage
    --no-first-run --no-default-browser-check --hide-scrollbars
    --disable-extensions "--user-data-dir=$PROFILE_DIR"
    --allow-file-access-from-files
    --run-all-compositor-stages-before-draw
  )
  case "$CHROME" in
    *chrome-headless-shell*) : ;;
    *) CHROME_FLAGS=(--headless=new "${CHROME_FLAGS[@]}") ;;
  esac
}

# Render a URL to PDF. Returns 0 on success.
render_pdf() {  # render_pdf <url> <outfile>
  "$CHROME" "${CHROME_FLAGS[@]}" \
    --no-pdf-header-footer \
    --print-to-pdf="$2" \
    --virtual-time-budget="$RENDER_BUDGET_MS" \
    "$(auth_url "$1")" >/dev/null 2>"$ERR_SINK"
  [ -s "$2" ]
}

# Render a local HTML snapshot file to PDF. Returns 0 on success.
render_local_pdf() {  # render_local_pdf <html_file> <outfile>
  local furl; furl="$(to_file_url "$1")"
  "$CHROME" "${CHROME_FLAGS[@]}" \
    --no-pdf-header-footer \
    --print-to-pdf="$2" \
    --virtual-time-budget="$RENDER_BUDGET_MS" \
    "$furl" >/dev/null 2>"$ERR_SINK"
  [ -s "$2" ]
}

# Build a PDF from a local snapshot: gen HTML+map, download images, slot by id (one sed pass), print.
build_pdf_snapshot() {  # build_pdf_snapshot <mode> <url> <dom_file> <pdf_out>
  local mode="$1" url="$2" dom="$3" pdf="$4"
  local pages_dir="$OUT_DIR/pages"
  mkdir -p "$pages_dir"
  local html="$pages_dir/$(printf '%04d' "$count")_$(slugify "$url").html"
  local mapping; mapping="$(mktemp 2>/dev/null || echo "$PROFILE_DIR/map.$count")"

  local rc errlog; errlog="$(mktemp 2>/dev/null || echo "$PROFILE_DIR/pyerr.$count")"
  if [ "$mode" = "content" ]; then
    local wi=0; [ "$DOWNLOAD_IMAGES" = "yes" ] && wi=1
    "$PYBIN" "$(pypath "$CONTENT_PY")" "$url" "$(pypath "$mapping")" "$wi" < "$dom" > "$html" 2>"$errlog"; rc=$?
  else
    "$PYBIN" "$(pypath "$REWRITER_PY")" "$url" "$(auth_url "$url")" "$(pypath "$mapping")" < "$dom" > "$html" 2>"$errlog"; rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    warn "  snapshot generation failed (python exit $rc); rendering live instead"
    [ -s "$errlog" ] && sed 's/^/      | /' "$errlog" >&2   # show the real Python error
    rm -f "$errlog" "$mapping"
    render_pdf "$url" "$pdf"; return
  fi
  rm -f "$errlog"

  # Download each image; collect token->path substitutions for one sed pass later.
  local id absurl ext rel abspath repl esc cu cp got=0 tab total n=0
  local sedscript; sedscript="$(mktemp 2>/dev/null || echo "$PROFILE_DIR/sed.$count")"
  tab="$(printf '\t')"
  total="$(wc -l < "$mapping" | tr -d ' ')"
  while IFS="$tab" read -r id absurl ext; do
    [ -z "$id" ] && continue
    { [ "$SKIP_CURRENT" = 1 ] || [ "$ABORT" = 1 ]; } && break   # Ctrl-C: stop fetching
    n=$(( n + 1 ))
    status "  downloading image $n/$total ..."
    rel="images/img_${id}${ext}"
    abspath="$OUT_DIR/$rel"
    cu=""; cp=""
    if [ -n "$AUTH_USER" ] && [ "$(url_host "$absurl")" = "$host" ]; then
      cu="$AUTH_USER"; cp="$AUTH_PASS"
    fi
    if fetch_auth "$absurl" "$abspath" "$cu" "$cp" 2>/dev/null && [ -s "$abspath" ]; then
      repl="$(to_file_url "$abspath")"
      got=$((got + 1)); IMG_COUNT=$((IMG_COUNT + 1))
      printf '%s\t%s\n' "$rel" "$absurl" >> "$IMG_MANIFEST"
    else
      rm -f "$abspath"
      repl="$(auth_url "$absurl")"   # let Chrome fetch it live as a fallback
    fi
    # Escape sed-special chars in the replacement; token id is numeric (safe).
    esc="$(printf '%s' "$repl" | sed -e 's/[\\&|]/\\&/g')"
    printf 's|CRAWLIMG_%s|%s|g\n' "$id" "$esc" >> "$sedscript"
  done < "$mapping"
  rm -f "$mapping"
  status_clear

  # Single pass: slot every downloaded image's local path back into the HTML.
  if [ -s "$sedscript" ]; then
    local tmp; tmp="$(mktemp 2>/dev/null || echo "$html.tmp")"
    sed -f "$sedscript" "$html" > "$tmp" && mv "$tmp" "$html"
  fi
  rm -f "$sedscript"
  [ "$total" -gt 0 ] && ok "  embedded $got/$total image(s) locally"

  run_spin "  rendering PDF" render_local_pdf "$html" "$pdf"
}

# Dump rendered DOM of a URL to stdout.
dump_dom() {  # dump_dom <url>
  "$CHROME" "${CHROME_FLAGS[@]}" \
    --dump-dom \
    --virtual-time-budget="$RENDER_BUDGET_MS" \
    "$(auth_url "$1")" 2>"$ERR_SINK"
}

# Extract href values from <a> anchors only (skips <link>/<script> assets).
extract_links() {  # extract_links <base_url> <dom_file>
  local dom="$2"
  # Two greps so '=' inside query strings and case don't break extraction.
  grep -oiE '<a\b[^>]*href[[:space:]]*=[[:space:]]*"[^"]*"' "$dom" 2>/dev/null \
    | grep -oE '"[^"]*"$' | sed -E 's/^"//; s/"$//'
  grep -oiE "<a\b[^>]*href[[:space:]]*=[[:space:]]*'[^']*'" "$dom" 2>/dev/null \
    | grep -oE "'[^']*'\$" | sed -E "s/^'//; s/'\$//"
}

# Extract image URLs from a page: <img src>/<img srcset> and image-file hrefs.
extract_images() {  # extract_images <dom_file>
  local dom="$1"
  # <img ... src="..."> only (anchored so <script>/<iframe> srcs aren't grabbed).
  grep -oiE '<img\b[^>]*src[[:space:]]*=[[:space:]]*"[^"]*"' "$dom" 2>/dev/null \
    | grep -oE '"[^"]*"$' | sed -E 's/^"//; s/"$//'
  grep -oiE "<img\b[^>]*src[[:space:]]*=[[:space:]]*'[^']*'" "$dom" 2>/dev/null \
    | grep -oE "'[^']*'\$" | sed -E "s/^'//; s/'\$//"
  # <img ... srcset="url1 1x, url2 2x"> -> emit each url
  grep -oiE '<img\b[^>]*srcset[[:space:]]*=[[:space:]]*"[^"]*"' "$dom" 2>/dev/null \
    | grep -oE '"[^"]*"$' | sed -E 's/^"//; s/"$//' \
    | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]].*$//'
  # hrefs that point at an image file
  grep -oiE 'href[[:space:]]*=[[:space:]]*"[^"]*"' "$dom" 2>/dev/null \
    | sed -E 's/^[^"]*"//; s/"$//' \
    | grep -iE '\.(jpg|jpeg|png|gif|svg|webp|bmp|ico|avif|tiff?)([?#]|$)'
}

# Track downloaded images so we never fetch the same asset twice.
IMG_SEEN=""
img_seen() { case " $IMG_SEEN " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
img_mark() { IMG_SEEN="$IMG_SEEN $1"; }

# Download every image referenced on a page into the images/ directory.
download_images() {  # download_images <base_url> <dom_file>
  local base="$1" dom="$2" raw abs ihost name out got=0
  while IFS= read -r raw; do
    [ -z "$raw" ] && continue
    { [ "$SKIP_CURRENT" = 1 ] || [ "$ABORT" = 1 ]; } && break   # Ctrl-C: stop fetching
    abs="$(resolve_url "$base" "$raw")"
    [ -z "$abs" ] && continue
    case "$abs" in http://*|https://*) : ;; *) continue ;; esac
    if [ "$IMAGES_SAME_HOST" = "yes" ]; then
      ihost="$(url_host "$abs")"
      [ "$ihost" = "$host" ] || continue
    fi
    img_seen "$abs" && continue
    img_mark "$abs"

    name="$(slugify "$abs")"
    # preserve a sensible extension
    case "$abs" in
      *.jpg|*.JPG|*.jpeg|*.JPEG) name="${name%.*}.jpg" ;;
      *.png|*.PNG)   name="${name%.*}.png" ;;
      *.gif|*.GIF)   name="${name%.*}.gif" ;;
      *.svg|*.SVG)   name="${name%.*}.svg" ;;
      *.webp|*.WEBP) name="${name%.*}.webp" ;;
    esac
    out="$IMAGES_DIR/$name"
    [ -e "$out" ] && out="$IMAGES_DIR/${IMG_COUNT}_$name"
    # Send Basic-Auth creds only when the image is served by the start host.
    local cu="" cp=""
    if [ -n "$AUTH_USER" ] && [ "$(url_host "$abs")" = "$host" ]; then
      cu="$AUTH_USER"; cp="$AUTH_PASS"
    fi
    if fetch_auth "$abs" "$out" "$cu" "$cp" 2>/dev/null && [ -s "$out" ]; then
      got=$((got + 1)); IMG_COUNT=$((IMG_COUNT + 1))
      status "  downloaded $got image(s) ..."
      printf '%s\t%s\n' "$name" "$abs" >> "$IMG_MANIFEST"
    else
      rm -f "$out"
    fi
  done <<EOF
$(extract_images "$dom")
EOF
  status_clear
  [ "$got" -gt 0 ] && ok "  downloaded $got image(s)"
  return 0
}

# --------------------------------- main --------------------------------------
main() {
  log "Start URL : $START_URL"
  log "Max pages : $MAX_PAGES   Max depth: $MAX_DEPTH   Delay: ${DELAY}s"

  # ----- preflight: hard requirements (clean message + exit if unmet) -----
  if [ "$USE_SYSTEM_CHROME" != "yes" ] || [ "$DOWNLOAD_IMAGES" = "yes" ]; then
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
      missing_required curl "A downloader (curl or wget) is required to fetch the browser and/or images."
    fi
  fi
  if [ "$USE_SYSTEM_CHROME" != "yes" ]; then
    if ! command -v unzip >/dev/null 2>&1 && [ -z "$PYBIN" ] && ! command -v tar >/dev/null 2>&1; then
      missing_required unzip "Unpacking the downloaded browser needs one of: unzip, python, or tar."
    fi
  fi

  # ----- resolve browser -----
  if [ "$USE_SYSTEM_CHROME" = "yes" ]; then
    CHROME="$(find_system_chrome)" || die "--use-system-chrome set but no Chrome/Chromium found on PATH."
    ok "Using system browser: $CHROME"
  else
    CHROME="$(download_chrome)"
  fi

  # ----- output dir & temp profile -----
  local host ts
  START_URL="$(normalize_url "$START_URL")"   # so the seed matches discovered links
  host="$(url_host "$START_URL")"
  ts="$(date +%Y%m%d-%H%M%S)"
  [ -z "$OUT_DIR" ] && OUT_DIR="$SCRIPT_DIR/output/${host}-${ts}"
  mkdir -p "$OUT_DIR"
  PROFILE_DIR="$(mktemp -d 2>/dev/null || echo "$CACHE_DIR/profile-$$")"
  mkdir -p "$PROFILE_DIR"
  trap 'rm -rf "$PROFILE_DIR"' EXIT          # clean temp profile on exit
  SKIP_CURRENT=0; ABORT=0; LAST_INT=-100
  trap on_interrupt INT

  build_flags

  # Smoke-test the browser; fall back to a system one if it can't launch.
  if ! "$CHROME" "${CHROME_FLAGS[@]}" --dump-dom "data:text/html,<title>t</title>" >/dev/null 2>"$ERR_SINK"; then
    warn "Downloaded browser failed to launch (often missing system libraries on Linux)."
    if sysc="$(find_system_chrome)"; then
      warn "Falling back to system browser: $sysc"
      CHROME="$sysc"; build_flags
    else
      die "No working browser available. On Debian/Ubuntu try: sudo apt-get install -y libnss3 libgbm1 libasound2"
    fi
  fi

  # ----- image output setup -----
  IMAGES_DIR="$OUT_DIR/images"
  IMG_MANIFEST="$OUT_DIR/images-manifest.txt"
  IMG_COUNT=0
  if [ "$DOWNLOAD_IMAGES" = "yes" ]; then
    mkdir -p "$IMAGES_DIR"; : > "$IMG_MANIFEST"
  fi

  # Python-dependent features: if Python is missing, warn once and degrade.
  SLOT_IMAGES="no"
  if [ -z "$PYBIN" ] && { [ "$DOWNLOAD_IMAGES" = "yes" ] || [ "$BODY_FIRST" = "yes" ] || [ "$CONTENT_ONLY" = "yes" ] || [ -n "$SELECT" ]; }; then
    warn "Python 3 was not found on PATH (and can't be installed automatically)."
    printf '    Some features are disabled. To enable them, install Python and re-run:\n' >&2
    printf '        %s\n' "$(install_hint python)" >&2
    [ -n "$SELECT" ] && \
      printf '    %s\n' "- --select (target a section) -> ignored; crawling the whole page" >&2
    [ "$CONTENT_ONLY" = "yes" ] && \
      printf '    %s\n' "- content-only (reader) mode -> falling back to a full visual copy of each page" >&2
    [ "$DOWNLOAD_IMAGES" = "yes" ] && \
      printf '    %s\n' "- image slot-back -> images still appear in the PDF (rendered live by Chrome) and are saved under images/" >&2
    [ "$BODY_FIRST" = "yes" ] && \
      printf '    %s\n' "- body-first crawl order -> falling back to a plain breadth-first crawl" >&2
  fi

  # Section targeting: scope crawling to a region.
  SELECT_ARGS=()
  if [ -n "$SELECT" ]; then
    if [ -n "$PYBIN" ]; then
      write_selector "$SELECT_PY"
      set -f   # split selectors with globbing off (so '*foo*' isn't expanded)
      SELECT_ARGS=( $(printf '%s' "$SELECT" | tr ',' ' ') )
      set +f
      log "Targeting section(s): $SELECT (following only links found inside it)"
    else
      SELECT=""   # already explained above; crawl whole page
    fi
  fi

  # Content-only (reader) mode: extract just the content into a clean PDF.
  if [ "$CONTENT_ONLY" = "yes" ]; then
    if [ -n "$PYBIN" ]; then
      write_content_extractor "$CONTENT_PY"
      log "Output mode: content-only (reader) -- extracting page content, dropping site chrome & styling"
    else
      CONTENT_ONLY="no"   # already explained above; degrade to full visual copy
    fi
  fi

  # Image slot-back (mirror path only; content mode handles tokens itself).
  if [ "$DOWNLOAD_IMAGES" = "yes" ] && [ -n "$PYBIN" ]; then
    SLOT_IMAGES="yes"
    [ "$CONTENT_ONLY" = "yes" ] || write_rewriter "$REWRITER_PY"
    [ "$CONTENT_ONLY" = "yes" ] || log "Image mode: slot downloaded images back into PDFs by id (Python: $PYBIN)"
  fi

  # Body-first ordering. STRIP_SPEC (unquoted -> args): tags, "--", class/id keywords.
  STRIP_SPEC="header nav footer -- footer navbar masthead"
  if [ "$BODY_FIRST" = "yes" ]; then
    if [ -n "$PYBIN" ]; then
      write_stripper "$STRIPPER_PY"
      log "Crawl order: body/content links first, then header/nav/footer links"
    else
      BODY_FIRST="no"   # already explained above; degrade to plain BFS
    fi
  fi

  [ -n "$AUTH_USER" ] && log "Basic-Auth enabled for host '$host' (user: $AUTH_USER)"

  # ----- crawl -----
  # Seed the high-priority (content) frontier with the start URL.
  C_URL=("$START_URL"); C_DEPTH=(0); N_URL=(); N_DEPTH=()
  local cHead=0 nHead=0 count=0 manifest="$OUT_DIR/manifest.txt"
  local crawl_start="$SECONDS"
  : > "$manifest"
  PDF_LIST=()   # array so paths with spaces survive the merge step
  log "Crawling... (Ctrl-C skips the current page; double-tap Ctrl-C to stop)"

  while [ "$cHead" -lt "${#C_URL[@]}" ] || [ "$nHead" -lt "${#N_URL[@]}" ]; do
    [ "$ABORT" = 1 ] && { warn "Crawl stopped early by user."; break; }
    [ "$count" -ge "$MAX_PAGES" ] && { warn "Reached max-pages limit ($MAX_PAGES)."; break; }

    # Content frontier first; fall back to header/nav only when content is empty.
    local url depth kind
    if [ "$cHead" -lt "${#C_URL[@]}" ]; then
      url="${C_URL[$cHead]}"; depth="${C_DEPTH[$cHead]}"; cHead=$((cHead + 1)); kind="content"
    else
      url="${N_URL[$nHead]}"; depth="${N_DEPTH[$nHead]}"; nHead=$((nHead + 1)); kind="nav"
    fi

    seen "$url" && continue
    mark "$url"

    count=$((count + 1))
    local idx pdf
    idx="$(printf '%04d' "$count")"
    pdf="$OUT_DIR/${idx}_$(slugify "$url").pdf"

    # Per-page status: progress, depth, frontier, pending counts, images, elapsed.
    local q_content q_nav elapsed origin=""
    q_content=$(( ${#C_URL[@]} - cHead ))
    q_nav=$(( ${#N_URL[@]} - nHead ))
    elapsed="$(fmt_time $(( SECONDS - crawl_start )))"
    [ "$BODY_FIRST" = "yes" ] && origin=" ($kind)"
    log "[$count/$MAX_PAGES] depth $depth$origin | queue ${q_content}c/${q_nav}n | imgs $IMG_COUNT | $elapsed elapsed"
    printf '    \033[2m%s\033[0m\n' "$url" >&2

    # Grab the rendered DOM once if needed (images, content, select, or links).
    local dom="" need_dom="no"
    [ "$CONTENT_ONLY" = "yes" ] && need_dom="yes"
    [ -n "$SELECT" ] && need_dom="yes"
    [ "$SLOT_IMAGES" = "yes" ] && need_dom="yes"
    [ "$DOWNLOAD_IMAGES" = "yes" ] && need_dom="yes"
    [ "$depth" -lt "$MAX_DEPTH" ] && need_dom="yes"
    if [ "$need_dom" = "yes" ]; then
      dom="$(mktemp 2>/dev/null || echo "$PROFILE_DIR/dom.$count")"
      run_spin "  loading page" dump_dom "$url" > "$dom"
    fi

    # Skip this page's work if Ctrl-C asked to (interrupt guard).
    local region_dom=""
    if [ "$SKIP_CURRENT" != 1 ] && [ "$ABORT" != 1 ]; then

    # Isolate the targeted section (scopes link discovery, not extraction).
    if [ -n "$SELECT" ] && [ -n "$dom" ]; then
      region_dom="$(mktemp 2>/dev/null || echo "$PROFILE_DIR/region.$count")"
      if ! "$PYBIN" "$(pypath "$SELECT_PY")" "${SELECT_ARGS[@]}" < "$dom" > "$region_dom" 2>"$ERR_SINK"; then
        rm -f "$region_dom"; region_dom=""
      fi
    fi

    # Produce the PDF (content-only extracts main content regardless of --select).
    local pdf_ok="no"
    if [ "$CONTENT_ONLY" = "yes" ] && [ -n "$dom" ]; then
      build_pdf_snapshot content "$url" "$dom" "$pdf" && pdf_ok="yes"
    elif [ "$SLOT_IMAGES" = "yes" ] && [ -n "$dom" ]; then
      build_pdf_snapshot mirror "$url" "$dom" "$pdf" && pdf_ok="yes"
    else
      run_spin "  rendering PDF" render_pdf "$url" "$pdf" && pdf_ok="yes"
      # Live mode: still save images as a separate archive if requested.
      [ "$DOWNLOAD_IMAGES" = "yes" ] && [ -n "$dom" ] && download_images "$url" "$dom"
    fi

    if [ "$pdf_ok" = "yes" ]; then
      ok "  -> $(basename "$pdf")"
      printf '%s\t%s\n' "$(basename "$pdf")" "$url" >> "$manifest"
      PDF_LIST+=("$pdf")
    else
      warn "  render failed, skipping"
      rm -f "$pdf"
    fi

    # Discover links to crawl next (only if we may go deeper and weren't interrupted).
    if [ "$depth" -lt "$MAX_DEPTH" ] && [ -n "$dom" ] && [ "$SKIP_CURRENT" != 1 ] && [ "$ABORT" != 1 ]; then
      local nd=$(( depth + 1 ))
      if [ -n "$SELECT" ]; then
        # Targeted: follow only links inside the selected region (all as content).
        if [ -n "$region_dom" ]; then
          enqueue_links content "$url" "$nd" <<EOF
$(extract_links "$url" "$region_dom")
EOF
        fi
      elif [ "$BODY_FIRST" = "yes" ]; then
        # Content frontier = links from the body (header/nav/footer stripped).
        local content_dom
        content_dom="$(mktemp 2>/dev/null || echo "$PROFILE_DIR/links.$count")"
        if "$PYBIN" "$(pypath "$STRIPPER_PY")" $STRIP_SPEC < "$dom" > "$content_dom" 2>"$ERR_SINK"; then
          enqueue_links content "$url" "$nd" <<EOF
$(extract_links "$url" "$content_dom")
EOF
        fi
        rm -f "$content_dom"
        # Nav frontier = remaining links (content ones already queued are deduped).
        enqueue_links nav "$url" "$nd" <<EOF
$(extract_links "$url" "$dom")
EOF
      else
        # Plain breadth-first: everything is content.
        enqueue_links content "$url" "$nd" <<EOF
$(extract_links "$url" "$dom")
EOF
      fi
    fi
    fi   # end interrupt guard

    [ -n "$region_dom" ] && rm -f "$region_dom"
    [ -n "$dom" ] && rm -f "$dom"

    if [ "$SKIP_CURRENT" = 1 ]; then warn "  page skipped"; SKIP_CURRENT=0; fi
    [ "$ABORT" = 1 ] && { warn "Crawl stopped early by user."; break; }

    sleep "$DELAY" 2>/dev/null || true   # be polite
  done

  local n_pdf total_time
  n_pdf=${#PDF_LIST[@]}
  total_time="$(fmt_time $(( SECONDS - crawl_start )))"
  printf '\033[36m%s\033[0m\n' "----------------------------------------------------------" >&2
  ok "Crawled $count page(s) in $total_time -> $n_pdf PDF(s)"
  [ "$DOWNLOAD_IMAGES" = "yes" ] && ok "Images: $IMG_COUNT downloaded into $IMAGES_DIR"
  ok "Output: $OUT_DIR"
  [ "$n_pdf" -eq 0 ] && die "No PDFs were produced."

  # ----- merge -----
  if [ "$DO_MERGE" != "no" ]; then
    local merged="$OUT_DIR/_ALL_${host}.pdf"
    if command -v pdfunite >/dev/null 2>&1; then
      run_spin "Merging $n_pdf PDF(s)" pdfunite "${PDF_LIST[@]}" "$merged" \
        && ok "Merged PDF: $merged" \
        || warn "pdfunite merge failed; per-page PDFs are still available."
    elif command -v gs >/dev/null 2>&1; then
      run_spin "Merging $n_pdf PDF(s)" gs -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite -sOutputFile="$merged" "${PDF_LIST[@]}" \
        && ok "Merged PDF: $merged" \
        || warn "ghostscript merge failed; per-page PDFs are still available."
    else
      if [ "$DO_MERGE" = "yes" ]; then
        warn "Merge requested but no merger found (and it can't be installed automatically)."
        printf '    Install poppler (pdfunite) to enable merging, then re-run:\n' >&2
        printf '        %s\n' "$(install_hint poppler)" >&2
        printf '    %s\n' "For now: the individual per-page PDFs are kept." >&2
      else
        log "No PDF merger (pdfunite/gs) found; leaving individual page PDFs. To merge: $(install_hint poppler)"
      fi
    fi
  fi

  ok "Done. Manifest: $manifest"
}

main "$@"
