pragma ComponentBehavior: Bound
import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "networkIndicator"

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
