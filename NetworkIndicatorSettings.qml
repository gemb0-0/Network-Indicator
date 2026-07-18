pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "networkIndicator"

    property var interfaceOptions: ["Auto-detect"]
    property var interfaceValues: ["auto"]

    function refreshInterfaces() {
        ifaceProcess.running = true;
    }

    function findSettings() {
        let item = root;
        while (item) {
            if (item.saveValue !== undefined && item.loadValue !== undefined)
                return item;
            item = item.parent;
        }
        return null;
    }

    Process {
        id: ifaceProcess
        command: [
            "sh", "-c",
            "for f in /sys/class/net/*; do [ -e \"$f\" ] || continue; dev=$(basename \"$f\"); if [ -d \"$f/device\" ]; then echo \"$dev|Physical\"; else echo \"$dev|Virtual\"; fi; done"
        ]
        stdout: SplitParser {
            onRead: line => {
                var trimmed = line.trim();
                if (trimmed.length === 0) return;
                var parts = trimmed.split("|");
                if (parts.length !== 2) return;
                var dev = parts[0];
                var type = parts[1];
                if (root.interfaceValues.indexOf(dev) !== -1) return;
                var newValues = root.interfaceValues.slice();
                var newOptions = root.interfaceOptions.slice();
                newValues.push(dev);
                newOptions.push(dev + " (" + type + ")");
                root.interfaceValues = newValues;
                root.interfaceOptions = newOptions;
            }
        }
    }

    Component.onCompleted: {
        refreshInterfaces();
    }

    StyledText {
        width: parent.width
        text: "Network Indicator"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Monitor your network upload and download speeds in real time."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    SliderSetting {
        settingKey: "updateInterval"
        label: "Update Interval"
        description: "How often to poll network statistics"
        defaultValue: 2
        minimum: 1
        maximum: 10
        unit: "s"
    }

    Item {
        width: parent.width
        implicitHeight: ifaceDropdown.implicitHeight

        DankDropdown {
            id: ifaceDropdown
            anchors.left: parent.left
            anchors.right: refreshBtn.left
            anchors.rightMargin: Theme.spacingS
            text: "Interface"
            description: "Select a specific network interface to track, or let the plugin automatically detect the active connection."
            options: root.interfaceOptions
            currentValue: {
                var settings = root.findSettings();
                if (!settings) return "Auto-detect";
                var saved = settings.loadValue("preferredInterface", "auto");
                var idx = root.interfaceValues.indexOf(saved);
                return idx >= 0 ? root.interfaceOptions[idx] : "Auto-detect";
            }
            onValueChanged: newValue => {
                var idx = root.interfaceOptions.indexOf(newValue);
                var val = idx >= 0 ? root.interfaceValues[idx] : "auto";
                var settings = root.findSettings();
                if (settings) settings.saveValue("preferredInterface", val);
            }
        }

        Rectangle {
            id: refreshBtn
            implicitWidth: 36
            implicitHeight: 36
            radius: Theme.cornerRadius
            color: refreshArea.containsMouse ? Theme.primaryHoverLight : "transparent"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            DankIcon {
                id: refreshIcon
                name: "refresh"
                color: Theme.surfaceText
                anchors.centerIn: parent

                RotationAnimation on rotation {
                    id: refreshAnim
                    from: 0
                    to: 360
                    duration: 500
                    running: false
                }
            }

            MouseArea {
                id: refreshArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    root.interfaceOptions = ["Auto-detect"];
                    root.interfaceValues = ["auto"];
                    refreshAnim.running = true;
                    root.refreshInterfaces();
                }
            }
        }
    }

    SelectionSetting {
        settingKey: "displayUnit"
        label: "Display Unit"
        description: "Unit for speed display"
        options: [
            { label: "Auto (B/s → KB/s → MB/s)", value: "auto" },
            { label: "KB/s", value: "kbps" },
            { label: "MB/s", value: "mbps" }
        ]
        defaultValue: "auto"
    }

    SelectionSetting {
        settingKey: "displayMode"
        label: "Display Mode"
        description: "Show upload and download separately, or as a single combined speed"
        options: [
            { label: "Separate (↓ + ↑)", value: "separate" },
            { label: "Combined (total speed)", value: "combined" }
        ]
        defaultValue: "separate"
    }
}
