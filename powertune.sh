#!/bin/sh
# powertune - AC/battery power profiles for a ThinkPad E14 Gen 7 (AMD) on Artix (OpenRC) or Arch (systemd)
#
# Usage: powertune [-n] [COMMAND]
#   auto        apply the profile for the current power source (default)
#   bat | ac    force a profile
#   status      show what is set right now, plus live battery draw
#   full        charge to 100% this once (the charge cap returns at next boot)
#   install     copy to /usr/local/bin and add: a boot service (OpenRC or
#               systemd), a udev rule (plug/unplug) and a resume hook
#   uninstall   remove all of that and lift the charge cap
#   -n          dry run: print what would be written, change nothing
#
# Plain POSIX sh. Optional: iw (for Wi-Fi power save).
# Do not run alongside TLP, power-profiles-daemon, auto-cpufreq or tuned.

PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH

# ------------------------------------------------------------------ settings
# Edit here, or put overrides in /etc/powertune.conf (same VAR=value syntax).

# Battery longevity: charging starts below START and stops at STOP.
# 0 / 100 = no cap.
CHARGE_START=75
CHARGE_STOP=80

# CPU energy hint (amd-pstate-epp):
#   performance | balance_performance | balance_power | power
AC_EPP=balance_performance
BAT_EPP=power

# Turbo boost: 1 on, 0 off. Off saves the most under load but slows bursts.
AC_BOOST=1
BAT_BOOST=0

# ThinkPad firmware profile: low-power | balanced | performance
AC_PROFILE=balanced
BAT_PROFILE=low-power

# PCIe link power: default | powersave | powersupersave
# (use "default" on battery too if Wi-Fi or the SSD ever misbehaves)
AC_ASPM=default
BAT_ASPM=powersupersave

# Runtime power management for idle PCI/USB devices: on (never sleep) | auto
# USB input devices are never touched, so mice and keyboards do not lag, and
# neither is Bluetooth: btusb manages autosuspend for the MT7925 itself.
AC_RUNTIME_PM=on
BAT_RUNTIME_PM=auto
RUNTIME_PM_SKIP="xhci_hcd"      # PCI drivers left at the kernel default

# Radeon adaptive backlight: 0 off .. 4 strongest. Lowers the backlight and
# raises contrast to compensate; costs some colour accuracy.
AC_ABM=0
BAT_ABM=2

# Wi-Fi power save: on | off
AC_WIFI_PS=off
BAT_WIFI_PS=on

# Seconds of silence before the audio codec powers down (0 = never)
AC_AUDIO_PS=0
BAT_AUDIO_PS=1

# How often dirty pages are flushed to disk, in 1/100 s
AC_WRITEBACK=500
BAT_WRITEBACK=1500

# ------------------------------------------------------------------- helpers
SELF=/usr/local/bin/powertune
CONF=/etc/powertune.conf
FULL_FLAG=/run/powertune.full
DRY=0

# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

