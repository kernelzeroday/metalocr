#!/bin/bash
set -euo pipefail
function process_args() {
  if [ $# -ne 1 ]; then
    echo "Usage: $0 <input-pdf>" >&2
    exit 1
  fi
  echo "$1"
}
function setup_environment() {
  local i="$1"
  echo "$(basename "$i" .pdf)" "$(mktemp -d)" "${i%.pdf}-mixocr.pdf" 50
}
function convert_pdf_to_tiff() {
  local i="$1" t="$2"
  for a in {1..3}; do
    if magick -density 300 "$i" -compress lzw -quality 100 "$t/page-%04d.tiff"; then
      return 0
    else
      sleep 1
    fi
  done
  echo "PDF to TIFF conversion failed after 3 attempts" >&2
  exit 1
}
function extract_text_tesseract() {
  local t="$1"
  for i in "$t"/*.tiff; do
    local f="${i%.tiff}_tesseract.pdf"
    tesseract "$i" "${i%.tiff}_tesseract" pdf || true
  done
}
function extract_text_shortcuts() {
  local t="$1"
  for i in "$t"/*.tiff; do
    local f="${i%.tiff}_shortcuts.txt"
    shortcuts run "Extract Text from Image" -i "$i" -o "$f" || true
  done
}
function embed_text_shortcuts() {
  local t="$1"
  for i in "$t"/*.tiff; do
    local p="${i%.tiff}_shortcuts.pdf" f="${i%.tiff}_shortcuts.txt"
    if [ -f "$f" ]; then
      magick "$i" -fill white -draw "text 0,0 ' '" -gravity South -fill black -annotate +0+0 @"$f" "$p" || continue
    else
      magick "$i" "$p" || continue
    fi
  done
}
function combine_pdfs() {
  local t="$1" s="$2" o="$3"
  local -a m=()
  local c=0 i=1 f=""
  for p in "$t"/*_tesseract.pdf "$t"/*_shortcuts.pdf; do
    if [ $c -eq 0 ]; then
      f="$t/chunk_$i.pdf"
      cp "$p" "$f" || exit 1
      m+=("$f")
    else
      pdfunite "$f" "$p" "$f.tmp" || exit 1
      mv "$f.tmp" "$f"
    fi
    c=$((c + 1))
    if [ $c -ge $s ]; then
      i=$((i + 1))
      c=0
    fi
  done
  if [ ${#m[@]} -gt 1 ]; then
    local l="$t/final_chunk.pdf"
    pdfunite "${m[@]}" "$l" || exit 1
    mv "$l" "$o"
  else
    mv "${m[0]}" "$o"
  fi
}
function cleanup() {
  local t="$1"
  rm -rf "$t"
}
function main() {
  local i=$(process_args "$@")
  local b t o s
  read -r b t o s < <(setup_environment "$i")
  convert_pdf_to_tiff "$i" "$t" || exit 1
  extract_text_tesseract "$t" || exit 1
  extract_text_shortcuts "$t" || exit 1
  embed_text_shortcuts "$t" || exit 1
  combine_pdfs "$t" "$s" "$o" || exit 1
  cleanup "$t"
  [ -f "$o" ] || { echo "Searchable PDF was not created." >&2; exit 1; }
}
main "$@"
