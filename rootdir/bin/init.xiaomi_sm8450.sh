#!/vendor/bin/sh
#
# Copyright (C) 2024 Paranoid Android
# SPDX-License-Identifier: Apache-2.0
#

function write_irq_affinity() {
    # Arguments:
    # $1 = irq name
    # $2 = cpu id
    irq_dir="$(dirname /proc/irq/*/$1)"
    [ -d "$irq_dir" ] && echo $2 > "${irq_dir}/smp_affinity_list"
}

# IRQ Tuning for Butter Smooth UI on SM8450
# Move heavy GPU and Display interrupts to the A710 cluster (CPUs 4-6)
# to prevent bottlenecks on weak A510 little cores.
write_irq_affinity kgsl_3d0_irq 4-6
write_irq_affinity msm_drm 4-6
