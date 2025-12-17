#!/bin/ksh

###############################################################################
# Rename Shared Disks Across Nodes
# Usage: rename_disk.sh <shared_disk_tag> <node1_lsmpio_output_file>
###############################################################################

# --- Ensure script is running on AIX ---
OSNAME=$(uname -s)
if [ "$OSNAME" != "AIX" ]; then
    echo "Error: This script is designed for AIX only. Detected OS: $OSNAME"
    exit 1
fi

# --- Argument Validation ---
if [ $# -ne 2 ]; then
  echo "Usage: $0 <shared_disk_tag> <node1_lsmpio_output_file>"
  echo "Example: $0 asm /tmp/node1_lsmpio.out"
  exit 1
fi

TAG="$1"
FILE1="$2"

if [ ! -f "$FILE1" ]; then
    echo "Error: Node1 lsmpio output file $FILE1 not found."
    exit 1
fi

echo "Node1 disk & volume names:"
cat "$FILE1"
echo ""

# --- Node 2 Data Collection ---
FILE2="/tmp/node2_lsmpio.out"
lsmpio -q > "$FILE2"

# --- Output files for filtered content ---
DATA1VOL="/tmp/node1_data.out"
DATA2VOL="/tmp/node2_data.out"

grep "$TAG" "$FILE1" > "$DATA1VOL"
grep "$TAG" "$FILE2" > "$DATA2VOL"

# --- Sanity Check ---
if [ ! -s "$DATA1VOL" ]; then
    echo "No disks with tag '$TAG' found in Node1 file."
    exit 1
fi

if [ ! -s "$DATA2VOL" ]; then
    echo "No disks with tag '$TAG' found in Node2 output."
    exit 1
fi

echo "Setting temporary names for Node2 disks..."
while read line; do
    disk=$(echo "$line" | awk '{print $1}')
    temp_name="${disk}temp"

    echo "Renaming $disk → $temp_name"
    /usr/sbin/rendev -l "$disk" -n "$temp_name"
done < "$DATA2VOL"

echo "\nTemporary names assigned:"
lsmpio -q

echo "\nMapping Node2 names to Node1 original names..."
while read line1; do
    src_disk=$(echo "$line1" | awk '{print $1}')
    volume_name=$(echo "$line1" | awk '{print $NF}')

    tgt_vol=$(grep "$volume_name" "$DATA2VOL")

    if [ -n "$tgt_vol" ]; then
        tgt_disk=$(echo "$tgt_vol" | awk '{print $1}')
        tgt_temp_disk="${tgt_disk}temp"

        echo "Renaming $tgt_temp_disk → $src_disk"
        /usr/sbin/rendev -l "$tgt_temp_disk" -n "$src_disk"
    else
        echo "Warning: Volume $volume_name not found on Node2"
    fi

done < "$DATA1VOL"

echo "\nFinal disk list:"
lsmpio -q

exit 0
