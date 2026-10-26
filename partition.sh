#!/bin/bash

DISK="/dev/block/mmcblk0"

# Get GPT partition number by exact partition name using sgdisk
get_part_num()
{
    local part_name="$1"
    sgdisk --print "$DISK" | busybox awk -v name="$part_name" '$1 ~ /^[0-9]+$/ && $7 == name {print $1; exit}'
}

# Wait for /dev/block/mmcblk0p<N> device node (create via mknod if ueventd lags)
wait_for_part_node()
{
    local part_num="$1"
    local part_node="${DISK}p${part_num}"
    local sys_dev="/sys/class/block/mmcblk0/mmcblk0p${part_num}/dev"
    local retries=10

    while [ ! -b "$part_node" ] && [ $retries -gt 0 ]; do
        blockdev --rereadpt "$DISK" 2>/dev/null || true
        if [ -f "$sys_dev" ] && [ ! -b "$part_node" ]; then
            local maj_min
            maj_min=$(cat "$sys_dev")
            mknod "$part_node" b "${maj_min%:*}" "${maj_min#*:}" 2>/dev/null || true
        fi
        [ -b "$part_node" ] && break
        sleep 1
        retries=$((retries - 1))
    done

    [ -b "$part_node" ]
}

# Unmount any mounted partitions on mmcblk0 so kernel can re-read GPT table
unmount_all_mmcblk0()
{
    swapoff -a 2>/dev/null || true
    for mp in $(busybox awk '$1 ~ /^\/dev\/block\/mmcblk0p/ {print $2}' /proc/mounts | busybox sort -r); do
        busybox umount "$mp" 2>/dev/null || busybox umount -l "$mp" 2>/dev/null || true
    done
}

