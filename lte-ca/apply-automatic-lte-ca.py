#!/usr/bin/env python3
"""Restore network-reported LTE carrier aggregation on MistOS 17.

Run once after repo sync, before building:
    python3 device/xiaomi/sm8450-common/lte-ca/apply-automatic-lte-ca.py

The patch is variant-independent and applies to user builds. It deliberately
does not change modem firmware, NV, RIL properties, or SELinux.
"""
from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path.cwd()
BASE = ROOT / "frameworks/base/telephony/java/android/telephony/ServiceState.java"
TRACKER = ROOT / "frameworks/opt/telephony/src/java/com/android/internal/telephony/ServiceStateTracker.java"
SETTINGS = ROOT / "packages/apps/Settings/res/xml/mobile_network_settings.xml"
MARKER = "updateLteCaFromPhysicalChannelConfigs"


def replace_once(text: str, old: str, new: str, name: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{name}: expected one source anchor, found {count}; no files changed")
    return text.replace(old, new, 1)


def patch_service_state(src: str) -> str:
    signature = "    public boolean isUsingCarrierAggregation() {"
    at = src.find(signature)
    if at == -1:
        raise RuntimeError("ServiceState: isUsingCarrierAggregation() not found")
    end = src.find("\n    }", at)
    if end == -1:
        raise RuntimeError("ServiceState: method end not found")
    end += len("\n    }")
    old = src[at:end]
    if "// mondrian: report network CA, never force the status icon" in old:
        return src
    if "mForceLteCA" not in old or "getCellBandwidths().length > 1" not in old:
        raise RuntimeError("ServiceState: unexpected implementation; no files changed")
    new = """    public boolean isUsingCarrierAggregation() {
        // mondrian: report network CA, never force the status icon.
        // RatRatcheter can retain previously reported bandwidths after the
        // secondary cell is released. A bandwidth array is not proof of CA.
        NetworkRegistrationInfo nri = getNetworkRegistrationInfo(
                NetworkRegistrationInfo.DOMAIN_PS,
                AccessNetworkConstants.TRANSPORT_TYPE_WWAN);
        return nri != null && nri.isUsingCarrierAggregation();
    }"""
    return src[:at] + new + src[end:]


HELPER = """    /**
     * Synchronize LTE CA with the modem's current physical channel report.
     * A secondary LTE serving cell is evidence of active CA; retained bandwidths
     * and user-facing force-LTE-CA settings are not.
     * An empty, non-null report clears a previously active aggregation state.
     */
    private static boolean updateLteCaFromPhysicalChannelConfigs(
            List<PhysicalChannelConfig> configs, ServiceState state) {
        if (configs == null || state == null) return false;

        NetworkRegistrationInfo nri = state.getNetworkRegistrationInfo(
                NetworkRegistrationInfo.DOMAIN_PS,
                AccessNetworkConstants.TRANSPORT_TYPE_WWAN);
        if (nri == null
                || nri.getAccessNetworkTechnology() != TelephonyManager.NETWORK_TYPE_LTE) {
            return false;
        }

        boolean primaryLte = false;
        boolean secondaryLte = false;
        for (PhysicalChannelConfig config : configs) {
            if (config.getNetworkType() != TelephonyManager.NETWORK_TYPE_LTE) continue;
            if (config.getConnectionStatus()
                    == PhysicalChannelConfig.CONNECTION_PRIMARY_SERVING) {
                primaryLte = true;
            } else if (config.getConnectionStatus()
                    == PhysicalChannelConfig.CONNECTION_SECONDARY_SERVING) {
                secondaryLte = true;
            }
        }

        // No usable primary cell in a non-empty report: do not guess.
        if (!configs.isEmpty() && !primaryLte) return false;
        boolean activeCa = primaryLte && secondaryLte;
        if (nri.isUsingCarrierAggregation() == activeCa) return false;

        nri.setIsUsingCarrierAggregation(activeCa);
        state.addNetworkRegistrationInfo(nri);
        return true;
    }

"""


def patch_tracker(src: str) -> str:
    if "private static boolean " + MARKER not in src:
        src = replace_once(
            src,
            "    private static int[] getBandwidthsFromConfigs(",
            HELPER + "    private static int[] getBandwidthsFromConfigs(",
            "ServiceStateTracker helper",
        )
    if "boolean hasChanged = " + MARKER + "(list, mSS);" not in src:
        src = replace_once(
            src,
            "                    mLastPhysicalChannelConfigList = list;\n"
            "                    boolean hasChanged = false;",
            "                    mLastPhysicalChannelConfigList = list;\n"
            "                    boolean hasChanged = "
            + MARKER + "(list, mSS);",
            "ServiceStateTracker PCC event",
        )
    if MARKER + "(mLastPhysicalChannelConfigList, mNewSS);" not in src:
        src = replace_once(
            src,
            "        setPhyCellInfoFromCellIdentity(mNewSS, networkRegState.getCellIdentity());",
            "        setPhyCellInfoFromCellIdentity(mNewSS, networkRegState.getCellIdentity());\n"
            "        " + MARKER + "(mLastPhysicalChannelConfigList, mNewSS);",
            "ServiceStateTracker poll",
        )
    return src


def patch_settings_xml(src: str) -> str:
    if 'android:key="force_lte_ca"' not in src:
        return src
    pattern = (
        r"\n\s*<SwitchPreferenceCompat\s+"
        r'android:key="force_lte_ca"\s+'
        r'android:title="@string/force_lte_ca_title"\s+'
        r'android:summary="@string/force_lte_ca_summary"\s*/>'
    )
    result, count = re.subn(pattern, "", src)
    if count != 1:
        raise RuntimeError("Settings: unexpected force-LTE-CA preference; no files changed")
    return result


def main() -> int:
    targets = [
        (BASE, patch_service_state),
        (TRACKER, patch_tracker),
        (SETTINGS, patch_settings_xml),
    ]
    try:
        edits = []
        for path, patch in targets:
            original = path.read_text(encoding="utf-8")
            modified = patch(original)
            edits.append((path, original, modified))
        for path, original, modified in edits:
            if original != modified:
                path.write_text(modified, encoding="utf-8")
                print(f"patched: {path.relative_to(ROOT)}")
            else:
                print(f"already applied: {path.relative_to(ROOT)}")
    except (OSError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print("Automatic LTE CA framework patch applied; works in user builds.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
