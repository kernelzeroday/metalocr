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
if [ $? -ne 0 ]; then
  echo "Error: PDF to PNG conversion failed."
  exit 1
fi

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

# Step 3: Overlay the extracted text back onto the PNG files
echo "Overlaying text onto images..."
for i in *.png; do
  TEXT_FILE="${i%.png}.txt"
  
  if [ -f "$TEXT_FILE" ]; then
    # Create a caption image and overlay it on the original image
    CAPTION_IMAGE="${i%.png}_caption.png"
    magick -background white -fill black -gravity North -size $(identify -format "%wx%h" "$i") caption:@"$TEXT_FILE" "$CAPTION_IMAGE"
    
    if [ -f "$CAPTION_IMAGE" ]; then
      magick "$i" "$CAPTION_IMAGE" -gravity north -composite "$i"
      if [ $? -ne 0 ]; then
        echo "Error: Overlaying text on $i failed."
      fi
      rm "$CAPTION_IMAGE"
    else
      echo "Error: Caption creation failed for $i."
    fi
  else
    echo "Warning: Text file $TEXT_FILE does not exist. Skipping text overlay for $i."
  fi
done

# Step 4: Combine images back into a PDF
echo "Combining images into a PDF..."
magick convert "$TEMP_DIR/page-*.png" "$OUTPUT_PDF"
if [ $? -ne 0 ]; then
  echo "Error: Combining PNGs into a PDF failed."
  exit 1
fi

# Step 5: Clean up temporary files
echo "Cleaning up..."
rm -rf "$TEMP_DIR"

if [ -f "$OUTPUT_PDF" ]; then
  echo "Searchable PDF created: $OUTPUT_PDF"
else
  echo "Error: Searchable PDF was not created."
fi