#backup partitions and GPT partition table
dump_provisioned()
{
    declare -a backupPartitions=("APDP" "DBI" "DDR" "DPO" "DPP" "LIMITS" "MODEM_FS1" "MODEM_FS2" 
                                "MODEM_FSC" "MODEM_FSG" "MSADP" "SEC" "SSD" "UEFI_BS_NV" "UEFI_RT_NV")
    
    mkdir -p /backup

    echo "Backing up GPT partition table..."
    sgdisk --backup=/backup/gpt_backup.bin "$DISK"
    sgdisk --print "$DISK" > /backup/partition_table.txt

    echo "Dumping provisioned partitions"
    for i in "${backupPartitions[@]}"
    do
        part_num=$(get_part_num "$i")
        if [ -n "$part_num" ] && [ -b "${DISK}p${part_num}" ]; then
            echo "Dumping $i (mmcblk0p${part_num})..."
            dd if="${DISK}p${part_num}" of="/backup/$i.bin"
        else
            echo "Skipping $i (partition not found on this device)"
        fi
    done
    sync
}
#########################################################
############# detect mainOS and data #####################
##########################################################
detect_partitions()
{
    MMOS=$(get_part_num "MMOS")
    echo "MMOS partition is GPT nr. $MMOS"
    MAINOS=$(get_part_num "MainOS")
    echo "MainOS partition is GPT nr. $MAINOS"
    DATA=$(get_part_num "Data")
    echo "Data partition is GPT nr. $DATA"

    if [ -z "$DATA" ]; then
        while true; do
            read -p "Data partition not found, proceed? " yn || exit 1
            case $yn in
                [Yy]* ) nodata=1; break;;
                [Nn]* ) exit 1;;
                * ) echo "Please answer yes or no.";;
            esac
        done
    fi

    if [ -z "$MAINOS" ]; then
        while true; do
            read -p "MainOS partition not found, proceed? " yn || exit 1
            case $yn in
                [Yy]* ) nomainos=1; break;;
                [Nn]* ) exit 1;;
                * ) echo "Please answer yes or no.";;
            esac
        done
    fi

    if [ -z "$MMOS" ]; then
        while true; do
            read -p "MMOS partition not found, proceed? " yn || exit 1
            case $yn in
                [Yy]* ) nommos=1; break;;
                [Nn]* ) exit 1;;
                * ) echo "Please answer yes or no.";;
            esac
        done
    fi
}
#########################################################
######## erase partitions and create Android ones #######
#########################################################
partition()
{ 
    unmount_all_mmcblk0

    declare -a sgdisk_args=()

    if [ -n "$nodata" ]; then
        echo "Will not delete Data"
    else
        echo "Deleting Data (partition $DATA)..."
        sgdisk_args+=("--delete=${DATA}")
    fi

    if [ -n "$nomainos" ]; then
        echo "Will not delete MainOS"
    else
        echo "Deleting MainOS (partition $MAINOS)..."
        sgdisk_args+=("--delete=${MAINOS}")
    fi

    if [ -n "$nommos" ]; then
        echo "Will not delete MMOS"
    else
        echo "Deleting MMOS (partition $MMOS)..."
        sgdisk_args+=("--delete=${MMOS}")
    fi

    echo "Creating Android partitions"
    declare -a androidPartitions=("aboot"      "1MiB"     "fat16"
                                  "boot"       "34MiB"    "ext4"
                                  "recovery"   "34MiB"    "ext4"
                                  "misc"       "16MiB"    "ext4"
                                  "modem"      "70MiB"    "fat16"
                                  "cache"      "150MiB"   "ext4"
                                  "persist"    "68MiB"    "ext4"
                                  "persistent" "68MiB"    "ext4"
                                  "fsc"        "1MiB"     "ext4"
                                  "fsg"        "2MiB"     "ext4"
                                  "metadata"   "2MiB"     "ext4"
                                  "ssd"        "2MiB"     "ext4"
                                  "modemst1"   "2MiB"     "ext4"
                                  "modemst2"   "2MiB"     "ext4"
                                  "vendor"     "260MiB"   "ext4"
                                  "system"     "3072MiB"  "ext4"
                                  "userdata"   "100%"     "ext4");

    for ((i=0; i<${#androidPartitions[@]}; i+=3)); do
        part_name="${androidPartitions[i]}"
        part_size="${androidPartitions[i+1]}"
        part_fs="${androidPartitions[i+2]}"

        if [ "$part_size" != "100%" ]; then
            # Convert e.g. "34MiB" -> "+34M" for sgdisk -n
            end_spec="+${part_size%iB}"
        else
            # 0 means fill up to the end of the largest available free block
            end_spec="0"
        fi

        if [[ "$part_fs" == "fat16" ]]; then
            type_code="0700"
        else
            type_code="8300"
        fi

        echo "Queueing partition: $part_name (Size: $part_size, FS: $part_fs, Type: $type_code)"
        sgdisk_args+=("--new=0:0:${end_spec}" "--change-name=0:${part_name}" "--typecode=0:${type_code}")
    done

    echo "Writing new GPT partition table..."
    if ! sgdisk "${sgdisk_args[@]}" "$DISK"; then
        echo "Error: sgdisk failed to write partition table!"
        exit 1
    fi

    echo "Verifying GPT partition table..."
    sgdisk --verify "$DISK"

    sync
    blockdev --rereadpt "$DISK" 2>/dev/null || true
    sleep 1

    ###format partitions###
    for ((i=0; i<${#androidPartitions[@]}; i+=3)); do
        part_name="${androidPartitions[i]}"
        part_fs="${androidPartitions[i+2]}"

        newpart=$(get_part_num "$part_name")
        if [ -z "$newpart" ] || ! wait_for_part_node "$newpart"; then
            echo "Error: Could not find device node for newly created partition $part_name"
            exit 1
        fi

        echo "Formatting $part_name (${DISK}p${newpart}) as $part_fs..."
        if [[ "$part_fs" == "fat16" ]]; then
            mkfs.fat "${DISK}p${newpart}"
        elif [[ "$part_fs" == "ext4" ]]; then
            mke2fs -F -t ext4 "${DISK}p${newpart}"
        fi
    done

    # Initialize /data/media/0 on userdata so TWRP MTP recognizes internal storage without manual Format Data
    userdata_num=$(get_part_num "userdata")
    if [ -n "$userdata_num" ] && [ -b "${DISK}p${userdata_num}" ]; then
        mkdir -p /data
        if busybox mount "${DISK}p${userdata_num}" /data; then
            mkdir -p /data/media/0
            chmod 0770 /data/media /data/media/0 2>/dev/null || true
            busybox umount /data
        fi
    fi

    # Ensure /dev/block/bootdevice symlink exists in TWRP for ROM updater-scripts
    if [ -d /dev/block/platform/msm_sdcc.1 ] && [ ! -e /dev/block/bootdevice ]; then
        ln -sf /dev/block/platform/msm_sdcc.1 /dev/block/bootdevice
    fi

    sync
}
#################
use_aboot()
{
    efiesp=$(get_part_num "EFIESP")
    aboot=$(get_part_num "aboot")

    if [ -z "$efiesp" ] || [ -z "$aboot" ]; then
        echo "Error: EFIESP or aboot partition not found!"
        exit 1
    fi

    mkdir -p /efiesp
    mkdir -p /aboot
    busybox mount "${DISK}p${efiesp}" /efiesp/
    busybox mount "${DISK}p${aboot}" /aboot/
    if [ -f /efiesp/emmc_appsboot.mbn ]; then
        if cp /efiesp/emmc_appsboot.mbn /aboot/emmc_appsboot.mbn && [ -s /aboot/emmc_appsboot.mbn ]; then
            rm /efiesp/emmc_appsboot.mbn
        else
            echo "Error: Failed to copy emmc_appsboot.mbn to aboot!"
            busybox umount /efiesp/ 2>/dev/null || true
            busybox umount /aboot/ 2>/dev/null || true
            exit 1
        fi
    else
        echo "Warning: /efiesp/emmc_appsboot.mbn not found (may have already been moved)"
    fi
    sync
    busybox umount /efiesp/
    busybox umount /aboot/
}
##############################

detect_partitions
dump_provisioned
partition
use_aboot

