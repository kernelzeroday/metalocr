#!/bin/bash

# Check if the required arguments are provided
if [ $# -ne 1 ]; then
  echo "Usage: $0 <input-pdf>"
  exit 1
fi

INPUT_PDF="$1"
BASENAME=$(basename "$INPUT_PDF" .pdf)
TEMP_DIR=$(mktemp -d)
OUTPUT_PDF="${BASENAME}-tessocr.pdf"

# Step 1: Convert the PDF to PNG files in the temporary directory
echo "Converting PDF to PNG files..."
magick -density 300 "$INPUT_PDF" "$TEMP_DIR/page-%04d.png"
if [ $? -ne 0 ]; then
  echo "Error: PDF to PNG conversion failed."
  exit 1
fi

# Step 2: Extract text from each PNG file using Tesseract and create a PDF with invisible text layer
echo "Extracting text with OCR and embedding as an invisible layer..."
for i in "$TEMP_DIR"/*.png; do
  OCR_OUTPUT="${i%.png}.pdf"
  
  # Run OCR with Tesseract and embed the text as an invisible layer in the PDF
  tesseract "$i" "${i%.png}" pdf
  
  if [ ! -f "$OCR_OUTPUT" ]; then
    echo "Error: OCR and PDF creation failed for $i."
    exit 1
  fi
done

# Step 3: Combine all the individual PDF pages with embedded text into a single PDF
echo "Combining individual PDFs into a single searchable PDF..."
pdfunite "$TEMP_DIR"/*.pdf "$OUTPUT_PDF"
if [ $? -ne 0 ]; then
  echo "Error: Combining PDFs into a single file failed."
  exit 1
fi

# Step 4: Clean up temporary files
echo "Cleaning up..."
rm -rf "$TEMP_DIR"

if [ -f "$OUTPUT_PDF" ]; then
  echo "Searchable PDF created: $OUTPUT_PDF"
else
  echo "Error: Searchable PDF was not created."
fi
