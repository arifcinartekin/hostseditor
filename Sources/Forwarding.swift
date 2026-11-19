import Foundation

/// Files installed under /Library for port forwarding. They live outside the app so the
/// forwards come back after a reboot even when Hosts Editor isn't running.
enum Forwarding {
    /// Run as root by the LaunchDaemon at boot and by the app after each save.
    /// Adds the 127.0.0.x aliases to lo0 and loads the pf rdr rules into the
    /// `com.apple/hostseditor` anchor, which the stock /etc/pf.conf already evaluates.
    static let applyScript = #"""
    #!/bin/sh
    # Managed by Hosts Editor.
    DIR="/Library/Application Support/HostsEditor"
    ANCHOR="com.apple/hostseditor"

    # Drop aliases that are no longer wanted.
    if [ -f "$DIR/aliases.applied" ]; then
      for ip in $(cat "$DIR/aliases.applied"); do
        grep -qx "$ip" "$DIR/aliases" 2>/dev/null || /sbin/ifconfig lo0 -alias "$ip" 2>/dev/null
      done
    fi
    for ip in $(cat "$DIR/aliases" 2>/dev/null); do
      /sbin/ifconfig lo0 alias "$ip" up
    done
    cp "$DIR/aliases" "$DIR/aliases.applied" 2>/dev/null

    if [ -s "$DIR/pf.rules" ]; then
      # Make sure the main ruleset (with its com.apple/* rdr-anchor) is loaded.
      /sbin/pfctl -sn 2>/dev/null | grep -q 'com.apple/\*' || /sbin/pfctl -q -f /etc/pf.conf 2>/dev/null
      /sbin/pfctl -q -a "$ANCHOR" -f "$DIR/pf.rules"
      /sbin/pfctl -q -e 2>/dev/null
    else
      /sbin/pfctl -q -a "$ANCHOR" -F all 2>/dev/null
    fi
    exit 0
    """#

    static let daemonPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(HostsStore.daemonLabel)</string>
        <key>ProgramArguments</key>
        <array>
            <string>/bin/sh</string>
            <string>\(HostsStore.forwardDir)/apply.sh</string>
        </array>
        <key>RunAtLoad</key><true/>
    </dict>
    </plist>

    """
}
