#!/bin/bash
set -euo pipefail
set -x

echo "Script started with arguments: $@" >&2

function process_args() {
  log_debug "Entering process_args function"
  if [ $# -ne 1 ]; then
    log_error "Usage: $0 <input-pdf>"
    exit 1
  fi
  log_debug "Input argument: $1"
  printf '%s\n' "$1"
  log_debug "Exiting process_args function"
}

function setup_environment() {
  local i="$1"
  local b=$(basename "$i" .pdf)
  local t=$(mktemp -d)
  local o="${i%.pdf}-mixocr.pdf"
  local s=50
  log_info "Setting up environment:"
  log_debug "Input file: $i"
  log_debug "Base name: $b"
  log_debug "Temp dir: $t"
  log_debug "Output file: $o"
  log_debug "Scale: $s"
  printf '%s|%s|%s|%s\n' "$b" "$t" "$o" "$s"
  log_debug "setup_environment function completed"
}

function convert_pdf_to_png() {
  local i="$1" t="$2"
  local output_pattern="${t}/page-%04d.png"
  log_info "Converting PDF to PNG: $i"
  magick -density 500 "$i" -background white -alpha remove "$output_pattern" || {
    local error_code=$?
    log_error "Error converting PDF to PNG: $i"
    log_error "magick command failed with exit code: $error_code"
    log_debug "Output pattern: $output_pattern"
    log_debug "Current working directory: $(pwd)"
    return $error_code
  }
  log_info "PDF to PNG conversion completed successfully"
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

  pdftk "$t"/*-metal.pdf cat output "$metal_pdf" || { log_error "Error creating metal_combined.pdf"; return 1; }
  pdftk "$t"/*-tess.pdf cat output "$tess_pdf" || { log_error "Error creating tess_combined.pdf"; return 1; }

  local metal_pages=$(pdftk "$metal_pdf" dump_data | grep NumberOfPages | awk '{print $2}')
  local tess_pages=$(pdftk "$tess_pdf" dump_data | grep NumberOfPages | awk '{print $2}')

  log_info "Metal OCR pages: $metal_pages, Tesseract OCR pages: $tess_pages"

  if [ "$metal_pages" != "$tess_pages" ]; then
    log_error "Error: Number of pages in metal OCR ($metal_pages) and Tesseract OCR ($tess_pages) PDFs do not match."
    return 1
  fi

  local interleave_cmd="pdftk A='$metal_pdf' B='$tess_pdf' cat"
  for ((i=1; i<=$metal_pages; i++)); do
    interleave_cmd+=" A$i B$i"
  done
  interleave_cmd+=" output '$temp_output'"

  log_info "Executing interleave command: $interleave_cmd"
  eval "$interleave_cmd" || { log_error "Error interleaving PDFs"; return 1; }

  mv "$temp_output" "$o" || { log_error "Error moving temp output to final output"; return 1; }

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

function log_debug() {
  echo "[DEBUG] $*" >&2
}

function log_error() {
  echo "[ERROR] $*" >&2
}

function log_info() {
  echo "[INFO] $*" >&2
}

function check_dependencies() {
  local deps=("magick" "tesseract" "pdftk" "gs")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
      log_error "Required dependency '$dep' not found. Please install it."
      exit 1
    fi
  done
  log_info "All dependencies are installed."
}

function main() {
  log_debug "Starting main function"
  check_dependencies
  local i b t o s
  i=$(process_args "$@")
  
  log_debug "About to setup environment"
  setup_output=$(setup_environment "$i")
  log_debug "Raw setup_output: $setup_output"
  
  IFS='|' read -r b t o s <<< "$setup_output"
  
  log_debug "Environment setup complete"
  log_debug "b: '$b'"
  log_debug "t: '$t'"
  log_debug "o: '$o'"
  log_debug "s: '$s'"
  
  if [[ -z "$b" || -z "$t" || -z "$o" || -z "$s" ]]; then
    log_error "One or more environment variables are empty"
    log_debug "Raw setup_output:"
    echo "$setup_output" | sed 's/^/  /' >&2
    exit 1
  fi
  
  log_info "Input file: $i"
  log_info "Base name: $b"
  log_info "Temporary directory: $t"
  log_info "Output file: $o"
  log_info "Scale: $s"
  
  log_debug "About to convert PDF to PNG"
  convert_pdf_to_png "$i" "$t" || {
    log_error "Failed to convert PDF to PNG. Exiting."
    cleanup "$t"
    exit 1
  }
  
  log_debug "PDF to PNG conversion complete"
  local png_files=()
  while IFS= read -r -d '' png; do
    png_files+=("$png")
  done < <(find "$t" -type f -name '*.png' -print0)
  
  local num_pngs=${#png_files[@]}
  log_info "Processing $num_pngs PNG files"
  
  local batch_size=4
  for ((i=0; i<num_pngs; i+=batch_size)); do
    for ((j=i; j<i+batch_size && j<num_pngs; j++)); do
      {
        log_debug "Processing ${png_files[j]} with metalocr"
        process_png_metalocr "$t" "${png_files[j]}" || log_error "Failed to process ${png_files[j]} with metalocr"
        log_debug "Processing ${png_files[j]} with tessocr"
        process_png_tessocr "$t" "${png_files[j]}" || log_error "Failed to process ${png_files[j]} with tessocr"
        log_info "Processed ${png_files[j]}"
      } &
    done
    wait
    log_info "Completed batch $((i/batch_size + 1)) of $((num_pngs/batch_size + 1))"
  done
  
  log_debug "About to interweave PDFs"
  interweave_pdfs "$t" "$t/interweaved.pdf" || {
    log_error "Failed to interweave PDFs. Exiting."
    cleanup "$t"
    exit 1
  }
  
  log_debug "About to normalize page size"
  normalize_page_size "$t/interweaved.pdf" "$o" || {
    log_error "Failed to normalize page size. Exiting."
    cleanup "$t"
    exit 1
  }
  
  cleanup "$t"
  
  if [ -f "$o" ]; then
    log_info "Searchable PDF created: $o"
    pdftk "$o" dump_data | grep NumberOfPages
  else
    log_error "Searchable PDF was not created."
    exit 1
  fi
  log_debug "Main function completed"
}

main "$@"
