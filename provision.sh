#!/bin/bash

DISK="/dev/block/mmcblk0"

get_part_num()
{
    local part_name="$1"
    sgdisk --print "$DISK" | busybox awk -v name="$part_name" '$1 ~ /^[0-9]+$/ && $7 == name {print $1; exit}'
}

detect_partitions()
{
    DPP=$(get_part_num "DPP")
    echo "DPP partition is GPT nr. $DPP"
    PERSIST=$(get_part_num "persist")
    echo "persist partition is GPT nr. $PERSIST"

    if [ -z "$DPP" ] || [ -z "$PERSIST" ]; then
        echo "Error: DPP or persist partition not found!"
        exit 1
    fi
}

mount_partitions()
{
    mkdir -p /DPP
    mkdir -p /persist
    busybox mount -o ro "${DISK}p${DPP}" /DPP/
    busybox mount "${DISK}p${PERSIST}" /persist/
}

umount_partitions()
{
    sync
    busybox umount /DPP/
    busybox umount /persist/
}

provision()
{
    extract_wlan_mac
    write_bdaddr
    provision_modem
}

copy_partition()
{
    local src_name="$1"
    local dst_name="$2"
    local src_num dst_num
    src_num=$(get_part_num "$src_name")
    dst_num=$(get_part_num "$dst_name")

    if [ -n "$src_num" ] && [ -n "$dst_num" ]; then
        echo "Provisioning $dst_name (mmcblk0p${dst_num}) from $src_name (mmcblk0p${src_num})..."
        dd if="${DISK}p${src_num}" of="${DISK}p${dst_num}"
    else
        echo "Warning: Could not find partition $src_name ($src_num) or $dst_name ($dst_num)"
    fi
}

provision_modem()
{
    copy_partition "MODEM_FS1" "modemst1"
    copy_partition "MODEM_FS2" "modemst2"
    copy_partition "MODEM_FSC" "fsc"
    copy_partition "MODEM_FSG" "fsg"
    copy_partition "SSD"       "ssd"
}

extract_wlan_mac()
{
    # Locate WLAN.PROVISION case-insensitively on FAT16 DPP partition
    local if
    if=$(busybox find /DPP -iname "WLAN.PROVISION" 2>/dev/null | busybox head -n 1)
    if [ -z "$if" ]; then
        if="/DPP/QCOM/WLAN.PROVISION"
    fi
    # Output file
    local of="/persist/wlan_mac.bin"

    if [ ! -f "$if" ]; then
        echo "Warning: $if not found, skipping WLAN MAC extraction"
        return
    fi

    # Function to extract 6 bytes and convert to uppercase
    extract_mac_address() {
        local start_byte=$1
        busybox hexdump -v -e '6/1 "%02X"' -s "$start_byte" -n 6 "$if" | busybox tr 'a-f' 'A-F'
    }

    # Extract each MAC address
    intf0_mac=$(extract_mac_address 3)
    intf1_mac=$(extract_mac_address 9)
    intf2_mac=$(extract_mac_address 15)
    intf3_mac=$(extract_mac_address 21)

    # Write the MAC addresses to the output file
    {
        echo "Intf0MacAddress=$intf0_mac"
        echo "Intf1MacAddress=$intf1_mac"
        echo "Intf2MacAddress=$intf2_mac"
        echo "Intf3MacAddress=$intf3_mac"
    } > "$of"
}

write_bdaddr()
{
    # Locate BT.PROVISION case-insensitively on FAT16 DPP partition
    local if
    if=$(busybox find /DPP -iname "BT.PROVISION" 2>/dev/null | busybox head -n 1)
    if [ -z "$if" ]; then
        if="/DPP/QCOM/BT.PROVISION"
    fi
    # Output file
    local of="/persist/bdaddr.txt"

    if [ ! -f "$if" ]; then
        echo "Warning: $if not found, skipping Bluetooth MAC extraction"
        return
    fi

    # Extract 6 bytes starting from the 3rd byte (offset 2)
    mac_address=$(busybox hexdump -v -e '6/1 "%02X"' -s 2 -n 6 "$if" | busybox tr 'a-f' 'A-F')

    # Format the extracted bytes into 00:00:00:00:00:00
    formatted_mac=$(echo "$mac_address" | busybox sed 's/\(..\)/\1:/g; s/:$//')

    # Write the formatted MAC address to the output file
    echo "$formatted_mac" > "$of"
}

detect_partitions
mount_partitions
provision
umount_partitions

# Ensure /dev/block/bootdevice symlink exists in TWRP for ROM updater-scripts
if [ -d /dev/block/platform/msm_sdcc.1 ] && [ ! -e /dev/block/bootdevice ]; then
    ln -sf /dev/block/platform/msm_sdcc.1 /dev/block/bootdevice
fi

# Ensure /data/media/0 exists and is mounted so MTP shows internal storage immediately
USERDATA=$(get_part_num "userdata")
if [ -n "$USERDATA" ] && [ -b "${DISK}p${USERDATA}" ]; then
    mkdir -p /data
    busybox mount "${DISK}p${USERDATA}" /data 2>/dev/null || true
    mkdir -p /data/media/0
fi

echo "Provisioning completed successfully."
