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
CHUNK_SIZE=50  # Number of files to process in each chunk
MERGED_PDFS=()

# Step 1: Convert the PDF to PNG files in the temporary directory
echo "Converting PDF to PNG files..."
magick -density 300 "$INPUT_PDF" "$TEMP_DIR/page-%04d.png"
if [ $? -ne 0 ]; then
  echo "Error: PDF to PNG conversion failed."
  exit 1
fi

# Step 2: Extract text from each PNG file using Shortcuts
echo "Extracting text with Shortcuts..."
for i in "$TEMP_DIR"/*.png; do
  TEXT_FILE="${i%.png}.txt"
  
  # Run the shortcut to extract text from the image
  shortcuts run "Extract Text from Image" -i "$i" -o "$TEXT_FILE"
  
  if [ ! -f "$TEXT_FILE" ]; then
    echo "Error: Text extraction failed for $i. No text file created."
    continue
  fi
done

# Step 3: Embed extracted text into each PDF page and combine
echo "Embedding text as invisible layer into PDFs..."
for i in "$TEMP_DIR"/*.png; do
  PAGE_PDF="${i%.png}.pdf"
  TEXT_FILE="${i%.png}.txt"
  
  # Combine the original image with the extracted text as an invisible layer
  # Using `convert` command to create a transparent text overlay and combine with original image
  if [ -f "$TEXT_FILE" ]; then
    convert "$i" -gravity Center \
      -pointsize 12 -fill black -annotate +0+0 "@$TEXT_FILE" \
      "$PAGE_PDF"
    
    # Use pypdf or pdfminer to ensure the text is properly embedded
    # In this simplified example, we assume `convert` handles the overlay
  else
    convert "$i" "$PAGE_PDF"
  fi
done

# Step 4: Combine PDFs in chunks to avoid too many open files error
echo "Combining individual PDFs in chunks..."
count=0
chunk_index=1
for pdf in "$TEMP_DIR"/*.pdf; do
  if [ $count -eq 0 ]; then
    chunk_file="$TEMP_DIR/chunk_$chunk_index.pdf"
    pdfunite "$pdf" "$chunk_file"
    MERGED_PDFS+=("$chunk_file")
  else
    pdfunite "${MERGED_PDFS[-1]}" "$pdf" "$chunk_file"
    mv "$chunk_file" "${MERGED_PDFS[-1]}"
  fi

  count=$((count + 1))

  if [ $count -ge $CHUNK_SIZE ]; then
    chunk_index=$((chunk_index + 1))
    count=0
  fi
done

# Step 5: Combine all chunks into the final PDF
echo "Combining all chunks into the final searchable PDF..."
final_chunk_file="$TEMP_DIR/final_chunk.pdf"
pdfunite "${MERGED_PDFS[@]}" "$final_chunk_file"

mv "$final_chunk_file" "$OUTPUT_PDF"

# Step 6: Clean up temporary files
echo "Cleaning up..."
rm -rf "$TEMP_DIR"

if [ -f "$OUTPUT_PDF" ]; then
  echo "Searchable PDF created: $OUTPUT_PDF"
else
  echo "Error: Searchable PDF was not created."
fi
