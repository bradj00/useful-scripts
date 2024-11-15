#!/bin/bash

################################################################################################
# Disclaimer:
# This script is provided "as is" without any warranties or guarantees. 
# I am not responsible for any data loss, damage to your system, or unexpected behavior 
# that may occur as a result of running this script. 
# Use this script entirely at your own risk.
#
#
# I just thought it was neat and useful.
#
#
# Before running the script, ensure you have:
#   - Full and verified backups of your data.
#   - Verified your system requirements and configurations.
#   - Thoroughly tested the script in a safe, non-production environment.
#
# By proceeding, you accept full responsibility for any outcomes.
# Always exercise caution when modifying disk partitions, LVM, or filesystems!
################################################################################################



# Helper functions for coloring the prompts
color_green() { echo -e "\033[0;32m$1\033[0m"; }
color_yellow() { echo -e "\033[0;33m$1\033[0m"; }
color_red() { echo -e "\033[0;31m$1\033[0m"; }

# Function to print a title for readability
print_title() {
    echo "====================================================="
    echo "$1"
    echo "====================================================="
}

# Set the absolute paths for the reboot flag and partition storage
REBOOT_NEEDED_FLAG="/working/scripts/tmp/resize_lvm_reboot_required"  # The flag for reboot detection
PARTITION_FILE="/working/scripts/tmp/selected_partition"  # Location to store user's partition selection for the PV

WORKING_DIR="/working/scripts"

echo -e "\n\tChecking the working directory: $(pwd)"
echo -e "\tReboot Flag Location: $REBOOT_NEEDED_FLAG"
echo -e "\tPartition File Location: $PARTITION_FILE\n"

# Ensure the WORKING_DIR exists
if [ ! -d "$WORKING_DIR/tmp" ]; then
    color_green "\tCreating /working/scripts/tmp directory"
    mkdir -p "$WORKING_DIR/tmp"
fi

# Ensure the script is run with sudo
if [ "$EUID" -ne 0 ]; then
    color_red "Please run this script as root or via sudo"
    exit 1
fi

####################################
#### SKIPPING TO POST-REBOOT MODE ###
####################################
if [ -f "$REBOOT_NEEDED_FLAG" ]; then
    color_green "\tReboot flag file exists: $REBOOT_NEEDED_FLAG"
    echo -e "\tFile details:"
    ls -l "$REBOOT_NEEDED_FLAG"
    echo -e "\tFile content (if any):"
    cat "$REBOOT_NEEDED_FLAG"

    # Retrieve the physical volume from the saved file
    if [ -f "$PARTITION_FILE" ]; then
        PARTITION=$(cat "$PARTITION_FILE")
        color_green "\tRecovered physical volume from file: $PARTITION"
    else
        color_red "\tError: No partition file found, cannot proceed!"
        exit 1
    fi

    ####### POST-REBOOT OPERATIONS START HERE #######
    
    # Step 2: Resize the Physical Volume (PV)
    print_title "Step 2: Resize Physical Volume (PV)"
    
    echo -e "\tResizing physical volume associated with $PARTITION"
    sudo pvresize "$PARTITION"
    
    if [ $? -ne 0 ]; then
        color_red "\tFailed to resize the physical volume. Exiting."
        exit 1
    else
        color_green "\tPhysical volume resized successfully."
    fi
    
    # Step 3: Extend Logical Volume (LV)
    print_title "Step 3: Extend Logical Volume (LV)"
    
    LV_PATH=$(sudo lvdisplay | grep "LV Path" | awk '{print $3}')
    if [ -z "$LV_PATH" ]; then
        color_red "\tLogical Volume not found!"
        exit 1
    fi
    
    color_green "\tFound Logical Volume: ${LV_PATH}"
    
    read -p "$(color_yellow '\tDo you want to extend the logical volume to use all available free space? (y/n): ')" confirm_lvextend
    
    if [[ "$confirm_lvextend" == "y" || "$confirm_lvextend" == "Y" ]]; then
        sudo lvextend -l +100%FREE "$LV_PATH"
        if [ $? -ne 0 ]; then
            color_red "\tFailed to extend the logical volume. Exiting."
            exit 1
        fi
        color_green "\tLogical volume extended successfully."
    else
        color_yellow "\tSkipping logical volume extension."
    fi
    
    # Step 4: Resize the filesystem
    print_title "Step 4: Resize the Filesystem"
    
    color_green "\tNow we will resize the filesystem to occupy the newly extended logical volume."
    
    read -p "$(color_yellow '\tDo you want to resize the filesystem? (y/n): ')" confirm_resizefs
    
    if [[ "$confirm_resizefs" == "y" || "$confirm_resizefs" == "Y" ]]; then
        sudo resize2fs "$LV_PATH"
        if [ $? -ne 0 ]; then
            color_red "\tFailed to resize the filesystem. Exiting."
            exit 1
        fi
        color_green "\tFilesystem resized successfully."
    else
        color_yellow "\tSkipping filesystem resizing."
    fi

    # Step 5: Final Check
    print_title "Step 5: Final Disk Space Check"
    echo -e "\tHere is the current disk usage:"
    df -h

    print_title "Script Cleanup"
    # Step 6: Cleanup TMP flag
    color_green "\tCleaning up the reboot flag and partition file."

    # Cleaning up the reboot flag and partition file after successful script completion
    rm -f "$REBOOT_NEEDED_FLAG"
    rm -f "$PARTITION_FILE"

    color_green "\tAll steps completed successfully!"
    exit 0
