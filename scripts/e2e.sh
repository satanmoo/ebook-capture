#!/usr/bin/env bash
# End-to-end checks for ebook-capture. They press real keys in a real app,
# so keep your hands off the keyboard and mouse while they run.
#
#   scripts/e2e.sh preview
#       Automatic. Generates a numbered book, opens it in Preview and checks
#       a full run, Ctrl-C and --resume, whole-window capture, leftovers,
#       overwriting, trimming an area past the window and stopping at the
#       end of the book. Selecting with the mouse uses a preset area; a real
#       drag is checked by hand. (The leftover check puts one small
#       folder in your Trash.)
#
#   scripts/e2e.sh app 1|2 [--pages N] [--margin PX]
#       Semi-automatic. Captures N pages (default 3) from the book you have
#       open in 교보도서관 (1) or Chrome (2), then opens the PDF for you to check.
#
# The terminal app running this needs Accessibility and Screen Recording
# permission (System Settings > Privacy & Security).

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$repo/.build/release/ebook-capture"
# Same rule as the tool (FileManager.temporaryDirectory): $TMPDIR first
tmp_root="${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}"
tmp_root="${tmp_root%/}/ebook-capture"
work=""
failures=0

ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
expect() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

# Pages in a PDF via PDFKit; 0 when missing or unreadable.
page_count() {
  osascript -l JavaScript -e 'function run(argv) {
    ObjC.import("PDFKit")
    const doc = $.PDFDocument.alloc.initWithURL($.NSURL.fileURLWithPath(argv[0]))
    return doc.isNil() ? 0 : doc.pageCount
  }' "$1" 2>/dev/null || echo 0
}

build() {
  echo "Building the release binary..."
  swift build -c release --package-path "$repo" >/dev/null
}

finish() {
  echo
  if (( failures == 0 )); then echo "All checks passed."; else echo "$failures check(s) failed."; exit 1; fi
}

# ---------------------------------------------------------------------------

