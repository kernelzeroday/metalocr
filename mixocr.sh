#!/bin/bash
set -euo pipefail

echo "Script started with arguments: $@" >&2

function process_args() {
  if [ $# -ne 1 ]; then
    echo "Usage: $0 <input-pdf>" >&2
    exit 1
  fi
  echo "Input argument: $1" >&2
  printf '%s\n' "$1"
}

function setup_environment() {
  local i="$1"
  local b=$(basename "$i" .pdf)
  local t=$(mktemp -d)
  local o="${i%.pdf}-mixocr.pdf"
  local s=50
  echo "Setting up environment:" >&2
  echo "Input file: $i" >&2
  echo "Base name: $b" >&2
  echo "Temp dir: $t" >&2
  echo "Output file: $o" >&2
  echo "Scale: $s" >&2
  printf '%s\n%s\n%s\n%s\n' "$b" "$t" "$o" "$s"
}

function convert_pdf_to_png() {
  local i="$1" t="$2"
  local output_pattern="${t}/page-%04d.png"
  magick -density 500 "$i" -background white -alpha remove "$output_pattern" || {
    local error_code=$?
    echo "Error converting PDF to PNG: $i" >&2
    echo "magick command failed with exit code: $error_code" >&2
    echo "Output pattern: $output_pattern" >&2
    echo "Current working directory: $(pwd)" >&2
    return $error_code
  }
}

function process_png_metalocr() {
  local t="$1" i="$2"
  local f="${i%.png}.txt" p="${i%.png}-metal.pdf"
  shortcuts run "Extract Text from Image" -i "$i" -o "$f" > /dev/null 2>&1 || true
  if [ -f "$f" ]; then
    magick "$i" -fill white -draw "text 0,0 ' '" -gravity South -fill black -annotate +0+0 "@$f" "$p" > /dev/null 2>&1
  else
    magick "$i" "$p" > /dev/null 2>&1
  fi
}

function process_png_tessocr() {
  local t="$1" i="$2"
  local p="${i%.png}-tess.pdf"
  tesseract "$i" "${i%.png}" pdf
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

  local interleave_cmd="pdftk A='$metal_pdf' B='$tess_pdf' cat"
  for ((i=1; i<=$metal_pages; i++)); do
    interleave_cmd+=" A$i B$i"
  done
  interleave_cmd+=" output '$temp_output'"

  echo "Executing interleave command: $interleave_cmd" >&2
  eval "$interleave_cmd" || { echo "Error interleaving PDFs" >&2; return 1; }

  mv "$temp_output" "$o" || { echo "Error moving temp output to final output" >&2; return 1; }

  rm "$metal_pdf" "$tess_pdf"
}

function normalize_page_size() {
  local input="$1" output="$2"
  local temp_output="${input%.pdf}_normalized.pdf"
  
  gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.5 -dPDFSETTINGS=/prepress -dNOPAUSE -dQUIET -dBATCH -dDetectDuplicateImages -dCompressFonts=true -dAutoRotatePages=/None -dFIXEDMEDIA -dPDFFitPage -r300 -sOutputFile="$temp_output" "$input"
  
  mv "$temp_output" "$output"
}

function cleanup() {
  local t="$1"
  rm -rf "$t"
}

function main() {
  local i
  i=$(process_args "$@")
  
  local setup_output
  mapfile -t setup_array < <(setup_environment "$i")
  
  local b="${setup_array[0]}"
  local t="${setup_array[1]}"
  local o="${setup_array[2]}"
  local s="${setup_array[3]}"
  
  if [[ -z "$b" || -z "$t" || -z "$o" || -z "$s" ]]; then
    echo "Error: One or more environment variables are empty" >&2
    echo "b: $b" >&2
    echo "t: $t" >&2
    echo "o: $o" >&2
    echo "s: $s" >&2
    echo "Raw setup_output:" >&2
    printf '%s\n' "${setup_array[@]}" >&2
    exit 1
  fi
  
  echo "Input file: $i" >&2
  echo "Base name: $b" >&2
  echo "Temporary directory: $t" >&2
  echo "Output file: $o" >&2
  echo "Scale: $s" >&2
  
  convert_pdf_to_png "$i" "$t" || {
    echo "Failed to convert PDF to PNG. Exiting." >&2
    cleanup "$t"
    exit 1
  }
  
  while IFS= read -r -d '' png; do
    process_png_metalocr "$t" "$png" &
    process_png_tessocr "$t" "$png" &
  done < <(find "$t" -type f -name '*.png' -print0)
  wait
  
  interweave_pdfs "$t" "$t/interweaved.pdf" || exit 1
  
  normalize_page_size "$t/interweaved.pdf" "$o"
  
  cleanup "$t"
  
  [ -f "$o" ] || { echo "Searchable PDF was not created." >&2; exit 1; }
  echo "Searchable PDF created: $o"
  pdftk "$o" dump_data | grep NumberOfPages
}

main "$@"