fi

#########################################
#### If No Reboot Flag, Start Fresh #####
#########################################

# Function to get user-selected physical volume (PV)
get_physical_partition_selection() {
    color_yellow "\tAvailable physical volumes (PV):"
    
    # List only physical volumes (`pvs`)
    sudo pvs --noheading --separator "," | awk '{print $1" ("$2")"}'

    echo
    color_yellow "\tPlease enter the full physical volume path (e.g., /dev/sda3): "
    read -p "$(echo -e '\t > ')" selected_partition
    
    # Check if the input is a valid block device (physical volume)
    if [[ -b "$selected_partition" || -e "$selected_partition" ]]; then
        PARTITION="$selected_partition"  # Set the valid physical volume (PV)

        # Save the partition to file for reboot recovery
        echo "$PARTITION" > "$PARTITION_FILE"
        color_green "\tPhysical volume saved to file: $PARTITION_FILE"

    else
        color_red "\tInvalid partition. Please try again."
        get_physical_partition_selection  # Recursive call to retry input
    fi
}

# Select the physical volume (PV), **not** the logical volume (LV)
get_physical_partition_selection

DEVICE="${PARTITION%[0-9]}"  # For block devices, strip any partition number to get the base device (e.g., /dev/sda)
color_green "\tTarget Physical Volume: $PARTITION"

# Introduction
print_title "LVM Partition Extension Wizard"

# Allow user to confirm the script
read -p "$(color_yellow '\tDo you want to continue? (y/n): ')" confirm_start

if [[ "$confirm_start" != "y" && "$confirm_start" != "Y" ]]; then
    color_red "\tExiting. No changes made."
    exit 0
fi

# Step 1: Resize partition (only if not resumed after reboot)
print_title "Step 1: Resize Partition"

if [[ "$PARTITION" =~ "mapper" ]]; then
    color_yellow "\tSkipping partition resize as this is an LVM logical volume."
else
    # Check if partition is already expanded
    CURRENT_END_SECTOR=$(sudo fdisk -l "$DEVICE" | grep "^$PARTITION" | awk '{print $3}')
    EXPECTED_END_SECTOR=$(sudo fdisk -l "$DEVICE" | grep "^Disk $DEVICE" | awk '{print $7}')

    if [[ "$CURRENT_END_SECTOR" -eq "$EXPECTED_END_SECTOR" ]]; then
        color_green "\tPartition $PARTITION is already resized to the full disk size. No action needed."
    else
        echo -e "\tCurrent Partition End: $CURRENT_END_SECTOR"
        echo -e "\tDisk End Sector: $EXPECTED_END_SECTOR"
        echo -e "\tWe will resize the partition to use available space now."

        read -p "$(color_yellow '\tDo you want to resize the partition now using fdisk? (y/n): ')" confirm_fdisk

        if [[ "$confirm_fdisk" == "y" || "$confirm_fdisk" == "Y" ]]; then
            sudo fdisk "$DEVICE" <<EOF
d
3
n
3
4198400

w
EOF

            if [ $? -ne 0 ]; then
                color_red "\tPartition resizing failed. Exiting."
                exit 1
            fi

            color_green "\tPartition resized successfully."

            # Set the flag for requiring reboot
            color_yellow "\tIt is recommended to reboot for the changes to take effect. Creating flag: $REBOOT_NEEDED_FLAG"
            touch "$REBOOT_NEEDED_FLAG"

            # Confirm successful creation and permissions
            if [ -f "$REBOOT_NEEDED_FLAG" ]; then
                color_green "\tFlag file created successfully."
                ls -l "$REBOOT_NEEDED_FLAG"
            else
                color_red "\tError: Flag file could not be created!"
            fi

            read -p "$(color_yellow '\tReboot now? (y/n): ')" confirm_reboot
            if [[ "$confirm_reboot" == "y" || "$confirm_reboot" == "Y" ]]; then
                color_green "\tRebooting..."
                sudo reboot
            else
                color_yellow "\tPlease reboot manually before continuing."
                exit 0
            fi
        else
            color_yellow "\tSkipping partition resize step."
        fi
    fi
fi