log() { printf 'powertune: %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
rd()  { cat "$1" 2>/dev/null; }
row() { printf '%-18s%s\n' "$1" "${2:-n/a}"; }

need_root() {
    [ "$DRY" = 1 ] || [ "$(id -u)" -eq 0 ] || die "this needs root"
}

# w VALUE FILE - write one value. A missing file is skipped (not every kernel
# or machine has every knob); returns non-zero only if the kernel refuses.
w() {
    [ -e "$2" ] || return 0
    if [ "$DRY" = 1 ]; then printf '%s <- %s\n' "$2" "$1"; return 0; fi
    [ "$(rd "$2")" = "$1" ] && return 0
    { printf '%s\n' "$1" > "$2"; } 2>/dev/null
}

# put VALUE FILE... - same for many files, with one summary line on failure
put() {
    _v=$1; shift
    _bad=0; _first=
    for _f in "$@"; do
        w "$_v" "$_f" && continue
        _bad=$((_bad + 1))
        [ -n "$_first" ] || _first=$_f
    done
    [ "$_bad" -eq 0 ] || log "kernel refused '$_v' for $_first ($_bad file(s))"
}

on_ac() {
    found=0
    for ps in /sys/class/power_supply/*; do
        [ "$(rd "$ps/type")" = Mains ] || continue
        found=1
        [ "$(rd "$ps/online")" = 1 ] && return 0
    done
    [ "$found" = 1 ] && return 1
    # no AC adapter device at all: go by what the battery says
    for b in /sys/class/power_supply/BAT*; do
        [ "$(rd "$b/status")" = Discharging ] && return 1
    done
    return 0
}

# ---------------------------------------------------------------------- knobs
set_thresholds() {  # START STOP
    for b in /sys/class/power_supply/BAT*; do
        [ -e "$b/charge_control_end_threshold" ] || continue
        # The firmware insists on start <= stop at every step, so which one
        # must go first depends on the old values. stop, start, stop covers
        # every case; the first write may be refused and that is fine.
        [ "$DRY" = 1 ] || w "$2" "$b/charge_control_end_threshold" || :
        put "$1" "$b/charge_control_start_threshold"
        put "$2" "$b/charge_control_end_threshold"
    done
}

set_profile() {  # low-power|balanced|performance
    pp=/sys/firmware/acpi/platform_profile
    case " $(rd "${pp}_choices") " in
        *" $1 "*) put "$1" "$pp" ;;
    esac
}

set_cpu() {  # EPP BOOST
    cf=/sys/devices/system/cpu/cpufreq
    drv=$(rd "$cf/policy0/scaling_driver")
    if [ "$drv" = amd-pstate-epp ]; then
        # With this driver "powersave" means "follow the EPP hint", not "pin
        # to the lowest clock". It has to be set first: EPP is locked while
        # the governor is "performance".
        put powersave "$cf"/policy*/scaling_governor
        put "$1" "$cf"/policy*/energy_performance_preference
    else
        log "CPU driver is '${drv:-none}', not amd-pstate-epp: EPP left alone (boot with amd_pstate=active)"
    fi
    if [ -e "$cf/boost" ]; then
        put "$2" "$cf/boost"
    else
        put "$2" "$cf"/policy*/boost
    fi
}

set_aspm() {  # default|powersave|powersupersave
    w "$1" /sys/module/pcie_aspm/parameters/policy ||
        log "PCIe ASPM policy is locked by the firmware; left as is"
}

set_runtime() {  # on|auto
    for d in /sys/bus/pci/devices/*; do
        drv=$(readlink "$d/driver" 2>/dev/null); drv=${drv##*/}
        if [ -n "$drv" ]; then
            case " $RUNTIME_PM_SKIP " in *" $drv "*) continue ;; esac
        fi
        put "$1" "$d/power/control"
    done
    for d in /sys/bus/usb/devices/*; do
        case $d in *:*) continue ;; esac            # interfaces, not devices
        skip=0
        for cls in "$d"/*:*/bInterfaceClass; do
            case $(rd "$cls") in
                03|e0) skip=1 ;;    # 03 = HID (mouse, keyboard), e0 = Bluetooth
            esac
        done
        [ "$skip" = 1 ] || put "$1" "$d/power/control"
    done
}

set_abm() {  # 0..4
    put "$1" /sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings
}

set_wifi() {  # on|off
    command -v iw >/dev/null 2>&1 || return 0
    for n in /sys/class/net/*/phy80211; do
        [ -e "$n" ] || continue
        n=${n%/phy80211}; n=${n##*/}
        if [ "$DRY" = 1 ]; then
            echo "iw dev $n set power_save $1"
        else
            iw dev "$n" set power_save "$1" 2>/dev/null ||
                log "could not set Wi-Fi power save $1 on $n"
        fi
    done
}

set_audio() {  # SECONDS
    put "$1" /sys/module/snd_hda_intel/parameters/power_save
}

set_writeback() {  # CENTISECONDS
    put "$1" /proc/sys/vm/dirty_writeback_centisecs
}

