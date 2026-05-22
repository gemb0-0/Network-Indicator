import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

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

    // ── Persistent data usage tracking ──
    property var usageData: ({})        // full parsed JSON object
    property real todayRx: 0            // today's accumulated download bytes
    property real todayTx: 0            // today's accumulated upload bytes
    property string todayKey: ""        // "yyyy-MM-dd" for current day
    property bool dataLoaded: false     // whether initial JSON was loaded
    property bool firstPollAfterLoad: true // first poll needs special delta handling
    property bool historyExpanded: false // whether 30-day history panel is shown
    property real _maxDailyUsage: 1      // cached max for bar proportions (avoid O(n²))

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

        // Deep-copy days to ensure it's a mutable JS object (not a frozen QML proxy)
        var safeDays = {};
        try { safeDays = JSON.parse(JSON.stringify(days || {})); }
        catch (e) { safeDays = days || {}; }

        usageData = { lastRxBytes: lastRx, lastTxBytes: lastTx, lastInterface: lastIface, days: safeDays };
        console.warn("NetworkIndicator: Loaded " + Object.keys(safeDays).length + " day(s) of history");

        todayKey = getCurrentDateKey();
        if (usageData.days[todayKey]) {
            todayRx = usageData.days[todayKey].rx || 0;
            todayTx = usageData.days[todayKey].tx || 0;
        } else {
            todayRx = 0;
            todayTx = 0;
        }

        dataLoaded = true;
        firstPollAfterLoad = true;
    }

    // ── Persistence: save via DMS Plugin State API (auto-debounced 150ms) ──
    function saveUsageData() {
        if (!dataLoaded) return;  // Don't save until we've loaded existing data
        usageData.days[todayKey] = { rx: todayRx, tx: todayTx };
        usageData.lastRxBytes = prevRxBytes;
        usageData.lastTxBytes = prevTxBytes;
        usageData.lastInterface = _activeIfaceThisCycle || usageData.lastInterface || "";
        pruneOldDays();

        if (pluginService) {
            pluginService.savePluginState(pluginId, "days", usageData.days);
            pluginService.savePluginState(pluginId, "lastRxBytes", usageData.lastRxBytes);
            pluginService.savePluginState(pluginId, "lastTxBytes", usageData.lastTxBytes);
            pluginService.savePluginState(pluginId, "lastInterface", usageData.lastInterface);
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

    // ── Get sorted history entries (newest first) ──
    function getHistoryEntries() {
        if (!usageData || !usageData.days) return [];
        var entries = [];
        var keys = Object.keys(usageData.days);
        keys.sort().reverse();
        for (var i = 0; i < keys.length; i++) {
            var day = usageData.days[keys[i]];
            entries.push({
                date: keys[i],
                label: formatDateLabel(keys[i]),
                total: (day.rx || 0) + (day.tx || 0),
                rx: day.rx || 0,
                tx: day.tx || 0
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
                } else {
                    root.todayRx = 0;
                    root.todayTx = 0;
                }
            }

            root._foundThisCycle = false;
            root._activeIfaceThisCycle = "";
            netProcess.running = true;
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
            "done"
        ]
        stdout: SplitParser {
            onRead: line => {
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
                            root.todayRx += gapRx;
                            root.todayTx += gapTx;
                        }
                        // If negative, counter reset (reboot) — don't add gap, start fresh delta
                    }
                    root.prevRxBytes = rxBytes;
                    root.prevTxBytes = txBytes;
                    root.saveUsageData();  // Persist gap recovery immediately
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
                    if (deltaRx > 0) root.todayRx += deltaRx;
                    if (deltaTx > 0) root.todayTx += deltaTx;
                }

                root.prevRxBytes = rxBytes;
                root.prevTxBytes = txBytes;

                // Save on every poll — the state API debounces writes automatically
                root.saveUsageData();
            }
        }
        onExited: {
            // Update interfaceFound ONLY after the full read completes (no flicker)
            root.interfaceFound = root._foundThisCycle;

            if (!root._foundThisCycle) {
                root.downloadSpeed = 0;
                root.uploadSpeed = 0;
                root.prevRxBytes = -1;
                root.prevTxBytes = -1;
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
            if (pluginService && !root.dataLoaded) {
                root.loadUsageData();
                if (root.dataLoaded) {
                    netProcess.running = true;
                    initTimer.running = false;
                }
                return;
            }

            if (!pluginService) {
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

            // ── Offline state: wifi_off icon ──
            DankIcon {
                visible: !root.interfaceFound
                name: "wifi_off"
                size: root.iconSize
                color: Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }

            // ── Online state ──
            DankIcon {
                visible: root.interfaceFound && root.displayMode !== "combined"
                name: "speed"
                size: root.iconSize
                color: Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }

            DankIcon {
                visible: root.interfaceFound && root.displayMode === "combined"
                name: "import_export"
                size: root.iconSize
                color: root.totalSpeed > 0 ? Theme.primary : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }

            // Combined mode: single total speed
            Row {
                visible: root.interfaceFound && root.displayMode === "combined"
                spacing: 2
                anchors.verticalCenter: parent.verticalCenter

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

                StyledText {
                    text: "↓"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
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

                StyledText {
                    text: "↑"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                    color: Theme.error
                    anchors.verticalCenter: parent.verticalCenter
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
            spacing: Theme.spacingXS
            visible: true

            // ── Offline state: wifi_off icon ──
            DankIcon {
                visible: !root.interfaceFound
                name: "wifi_off"
                size: root.iconSize
                color: Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            // ── Online state ──
            DankIcon {
                visible: root.interfaceFound && root.displayMode !== "combined"
                name: "speed"
                size: root.iconSize
                color: Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            DankIcon {
                visible: root.interfaceFound && root.displayMode === "combined"
                name: "import_export"
                size: root.iconSize
                color: root.totalSpeed > 0 ? Theme.primary : Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            // Combined mode: single total speed
            StyledText {
                visible: root.interfaceFound && root.displayMode === "combined"
                text: root.formatSpeed(root.totalSpeed)
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            // Separate mode: download ↓
            Column {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 1
                anchors.horizontalCenter: parent.horizontalCenter

                StyledText {
                    text: "↓"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: Theme.primary
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                StyledText {
                    text: root.formatSpeed(root.downloadSpeed)
                    font.pixelSize: Theme.fontSizeXSmall
                    color: Theme.surfaceText
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            // Separate mode: upload ↑
            Column {
                visible: root.interfaceFound && root.displayMode === "separate"
                spacing: 1
                anchors.horizontalCenter: parent.horizontalCenter

                StyledText {
                    text: "↑"
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Bold
                    color: Theme.error
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                StyledText {
                    text: root.formatSpeed(root.uploadSpeed)
                    font.pixelSize: Theme.fontSizeXSmall
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
                    root.popoutHeight = 220;
                }
            }

            Item {
                width: parent.width
                implicitHeight: root.popoutHeight - Theme.spacingXL

                Flickable {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    contentHeight: popoutContentCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: popoutContentCol
                        width: parent.width
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
                                text: "No network connection"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.error
                                horizontalAlignment: Text.AlignHCenter
                                width: parent.width
                            }
                        }

                        // ── Offline banner ──
                        StyledRect {
                            visible: !root.interfaceFound
                            width: parent.width
                            height: 60
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainerHigh

                            Row {
                                anchors.centerIn: parent
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: "wifi_off"
                                    size: 24
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: "Network is offline"
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
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

                        // ── Data Used Wrapper (combines card + history to manage spacing) ──
                        Column {
                            width: parent.width
                            spacing: 0

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
                                    if (root.historyExpanded) {
                                        var entries = root.getHistoryEntries();
                                        // Cache max usage for bar proportions (avoids O(n²) in Repeater)
                                        root._maxDailyUsage = root.getMaxDailyUsage();
                                        // 196 base + header(~24) + per-row(36 + spacingXS) * count, clamped
                                        var historyH = 28 + entries.length * 40;
                                        root.popoutHeight = Math.min(220 + historyH, 560);
                                    } else {
                                        root.popoutHeight = 220;
                                    }
                                }
                            }
                        }

                        // ── 30-Day History (animated expand/collapse) ──
                        Item {
                            id: historyWrapper
                            width: parent.width
                            height: root.historyExpanded ? historyColumnInner.implicitHeight + Theme.spacingM : 0
                            clip: true
                            opacity: root.historyExpanded ? 1.0 : 0.0

                            Behavior on height {
                                NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                            }
                            Behavior on opacity {
                                NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
                            }

                            Column {
                                id: historyColumnInner
                                width: parent.width
                                y: Theme.spacingM
                                spacing: Theme.spacingXS

                                StyledText {
                                    text: "Last 30 Days"
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Bold
                                    color: Theme.surfaceVariantText
                                    bottomPadding: Theme.spacingXS
                                }

                                Repeater {
                                    model: root.historyExpanded ? root.getHistoryEntries() : []

                                    StyledRect {
                                        id: historyRow
                                        required property var modelData
                                        required property int index
                                        width: historyColumnInner.width
                                        height: 36
                                        radius: Theme.cornerRadius / 2
                                        color: modelData.date === root.todayKey
                                            ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.08)
                                            : Theme.surfaceContainerHigh

                                        // Entrance animations: fade-in + slide-up
                                        opacity: 0
                                        transform: Translate { id: rowTranslate; y: 8 }

                                        Component.onCompleted: {
                                            fadeInAnim.start();
                                            slideUpAnim.start();
                                        }

                                        NumberAnimation {
                                            id: fadeInAnim
                                            target: historyRow
                                            property: "opacity"
                                            from: 0; to: 1
                                            duration: 100
                                            easing.type: Easing.OutCubic
                                        }
                                        NumberAnimation {
                                            id: slideUpAnim
                                            target: rowTranslate
                                            property: "y"
                                            from: 8; to: 0
                                            duration: 120
                                            easing.type: Easing.OutCubic
                                        }

                                        Row {
                                            anchors.fill: parent
                                            anchors.leftMargin: Theme.spacingS
                                            anchors.rightMargin: Theme.spacingS
                                            spacing: Theme.spacingS

                                            // Date label
                                            StyledText {
                                                id: dateLabel
                                                text: modelData.date === root.todayKey ? "Today" : modelData.label
                                                font.pixelSize: Theme.fontSizeSmall
                                                font.weight: modelData.date === root.todayKey ? Font.Bold : Font.Normal
                                                color: modelData.date === root.todayKey ? Theme.primary : Theme.surfaceVariantText
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
                                                    width: Math.max(2, parent.width * (modelData.total / root._maxDailyUsage))
                                                    height: parent.height
                                                    radius: 4
                                                    color: modelData.date === root.todayKey ? Theme.primary : Theme.surfaceVariantText

                                                    Behavior on width {
                                                        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                                                    }
                                                }
                                            }

                                            // Total data label
                                            StyledText {
                                                id: totalLabel
                                                text: root.formatBytes(modelData.total)
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: modelData.date === root.todayKey ? Theme.primary : Theme.surfaceText
                                                horizontalAlignment: Text.AlignRight
                                                width: Math.max(65, implicitWidth)
                                                anchors.verticalCenter: parent.verticalCenter
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    }
                }
            }
        }
    }

    popoutWidth: 325
    popoutHeight: 220

    Behavior on popoutHeight {
        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
    }
}