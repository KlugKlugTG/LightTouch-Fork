package org.lighttouch.android;
import android.os.Bundle;
interface IFirmware {
    // jailbreak: prepare it jailbroken (afc2, Cydia and Substrate), its bootstrap already in CydiaBootstrap.directory
    Bundle start(String firmwareId, String ipswPath, String trustedToolsRoot, String bootromPath, boolean jailbreak);
    // An existing, stopped device in the library gains Cydia in place (firmwarekit edit --action jailbreak): the
    // same edits a jailbroken preparation makes, so its apps and data stay. Its bootstrap comes from
    // CydiaBootstrap.directory, and status() reports this run.
    Bundle jailbreak(String devicePath);
    Bundle status();
    void cancel();
    void finish();
    boolean supports(String firmwareId);
}
