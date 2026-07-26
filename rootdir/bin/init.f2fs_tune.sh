#!/vendor/bin/sh

# F2FS SYSFS Tuning for UFS 3.1
# Dynamically iterates over mounted F2FS filesystems to avoid hardcoded block device names
for F2FS_SYSFS in /sys/fs/f2fs/*; do
    if [ -f "$F2FS_SYSFS/gc_idle" ]; then
        # Enable asynchronous background Garbage Collection during deep idle
        echo 1 > "$F2FS_SYSFS/gc_idle"

        # Balance GC sleep times to optimize power consumption vs cleanup speed
        echo 500 > "$F2FS_SYSFS/gc_idle_sleep_time"
        echo 500 > "$F2FS_SYSFS/gc_urgent_sleep_time"

        # Configure asynchronous discard (TRIM) to optimize block reuse for UFS controllers
        echo 16 > "$F2FS_SYSFS/discard_granularity"
        echo 50 > "$F2FS_SYSFS/idle_time_discard"

        # Disable heavy I/O statistics tracking to reduce CPU overhead
        if [ -f "$F2FS_SYSFS/iostat_enable" ]; then
            echo 0 > "$F2FS_SYSFS/iostat_enable"
        fi
    fi
done