preview_checks() {
  local book region
  work="$(mktemp -d)"
  book="$work/numbered.pdf"
  trap 'osascript -e "tell application \"Preview\" to close (every window whose name is \"numbered.pdf\")" >/dev/null 2>&1; [[ -n "$work" ]] && rm -rf "$work"' EXIT
  export EBOOK_CAPTURE_APP=com.apple.Preview

  # Each page is filled with its own number so every page looks different.
  # The built-in CUPS text filter turns a form feed into a page break.
  for p in $(seq 1 10); do
    for _ in $(seq 1 40); do printf 'PAGE %d   PAGE %d   PAGE %d\n' "$p" "$p" "$p"; done
    printf '\f'
  done > "$work/numbered.txt"
  cupsfilter -i text/plain -m application/pdf "$work/numbered.txt" > "$book" 2>/dev/null
  open -a Preview "$book"
  sleep 3

  # Preview opens on the main screen, whose origin is (0, 0), so its window
  # position is also the screen-relative position the tool expects.
  local bounds x y w h
  bounds="$(osascript -e 'tell application "System Events" to tell process "Preview" to get {position, size} of front window')"
  read -r x y w h <<< "${bounds//,/ }"
  region="$((x + 60)) $((y + 60)) $((w - 120)) $((h - 120))"
  first_page() { osascript -e 'tell application "Preview" to activate' -e 'tell application "System Events" to key code 115' >/dev/null; }

  echo "1. Full run with --region ($region)"
  first_page
  "$bin" -o "$work/full.pdf" --pages 10 --app 1 --region "$region" > "$work/full.log" 2>&1 || true
  expect '[[ "$(page_count "$work/full.pdf")" -eq 10 ]]' "PDF has 10 pages"
  expect '! grep -q "waiting once more" "$work/full.log"' "every page turn was detected"
  expect '[[ ! -e "$tmp_root/full" ]]' "temporary folder removed"

  echo "2. Ctrl-C during an interactive run, then --resume"
  first_page
  # Answers: output, pages, area (3 = whole window), app
  printf '%s\n' "$work/stopped" 10 3 1 | "$bin" > "$work/stopped.log" 2>&1 &
  local pid=$!
  sleep 5
  kill -INT "$pid"
  local code=0
  wait "$pid" || code=$?
  local partial
  partial="$(page_count "$work/stopped.pdf")"
  expect '[[ $code -eq 130 ]]' "exit code 130 (got $code)"
  expect '(( partial > 0 && partial < 10 ))' "partial PDF has $partial pages"
  expect '[[ -f "$tmp_root/stopped/session.json" ]]' "pages and progress kept for --resume"
  expect 'grep -q -- "--resume" "$work/stopped.log"' "resume command shown"
  # Don't touch Preview: --resume works out the page from the counts.
  # A limit past the book makes it run to the end, so a repeated or skipped
  # page at the seam shows up as 11 or 9 pages.
  "$bin" -o "$work/stopped.pdf" --resume --pages 15 < /dev/null > "$work/resumed.log" 2>&1 || true
  expect 'grep -q "Continuing from page $((partial + 1))" "$work/resumed.log"' "continued from page $((partial + 1))"
  expect 'grep -q "Reached the end of the book" "$work/resumed.log"' "resumed run went to the end of the book"
  expect '[[ "$(page_count "$work/stopped.pdf")" -eq 10 ]]' "resumed PDF has exactly 10 pages (nothing repeated or skipped)"
  # The only extra wait should be the one that finds the end of the book
  expect '[[ "$(grep -c "waiting once more" "$work/resumed.log")" -eq 1 ]]' "every page turn was detected (one wait, at the end)"
  expect '[[ ! -e "$tmp_root/stopped" ]]' "temporary folder removed after finishing"

  echo "3. Whole window, name without .pdf, leftover temporary folder"
  first_page
  mkdir -p "$tmp_root/whole"
  sips -s format png "$book" --out "$tmp_root/whole/page-99999.png" >/dev/null
  (cd "$work" && "$bin" -o whole --pages 3 --app 1 --margin 60 > whole.log 2>&1) || true
  expect 'grep -q "added .pdf extension" "$work/whole.log"' ".pdf extension added and reported"
  expect 'grep -q "Moved a leftover capture folder to the Trash" "$work/whole.log"' "leftover folder moved to the Trash"
  expect '[[ "$(page_count "$work/whole.pdf")" -eq 3 ]]' "PDF has 3 pages (leftover page not included)"

  echo "4. Existing output"
  first_page
  local before
  before="$(md5 -q "$work/whole.pdf")"
  if "$bin" -o "$work/whole.pdf" --pages 2 --app 1 --margin 60 < /dev/null > "$work/refuse.log" 2>&1; then
    bad "refused without -f"
  else
    ok "refused without -f"
  fi
  expect '[[ "$(md5 -q "$work/whole.pdf")" == "$before" ]]' "existing file untouched"
  "$bin" -o "$work/whole.pdf" --pages 2 --app 1 --margin 60 -f < /dev/null > "$work/force.log" 2>&1 || true
  expect '[[ "$(page_count "$work/whole.pdf")" -eq 2 ]]' "-f overwrote it (2 pages)"

  echo "5. An area slightly past the window is trimmed"
  first_page
  "$bin" -o "$work/trim.pdf" --pages 2 --app 1 --region "$((x + 60)) $((y + 60)) $w $h" > "$work/trim.log" 2>&1 || true
  expect 'grep -q "trimmed to the" "$work/trim.log"' "trim reported"
  expect '[[ "$(page_count "$work/trim.pdf")" -eq 2 ]]' "captured 2 pages anyway"

  echo "6. Select with the mouse, then capture several pages"
  # The helper shows the overlay briefly and answers with this area instead
  # of waiting for a drag. Turning pages after an overlay is what used to
  # make the process quit silently.
  first_page
  code=0
  EBOOK_CAPTURE_TEST_SELECTION="$region" "$bin" -o "$work/select.pdf" --pages 3 --app 1 --region select \
    > "$work/select.log" 2>&1 || code=$?
  expect '[[ $code -eq 0 ]]' "exit code 0 (got $code)"
  expect 'grep -q "Capture area (x y w h): $region" "$work/select.log"' "selected area used ($region)"
  expect '[[ "$(page_count "$work/select.pdf")" -eq 3 ]]' "PDF has 3 pages"

  echo "7. End of the book (--pages larger than the book)"
  first_page
  "$bin" -o "$work/end.pdf" --pages 15 --app 1 --margin 60 > "$work/end.log" 2>&1 || true
  expect 'grep -q "Reached the end of the book" "$work/end.log"' "end of the book reported"
  expect '[[ "$(page_count "$work/end.pdf")" -eq 10 ]]' "PDF has all 10 pages of the book, no duplicates"
}

app_check() {
  local app="$1"; shift
  local pages=3 margin=10
  while (( $# )); do
    case "$1" in
      --pages) pages="$2"; shift 2 ;;
      --margin) margin="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
  done
  local out
  work="$(mktemp -d)"
  out="$work/e2e-check.pdf"

  echo "Open a book in $( [[ $app == 1 ]] && echo 교보도서관 || echo "Chrome (click the page once)" )."
  echo "The next $pages page(s) will be captured; don't touch anything until it finishes."
  read -r -p "Press Enter to start... " < /dev/tty

  "$bin" -o "$out" --pages "$pages" --app "$app" --margin "$margin" < /dev/null || true
  expect '[[ "$(page_count "$out")" -eq $pages ]]' "PDF has $pages pages"

  if [[ -f "$out" ]]; then
    open "$out"
    echo "Check the PDF: nothing cut off, pages in order, no duplicates."
    read -r -p "Delete the test PDF? [y/N] " answer < /dev/tty
    if [[ "$answer" == [yY] ]]; then rm -rf "$work"; else echo "Kept: $out"; fi
  fi
}

case "${1:-}" in
  preview) build; preview_checks ;;
  app) [[ "${2:-}" == [12] ]] || { echo "usage: $0 app 1|2 [--pages N] [--margin PX]" >&2; exit 2; }
       build; app_check "${@:2}" ;;
  *) echo "usage: $0 preview | app 1|2 [--pages N] [--margin PX]" >&2; exit 2 ;;
esac
finish
