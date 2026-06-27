pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import QtCore

PluginComponent {
    id: root


    layerNamespacePlugin: "network-indicator"

    // ── Settings ──
    property int updateInterval: pluginData.updateInterval || 2
    property string displayUnit: pluginData.displayUnit || "auto"
    // "separate" = show ↑ and ↓ individually, "combined" = single total speed
    property string displayMode: pluginData.displayMode || "separate"

    // ── Internal state ──
    property real downloadSpeed: 0
    property real uploadSpeed: 0
    property real totalSpeed: downloadSpeed + uploadSpeed
    property real prevRxBytes: -1   // -1 = uninitialized sentinel
    property real prevTxBytes: -1
    property bool interfaceFound: true  // assume online until first poll completes
    property bool _foundThisCycle: false // per-cycle temp flag (never triggers re-render)
    property string _activeIfaceThisCycle: "" // interface name found this cycle
    property string _activeSsidThisCycle: ""  // ssid found this cycle

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

    // ── Formatting helpers ──
    function formatSpeed(bytesPerSec) {
        if (displayUnit === "kbps") {
            return (bytesPerSec / 1024).toFixed(1) + " KB/s";
        } else if (displayUnit === "mbps") {
            return (bytesPerSec / (1024 * 1024)).toFixed(2) + " MB/s";
        }
        // auto
        if (bytesPerSec < 1024) {
            return bytesPerSec.toFixed(0) + " B/s";
        } else if (bytesPerSec < 1024 * 1024) {
            return (bytesPerSec / 1024).toFixed(1) + " KB/s";
        } else {
            return (bytesPerSec / (1024 * 1024)).toFixed(2) + " MB/s";
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
            console.warn("NetworkIndicator: pluginService not available yet, deferring load.");
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
        console.warn("NetworkIndicator: Loaded " + Object.keys(safeDays).length + " day(s) of history");

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
                total: r + t,
                rx: r,
                tx: t
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
        return { total: sum, dayCount: entries.length };
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

    // ── Update Popout Height dynamically ──
    function updatePopoutHeight() {
        if (!root.historyExpanded) {
            root.popoutHeight = root.interfaceFound ? 220 : 250;
        } else {
            root._maxDailyUsage = root.getMaxDailyUsage();
            
            // We use fixed component heights here to avoid a QML layout race condition.
            // If we read 'historyLabel.height' in the same frame that the popout expands,
            // it evaluates to 0, causing the ListView's height to become negative and disappear.
            // nonListH = historyLabel(18) + spacingS(8) + filters(32) + spacingM(12) + spacingXS(4) + totalSection(44)
            var nonListH = 118;
                           
            var entriesCount = historyModel.count;
            var listContentH = entriesCount > 0 ? (entriesCount * 36 + (entriesCount - 1) * Theme.spacingXS) : 0;
            
            // The extra 8px of padding is added here via `+ Theme.spacingS`
            // (Theme.spacingS evaluates to exactly 8px in DankMaterialShell)
            var historyH = nonListH + listContentH + Theme.spacingS;
            
            // 232 is collapsedHeight (220) + historySection.topMargin (12).
            // Without the 12px offset, historySection is 12px shorter than historyH, 
            // causing the DankListView to clip its bottom entry and show a scrollbar!
            root.popoutHeight = Math.min(232 + historyH, 600);
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
            netProcess.running = true;
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

    // ── Process: reads /proc/net/dev + operstate ──
    Process {
        id: netProcess
        command: [
            "sh", "-c",
            "cat /proc/net/dev; " +
            "for f in /sys/class/net/*/operstate; do " +
            "  iface=$(basename $(dirname $f)); " +
            "  echo \"OPSTATE:${iface}:$(cat $f)\"; " +
            "  if [ -d /sys/class/net/${iface}/wireless ]; then " +
            "    ssid=$(iwgetid -r ${iface} 2>/dev/null); " +
            "    if [ -z \"$ssid\" ] && command -v nmcli >/dev/null 2>&1; then " +
            "      ssid=$(nmcli -t -c no -f device,active,ssid dev wifi 2>/dev/null | grep \"^${iface}:yes:\" | cut -d: -f3-); " +
            "    fi; " +
            "    echo \"SSID:${iface}:${ssid}\"; " +
            "  fi; " +
            "done"
        ]
        stdout: SplitParser {
            onRead: line => {
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

                // Skip loopback and virtual interfaces, use first real interface
                if (ifaceName === "lo") return;
                if (ifaceName.startsWith("docker") || ifaceName.startsWith("br-") ||
                    ifaceName.startsWith("veth") || ifaceName.startsWith("virbr")) return;

                // Lock in this interface for the cycle
                root._foundThisCycle = true;
                root._activeIfaceThisCycle = ifaceName;
                root._activeSsidThisCycle = ""; // Reset until SSID line overrides

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
                    // Note: Gap recovery is saved when process exits (so SSID is ready)
                    return;
                }

                // ── Normal delta accumulation ──
                if (root.prevRxBytes >= 0 && root.prevTxBytes >= 0) {
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
                }

                root.prevRxBytes = rxBytes;
                root.prevTxBytes = txBytes;
                // Wait for exit to save so we have the SSID
            }
        }
        onExited: exitCode => {
            // Update interfaceFound ONLY after the full read completes (no flicker)
            root.interfaceFound = root._foundThisCycle;

            if (!root._foundThisCycle) {
                root.downloadSpeed = 0;
                root.uploadSpeed = 0;
                root.prevRxBytes = -1;
                root.prevTxBytes = -1;
            } else {
                root.currentNetworkName = root._activeSsidThisCycle || root._activeIfaceThisCycle;

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
                            historyModel.setProperty(0, "rx", r);
                            historyModel.setProperty(0, "tx", t);
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
    }

    // ── Delayed init: gives DMS time to inject pluginService ──
property int _initAttempts: 0
    property int _initLogEvery: 20
    Timer {
        id: initTimer
        interval: 500
        repeat: true
        onTriggered: {
            if (root.pluginService && !root.dataLoaded) {
                root.loadUsageData();
                if (root.dataLoaded) {
                    netProcess.running = true;
                    initTimer.running = false;
                }
                return;
            }

            if (!root.pluginService) {
                root._initAttempts++;
                if (root._initAttempts % root._initLogEvery === 0) {
                    console.warn("NetworkIndicator: waiting for pluginService (" + root._initAttempts + " attempts)");
                }
            }
        }
    }

    // ── Load persisted data and start polling ──
    Component.onCompleted: {
        if (pluginService) {
            loadUsageData();
            if (dataLoaded) {
                netProcess.running = true;
            }
        } else {
            // pluginService not injected yet — retry after a short delay
            initTimer.running = true;
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
            visible: true

            // ── Offline state: differentiate wifi_off vs disconnected ──
            DankIcon {
                visible: !root.interfaceFound
                name: "speed"
                size: root.iconSize + 3
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
                    color: root.totalSpeed > 0 ? Theme.primary : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                    weight: 700
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }

                StyledText {
                    text: root.formatSpeed(root.totalSpeed)
                    font.pixelSize: Theme.fontSizeSmall
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
                    color: root.downloadSpeed > 0 ? Theme.primary : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.downloadSpeed)
                    font.pixelSize: Theme.fontSizeSmall
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
                    color: root.uploadSpeed > 0 ? Theme.error : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.uploadSpeed)
                    font.pixelSize: Theme.fontSizeSmall
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
            visible: true

            // ── Offline state: differentiate wifi_off vs disconnected ──
            DankIcon {
                visible: !root.interfaceFound
                name: "speed"
                size: root.iconSize + 2
                color: Theme.error
                anchors.horizontalCenter: parent.horizontalCenter
                weight: 700
                filled: true

            }

            // Combined mode: single total speed
            Column {
                visible: root.interfaceFound && root.displayMode === "combined"
                spacing: 1
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "import_export"
                    size: root.iconSize
                    color: root.totalSpeed > 0 ? Theme.primary : Theme.surfaceVariantText
                    anchors.horizontalCenter: parent.horizontalCenter
                    weight: 700

                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }

                StyledText {
                    text: root.formatSpeed(root.totalSpeed)
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            // Separate mode: download ↓
            Column {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 1
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "arrow_downward"
                    size: root.iconSize
                    color: root.downloadSpeed > 0 ? Theme.primary : Theme.surfaceVariantText
                    anchors.horizontalCenter: parent.horizontalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.downloadSpeed)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            // Separate mode: upload ↑
            Column {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 1
                anchors.horizontalCenter: parent.horizontalCenter

                DankIcon {
                    name: "arrow_upward"
                    size: root.iconSize
                    color: root.uploadSpeed > 0 ? Theme.error : Theme.surfaceVariantText
                    anchors.horizontalCenter: parent.horizontalCenter
                    weight: 700
                    
                    Behavior on color {
                        ColorAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                }
                StyledText {
                    text: root.formatSpeed(root.uploadSpeed)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    // ── Popout with detailed network stats ──
    popoutContent: Component {
        PopoutComponent {
            id: popoutColumn
            showCloseButton: false
            onVisibleChanged: {
                if (visible) {
                    root.historyExpanded = false;
                    root.popoutHeight = root.interfaceFound ? 220 : 250;
                } else {
                    root.selectedNetworkFilter = "All";
                }
            }

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight - Theme.spacingXL

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
                                text: "Network Monitor"
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

                        // ── Offline banner (clickable → opens DMS Network Settings) ──
                        StyledRect {
                            visible: !root.interfaceFound
                            width: parent.width
                            height: offlineBannerCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: offlineBannerMouse.containsMouse
                                ? Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.12)
                                : Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.06)

                            Behavior on color {
                                ColorAnimation { duration: 150; easing.type: Easing.OutCubic }
                            }

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: root.offlineReason === "wifi_off" ? "wifi_off" : "signal_wifi_off"
                                    size: 28
                                    color: Theme.error
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    id: offlineBannerCol
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 28 - chevronIcon.width - Theme.spacingS * 2
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
                                    size: 20
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
                                height: 70
                                radius: Theme.cornerRadius
                                color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.2)

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 2

                                    DankIcon {
                                        name: "download"
                                        size: 24
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
                                height: 70
                                radius: Theme.cornerRadius
                                color: Qt.rgba(Theme.error.r, Theme.error.g, Theme.error.b, 0.2)

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 2

                                    DankIcon {
                                        name: "upload"
                                        size: 24
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
                        height: 70
                        radius: Theme.cornerRadius
                        color: Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, 0.5)

                        Row {
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            DankIcon {
                                name: "data_usage"
                                size: 24
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2
                                width: parent.width - 24 - Theme.spacingM - expandIcon.width - Theme.spacingM

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
                                size: 20
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
                                    filtersFlickable.contentX = 0;
                                    historyListView.positionViewAtBeginning();
                                }
                                root.updatePopoutHeight();
                            }
                        }
                    }
                } // end stickyTop Column

                // ── 30-Day History Section (anchored below sticky top) ──
                Item {
                    id: historySection
                    anchors.top: stickyTop.bottom
                    anchors.topMargin: root.historyExpanded ? Theme.spacingM : 0
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: 0
                    visible: root.historyExpanded
                    opacity: root.historyExpanded ? 1.0 : 0.0
                    clip: true

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
                        height: 32
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
                                    height: 32
                                    width: filterText.implicitWidth + Theme.spacingM * 2
                                    radius: 16
                                    color: root.selectedNetworkFilter === filterChip.name 
                                        ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.2)
                                        : Qt.rgba(Theme.surfaceVariantText.r, Theme.surfaceVariantText.g, Theme.surfaceVariantText.b, 0.1)
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
                                            root.updatePopoutHeight();
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
                            implicitWidth: 10
                            background: Item {}
                            contentItem: Rectangle {
                                implicitWidth: 8
                                radius: 25
                                color: Qt.rgba(
                                    Theme.surfaceVariantText.r,
                                    Theme.surfaceVariantText.g,
                                    Theme.surfaceVariantText.b,
                                    historyScrollBar.active ? 0.5 : 0.3
                                )

                                Behavior on color { ColorAnimation { duration: 150 } }
                            }
                        }

                        delegate: StyledRect {
                            id: historyRow
                            required property string date
                            required property string label
                            required property real total
                            required property real rx
                            required property real tx
                            required property int index
                            
                            width: historyListView.width - 13
                            height: 36
                            radius: Theme.cornerRadius / 2
                            color: historyRow.date === root.todayKey
                                ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.08)
                                : Qt.rgba(Theme.surfaceVariantText.r, Theme.surfaceVariantText.g, Theme.surfaceVariantText.b, 0.1)

                            Row {
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
                                    width: Math.max(50, implicitWidth)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                // Usage bar
                                Item {
                                    width: Math.max(0, parent.width - dateLabel.width - totalLabel.width - Theme.spacingS * 3)
                                    height: 8
                                    clip: true
                                    anchors.verticalCenter: parent.verticalCenter

                                    StyledRect {
                                        width: parent.width
                                        height: parent.height
                                        radius: 4
                                        color: Qt.rgba(Theme.surfaceVariantText.r,
                                                       Theme.surfaceVariantText.g,
                                                       Theme.surfaceVariantText.b, 0.1)
                                    }

                                    StyledRect {
                                        width: Math.max(2, parent.width * (historyRow.total / root._maxDailyUsage))
                                        height: parent.height
                                        radius: 4
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
                                    width: Math.max(65, implicitWidth)
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
                        opacity: 0
                        transform: Translate { id: totalRowTranslate; y: 8 }

                        Component.onCompleted: {
                            totalRowEntranceAnim.start();
                        }

                        SequentialAnimation {
                            id: totalRowEntranceAnim
                            PauseAnimation { duration: root.getHistoryEntries().length * 25 }
                            ParallelAnimation {
                                NumberAnimation {
                                    target: totalSection
                                    property: "opacity"
                                    from: 0; to: 1
                                    duration: 120
                                    easing.type: Easing.OutCubic
                                }
                                NumberAnimation {
                                    target: totalRowTranslate
                                    property: "y"
                                    from: 8; to: 0
                                    duration: 120
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }

                        StyledRect {
                            id: totalRow
                            y: Theme.spacingS
                            width: parent.width
                            height: 36
                            radius: Theme.cornerRadius / 2
                            color: Qt.rgba(Theme.surfaceText.r, Theme.surfaceText.g, Theme.surfaceText.b, 0.08)

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.spacingS
                                anchors.rightMargin: Theme.spacingS

                                StyledText {
                                    text: "Total"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    width: Math.max(50, implicitWidth)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Item {
                                    width: parent.width - 50 - Math.max(65, overallLabel.implicitWidth) - Theme.spacingS
                                    height: 1
                                }

                                StyledText {
                                    id: overallLabel
                                    text: root.selectedNetworkFilter ? root.formatBytes(root.getOverallUsage().total) : ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                    horizontalAlignment: Text.AlignRight
                                    width: Math.max(65, implicitWidth)
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                } // end historySection
            }
        }
    }

    popoutWidth: 325
    popoutHeight: 220

    Behavior on popoutHeight {
        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
    }
}