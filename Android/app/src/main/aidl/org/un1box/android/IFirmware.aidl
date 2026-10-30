package org.un1box.android;
import android.os.Bundle;
interface IFirmware {
    Bundle start(String firmwareId, String ipswPath, String trustedToolsRoot, String bootromPath, boolean jailbreak);
    Bundle status();
    void cancel();
    void finish();
    boolean supports(String firmwareId);
}
