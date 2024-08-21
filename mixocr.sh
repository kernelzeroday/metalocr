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

function convert_pdf_to_png() {
  local i="$1" t="$2"
  magick -density 300 "$i" "$t/page-%04d.png" || {
    echo "Error converting PDF to PNG: $i" >&2
    exit 1
    }
}

function process_png_metalocr() {
  local t="$1" i="$2"
  local f="${i%.png}.txt" p="${i%.png}-metal.pdf"
  shortcuts run "Extract Text from Image" -i "$i" -o "$f" > /dev/null 2>&1 || true
  if [ -f "$f" ]; then
    magick "$i" -fill white -draw "text 0,0 ' '" -gravity South -fill black -annotate +0+0 @"$f" "$p" > /dev/null 2>&1
  else
    magick "$i" "$p" > /dev/null 2>&1
  fi
}



function process_png_tessocr() {
  local t="$1" i="$2"
  local p="${i%.png}-tess.pdf"
  tesseract "$i" "${i%.png}" pdf --singlefile
  mv "${i%.png}.pdf" "$p"
}

function interweave_pdfs() {
  local t="$1" o="$2"
  local metal_pdf="$t/metal_combined.pdf"
  local tess_pdf="$t/tess_combined.pdf"
  local temp_output="$t/temp_output.pdf"

  pdftk "$t"/*-metal.pdf cat output "$metal_pdf" || { echo "Error creating metal_combined.pdf" >&2; return 1; }
  pdftk "$t"/*-tess.pdf cat output "$tess_pdf" || { echo "Error creating tess_combined.pdf" >&2; return 1; }

  local metal_pages=$(pdftk "$metal_pdf" dump_data | grep NumberOfPages | awk '{print $2}')
  local tess_pages=$(pdftk "$tess_pdf" dump_data | grep NumberOfPages | awk '{print $2}')

  echo "Metal OCR pages: $metal_pages, Tesseract OCR pages: $tess_pages" >&2

  if [ "$metal_pages" != "$tess_pages" ]; then
    echo "Error: Number of pages in metal OCR ($metal_pages) and Tesseract OCR ($tess_pages) PDFs do not match." >&2
    return 1
  fi

  local interleave_cmd="pdftk A=$metal_pdf B=$tess_pdf cat"
  for ((i=1; i<=$metal_pages; i++)); do
    interleave_cmd+=" A$i B$i"
  done
  interleave_cmd+=" output $temp_output"

  echo "Executing interleave command: $interleave_cmd" >&2
  eval "$interleave_cmd" || { echo "Error interleaving PDFs" >&2; return 1; }

  mv "$temp_output" "$o" || { echo "Error moving temp output to final output" >&2; return 1; }

  rm "$metal_pdf" "$tess_pdf"
}

function cleanup() {
  local t="$1"
  rm -rf "$t"
}

function main() {
  local i=$(process_args "$@")
  local b t o s
  read -r b t o s < <(setup_environment "$i")
  
  convert_pdf_to_png "$i" "$t" || exit 1
  
  for png in "$t"/*.png; do
    process_png_metalocr "$t" "$png" &
    process_png_tessocr "$t" "$png" &
  done
  wait
  
  interweave_pdfs "$t" "$o" || exit 1
  cleanup "$t"
  
  [ -f "$o" ] || { echo "Searchable PDF was not created." >&2; exit 1; }
  echo "Searchable PDF created: $o"
  pdftk "$o" dump_data | grep NumberOfPages
}

main "$@"
