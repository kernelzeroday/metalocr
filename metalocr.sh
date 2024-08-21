#!/bin/bash

# Check if the required arguments are provided
if [ $# -ne 1 ]; then
  echo "Usage: $0 <input-pdf>"
  exit 1
fi

INPUT_PDF="$1"
BASENAME=$(basename "$INPUT_PDF" .pdf)
TEMP_DIR=$(mktemp -d)
OUTPUT_PDF="${BASENAME}-metalocr.pdf"

# Step 1: Convert the PDF to PNG files in the temporary directory
echo "Converting PDF to PNG files..."
magick -density 300 "$INPUT_PDF" "$TEMP_DIR/page-%04d.png"

# Step 2: Extract text from each PNG file using Shortcuts and save the output as text files
echo "Extracting text from PNG files..."
cd "$TEMP_DIR" || exit
for i in *.png; do
  echo "Processing $i..."
  TEXT_FILE="${i%.png}.txt"
  
  # Run the shortcut and ensure it outputs the text file
  shortcuts run "Extract Text from Image" -i "$i" -o "$TEXT_FILE"
  
  if [ ! -f "$TEXT_FILE" ]; then
    echo "Error: Text extraction failed for $i. No text file created."
  fi
done

# Step 3: Combine the PNG files and the extracted text back into a searchable PDF
echo "Creating searchable PDF..."
for i in *.png; do
  TEXT_FILE="${i%.png}.txt"
  
  if [ -f "$TEXT_FILE" ]; then
    # If the text file exists, overlay the text onto the image
    magick "$i" -density 300 -units PixelsPerInch -gravity North -pointsize 10 -draw "text 10,10 '$(cat "$TEXT_FILE" | sed "s/\'/\\\'/g")'" "$i"
  else
    echo "Warning: Text file $TEXT_FILE does not exist. Skipping text overlay for $i."
  fi
done

# Combine images back into a PDF
magick convert "$TEMP_DIR/page-*.png" "$OUTPUT_PDF"

# Step 4: Clean up temporary files
echo "Cleaning up..."
rm -rf "$TEMP_DIR"

echo "Searchable PDF created: $OUTPUT_PDF"