# ------------------------------------------------------------------- actions
apply() {  # ac|bat
    need_root
    [ -e "$FULL_FLAG" ] || set_thresholds "$CHARGE_START" "$CHARGE_STOP"
    if [ "$1" = bat ]; then
        set_profile   "$BAT_PROFILE"
        set_cpu       "$BAT_EPP" "$BAT_BOOST"
        set_aspm      "$BAT_ASPM"
        set_runtime   "$BAT_RUNTIME_PM"
        set_abm       "$BAT_ABM"
        set_wifi      "$BAT_WIFI_PS"
        set_audio     "$BAT_AUDIO_PS"
        set_writeback "$BAT_WRITEBACK"
    else
        set_profile   "$AC_PROFILE"
        set_cpu       "$AC_EPP" "$AC_BOOST"
        set_aspm      "$AC_ASPM"
        set_runtime   "$AC_RUNTIME_PM"
        set_abm       "$AC_ABM"
        set_wifi      "$AC_WIFI_PS"
        set_audio     "$AC_AUDIO_PS"
        set_writeback "$AC_WRITEBACK"
    fi
    put 0 /proc/sys/kernel/nmi_watchdog      # a debugging aid that costs wakeups
    [ "$DRY" = 1 ] || echo "powertune: $1 profile applied"
}

