import Foundation

extension SystemEdits {
    // launchd invokes one root worker for a nonempty queue. Requests contain only a validated basename;
    // package maintainer scripts execute through dpkg, with its ordinary dependency/conflict checks.
    static let debInstallerScript = #"""
    #!/bin/bash
    export PATH=/usr/bin:/bin:/usr/sbin:/sbin
    base=/var/root/Media/Un1box
    mkdir -p "$base/InstallQueue" "$base/Results"
    shopt -s nullglob
    for request in "$base"/InstallQueue/*.request; do
        token=${request##*/}; token=${token%.request}
        [[ "$token" =~ ^[a-f0-9]{32}$ ]] || { rm -f "$request"; continue; }
        result="$base/Results/$token"
        IFS= read -r name < "$request"
        if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,123}\.deb$ ]]; then
            printf 'Invalid package filename\n' > "$result.log"
            printf 'failed:64\n' > "$result.status.tmp"
        else
            printf 'running\n' > "$result.status"
            # Cydia's first-boot startup may still hold dpkg's lock. Retry only that diagnostic.
            code=1
            for attempt in {1..60}; do
                DEBIAN_FRONTEND=noninteractive dpkg --force-confold -i "/var/mobile/Media/Un1box/Packages/$name" > "$result.log" 2>&1
                code=$?
                [[ $code -eq 0 ]] && break
                grep -Eiq 'status database.*locked|unable to lock|lock.*held|another process.*dpkg' "$result.log" || break
                sleep 2
            done
            if [[ $code -eq 0 ]]; then
                if command -v sbdidlaunch >/dev/null; then sbdidlaunch >> "$result.log" 2>&1; fi
                if command -v uicache >/dev/null; then
                    su -c uicache mobile >> "$result.log" 2>&1
                    cachecode=$?
                    if [[ $cachecode -ne 0 ]]; then printf 'Icon cache refresh failed (%s)\n' "$cachecode" >> "$result.log"; fi
                fi
                printf 'installed\n' > "$result.status.tmp"
            else
                printf 'failed:%s\n' "$code" > "$result.status.tmp"
            fi
        fi
        mv -f "$result.status.tmp" "$result.status"
        rm -f "$request"
    done
    """#

    static func installDebInstaller(_ m: URL) throws -> (root: [String], modes: [(path: String, mode: UInt16)]) {
        let script = "usr/libexec/un1box-deb-install"
        let job = "System/Library/LaunchDaemons/org.un1box.deb-install.plist"
        let dirs = ["private/var/root/Media", "private/var/root/Media/Un1box",
            "private/var/root/Media/Un1box/InstallQueue", "private/var/root/Media/Un1box/Results"]
        for dir in dirs { try mkdirs(m.appendingPathComponent(dir)) }
        try mkdirs(m.appendingPathComponent(script).deletingLastPathComponent())
        try put(Data((debInstallerScript + "\n").utf8), m.appendingPathComponent(script), mode: 0o755)
        let plist: [String: Any] = ["Label": "org.un1box.deb-install", "UserName": "root",
            "ProgramArguments": ["/bin/bash", "/" + script], "RunAtLoad": true,
            "QueueDirectories": ["/var/root/Media/Un1box/InstallQueue"],
            "ThrottleInterval": 2]
        try put(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), m.appendingPathComponent(job), mode: 0o644)
        return (dirs + [script, job], [(script, 0o755), (job, 0o644)])
    }
}
