pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    QtObject {
        id: dims
        readonly property real popoutWidth: 340
        readonly property real panelHeightRatio: 0.75
        readonly property real cardMinHeight: 70
        readonly property real chipMinHeight: 32
        readonly property real rowMinHeight: 22
        readonly property real dateLabelMinWidth: 50
        readonly property real valueLabelMinWidth: 65
        readonly property real offlineIconDelta: 3
    }

    layerNamespacePlugin: "network-indicator"

    // ── Settings ──
    property int updateInterval: pluginData.updateInterval || 2
    property string displayUnit: pluginData.displayUnit || "auto"
    // "separate" = show ↑ and ↓ individually, "combined" = single total speed
    property string displayMode: pluginData.displayMode || "separate"
    property string preferredInterface: pluginData.preferredInterface || "auto"
    property bool checkConnectivity: pluginData.checkConnectivity !== undefined ? pluginData.checkConnectivity : true
    readonly property real pillTextSize: root.textSize ?? Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)
    onCheckConnectivityChanged: _consecutiveFailures = 0

    // ── Internal state ──
    property real downloadSpeed: 0
    property real uploadSpeed: 0
    property real totalSpeed: downloadSpeed + uploadSpeed
    property real prevRxBytes: -1   // -1 = uninitialized sentinel
    property real prevTxBytes: -1
    property string prevIface: ""   // tracks interface change between cycles
    property bool interfaceFound: true  // assume online until first poll completes
    property bool _foundThisCycle: false // per-cycle temp flag (never triggers re-render)
    property string _activeIfaceThisCycle: "" // interface name found this cycle
    property string _activeSsidThisCycle: ""  // ssid found this cycle
    property string _cachedSsid: ""           // cached SSID across cycles to avoid redundant lookups
    property int _ssidPollCount: 0            // forces a fresh SSID lookup every 15 polls (catches same-iface network switches)
    property string connectivityState: "full" // "full" | "portal" | "limited" | "none" | "unknown"
    property string connectivitySource: "init" // "nm" | "curl" | "route" | "init"
    property int _consecutiveFailures: 0      // debouncing counter for offline/limited state
    property bool hasInternet: !checkConnectivity || connectivityState === "full" || connectivityState === "unknown"

    // ── Persistent data usage tracking ──
    property var usageData: ({})        // full parsed JSON object
    property real todayRx: 0            // today's accumulated download bytes
    property real todayTx: 0            // today's accumulated upload bytes
    property var todayNetworks: ({})    // today's usage per network
    property string currentNetworkName: "" // resolved network name (SSID or iface)
    property string todayKey: ""        // "yyyy-MM-dd" for current day
    property bool dataLoaded: false     // whether initial JSON was loaded
    property bool firstPollAfterLoad: true // first poll needs special delta handling
    property bool historyExpanded: false // whether 30-day history panel is shown
    property real _maxDailyUsage: 1      // cached max for bar proportions (avoid O(n²))
    property string selectedNetworkFilter: "All" // active filter for history
    property real _tempDeltaRx: 0       // temp storage for current cycle
    property real _tempDeltaTx: 0       // temp storage for current cycle
    property real unsavedBytes: 0       // bytes accumulated since last disk write

    // ── Offline reason detection (uses DMS NetworkService) ──
    property bool _dmsNetworkAvailable: typeof DMSNetworkService !== "undefined" && DMSNetworkService.networkAvailable
    property string offlineReason: {
        if (root.interfaceFound) return "";
        if (_dmsNetworkAvailable && !DMSNetworkService.wifiEnabled) return "wifi_off";
        return "disconnected";
    }

    function indicatorIconColor(speed, activeColor) {
        if (!root.hasInternet && root.interfaceFound) return Theme.warning;
        if (speed > 0) return activeColor;
        return Theme.surfaceVariantText;
    }

    // ── Formatting helpers ──
    function formatSpeed(bytesPerSec) {
        
        function formatNum(val, isBytes) {
            if (val === 0) return "0";
            if (isBytes) return val.toFixed(0);
            
            if (val < 10) return val.toFixed(2);
            if (val < 100) return val.toFixed(1);
            return val.toFixed(0);
        }

        if (displayUnit === "kbps") {
            return formatNum(bytesPerSec / 1024, false) + " KB/s";
        } else if (displayUnit === "mbps") {
            return formatNum(bytesPerSec / (1024 * 1024), false) + " MB/s";
        }
        
        // auto
        if (bytesPerSec < 1024) {
            return formatNum(bytesPerSec, true) + " B/s";
        } else if (bytesPerSec < 1024 * 1024) {
            return formatNum(bytesPerSec / 1024, false) + " KB/s";
        } else {
            return formatNum(bytesPerSec / (1024 * 1024), false) + " MB/s";
        }
    }

    function formatBytes(bytes) {
        if (bytes < 1024) return bytes.toFixed(0) + " B";
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
        if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(2) + " MB";
        return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB";
    }

    function formatDateLabel(dateStr) {
        // "yyyy-MM-dd" → "Mon DD" e.g. "May 16"
        var d = new Date(dateStr + "T00:00:00");
        var months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
        return months[d.getMonth()] + " " + d.getDate();
    }

    function getCurrentDateKey() {
        return Qt.formatDate(new Date(), "yyyy-MM-dd");
    }

    // ── Persistence: load via DMS Plugin State API ──
    function loadUsageData() {
        if (!pluginService) {
            return;  // Don't load or set dataLoaded — wait for pluginService to be injected
        }

        var days = pluginService.loadPluginState(pluginId, "days", {});
        var lastRx = pluginService.loadPluginState(pluginId, "lastRxBytes", -1);
        var lastTx = pluginService.loadPluginState(pluginId, "lastTxBytes", -1);
        var lastIface = pluginService.loadPluginState(pluginId, "lastInterface", "");

        var safeDays = {};
        try { safeDays = JSON.parse(JSON.stringify(days || {})); }
        catch (e) { safeDays = days || {}; }

        // Migrate legacy data
        var keys = Object.keys(safeDays);
        for (var i = 0; i < keys.length; i++) {
            var day = safeDays[keys[i]];
            if (!day.networks) {
                day.networks = { "unknown": { rx: day.rx || 0, tx: day.tx || 0 } };
            }
        }

        var lastNetwork = pluginService.loadPluginState(pluginId, "lastNetworkName", "");

        usageData = { lastRxBytes: lastRx, lastTxBytes: lastTx, lastInterface: lastIface, lastNetworkName: lastNetwork, days: safeDays };


        todayKey = getCurrentDateKey();
        if (usageData.days[todayKey]) {
            todayRx = usageData.days[todayKey].rx || 0;
            todayTx = usageData.days[todayKey].tx || 0;
            // deep copy to avoid modifying the read-only proxy in some Qt versions
            todayNetworks = JSON.parse(JSON.stringify(usageData.days[todayKey].networks || {}));
        } else {
            todayRx = 0;
            todayTx = 0;
            todayNetworks = {};
        }

        dataLoaded = true;
        firstPollAfterLoad = true;
    }

    // ── Persistence: save via DMS Plugin State API (auto-debounced 150ms) ──
    function saveUsageData() {
        if (!dataLoaded) return;

        root.unsavedBytes = 0;
        usageData.days[todayKey] = { rx: todayRx, tx: todayTx, networks: todayNetworks };
        usageData.lastRxBytes = prevRxBytes;
        usageData.lastTxBytes = prevTxBytes;
        usageData.lastInterface = _activeIfaceThisCycle || usageData.lastInterface || "";
        usageData.lastNetworkName = currentNetworkName || usageData.lastNetworkName || "";
        pruneOldDays();

        if (pluginService) {
            pluginService.savePluginState(pluginId, "days", usageData.days);
            pluginService.savePluginState(pluginId, "lastRxBytes", usageData.lastRxBytes);
            pluginService.savePluginState(pluginId, "lastTxBytes", usageData.lastTxBytes);
            pluginService.savePluginState(pluginId, "lastInterface", usageData.lastInterface);
            pluginService.savePluginState(pluginId, "lastNetworkName", usageData.lastNetworkName);
        }
    }

    // ── Prune entries older than 30 days ──
    function pruneOldDays() {
        var cutoff = new Date();
        cutoff.setDate(cutoff.getDate() - 30);
        var cutoffStr = Qt.formatDate(cutoff, "yyyy-MM-dd");

        var keys = Object.keys(usageData.days);
        for (var i = 0; i < keys.length; i++) {
            if (keys[i] < cutoffStr) {
                delete usageData.days[keys[i]];
            }
        }
    }

    // ── Get all known networks ──
    function getAvailableNetworks() {
        if (!usageData || !usageData.days) return ["All"];
        var nets = {"All": true};
        var keys = Object.keys(usageData.days);
        for (var i = 0; i < keys.length; i++) {
            var n = usageData.days[keys[i]].networks;
            if (n) {
                var nKeys = Object.keys(n);
                for (var j = 0; j < nKeys.length; j++) {
                    nets[nKeys[j]] = true;
                }
            }
        }
        return Object.keys(nets);
    }

    // ── Get sorted history entries (newest first) ──
    function getHistoryEntries() {
        if (!usageData || !usageData.days) return [];
        var entries = [];
        var keys = Object.keys(usageData.days);
        keys.sort().reverse();
        for (var i = 0; i < keys.length; i++) {
            var day = usageData.days[keys[i]];
            var r = 0;
            var t = 0;
            if (selectedNetworkFilter === "All") {
                r = day.rx || 0;
                t = day.tx || 0;
            } else if (day.networks && day.networks[selectedNetworkFilter]) {
                r = day.networks[selectedNetworkFilter].rx || 0;
                t = day.networks[selectedNetworkFilter].tx || 0;
            }
            if (r === 0 && t === 0 && selectedNetworkFilter !== "All") continue;

            entries.push({
                date: keys[i],
                label: formatDateLabel(keys[i]),
                total: r + t
            });
        }
        return entries;
    }

    // ── Get max daily usage (for bar proportions) ──
    function getMaxDailyUsage() {
        var entries = getHistoryEntries();
        var max = 0;
        for (var i = 0; i < entries.length; i++) {
            if (entries[i].total > max) max = entries[i].total;
        }
        return max > 0 ? max : 1;
    }

    // ── Get overall usage across all stored days (up to 30) ──
    function getOverallUsage() {
        var entries = getHistoryEntries();
        var sum = 0;
        for (var i = 0; i < entries.length; i++) {
            sum += entries[i].total;
        }
        return sum;
    }

    // ── Stable ListModel caches (avoid Repeater model rebuild on poll) ──
    ListModel { id: networksModel }
    ListModel { id: historyModel }

    function refreshNetworksModel() {
        var nets = root.getAvailableNetworks();
        networksModel.clear();
        for (var i = 0; i < nets.length; i++) {
            networksModel.append({ "name": nets[i] });
        }
    }

    function refreshHistoryModel() {
        var entries = root.getHistoryEntries();
        historyModel.clear();
        for (var i = 0; i < entries.length; i++) {
            historyModel.append(entries[i]);
        }
    }


    // ── Timer to poll network stats ──
    Timer {
        id: pollTimer
        interval: root.updateInterval * 1000
        running: root.dataLoaded
        repeat: true
        onTriggered: {
            // Check for midnight rollover or time jumps (e.g. NTP sync after boot)
            var currentKey = root.getCurrentDateKey();
            if (currentKey !== root.todayKey) {
                // Save the old day, switch to the new day
                root.saveUsageData();
                root.todayKey = currentKey;
                
                // Restore existing data for the new day if it exists, instead of resetting to 0
                if (root.usageData.days[currentKey]) {
                    root.todayRx = root.usageData.days[currentKey].rx || 0;
                    root.todayTx = root.usageData.days[currentKey].tx || 0;
                    root.todayNetworks = JSON.parse(JSON.stringify(root.usageData.days[currentKey].networks || {}));
                } else {
                    root.todayRx = 0;
                    root.todayTx = 0;
                    root.todayNetworks = {};
                }
            }

            root._foundThisCycle = false;
            root._activeIfaceThisCycle = "";
            root._activeSsidThisCycle = "";
            root._tempDeltaRx = 0;
            root._tempDeltaTx = 0;
            root._ssidPollCount = (root._ssidPollCount + 1) % 15;
            if (!ssidProcess.running) root.sampleNetwork();
        }
    }

    // ── Timer to periodically save to disk (every 7 mins) ──
    Timer {
        id: saveTimer
        interval: 420000
        running: root.dataLoaded
        repeat: true
        onTriggered: {
            if (root.unsavedBytes > 0) {
                root.saveUsageData();
            }
        }
    }

    // ── Timer to check internet connectivity (20s if connected, 5s if offline) ──
    Timer {
        id: connectivityTimer
        interval: root.hasInternet ? 20000 : 5000
        running: root.dataLoaded && root.checkConnectivity
        repeat: true
        triggeredOnStart: true
        onTriggered: connectivityProcess.running = true
    }

    // ── Process: checks actual internet reachability with NM -> Route Gate -> curl fallback ──
    Process {
        id: connectivityProcess
        command: [
            "sh", "-c",
            "PRIMARY_URL=\"http://connectivitycheck.gstatic.com/generate_204\"; " +
            "FALLBACK_URL=\"http://nmcheck.gnome.org/check_network_status.txt\"; " +
            "FALLBACK_EXPECTED=\"NetworkManager is online\"; " +
            "if command -v nmcli >/dev/null 2>&1 && [ \"$(nmcli -t -f RUNNING general 2>/dev/null)\" = \"running\" ]; then " +
            "  nm_check_enabled=\"unknown\"; " +
            "  if command -v busctl >/dev/null 2>&1; then " +
            "    avail=$(busctl get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager ConnectivityCheckAvailable 2>/dev/null | awk '{print $2}'); " +
            "    en=$(busctl get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager ConnectivityCheckEnabled 2>/dev/null | awk '{print $2}'); " +
            "    if [ \"$avail\" = \"true\" ] && [ \"$en\" = \"true\" ]; then nm_check_enabled=\"yes\"; " +
            "    elif [ \"$avail\" = \"false\" ] || [ \"$en\" = \"false\" ]; then nm_check_enabled=\"no\"; fi; " +
            "  fi; " +
            "  if [ \"$nm_check_enabled\" = \"yes\" ]; then " +
            "    nm_res=$(nmcli networking connectivity check 2>/dev/null); " +
            "    case \"$nm_res\" in " +
            "      full|portal|limited|none) echo \"CONNECTIVITY:${nm_res}:nm\"; exit 0 ;; " +
            "    esac; " +
            "  fi; " +
            "fi; " +
            "has_route=0; " +
            "if command -v ip >/dev/null 2>&1; then " +
            "  if ip route show default 2>/dev/null | grep -q \"default\"; then has_route=1; " +
            "  elif ip -6 route show default 2>/dev/null | grep -q \"default\"; then has_route=1; fi; " +
            "else has_route=1; fi; " +
            "if [ \"$has_route\" -eq 0 ]; then echo \"CONNECTIVITY:none:route\"; exit 0; fi; " +
            "if command -v curl >/dev/null 2>&1; then " +
            "  code=$(curl -s -o /dev/null -w \"%{http_code}\" --max-time 4 \"$PRIMARY_URL\" 2>/dev/null); " +
            "  if [ \"$code\" = \"204\" ]; then echo \"CONNECTIVITY:full:curl\"; exit 0; fi; " +
            "  resp=$(curl -s -i --max-time 4 \"$FALLBACK_URL\" 2>/dev/null); " +
            "  if [ -n \"$resp\" ]; then " +
            "    fb_code=$(echo \"$resp\" | head -n 1 | awk '{print $2}'); " +
            "    fb_body=$(echo \"$resp\" | sed '1,/^\r\\{0,1\\}$/d'); " +
            "    if echo \"$fb_body\" | grep -qF \"$FALLBACK_EXPECTED\"; then echo \"CONNECTIVITY:full:curl\"; exit 0; fi; " +
            "    if [ -n \"$fb_code\" ] && [ \"$fb_code\" -ge 200 ] && [ \"$fb_code\" -lt 400 ]; then echo \"CONNECTIVITY:portal:curl\"; exit 0; fi; " +
            "  fi; " +
            "  echo \"CONNECTIVITY:limited:curl\"; exit 0; " +
            "fi; " +
            "echo \"CONNECTIVITY:unknown:none\""
        ]
        stdout: SplitParser {
            onRead: line => {
                if (line.startsWith("CONNECTIVITY:")) {
                    var parts = line.split(":");
                    var status = parts[1] ? parts[1].trim() : "unknown";
                    var source = parts[2] ? parts[2].trim() : "unknown";

                    if (status === "full") {
                        root._consecutiveFailures = 0;
                        root.connectivityState = "full";
                        root.connectivitySource = source;
                    } else if (status === "portal") {
                        // Captive portal is an active redirect/response; apply immediately without debounce
                        root._consecutiveFailures = 0;
                        root.connectivityState = "portal";
                        root.connectivitySource = source;
                    } else if (status === "none") {
                        // No network/route is definitive; apply immediately
                        root._consecutiveFailures = 0;
                        root.connectivityState = "none";
                        root.connectivitySource = source;
                    } else if (status === "limited") {
                        // Debounce limited state (requires 2 consecutive failures to prevent flicker)
                        root._consecutiveFailures++;
                        if (root._consecutiveFailures >= 2 || !root.hasInternet) {
                            root.connectivityState = "limited";
                            root.connectivitySource = source;
                        }
                    } else {
                        root._consecutiveFailures = 0;
                        root.connectivityState = "unknown";
                        root.connectivitySource = source;
                    }
                }
            }
        }
    }

    // ── Network sampling: reads /proc + /sys through FileView (no process per tick) ──
    // blockAllReads (not blockLoading) so text() after reload() or a path change returns fresh content, not the previous read
    FileView { id: procNetDev; path: "/proc/net/dev"; blockAllReads: true; printErrors: false }
    FileView { id: procNetRoute; path: "/proc/net/route"; blockAllReads: true; printErrors: false }
    FileView { id: sysFile; blockAllReads: true; printErrors: false }

    // Returns "" when the file is missing or unreadable
    function readSysFile(path) {
        if (sysFile.path === path) sysFile.reload();
        else sysFile.path = path;
        return (sysFile.text() || "").trim();
    }

    function ifaceExists(dev) { return readSysFile("/sys/class/net/" + dev + "/uevent") !== ""; }
    function ifaceIsPhysical(dev) { return readSysFile("/sys/class/net/" + dev + "/device/uevent") !== ""; }
    function ifaceIsWireless(dev) { return readSysFile("/sys/class/net/" + dev + "/uevent").indexOf("DEVTYPE=wlan") !== -1; }

    function pickInterface(devLines) {
        if (root.preferredInterface !== "auto") {
            return ifaceExists(root.preferredInterface) ? root.preferredInterface : "";
        }

        // Default routes (destination and mask 00000000), first physical one wins
        procNetRoute.reload();
        var routes = (procNetRoute.text() || "").split("\n");
        for (var i = 1; i < routes.length; i++) {
            var cols = routes[i].trim().split(/\s+/);
            if (cols.length > 7 && cols[1] === "00000000" && cols[7] === "00000000" && ifaceIsPhysical(cols[0])) {
                return cols[0];
            }
        }

        // No usable default route: first physical interface that is up with carrier, else first up/unknown one
        var names = Object.keys(devLines).sort();
        var fallback = "";
        for (var j = 0; j < names.length; j++) {
            var dev = names[j];
            if (!ifaceIsPhysical(dev)) continue;
            var state = readSysFile("/sys/class/net/" + dev + "/operstate");
            if (state === "up" && readSysFile("/sys/class/net/" + dev + "/carrier") === "1") return dev;
            if (!fallback && (state === "up" || state === "unknown")) fallback = dev;
        }
        return fallback;
    }

    function sampleNetwork() {
        // Captured before the cycle mutates prevIface
        var cachedIface = root.prevIface;
        var cachedSsid = (typeof NetworkService !== "undefined" && NetworkService.wifiInterface === root.prevIface && NetworkService.currentWifiSSID)
            ? NetworkService.currentWifiSSID
            : (root._ssidPollCount === 0 ? "" : root._cachedSsid);

        procNetDev.reload();
        var devLines = {};
        var lines = (procNetDev.text() || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var idx = lines[i].indexOf(":");
            if (idx > 0) devLines[lines[i].substring(0, idx).trim()] = lines[i];
        }

        var dev = pickInterface(devLines);
        if (!dev) {
            root.finishCycle();
            return;
        }

        if (devLines[dev]) root.handleStatLine(devLines[dev]);
        root.handleStatLine("OPSTATE:" + dev + ":" + (readSysFile("/sys/class/net/" + dev + "/operstate") || "unknown"));

        if (!ifaceIsWireless(dev)) {
            root.finishCycle();
        } else if (dev === cachedIface && cachedSsid) {
            root.handleStatLine("SSID:" + dev + ":" + cachedSsid);
            root.finishCycle();
        } else {
            // Only an uncached SSID lookup needs a process
            ssidProcess.iface = dev;
            ssidProcess.running = true;
        }
    }

    function handleStatLine(line) {
        if (line.startsWith("SSID:")) {
            var sparts = line.split(":");
            var sIface = sparts[1];
            var sSsid = sparts.slice(2).join(":").trim(); // Handle SSIDs with colons
            if (sIface === root._activeIfaceThisCycle) {
                root._activeSsidThisCycle = sSsid || "unknown";
            }
            return;
        }

        // Handle operstate lines — they come after the /proc/net/dev output
        if (line.startsWith("OPSTATE:")) {
            var oparts = line.split(":");
            var oIface = oparts[1];
            var oState = oparts[2];
            // If this is the interface we picked this cycle, mark offline when down
            if (oIface === root._activeIfaceThisCycle && oState === "down") {
                root._foundThisCycle = false;
            }
            return;
        }

        // Already found our interface this cycle — skip remaining lines
        if (root._foundThisCycle) return;

        // Lines look like: "  eth0: 12345 ... 67890 ..."
        var trimmed = line.trim();
        if (trimmed.indexOf(":") === -1) return;

        var parts = trimmed.split(":");
        var ifaceName = parts[0].trim();

        // Lock in this interface for the cycle
        root._foundThisCycle = true;
        root._activeIfaceThisCycle = ifaceName;
        root._activeSsidThisCycle = ""; // Reset until SSID line overrides
        if (ifaceName !== root.prevIface) {
            root._cachedSsid = ""; // SSID cache belongs to the previous interface
        }

        var stats = parts[1].trim().split(/\s+/);
        // columns: rx_bytes rx_packets ... (8 rx fields) tx_bytes tx_packets ...
        var rxBytes = parseFloat(stats[0]) || 0;
        var txBytes = parseFloat(stats[8]) || 0;

        // ── First poll after loading saved data: recover gap ──
        if (root.firstPollAfterLoad) {
            root.firstPollAfterLoad = false;
            var savedRx = root.usageData.lastRxBytes || -1;
            var savedTx = root.usageData.lastTxBytes || -1;
            var savedIface = root.usageData.lastInterface || "";

            // Only recover gap if same interface (different interface = unreliable counters)
            if (savedRx >= 0 && savedTx >= 0 && savedIface === ifaceName) {
                // Counters grew since last save → data accumulated while plugin was off
                var gapRx = rxBytes - savedRx;
                var gapTx = txBytes - savedTx;
                if (gapRx >= 0 && gapTx >= 0) {
                    root._tempDeltaRx = gapRx;
                    root._tempDeltaTx = gapTx;
                    root.todayRx += gapRx;
                    root.todayTx += gapTx;
                }
                // If negative, counter reset (reboot) — don't add gap, start fresh delta
            }
            root.prevRxBytes = rxBytes;
            root.prevTxBytes = txBytes;
            root.prevIface = ifaceName;
            // Note: Gap recovery is saved when process exits (so SSID is ready)
            return;
        }

        // ── Normal delta accumulation ──
        if (root.prevRxBytes >= 0 && root.prevTxBytes >= 0 && root.prevIface === ifaceName) {
            var deltaRx = rxBytes - root.prevRxBytes;
            var deltaTx = txBytes - root.prevTxBytes;
            var elapsed = root.updateInterval;

            // Speed calculation
            root.downloadSpeed = Math.max(0, deltaRx / elapsed);
            root.uploadSpeed = Math.max(0, deltaTx / elapsed);

            // Accumulate to daily total (only positive deltas)
            root._tempDeltaRx = Math.max(0, deltaRx);
            root._tempDeltaTx = Math.max(0, deltaTx);
            
            if (deltaRx > 0) root.todayRx += deltaRx;
            if (deltaTx > 0) root.todayTx += deltaTx;
        } else if (root.prevIface !== ifaceName) {
            // Interface changed, reset speeds to avoid massive spike
            root.downloadSpeed = 0;
            root.uploadSpeed = 0;
        }

        root.prevRxBytes = rxBytes;
        root.prevTxBytes = txBytes;
        root.prevIface = ifaceName;
        // Wait for exit to save so we have the SSID
    }

    function finishCycle() {
        // Update interfaceFound ONLY after the full read completes (no flicker)
        root.interfaceFound = root._foundThisCycle;

        if (!root._foundThisCycle) {
            root.downloadSpeed = 0;
            root.uploadSpeed = 0;
            root.prevRxBytes = -1;
            root.prevTxBytes = -1;
            root._cachedSsid = "";
        } else {
            if (root._activeSsidThisCycle) {
                root._cachedSsid = root._activeSsidThisCycle;
            }
            root.currentNetworkName = root._activeSsidThisCycle || root._cachedSsid || root._activeIfaceThisCycle;

            if (root._tempDeltaRx > 0 || root._tempDeltaTx > 0) {
                var net = root.todayNetworks[root.currentNetworkName] || { rx: 0, tx: 0 };
                net.rx += root._tempDeltaRx;
                net.tx += root._tempDeltaTx;
                // QML requires re-assigning the object to trigger property bindings for dicts sometimes, 
                // or modifying it directly might not persist if not careful.
                var newDict = JSON.parse(JSON.stringify(root.todayNetworks));
                newDict[root.currentNetworkName] = net;
                root.todayNetworks = newDict;

                // Update the model dynamically without rebuilding if expanded
                if (root.historyExpanded && historyModel.count > 0) {
                    var topEntry = historyModel.get(0);
                    if (topEntry.date === root.todayKey) {
                        var r = 0;
                        var t = 0;
                        if (root.selectedNetworkFilter === "All") {
                            r = root.todayRx;
                            t = root.todayTx;
                        } else if (root.todayNetworks[root.selectedNetworkFilter]) {
                            r = root.todayNetworks[root.selectedNetworkFilter].rx || 0;
                            t = root.todayNetworks[root.selectedNetworkFilter].tx || 0;
                        }
                        historyModel.setProperty(0, "total", r + t);
                    }
                }
            }

            root.unsavedBytes += (root._tempDeltaRx + root._tempDeltaTx);

            if (root.unsavedBytes >= 50 * 1024 * 1024) {
                root.saveUsageData();
            }
        }
    }

    // ── Process: SSID lookup, only when not cached or provided by NetworkService ──
    Process {
        id: ssidProcess
        property string iface: ""
        command: [
            "sh", "-c",
            "ssid=$(iwgetid -r \"$1\" 2>/dev/null); " +
            "if [ -z \"$ssid\" ] && command -v iw >/dev/null 2>&1; then " +
            "  ssid=$(iw dev \"$1\" link 2>/dev/null | awk -F'SSID: ' '/SSID:/ {print $2}'); " +
            "fi; " +
            "if [ -z \"$ssid\" ] && command -v nmcli >/dev/null 2>&1; then " +
            "  ssid=$(nmcli -t -c no -f device,active,ssid dev wifi 2>/dev/null | grep \"^$1:yes:\" | cut -d: -f3- | sed 's/\\\\:/:/g'); " +
            "fi; " +
            "if [ -n \"$ssid\" ]; then echo \"SSID:$1:$ssid\"; fi",
            "_", ssidProcess.iface
        ]
        stdout: SplitParser {
            onRead: line => root.handleStatLine(line)
        }
        onExited: root.finishCycle()
    }

    function initData() {
        if (!pluginService || dataLoaded) return;
        loadUsageData();
        root.sampleNetwork();
    }

    // ── Load persisted data and start polling ──
    Component.onCompleted: initData()

    Connections {
        target: root
        function onPluginServiceChanged() {
            initData();
        }
    }

    // ── Save on destruction ──
    Component.onDestruction: {
        saveUsageData();
    }

    // ── Horizontal Bar Pill (for horizontal DankBar) ──
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            // ── Offline state: differentiate wifi_off vs disconnected ──
            DankIcon {
                visible: !root.interfaceFound
                name: "android_wifi_3_bar_off"
                size: root.iconSize + dims.offlineIconDelta
                weight: 700
                color: Theme.error
                anchors.verticalCenter: parent.verticalCenter
            }

            // Combined mode: single total speed
            Row {
                visible: root.interfaceFound && root.displayMode === "combined"
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    name: "import_export"
                    size: root.iconSize
                    color: root.indicatorIconColor(root.totalSpeed, Theme.primary)
                    anchors.verticalCenter: parent.verticalCenter
                    weight: 700
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }

                StyledText {
                    text: root.formatSpeed(root.totalSpeed)
                    font.pixelSize: root.pillTextSize
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Separate mode: upload ↑
            Row {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    name: "arrow_upward"
                    size: root.iconSize
                    color: root.indicatorIconColor(root.uploadSpeed, Theme.error)
                    anchors.verticalCenter: parent.verticalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.uploadSpeed)
                    font.pixelSize: root.pillTextSize
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            // Separate mode: download ↓
            Row {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    name: "arrow_downward"
                    size: root.iconSize
                    color: root.indicatorIconColor(root.downloadSpeed, Theme.primary)
                    anchors.verticalCenter: parent.verticalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.downloadSpeed)
                    font.pixelSize: root.pillTextSize
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    // ── Vertical Bar Pill (for vertical DankBar) ──
    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingS

            // ── Offline state: differentiate wifi_off vs disconnected ──
            DankIcon {
                visible: !root.interfaceFound
                name: "android_wifi_3_bar_off"
                size: root.iconSize + dims.offlineIconDelta
                color: Theme.error
                anchors.horizontalCenter: parent.horizontalCenter
                weight: 700
            }

            // Combined mode: single total speed
            Column {
                visible: root.interfaceFound && root.displayMode === "combined"
                spacing: 2
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "import_export"
                    size: root.iconSize
                    color: root.indicatorIconColor(root.totalSpeed, Theme.primary)
                    anchors.horizontalCenter: parent.horizontalCenter
                    weight: 700

                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }

                StyledText {
                    text: root.formatSpeed(root.totalSpeed).replace(" ", "\n")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: root.pillTextSize
                    color: (!root.hasInternet && root.interfaceFound) ? Theme.warning : Theme.surfaceText
                }
            }

            // Separate mode: upload ↑
            Column {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 2
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "arrow_upward"
                    size: root.iconSize
                    color: root.indicatorIconColor(root.uploadSpeed, Theme.error)
                    anchors.horizontalCenter: parent.horizontalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.uploadSpeed).replace(" ", "\n")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: root.pillTextSize
                    color: Theme.surfaceText
                }
            }

            // Separate mode: download ↓
            Column {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 2
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "arrow_downward"
                    size: root.iconSize
                    color: root.indicatorIconColor(root.downloadSpeed, Theme.primary)
                    anchors.horizontalCenter: parent.horizontalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.downloadSpeed).replace(" ", "\n")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: root.pillTextSize
                    color: Theme.surfaceText
                }
            }
        }
    }

    // ── Popout with detailed network stats ──
    popoutContent: Component {
        PopoutComponent {
            showCloseButton: false

            onVisibleChanged: {
                if (visible) {
                    root.historyExpanded = false;
                } else {
                    root.selectedNetworkFilter = "All";
                }
            }

            Item {
                width: parent.width
                implicitHeight: stickyTop.implicitHeight + (root.historyExpanded ? Theme.spacingM + historySection.height : 0)

                // ── Sticky top section (does not scroll) ──
                Column {
                    id: stickyTop
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    spacing: Theme.spacingM

                        // ── Custom Centered Header ──
                        Column {
                            width: parent.width
                            spacing: 2

                            StyledText {
                                text: "Network Indicator"
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.Bold
                                color: Theme.surfaceText
                                horizontalAlignment: Text.AlignHCenter
                                width: parent.width
                            }

                            StyledText {
                                visible: !root.interfaceFound
                                text: root.offlineReason === "wifi_off" ? "WiFi is turned off" : "Not connected to any network"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.error
                                horizontalAlignment: Text.AlignHCenter
                                width: parent.width
                            }
                        }

                        // ── No Internet / Portal banner (connected locally but no/restricted internet) ──
                        StyledRect {
                            visible: root.interfaceFound && !root.hasInternet
                            width: parent.width
                            height: noInternetBannerCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.warning, 0.08)

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                DankIcon {
                                    id: noInternetIcon
                                    name: root.connectivityState === "portal" ? "portal" : "android_wifi_3_bar_alert"
                                    size: Theme.iconSizeLarge
                                    color: Theme.warning
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    id: noInternetBannerCol
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - noInternetIcon.width - Theme.spacingS
                                    spacing: 2

                                    StyledText {
                                        text: root.connectivityState === "portal" ? "Sign-in required" : "No internet access"
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Bold
                                        color: Theme.warning
                                        width: parent.width
                                        elide: Text.ElideRight
                                    }
                                    StyledText {
                                        text: root.connectivityState === "portal" ? "This network requires you to log in" : "Check your router or internet connection"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        width: parent.width
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }

                        // ── Offline banner (clickable → opens DMS Network Settings) ──
                        StyledRect {
                            visible: !root.interfaceFound
                            width: parent.width
                            height: offlineBannerCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: offlineBannerMouse.containsMouse
                                ? Theme.withAlpha(Theme.error, 0.12)
                                : Theme.withAlpha(Theme.error, 0.06)

                            Behavior on color {
                                ColorAnimation { duration: 150; easing.type: Easing.OutCubic }
                            }

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                DankIcon {
                                    id: offlineIcon
                                    name: root.offlineReason === "wifi_off" ? "wifi_off" : "signal_wifi_off"
                                    size: Theme.iconSizeLarge
                                    color: Theme.error
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    id: offlineBannerCol
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - offlineIcon.width - chevronIcon.width - Theme.spacingS * 2
                                    spacing: 2

                                    StyledText {
                                        text: root.offlineReason === "wifi_off"
                                            ? "WiFi is turned off"
                                            : "No network connection"
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Bold
                                        color: Theme.surfaceText
                                        width: parent.width
                                        elide: Text.ElideRight
                                    }
                                    StyledText {
                                        text: root.offlineReason === "wifi_off"
                                            ? "Click to enable WiFi"
                                            : "Click to browse available networks"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        width: parent.width
                                        elide: Text.ElideRight
                                    }
                                }

                                DankIcon {
                                    id: chevronIcon
                                    name: "chevron_right"
                                    size: Theme.iconSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                hoverEnabled: true
                                id: offlineBannerMouse
                                onClicked: {
                                    root.closePopout();
                                    PopoutService.openSettingsWithTab("network");
                                }
                            }
                        }

                        // ── Download + Upload side by side ──
                        Row {
                            visible: root.interfaceFound
                            width: parent.width
                            spacing: Theme.spacingS

                            // Download card
                            StyledRect {
                                width: (parent.width - Theme.spacingS) / 2
                                implicitHeight: Math.max(dims.cardMinHeight, downloadCol.implicitHeight + Theme.spacingM * 2)
                                radius: Theme.cornerRadius
                                color: Theme.withAlpha(Theme.primary, 0.2)

                                Column {
                                    id: downloadCol
                                    anchors.centerIn: parent
                                    spacing: 2

                                    DankIcon {
                                        name: "download"
                                        size: Theme.iconSize
                                        color: Theme.primary
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                    StyledText {
                                        text: root.formatSpeed(root.downloadSpeed)
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Bold
                                        color: Theme.primary
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                }
                            }

                            // Upload card
                            StyledRect {
                                width: (parent.width - Theme.spacingS) / 2
                                implicitHeight: Math.max(dims.cardMinHeight, uploadCol.implicitHeight + Theme.spacingM * 2)
                                radius: Theme.cornerRadius
                                color: Theme.withAlpha(Theme.error, 0.2)

                                Column {
                                    id: uploadCol
                                    anchors.centerIn: parent
                                    spacing: 2

                                    DankIcon {
                                        name: "upload"
                                        size: Theme.iconSize
                                        color: Theme.error
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                    StyledText {
                                        text: root.formatSpeed(root.uploadSpeed)
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Bold
                                        color: Theme.error
                                        anchors.horizontalCenter: parent.horizontalCenter
                                    }
                                }
                            }
                        }

                    // ── Data Used Today (clickable to expand history) ──
                    StyledRect {
                        id: dataUsedCard
                        width: parent.width
                        implicitHeight: Math.max(dims.cardMinHeight, dataUsedRow.implicitHeight + Theme.spacingM * 2)
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)

                        Row {
                            id: dataUsedRow
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            DankIcon {
                                id: dataUsageIcon
                                name: "data_usage"
                                size: Theme.iconSize
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Column {
                                id: dataUsedCol
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                width: parent.width - dataUsageIcon.width - Theme.spacingM - expandIcon.width - Theme.spacingM

                                StyledText {
                                    text: "Data Used Today"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                                StyledText {
                                    text: root.formatBytes(root.todayRx + root.todayTx)
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Font.Bold
                                    color: Theme.surfaceVariantText
                                }
                            }

                            DankIcon {
                                id: expandIcon
                                name: "expand_more"
                                size: Theme.iconSizeSmall
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                                rotation: root.historyExpanded ? 180 : 0

                                Behavior on rotation {
                                    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.historyExpanded = !root.historyExpanded;
                                root.selectedNetworkFilter = "All";
                                if (root.historyExpanded) {
                                    root.refreshNetworksModel();
                                    root.refreshHistoryModel();
                                    root._maxDailyUsage = root.getMaxDailyUsage();
                                    filtersFlickable.contentX = 0;
                                    historyListView.positionViewAtBeginning();
                                }
                            }
                        }
                    }
                } // end stickyTop Column

                // ── 30-Day History Section (anchored below sticky top) ──
                Item {
                    id: historySection
                    property real naturalHeight: historyLabel.implicitHeight + Theme.spacingS + filtersFlickable.height + Theme.spacingM + historyListView.contentHeight + Theme.spacingXS + totalSection.height
                    property real expandedHeight: Math.min(naturalHeight, Math.max(0, (root.parentScreen && root.parentScreen.height ? root.parentScreen.height * dims.panelHeightRatio : 0) - stickyTop.implicitHeight - Theme.spacingM))
                    implicitHeight: height
                    height: root.historyExpanded ? expandedHeight : 0
                    anchors.top: stickyTop.bottom
                    anchors.topMargin: root.historyExpanded ? Theme.spacingM : 0
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: 0
                    visible: root.historyExpanded
                    opacity: root.historyExpanded ? 1.0 : 0.0
                    clip: true

                    Behavior on height {
                        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                    }

                    Behavior on opacity {
                        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                    }

                    // "Last 30 Days" header (sticky at top)
                    StyledText {
                        id: historyLabel
                        anchors.top: parent.top
                        width: parent.width - Theme.spacingM
                        text: "Last 30 Days"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Bold
                        color: Theme.surfaceVariantText
                        bottomPadding: Theme.spacingXS
                    }

                    // ── Network Filter Chips ──
                    Flickable {
                        id: filtersFlickable
                        anchors.top: historyLabel.bottom
                        anchors.topMargin: Theme.spacingS
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: Math.max(dims.chipMinHeight, filtersRow.implicitHeight)
                        contentWidth: filtersRow.implicitWidth
                        boundsBehavior: Flickable.StopAtBounds
                        clip: true

                        Row {
                            id: filtersRow
                            spacing: Theme.spacingS

                            Repeater {
                                model: networksModel

                                StyledRect {
                                    id: filterChip
                                    required property string name
                                    height: Math.max(dims.chipMinHeight, filterText.implicitHeight + Theme.spacingS * 2)
                                    width: filterText.implicitWidth + Theme.spacingM * 2
                                    radius: height / 2
                                    color: root.selectedNetworkFilter === filterChip.name 
                                        ? Theme.withAlpha(Theme.primary, 0.2)
                                        : Theme.withAlpha(Theme.surfaceVariantText, 0.1)
                                    border.width: root.selectedNetworkFilter === filterChip.name ? 1 : 0
                                    border.color: Theme.primary

                                    Behavior on color { ColorAnimation { duration: 150 } }

                                    StyledText {
                                        id: filterText
                                        anchors.centerIn: parent
                                        text: filterChip.name
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: root.selectedNetworkFilter === filterChip.name ? Font.Bold : Font.Normal
                                        color: root.selectedNetworkFilter === filterChip.name ? Theme.primary : Theme.surfaceVariantText
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.selectedNetworkFilter = filterChip.name;
                                            root.refreshHistoryModel();
                                            root._maxDailyUsage = root.getMaxDailyUsage();
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Scrollable daily entries (using DankListView for smooth scrolling)
                    DankListView {
                        id: historyListView
                        anchors.top: filtersFlickable.bottom
                        anchors.topMargin: Theme.spacingM
                        anchors.bottom: totalSection.top
                        anchors.bottomMargin: Theme.spacingXS
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.rightMargin: 2
                        clip: true
                        spacing: Theme.spacingXS
                        
                        model: historyModel
                        
                        ScrollBar.vertical: ScrollBar {
                            id: historyScrollBar
                            policy: ScrollBar.AsNeeded
                            implicitWidth: Theme.spacingS + 2
                            background: Item {}
                            contentItem: Rectangle {
                                implicitWidth: Theme.spacingS
                                radius: implicitWidth / 2
                                color: Theme.withAlpha(Theme.surfaceVariantText, historyScrollBar.active ? 0.5 : 0.3)

                                Behavior on color { ColorAnimation { duration: 150 } }
                            }
                        }

                        delegate: StyledRect {
                            id: historyRow
                            required property string date
                            required property string label
                            required property real total

                            width: historyListView.width - historyScrollBar.implicitWidth - 3
                            height: Math.max(dims.rowMinHeight, historyRowContent.implicitHeight + Theme.spacingS * 2)
                            radius: Theme.cornerRadius / 2
                            color: historyRow.date === root.todayKey
                                ? Theme.withAlpha(Theme.primary, 0.08)
                                : Theme.withAlpha(Theme.surfaceVariantText, 0.1)

                            Row {
                                id: historyRowContent
                                anchors.fill: parent
                                anchors.leftMargin: Theme.spacingS
                                anchors.rightMargin: Theme.spacingS
                                spacing: Theme.spacingS

                                // Date label
                                StyledText {
                                    id: dateLabel
                                    text: historyRow.date === root.todayKey ? "Today" : historyRow.label
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: historyRow.date === root.todayKey ? Font.Bold : Font.Normal
                                    color: historyRow.date === root.todayKey ? Theme.primary : Theme.surfaceVariantText
                                    width: Math.max(dims.dateLabelMinWidth, implicitWidth)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                // Usage bar
                                Item {
                                    width: Math.max(0, parent.width - dateLabel.width - totalLabel.width - Theme.spacingS * 3)
                                    height: Theme.spacingS
                                    clip: true
                                    anchors.verticalCenter: parent.verticalCenter

                                    StyledRect {
                                        width: parent.width
                                        height: parent.height
                                        radius: height / 2
                                        color: Theme.withAlpha(Theme.surfaceVariantText, 0.1)
                                    }

                                    StyledRect {
                                        width: Math.max(2, parent.width * (historyRow.total / root._maxDailyUsage))
                                        height: parent.height
                                        radius: height / 2
                                        color: historyRow.date === root.todayKey ? Theme.primary : Theme.surfaceVariantText

                                        Behavior on width {
                                            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                                        }
                                    }
                                }

                                // Total data label
                                StyledText {
                                    id: totalLabel
                                    text: root.formatBytes(historyRow.total)
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: historyRow.date === root.todayKey ? Theme.primary : Theme.surfaceText
                                    horizontalAlignment: Text.AlignRight
                                    width: Math.max(dims.valueLabelMinWidth, implicitWidth)
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }

                    // ── Sticky Total row (pinned at bottom) ──
                    Item {
                        id: totalSection
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: totalRow.height + Theme.spacingS

                        StyledRect {
                            id: totalRow
                            y: Theme.spacingS
                            width: parent.width
                            height: Math.max(dims.rowMinHeight, totalRowContent.implicitHeight + Theme.spacingS * 2)
                            radius: Theme.cornerRadius / 2
                            color: Theme.withAlpha(Theme.surfaceText, 0.08)

                            Row {
                                id: totalRowContent
                                anchors.fill: parent
                                anchors.leftMargin: Theme.spacingS
                                anchors.rightMargin: Theme.spacingS

                                StyledText {
                                    text: "Total"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    width: Math.max(dims.dateLabelMinWidth, implicitWidth)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Item {
                                    width: parent.width - dims.dateLabelMinWidth - Math.max(dims.valueLabelMinWidth, overallLabel.implicitWidth) - Theme.spacingS
                                    height: 1
                                }

                                StyledText {
                                    id: overallLabel
                                    text: root.selectedNetworkFilter ? root.formatBytes(root.getOverallUsage()) : ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    horizontalAlignment: Text.AlignRight
                                    width: Math.max(dims.valueLabelMinWidth, implicitWidth)
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                } // end historySection
            }
        }
    }

    popoutWidth: dims.popoutWidth
}