status() {
    cf=/sys/devices/system/cpu/cpufreq
    if on_ac; then row "power source" AC; else row "power source" battery; fi

    for b in /sys/class/power_supply/BAT*; do
        [ -d "$b" ] || continue
        uw=$(rd "$b/power_now")
        if [ -z "$uw" ]; then
            ua=$(rd "$b/current_now"); uv=$(rd "$b/voltage_now")
            [ -n "$ua" ] && [ -n "$uv" ] && uw=$((${ua#-} * uv / 1000000))
        fi
        uw=${uw#-}
        watts="? W"
        [ -n "$uw" ] && watts="$((uw / 1000000)).$((uw % 1000000 / 100000)) W"
        cap="no charge cap support"
        [ -e "$b/charge_control_end_threshold" ] &&
            cap="charges $(rd "$b/charge_control_start_threshold")-$(rd "$b/charge_control_end_threshold")%"
        row "${b##*/}" "$(rd "$b/capacity")% $(rd "$b/status"), $watts, $cap"
    done

    row "cpu driver"       "$(rd "$cf/policy0/scaling_driver")"
    row "governor / EPP"   "$(rd "$cf/policy0/scaling_governor") / $(rd "$cf/policy0/energy_performance_preference")"
    if [ -e "$cf/boost" ]; then row "boost" "$(rd "$cf/boost")"
    else row "boost" "$(rd "$cf/policy0/boost")"; fi
    row "firmware profile" "$(rd /sys/firmware/acpi/platform_profile)"

    aspm=$(rd /sys/module/pcie_aspm/parameters/policy)
    aspm=${aspm#*\[}; aspm=${aspm%%\]*}
    row "PCIe ASPM" "$aspm"

    for f in /sys/class/drm/card*-eDP-*/amdgpu/panel_power_savings; do
        [ -e "$f" ] && row "panel ABM" "$(rd "$f")"
    done

    for n in /sys/class/net/*/phy80211; do
        [ -e "$n" ] || continue
        n=${n%/phy80211}; n=${n##*/}
        if command -v iw >/dev/null 2>&1; then
            ps=$(iw dev "$n" get power_save 2>/dev/null)
            row "Wi-Fi power save" "$n ${ps##*: }"
        else
            row "Wi-Fi power save" "$n unknown (install iw)"
        fi
    done

    row "audio idle (s)"   "$(rd /sys/module/snd_hda_intel/parameters/power_save)"
    row "writeback (cs)"   "$(rd /proc/sys/vm/dirty_writeback_centisecs)"
    [ -e "$FULL_FLAG" ] && row "note" "charge cap lifted until next boot"
    return 0
}

# OpenRC (Artix) or systemd (Arch). Checked by what is running as PID 1.
init_system() {
    if [ -d /run/systemd/system ]; then echo systemd
    elif command -v openrc-run >/dev/null 2>&1; then echo openrc
    else echo unknown; fi
}

SYSTEMD_UNIT=/etc/systemd/system/powertune.service
SYSTEMD_SLEEP=/usr/lib/systemd/system-sleep/powertune
ELOGIND_SLEEP=/etc/elogind/system-sleep/powertune

# sleep hook: same calling convention for elogind and systemd-sleep
write_sleep_hook() {  # PATH
    mkdir -p "${1%/*}"
    cat > "$1" <<EOF
#!/bin/sh
# re-apply after resume in case the firmware reset anything while asleep
[ "\$1" = post ] && $SELF auto
exit 0
EOF
    chmod 755 "$1"
}

install_openrc() {
    cat > /etc/init.d/powertune <<EOF
#!/usr/bin/openrc-run
description="Apply the AC or battery power profile at boot"

depend() {
    need localmount
    after modules sysctl
}

start() {
    ebegin "Applying power profile"
    $SELF auto
    eend \$?
}
EOF
    chmod 755 /etc/init.d/powertune
    [ -d /etc/elogind ] && write_sleep_hook "$ELOGIND_SLEEP"
    rc-update add powertune default
    udevadm control --reload-rules
    rc-service powertune restart
}

install_systemd() {
    cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Apply the AC or battery power profile at boot
After=local-fs.target systemd-modules-load.service systemd-sysctl.service

[Service]
Type=oneshot
ExecStart=$SELF auto

[Install]
WantedBy=multi-user.target
EOF
    write_sleep_hook "$SYSTEMD_SLEEP"
    systemctl daemon-reload
    udevadm control --reload-rules
    systemctl enable powertune.service
    systemctl restart powertune.service
}

# is another power manager enabled? (they would overwrite each other)
other_enabled() {  # NAME
    case $(init_system) in
        openrc)  rc-update show 2>/dev/null | grep -qw -- "$1" ;;
        systemd) systemctl is-enabled "$1" >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}

install_all() {
    [ "$(id -u)" -eq 0 ] || die "install needs root"
    init=$(init_system)
    [ "$init" != unknown ] || die "neither OpenRC nor systemd found - cannot install a boot service"

    src=$(readlink -f "$0")
    if [ "$src" != "$SELF" ]; then
        install -Dm755 "$src" "$SELF" || die "could not copy to $SELF"
    fi

    cat > /etc/udev/rules.d/85-powertune.rules <<EOF
# switch power profile when the charger is plugged in or pulled
SUBSYSTEM=="power_supply", ATTR{type}=="Mains", ACTION=="change", RUN+="$SELF auto"
EOF

    "install_$init"

    for s in tlp power-profiles-daemon auto-cpufreq tuned; do
        if other_enabled "$s"; then
            log "warning: $s is enabled too. The two will overwrite each other - keep one."
        fi
    done
    command -v iw >/dev/null 2>&1 || log "note: install iw to get Wi-Fi power save"
    echo "installed ($init). Check with: powertune status"
}

uninstall_all() {
    [ "$(id -u)" -eq 0 ] || die "uninstall needs root"
    command -v rc-update >/dev/null 2>&1 && rc-update del powertune default 2>/dev/null
    if command -v systemctl >/dev/null 2>&1 && [ -e "$SYSTEMD_UNIT" ]; then
        systemctl disable powertune.service 2>/dev/null
    fi
    rm -f /etc/init.d/powertune "$SYSTEMD_UNIT" /etc/udev/rules.d/85-powertune.rules \
          "$ELOGIND_SLEEP" "$SYSTEMD_SLEEP" "$FULL_FLAG"
    [ -d /run/systemd/system ] && systemctl daemon-reload
    udevadm control --reload-rules 2>/dev/null
    # The charge cap is stored in the embedded controller and would outlive a
    # reboot, so lift it explicitly. Everything else resets on the next boot.
    set_thresholds 0 100
    rm -f "$SELF"
    echo "removed. $CONF (if any) was left in place; reboot to reset the rest."
}

# ---------------------------------------------------------------------- main
if [ "${1:-}" = -n ]; then DRY=1; shift; fi

case ${1:-auto} in
    auto)      if on_ac; then apply ac; else apply bat; fi ;;
    bat|ac)    apply "$1" ;;
    status)    status ;;
    full)
        need_root
        [ "$DRY" = 1 ] || : > "$FULL_FLAG"
        set_thresholds 0 100
        echo "charging to 100%; the ${CHARGE_STOP}% cap returns at next boot"
        ;;
    install)   install_all ;;
    uninstall) uninstall_all ;;
    *)         sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 2 ;;
esac
