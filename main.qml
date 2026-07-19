import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.qfield
import org.qgis
import Theme
import "qrc:/qml" as QFieldItems


Item {
    id: plugin

    // =========================================================
    // 0) CORE HOOKS / GLOBALS
    // =========================================================
    property var mainWindow: iface.mainWindow()
    property var dashBoard: iface.findItemByObjectName("dashBoard")
    property var geometryHighlighter: iface.findItemByObjectName("geometryHighlighter")
    property var positionSource: iface.findItemByObjectName("positionSource")

    property string currentTool: "none"   // none | area | linear | sheet_to_linear | management | copy_linear | deposition | runoff_point | overland_water_flow_point | note | photos_point | glossary
    property int hudBottomOffset: 100
    property int previewRefreshMs: 300
    property int drawerAutoCloseMs: 300
    property int drawerAutoCloseMsPhotos: 600    // tuned for photos

    property int dialogMaxWidth: 560
    property real dialogWidthFactor: 0.94
    property real dialogHeightFactor: 0.96
    property int dialogPadding: 14

    // Field that receives the creation date and time for every new feature.
    property string creationTimestampField: "Date"

    // Crosshair styling used by all digitizing tools, including Management.
    property color crosshairColor: "#FF3B30"
    property color crosshairCenterColor: "#202020"


    // If you add a new tool later:
    // 1) add an entry here
    // 2) add a Tool module block below with matching key
    property var toolSpecs: [
        { key: "glossary", icon: "ic_book_white_24dp" },
        { key: "management", icon: "ic_baseline-list_white_24dp" },
        { key: "area",   icon: "ic_geometry_polygon_24dp" },
        { key: "linear", icon: "ic_geometry_line_24dp" },
        { key: "copy_linear", icon: "ic_transfer_into_black_24dp" },
        { key: "sheet_to_linear", icon: "ic_camera_resolution_black_24dp" },
        { key: "deposition", icon: "ic_ring_tool_white_24dp" },
        { key: "runoff_point", icon: "ic_redo_black_24dp" },
        { key: "overland_water_flow_point", icon: "ic_opacity_black_24dp" },
        { key: "note", icon: "ic_pin_black_24dp" },
        { key: "photos_point", icon: "ic_camera_photo_black_24dp" }
    ]

    // =========================================================
    // 1) SHARED HELPERS (used by all tool-modules)
    // =========================================================
    function toast(msg) { mainWindow.displayToast(msg) }

    function switchToLayer(layerName) {
        try {
            let layers = qgisProject.mapLayersByName(layerName)
            if (!layers || layers.length === 0) return false
            dashBoard.activeLayer = layers[0]
            if (dashBoard.ensureEditableLayerSelected) dashBoard.ensureEditableLayerSelected()
            return true
        } catch (e) { return false }
    }
    function parseDecimal(text) {
        if (!text || text.trim() === "") return null

        // allow decimal comma
        let normalized = text.replace(",", ".")
        let value = Number(normalized)

        return isNaN(value) ? null : value
    }

    function layerByName(layerName) {
        try {
            let layers = qgisProject.mapLayersByName(layerName)
            if (layers && layers.length > 0) return layers[0]
        } catch (e) {}
        return null
    }

    function mapCanvasNow() {
        try { let mc = iface.mapCanvas(); if (mc) return mc } catch (e) {}
        return iface.findItemByObjectName("mapCanvas")
    }

    function centerProjected() {
        let mc = mapCanvasNow()
        if (mc && mc.center) return mc.center
        if (dashBoard && dashBoard.mapSettings && dashBoard.mapSettings.center) return dashBoard.mapSettings.center
        return null
    }

    function projectCrs() {
        let mc = mapCanvasNow()
        try { if (mc && mc.mapSettings && mc.mapSettings.destinationCrs) return mc.mapSettings.destinationCrs } catch (e) {}
        try { if (dashBoard && dashBoard.mapSettings && dashBoard.mapSettings.destinationCrs) return dashBoard.mapSettings.destinationCrs } catch (e2) {}
        return null
    }

    function gpsValid() {
        return positionSource
            && positionSource.active
            && positionSource.positionInformation
            && positionSource.positionInformation.latitudeValid
            && positionSource.positionInformation.longitudeValid
    }

    function pointFromGpsOrCenter(useCenter) {
        if (useCenter) {
            let c = centerProjected()
            if (!c) return null
            return { x: c.x, y: c.y }
        } else {
            if (!gpsValid()) return null
            let p = positionSource.projectedPosition
            return { x: p.x, y: p.y }
        }
    }


    // ---------- IDs ----------
    function pad3(n) {
        if (n < 10) return "00" + n
        if (n < 100) return "0" + n
        return "" + n
    }
    function idWithPrefix(prefix, n) { return prefix + pad3(n) } // "L001", "FL001"

    function idToInt(anyId) {
        if (!anyId) return null
        let s = ("" + anyId).trim()
        let m = s.match(/(\d+)/)
        if (!m || m.length < 2) return null
        let n = parseInt(m[1], 10)
        if (isNaN(n)) return null
        return n
    }

    // ---------- Mandatory helper ----------
    function requireFilled(val, label) {
        let s = (val || "").trim()
        if (s === "") { toast(qsTr("Please fill in %1.").arg(label)); return false }
        return true
    }

    // ---------- Geometry preview ----------
    function clearPreview() {
        if (!geometryHighlighter || !geometryHighlighter.geometryWrapper) return
        geometryHighlighter.geometryWrapper.qgsGeometry =
            GeometryUtils.createGeometryFromWkt("GEOMETRYCOLLECTION EMPTY")
    }

    function polygonWktForPreview(vertices) {
        if (!vertices || vertices.length === 0) return null
        if (vertices.length < 3) {
            let s = ""
            for (let i = 0; i < vertices.length; i++) {
                s += vertices[i].x + " " + vertices[i].y
                if (i < vertices.length - 1) s += ","
            }
            return "LINESTRING(" + s + ")"
        } else {
            let ring = ""
            for (let j = 0; j < vertices.length; j++)
                ring += vertices[j].x + " " + vertices[j].y + ","
            ring += vertices[0].x + " " + vertices[0].y
            return "POLYGON((" + ring + "))"
        }
    }

    function polygonWktFinal(vertices) {
        if (!vertices || vertices.length < 3) return null
        let ring = ""
        for (let i = 0; i < vertices.length; i++)
            ring += vertices[i].x + " " + vertices[i].y + ","
        ring += vertices[0].x + " " + vertices[0].y
        return "POLYGON((" + ring + "))"
    }

    function updatePreviewFromVertices(vertices) {
        if (!geometryHighlighter || !geometryHighlighter.geometryWrapper) return
        let wkt = polygonWktForPreview(vertices)
        if (!wkt) { clearPreview(); return }
        let geom = GeometryUtils.createGeometryFromWkt(wkt)
        if (!geom) return
        geometryHighlighter.geometryWrapper.qgsGeometry = geom
        let crs = projectCrs()
        if (crs) geometryHighlighter.geometryWrapper.crs = crs
    }

    // ---------- Creation timestamp ----------
    function applyCreationTimestamp(feature) {
        if (!feature) return false

        try {
            // QML JavaScript Date is passed to QgsFeature as a date-time value.
            // setAttribute returns false when the configured field does not exist.
            return feature.setAttribute(plugin.creationTimestampField, new Date())
        } catch (e) {
            plugin.toast(qsTr("Could not set the creation date and time."))
            return false
        }
    }

    // ---------- Drawer commit (defaults + reapply on LIVE feature) ----------
    // reapplyFn(liveFeature) is optional
    function commitViaDrawerAndHide(feature, reapplyFn) {
        let drawer = iface.findItemByObjectName("overlayFeatureFormDrawer")
        if (!drawer || !drawer.featureModel) {
            toast("Form drawer not found")
            return false
        }
        try {
            drawer.featureModel.feature = feature
            drawer.featureModel.resetAttributes(true) // apply QGIS defaults

            // Write the creation timestamp after resetting defaults.
            plugin.applyCreationTimestamp(drawer.featureModel.feature)

            if (reapplyFn) {
                try { reapplyFn(drawer.featureModel.feature) } catch (eRe) {}
            }

            drawer.state = "Add"
            drawer.open()
        } catch (e) {
            toast("Error opening the form")
            return false
        }
        closeDrawerTimer.start()
        return true
    }

    function commitEditViaDrawerAndHide(feature, reapplyFn) {
        let drawer = iface.findItemByObjectName("overlayFeatureFormDrawer")
        if (!drawer || !drawer.featureModel) {
            toast("Form drawer not found")
            return false
        }
        try {
            drawer.featureModel.feature = feature
            if (reapplyFn) {
                try { reapplyFn(drawer.featureModel.feature) } catch (eRe) {}
            }
            drawer.state = "Edit"
            drawer.open()
        } catch (e) {
            toast("Error opening the form")
            return false
        }
        closeDrawerTimer.start()
        return true
    }

    function commitViaDrawerWithDelay(feature, delayMs, afterCommitCallback) {
    overlayFeatureFormDrawer.featureModel.feature = feature
    overlayFeatureFormDrawer.featureModel.resetAttributes(true)

    // Write the creation timestamp after resetting defaults.
    plugin.applyCreationTimestamp(overlayFeatureFormDrawer.featureModel.feature)

    overlayFeatureFormDrawer.state = "Add"
    overlayFeatureFormDrawer.open()

    // Optional callback after commit
    if (afterCommitCallback) {
        overlayFeatureFormDrawer.accepted.connect(function() {
            afterCommitCallback(feature)
        })
    }

    // Delayed close
    Qt.createQmlObject(
        'import QtQuick; Timer { interval: ' + delayMs + '; running: true; repeat: false; onTriggered: overlayFeatureFormDrawer.close() }',
        overlayFeatureFormDrawer
    )
}

    Timer {
        id: closeDrawerTimer
        interval: drawerAutoCloseMs
        repeat: false
        onTriggered: {
            let drawer = iface.findItemByObjectName("overlayFeatureFormDrawer")
            if (drawer) { try { drawer.close() } catch (e) {} }
        }
    }

    // ---------- Shared bold label for button text ----------
    Component {
        id: boldBtnText
        Label {
            text: ""
            color: "white"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.bold: true
            font.pixelSize: 15
            wrapMode: Text.WordWrap
            elide: Text.ElideRight
        }
    }

    // =========================================================
    // SHARED COMPONENT: NiceComboBox (dark, scrollable, footer space)
    // =========================================================
    Component {
        id: niceComboPopup

        Popup {
            // expects: property var combo
            property var combo

            // NEW: adaptive sizing
            property int itemHeight: 52
            property int footerHeight: 80

            y: combo ? combo.height : 0
            width: combo ? combo.width : 320

            // REPLACE the old height line with this:
            height: {
                if (!combo || !combo.model) return 220

                var count = 0
                if (combo.model.length !== undefined) {
                    count = combo.model.length          // JS array model: [...]
                } else if (combo.model.count !== undefined) {
                    count = combo.model.count           // ListModel
                } else {
                    count = 8                           // fallback
                }

                var wanted = count * itemHeight + footerHeight
                var maxH = Math.min(plugin.mainWindow.height * 0.60, 460)
                var minH = itemHeight * 3 + footerHeight   // at least ~3 items visible

                return Math.max(minH, Math.min(wanted, maxH))
            }

            modal: true
            focus: true
            closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

            background: Rectangle {
                radius: 12
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ListView {
                id: lv
                anchors.fill: parent
                anchors.margins: 6
                clip: true
                model: combo ? combo.model : null

                // Keeps last item tappable (extra scroll space)
                footer: Item { width: 1; height: footerHeight }

                delegate: ItemDelegate {
                    width: lv.width
                    padding: 10

                    onClicked: {
                        if (combo) combo.currentIndex = index
                        if (combo && combo.popup) combo.popup.close()
                    }

                    contentItem: Text {
                        text: modelData
                        color: "white"
                        font.pixelSize: 14
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2      // prevents huge rows
                        elide: Text.ElideNone
                        horizontalAlignment: Text.AlignLeft
                    }
                }


                ScrollIndicator.vertical: ScrollIndicator { }
            }
        }
    }


    // =========================================================
    // 2) TOOL SWITCHING (single place)
    // =========================================================
    function deactivateAllTools() {
        toolArea.deactivate()
        toolLinear.deactivate()
        toolAreaLine.deactivate()
        toolManagement.deactivate()
        toolCopyLinear.deactivate()
        toolDeposition.deactivate()
        toolRunoffPoint.deactivate()  
        toolOverlandWaterFlowPoint.deactivate()
        toolNote.deactivate()
        toolPhotoPoint.deactivate()
        toolGlossary.deactivate()
        clearPreview()
    }

    function setTool(key) {
        if (currentTool === key) {
            deactivateAllTools()
            currentTool = "none"
            return
        }
        deactivateAllTools()
        currentTool = key

        // activate chosen tool
        if (key === "area") toolArea.activate()
        else if (key === "linear") toolLinear.activate()
        else if (key === "sheet_to_linear") toolAreaLine.activate()
        else if (key === "management") toolManagement.activate()
        else if (key === "copy_linear") toolCopyLinear.activate()
        else if (key === "deposition") toolDeposition.activate()
        else if (key === "runoff_point") toolRunoffPoint.activate()
        else if (key === "overland_water_flow_point") toolOverlandWaterFlowPoint.activate()
        else if (key === "note") toolNote.activate()
        else if (key === "photos_point") toolPhotoPoint.activate()
        else if (key === "glossary") toolGlossary.activate()
    }

    // =========================================================
    // 3) TOOLBAR BUTTON CREATION (data-driven)
    // =========================================================
    function createToolbarButton(key, iconName) {
        // We create QfToolButton dynamically so adding new tool needs only:
        // - new toolSpecs entry
        // - new Tool module block
        let qml =
            'import QtQuick\n' +
            'import org.qfield\n' +
            'import Theme\n' +
            'QfToolButton {\n' +
            '  iconSource: Theme.getThemeVectorIcon("' + iconName + '")\n' +
            '  iconColor: Theme.mainColor\n' +
            '  bgcolor: (plugin.currentTool === "' + key + '") ? Theme.gray : Theme.darkGray\n' +
            '  round: true\n' +
            '  onClicked: plugin.setTool("' + key + '")\n' +
            '}'
        let btn = Qt.createQmlObject(qml, plugin, "tb_" + key)
        iface.addItemToPluginsToolbar(btn)
    }

    Component.onCompleted: {
        for (let i = 0; i < toolSpecs.length; i++) {
            createToolbarButton(toolSpecs[i].key, toolSpecs[i].icon)
        }
        clearPreview()
    }

    // =========================================================
    // 4) SHARED CROSSHAIR (visibility controlled by modules)
    // =========================================================
    Item {
        id: crosshair
        parent: mainWindow.contentItem
        visible: toolArea.crosshairVisible || 
        toolLinear.crosshairVisible || 
        toolAreaLine.crosshairVisible ||
        toolCopyLinear.crosshairVisible || 
        toolDeposition.crosshairVisible || 
        toolRunoffPoint.crosshairVisible || 
        toolOverlandWaterFlowPoint.crosshairVisible || 
        toolNote.crosshairVisible
        anchors.centerIn: parent
        width: (toolLinear.crosshairVisible || toolAreaLine.crosshairSmall) ? 34 : 44
        height: width
        z: 60

        Rectangle {
            anchors.centerIn: parent
            width: (toolLinear.crosshairVisible || toolAreaLine.crosshairSmall) ? 22 : 30
            height: width
            radius: width / 2
            color: "transparent"
            border.width: 2
            border.color: plugin.crosshairColor
            opacity: 0.95
        }

        Rectangle {
            anchors.centerIn: parent
            width: 2
            height: (toolLinear.crosshairVisible || toolAreaLine.crosshairSmall) ? 30 : 40
            color: plugin.crosshairColor
            opacity: 0.95
        }

        Rectangle {
            anchors.centerIn: parent
            width: (toolLinear.crosshairVisible || toolAreaLine.crosshairSmall) ? 30 : 40
            height: 2
            color: plugin.crosshairColor
            opacity: 0.95
        }

        Rectangle {
            anchors.centerIn: parent
            width: (toolLinear.crosshairVisible || toolAreaLine.crosshairSmall) ? 7 : 8
            height: width
            radius: width / 2
            color: plugin.crosshairCenterColor
            border.color: plugin.crosshairColor
            border.width: 1
        }
    }

    // =========================================================
    // 5) PREVIEW TIMER (driven by modules)
    // =========================================================
    Timer {
        id: previewTimer
        interval: previewRefreshMs
        repeat: true
        running: toolArea.previewRunning || toolAreaLine.previewRunning || toolDeposition.previewRunning || toolNote.previewRunning
        onTriggered: {
            if (toolArea.previewRunning) updatePreviewFromVertices(toolArea.vertices)
            else if (toolAreaLine.previewRunning) updatePreviewFromVertices(toolAreaLine.areaVertices)
        }
    }

    // =========================================================
    // 6) TOOL MODULES
    //    Each module is self-contained:
    //    - state
    //    - HUD
    //    - dialogs
    //    - activate/deactivate
    // =========================================================

    // =========================================================
    // TOOL: AREA (Sheet Erosion)
    // =========================================================
    Item {
        id: toolArea

        // Layer / fields
        property string layerName: "Sheet_Erosion"

        // module signals
        property bool crosshairVisible: plugin.currentTool === "area"
        property bool previewRunning: plugin.currentTool === "area" && vertices.length > 0

        // state
        property var vertices: []
        property var pendingGeometry: null

        // dialog state
        property int page: 0

        function activate() {
            vertices = []
            pendingGeometry = null
            page = 0
            plugin.switchToLayer(layerName)
        }

        function deactivate() {
            if (areaDialog.opened) areaDialog.close()
            vertices = []
            pendingGeometry = null
            page = 0
        }

        // =====================================================
        // HUD
        // =====================================================
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "area"
            z: 70

            width: Math.min(parent.width * 0.78, 360)
            height: 80
            radius: 18

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 4

                Label {
                    text: qsTr("Sheet erosion")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 15
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: "+"
                        Layout.preferredWidth: 46
                        Layout.preferredHeight: 42
                        onClicked: {
                            if (!plugin.switchToLayer(toolArea.layerName)) return
                            let c = plugin.centerProjected()
                            if (!c) { plugin.toast("Map center not available"); return }
                            toolArea.vertices = toolArea.vertices.concat([{ x: c.x, y: c.y }])
                            plugin.updatePreviewFromVertices(toolArea.vertices)
                        }
                        background: Rectangle { radius: 21; color: "#000000"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 22 } }
                    }

                    Button {
                        text: "-"
                        Layout.preferredWidth: 46
                        Layout.preferredHeight: 42
                        enabled: toolArea.vertices.length > 0
                        onClicked: {
                            if (toolArea.vertices.length === 0) return
                            toolArea.vertices = toolArea.vertices.slice(0, toolArea.vertices.length - 1)
                            plugin.updatePreviewFromVertices(toolArea.vertices)
                        }
                        background: Rectangle { radius: 21; color: "#000000"; opacity: enabled ? 0.25 : 0.12; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 22 } }
                    }

                    Button {
                        text: qsTr("Create")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        enabled: toolArea.vertices.length >= 3
                        onClicked: {
                            let wkt = plugin.polygonWktFinal(toolArea.vertices)
                            let geom = GeometryUtils.createGeometryFromWkt(wkt)
                            if (!geom) { plugin.toast("Invalid polygon geometry"); return }
                            toolArea.pendingGeometry = geom

                            // reset UI defaults
                            toolArea.page = 0
                            cbAreaType.currentIndex = 0
                            tfTillage.text = ""

                            swEntire.checked = false
                            swFlow.checked = false

                            swSed.checked = false; cbSed.currentIndex = 0
                            swEin.checked = false; cbEin.currentIndex = 0
                            swZuf.checked = false; cbZuf.currentIndex = 0
                            swAbf.checked = false; cbAbf.currentIndex = 0

                            areaDialog.open()
                        }
                        background: Rectangle { radius: 14; color: "white"; opacity: enabled ? 0.25 : 0.12; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                    }
                }
            }
        }

        // =====================================================
        // Dialog
        // =====================================================
        Dialog {
            id: areaDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Record sheet erosion")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 560)

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: plugin.dialogPadding
                spacing: 4   // requested

                Label {
                    Layout.fillWidth: true
                    color: "white"
                    opacity: 0.85
                    font.pixelSize: 12
                    text: qsTr("Page %1 of 2").arg(toolArea.page + 1)
                }

                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: toolArea.page

                    // ===================== PAGE 1 =====================
                    Item {
                        ColumnLayout {
                            width: parent.width
                            spacing: 8

                            Label { text: qsTr("Type"); color: "white"; font.pixelSize: 14; font.bold: true }

                            ComboBox {
                                id: cbAreaType
                                Layout.fillWidth: true
                                model: [
                                    qsTr("Sheet erosion"),
                                    qsTr("Sheet erosion in wheel tracks"),
                                    qsTr("Sheet erosion in small parallel rills")
                                ]

                                contentItem: Text {
                                    text: cbAreaType.displayText
                                    color: "white"
                                    verticalAlignment: Text.AlignVCenter
                                    elide: Text.ElideRight
                                    font.pixelSize: 14
                                }
                                popup: niceComboPopup.createObject(cbAreaType, { combo: cbAreaType })
                            }

                            Item {
                                Layout.fillWidth: true
                                visible: cbAreaType.currentText === qsTr("Sheet erosion in wheel tracks")
                                implicitHeight: visible ? colTillage.implicitHeight : 0

                                ColumnLayout {
                                    id: colTillage
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Label { text: qsTr("Affected wheel tracks (number)"); color: "white"; font.pixelSize: 13 }
                                    TextField {
                                        id: tfTillage
                                        Layout.fillWidth: true
                                        inputMethodHints: Qt.ImhDigitsOnly
                                        placeholderText: qsTr("e.g. 3")
                                        color: "white"
                                        placeholderTextColor: "#BBBBBB"
                                    }
                                }
                            }

                            // Entire area
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Label {
                                    text: qsTr("Entire parcel affected?")
                                    color: "white"
                                    font.pixelSize: 13
                                    Layout.fillWidth: true
                                }
                                Switch { id: swEntire; checked: false }
                            }

                            // Flow_Line moved to page 1
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Label {
                                    text: qsTr("Erosion in thalweg?")
                                    color: "white"
                                    font.pixelSize: 13
                                    Layout.fillWidth: true
                                }
                                Switch { id: swFlow; checked: false }
                            }

                            Item { Layout.fillHeight: true; Layout.fillWidth: true }
                        }
                    }

                    // ===================== PAGE 2 =====================
                    Item {
                        ColumnLayout {
                            width: parent.width
                            spacing: 8

                            // Sedimentation
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Label { text: qsTr("Is sedimentation present?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                Switch { id: swSed; checked: false }
                            }
                            ComboBox {
                                id: cbSed
                                Layout.fillWidth: true
                                visible: swSed.checked
                                model: [
                                    qsTr("on adjacent parcel"),
                                    qsTr("on road"),
                                    qsTr("on structure")
                                ]
                                contentItem: Text { text: cbSed.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                popup: niceComboPopup.createObject(cbSed, { combo: cbSed })
                            }

                            // Input
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Label { text: qsTr("Is there an input?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                Switch { id: swEin; checked: false }
                            }
                            ComboBox {
                                id: cbEin
                                Layout.fillWidth: true
                                visible: swEin.checked
                                model: [
                                    qsTr("into stream"),
                                    qsTr("into ditch"),
                                    qsTr("into protected biotope")
                                ]
                                contentItem: Text { text: cbEin.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                popup: niceComboPopup.createObject(cbEin, { combo: cbEin })
                            }

                            // Inflow
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Label { text: qsTr("Is there an inflow?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                Switch { id: swZuf; checked: false }
                            }
                            ComboBox {
                                id: cbZuf
                                Layout.fillWidth: true
                                visible: swZuf.checked
                                model: [
                                    qsTr("Concentrated inflow"),
                                    qsTr("Inflow from another parcel"),
                                    qsTr("Diffuse inflow")
                                ]
                                contentItem: Text { text: cbZuf.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                popup: niceComboPopup.createObject(cbZuf, { combo: cbZuf })
                            }

                            // Outflow
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Label { text: qsTr("Is there an outflow?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                Switch { id: swAbf; checked: false }
                            }
                            ComboBox {
                                id: cbAbf
                                Layout.fillWidth: true
                                visible: swAbf.checked
                                model: [
                                    qsTr("Outflow into rills"),
                                    qsTr("Outflow into inlet shaft"),
                                    qsTr("Outflow onto shoulder"),
                                    qsTr("Other outflow")
                                ]
                                contentItem: Text { text: cbAbf.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                popup: niceComboPopup.createObject(cbAbf, { combo: cbAbf })
                            }

                            Item { Layout.fillHeight: true; Layout.fillWidth: true }
                        }
                    }
                }

                // Bottom buttons
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: (toolArea.page === 0) ? qsTr("Cancel") : qsTr("Back")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            if (toolArea.page === 0) {
                                toolArea.pendingGeometry = null
                                areaDialog.close()
                            } else {
                                toolArea.page = 0
                            }
                        }
                    }

                    Button {
                        text: (toolArea.page === 0) ? qsTr("Next") : qsTr("Save")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            if (toolArea.page === 0) {
                                // Validate page 1 before moving to page 2.
                                if (cbAreaType.currentText === qsTr("Sheet erosion in wheel tracks")) {
                                    let wheelTrackText = tfTillage.text.trim()
                                    let wheelTrackCount = parseInt(wheelTrackText, 10)

                                    if (wheelTrackText === ""
                                            || isNaN(wheelTrackCount)
                                            || wheelTrackCount < 1
                                            || String(wheelTrackCount) !== wheelTrackText) {
                                        plugin.toast(qsTr("Please enter a whole number of wheel tracks (1 or more)."))
                                        tfTillage.forceActiveFocus()
                                        return
                                    }
                                }

                                toolArea.page = 1
                                return
                            }

                            // SAVE
                            if (!toolArea.pendingGeometry) { plugin.toast("No geometry available"); return }
                            if (!plugin.switchToLayer(toolArea.layerName)) return
                            let layer = plugin.layerByName(toolArea.layerName)
                            if (!layer) { plugin.toast("Layer not available"); return }

                            let feature = FeatureUtils.createBlankFeature(layer.fields, toolArea.pendingGeometry)

                            // Type
                            feature.setAttribute("Type", cbAreaType.currentText)

                            // Wheel tracks
                            if (cbAreaType.currentText === qsTr("Sheet erosion in wheel tracks")) {
                                // Safety check in case the dialog state was changed programmatically.
                                let wheelTrackText = tfTillage.text.trim()
                                let n = parseInt(wheelTrackText, 10)
                                if (wheelTrackText === ""
                                    || isNaN(n)
                                    || n < 1
                                    || String(n) !== wheelTrackText) {
                                    plugin.toast(qsTr("Please enter a whole number of wheel tracks (1 or more)."))
                                    toolArea.page = 0
                                    tfTillage.forceActiveFocus()
                                    return
                                }
                                feature.setAttribute("Affected_Wheel_Tracks", n)
                            } else {
                                feature.setAttribute("Affected_Wheel_Tracks", null)
                            }

                            // bools
                            feature.setAttribute("Entire_Area", swEntire.checked)
                            feature.setAttribute("Thalweg", swFlow.checked)

                            // Sedimentation
                            if (!swSed.checked) {
                                feature.setAttribute("Sedimentation", "No sedimentation")
                            } else {
                                let s = cbSed.currentText
                                if (s === qsTr("on adjacent parcel")) feature.setAttribute("Sedimentation", "Sedimentation on adjacent parcel")
                                else if (s === qsTr("on road")) feature.setAttribute("Sedimentation", "Sedimentation on road")
                                else if (s === qsTr("on structure")) feature.setAttribute("Sedimentation", "Sedimentation on structure")
                                else feature.setAttribute("Sedimentation", "Sedimentation")
                            }

                            // Input
                            if (!swEin.checked) {
                                feature.setAttribute("Input", "No input")
                            } else {
                                let e = cbEin.currentText
                                if (e === qsTr("into stream")) feature.setAttribute("Input", "Input into stream")
                                else if (e === qsTr("into ditch")) feature.setAttribute("Input", "Input into ditch")
                                else if (e === qsTr("into protected biotope")) feature.setAttribute("Input", "Input into protected biotope")
                                else feature.setAttribute("Input", "Input")
                            }

                            // Inflow
                            if (!swZuf.checked) {
                                feature.setAttribute("Inflow", "No inflow")
                            } else {
                                feature.setAttribute("Inflow", cbZuf.currentText) // already full phrases
                            }

                            // Outflow
                            if (!swAbf.checked) {
                                feature.setAttribute("Outflow", "No outflow")
                            } else {
                                feature.setAttribute("Outflow", cbAbf.currentText) // already full phrases
                            }

                            areaDialog.close()
                            plugin.commitViaDrawerAndHide(feature, null)

                            toolArea.vertices = []
                            toolArea.pendingGeometry = null
                            plugin.clearPreview()
                            plugin.setTool("none")
                        }
                    }
                }
            }
        }
    }


    // =========================================================
    // TOOL: LINEAR EROSION (measurement points)
    // =========================================================
    Item {
        id: toolLinear

        property string layerName: "Linear_Erosion_Measurement_Points"

        property bool crosshairVisible: plugin.currentTool === "linear"
        property bool crosshairSmall: true  // used by shared crosshair sizing

        // state
        property int lineSeq: 1
        property string currentLineId: ""
        property int nextPointNumber: 1
        property string currentLineTypee: ""
        property bool currentLineBothTracks: false
        property bool currentLineFlow_Line: false   // NEW: saved for entire line

        property real pendingX: 0
        property real pendingY: 0

        property int step: 0
        property bool needsTypeeSelection: true

        // NEW: last point controls extra page
        property bool isLastPoint: false

        function activate() {
            plugin.switchToLayer(layerName)
        }

        function deactivate() {
            if (lin_linearDialog.opened) lin_linearDialog.close()
        }

        function ensureLineInit() {
            if (!currentLineId || currentLineId === "") {
                currentLineId = plugin.idWithPrefix("L", lineSeq)
                nextPointNumber = 1
                currentLineTypee = ""
                currentLineBothTracks = false
                currentLineFlow_Line = false
            }
        }

        function totalSteps() { return isLastPoint ? 5 : 4 }
        function pageLabel() { return qsTr("Page %1 of %2").arg(step + 1).arg(totalSteps()) }

        function requireMeasures() {
            return plugin.requireFilled(lin_tfDepth.text, qsTr("Depth (cm)"))
                && plugin.requireFilled(lin_tfTopWidth.text, qsTr("Top width (cm)"))
                && plugin.requireFilled(lin_tfBottomWidth.text, qsTr("Bottom width (cm)"))
        }

        // =====================================================
        // helpers: build strings for the final-page fields
        // =====================================================
        function sedimentationValue() {
            if (!lin_swSed.checked) return "No sedimentation"
            let s = lin_cbSed.currentText
            if (s === qsTr("on adjacent parcel")) return "Sedimentation on adjacent parcel"
            if (s === qsTr("on road")) return "Sedimentation on road"
            if (s === qsTr("on structure")) return "Sedimentation on structure"
            return "Sedimentation"
        }

        function inputValue() {
            if (!lin_swEin.checked) return "No input"
            let e = lin_cbEin.currentText
            if (e === qsTr("into stream")) return "Input into stream"
            if (e === qsTr("into ditch")) return "Input into ditch"
            if (e === qsTr("into protected biotope")) return "Input into protected biotope"
            return "Input"
        }

        function inflowValue() {
            if (!lin_swZuf.checked) return "No inflow"
            return lin_cbZuf.currentText
        }

        function outflowValue() {
            if (!lin_swAbf.checked) return "No outflow"
            return lin_cbAbf.currentText
        }

        function savePoint(withEndFields) {
            if (!plugin.switchToLayer(toolLinear.layerName)) return
            let layer = plugin.layerByName(toolLinear.layerName)
            if (!layer) { plugin.toast("Layer not available"); return }

            let geom = GeometryUtils.createGeometryFromWkt("POINT(" + toolLinear.pendingX + " " + toolLinear.pendingY + ")")
            if (!geom) { plugin.toast("Invalid geometry"); return }

            let idInt = plugin.idToInt(toolLinear.currentLineId)
            if (idInt === null) { plugin.toast("Invalid erosion line ID (e.g. L001)"); return }

            let feature = FeatureUtils.createBlankFeature(layer.fields, geom)

            feature.setAttribute("Erosion_Line_ID", idInt)
            feature.setAttribute("Type", toolLinear.currentLineTypee)

            feature.setAttribute("Depth_cm", parseDecimal(lin_tfDepth.text))
            feature.setAttribute("Top_Width_cm", parseDecimal(lin_tfTopWidth.text))
            feature.setAttribute("Bottom_Width_cm", parseDecimal(lin_tfBottomWidth.text))
            feature.setAttribute("Side wall", lin_swSide_Wall.checked ? "Curved" : "Straight")

            feature.setAttribute("Both_Wheel_Tracks", toolLinear.currentLineBothTracks)
            feature.setAttribute("Thalweg", toolLinear.currentLineFlow_Line)

            feature.setAttribute("Last_Point", toolLinear.isLastPoint)

            if (withEndFields) {
                feature.setAttribute("Sedimentation", toolLinear.sedimentationValue())
                feature.setAttribute("Input", toolLinear.inputValue())
                feature.setAttribute("Inflow", toolLinear.inflowValue())
                feature.setAttribute("Outflow", toolLinear.outflowValue())
            } else {
                feature.setAttribute("Sedimentation", null)
                feature.setAttribute("Input", null)
                feature.setAttribute("Inflow", null)
                feature.setAttribute("Outflow", null)
            }

            lin_linearDialog.close()

            plugin.commitViaDrawerAndHide(feature, function(liveFeature) {
                liveFeature.setAttribute("Erosion_Line_ID", idInt)
                liveFeature.setAttribute("Type", toolLinear.currentLineTypee)
                liveFeature.setAttribute("Both_Wheel_Tracks", toolLinear.currentLineBothTracks)
                liveFeature.setAttribute("Thalweg", toolLinear.currentLineFlow_Line)
                liveFeature.setAttribute("Last_Point", toolLinear.isLastPoint)

                if (withEndFields) {
                    liveFeature.setAttribute("Sedimentation", toolLinear.sedimentationValue())
                    liveFeature.setAttribute("Input", toolLinear.inputValue())
                    liveFeature.setAttribute("Inflow", toolLinear.inflowValue())
                    liveFeature.setAttribute("Outflow", toolLinear.outflowValue())
                }
            })

            if (toolLinear.isLastPoint) {
                toolLinear.lineSeq = toolLinear.lineSeq + 1
                toolLinear.currentLineId = ""
                toolLinear.currentLineTypee = ""
                toolLinear.currentLineBothTracks = false
                toolLinear.currentLineFlow_Line = false
                toolLinear.nextPointNumber = 1
            } else {
                toolLinear.nextPointNumber = toolLinear.nextPointNumber + 1
            }
        }

        // =====================================================
        // HUD
        // =====================================================
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "linear"
            z: 70

            width: Math.min(parent.width * 0.70, 420)
            height: 80
            radius: 18

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 4

                Label {
                    text: qsTr("Linear erosion (measurement points)")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 14
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 52
                        Button {
                            anchors.fill: parent
                            text: qsTr("Current position")
                            onClicked: {
                                if (!plugin.switchToLayer(toolLinear.layerName)) return
                                toolLinear.ensureLineInit()

                                let pt = plugin.pointFromGpsOrCenter(false)
                                if (!pt) { plugin.toast("Invalid GPS position – please check"); return }
                                toolLinear.pendingX = pt.x
                                toolLinear.pendingY = pt.y

                                lin_tfLineId.text = toolLinear.currentLineId
                                toolLinear.step = 0
                                toolLinear.needsTypeeSelection = (toolLinear.currentLineTypee === "" || toolLinear.nextPointNumber === 1)

                                lin_tfDepth.text = ""
                                lin_tfTopWidth.text = ""
                                lin_tfBottomWidth.text = ""
                                lin_swSide_Wall.checked = false

                                toolLinear.isLastPoint = false
                                lin_swLast.checked = false

                                lin_swBothTracks.checked = toolLinear.currentLineBothTracks
                                lin_swThalweg.checked = toolLinear.currentLineFlow_Line
                                if (toolLinear.needsTypeeSelection) lin_cbLineType.currentIndex = 0

                                // reset final-page controls
                                lin_swSed.checked = false; lin_cbSed.currentIndex = 0
                                lin_swEin.checked = false; lin_cbEin.currentIndex = 0
                                lin_swZuf.checked = false; lin_cbZuf.currentIndex = 0
                                lin_swAbf.checked = false; lin_cbAbf.currentIndex = 0

                                lin_linearDialog.open()
                            }
                            background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                            contentItem: Text {
                                text: qsTr("Current position")
                                color: "white"
                                font.pixelSize: 15
                                font.bold: true

                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter

                                wrapMode: Text.WordWrap
                                maximumLineCount: 2
                            }
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        Button {
                            anchors.fill: parent
                            text: qsTr("Map center")
                            onClicked: {
                                if (!plugin.switchToLayer(toolLinear.layerName)) return
                                toolLinear.ensureLineInit()

                                let pt = plugin.pointFromGpsOrCenter(true)
                                if (!pt) { plugin.toast("Map center not available"); return }
                                toolLinear.pendingX = pt.x
                                toolLinear.pendingY = pt.y

                                lin_tfLineId.text = toolLinear.currentLineId
                                toolLinear.step = 0
                                toolLinear.needsTypeeSelection = (toolLinear.currentLineTypee === "" || toolLinear.nextPointNumber === 1)

                                lin_tfDepth.text = ""
                                lin_tfTopWidth.text = ""
                                lin_tfBottomWidth.text = ""
                                lin_swSide_Wall.checked = false

                                toolLinear.isLastPoint = false
                                lin_swLast.checked = false

                                lin_swBothTracks.checked = toolLinear.currentLineBothTracks
                                lin_swThalweg.checked = toolLinear.currentLineFlow_Line
                                if (toolLinear.needsTypeeSelection) lin_cbLineType.currentIndex = 0

                                lin_swSed.checked = false; lin_cbSed.currentIndex = 0
                                lin_swEin.checked = false; lin_cbEin.currentIndex = 0
                                lin_swZuf.checked = false; lin_cbZuf.currentIndex = 0
                                lin_swAbf.checked = false; lin_cbAbf.currentIndex = 0

                                lin_linearDialog.open()
                            }
                            background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                            contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                        }
                    }
                }
            }
        }

        // =====================================================
        // Dialog
        // =====================================================
        Dialog {
            id: lin_linearDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Record linear erosion")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 590)

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.leftMargin: plugin.dialogPadding
                anchors.rightMargin: plugin.dialogPadding
                anchors.bottomMargin: plugin.dialogPadding
                anchors.topMargin: Math.max(0, plugin.dialogPadding - 12)
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    Label { text: toolLinear.pageLabel(); color: "white"; font.pixelSize: 12; opacity: 0.85 }
                    Item { Layout.fillWidth: true }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    ScrollBar.vertical.policy: ScrollBar.AsNeeded

                    contentItem: Flickable {
                        id: lin_linearFlick
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.VerticalFlick
                        contentWidth: width

                        ColumnLayout {
                            width: lin_linearFlick.width
                            spacing: 10

                            Label {
                                Layout.fillWidth: true
                                color: "white"
                                font.pixelSize: 13
                                wrapMode: Text.WordWrap
                                text: qsTr("Point %1  •  Line %2")
                                    .arg(toolLinear.nextPointNumber)
                                    .arg(lin_tfLineId.text === "" ? toolLinear.currentLineId : lin_tfLineId.text)
                            }

                            StackLayout {
                                Layout.fillWidth: true
                                currentIndex: toolLinear.step

                                // Step 0
                                Item {
                                    implicitHeight: lin_step0Col.implicitHeight
                                    ColumnLayout {
                                        id: lin_step0Col
                                        width: parent.width
                                        spacing: 10
                                        Label { text: qsTr("Erosion line"); color: "white"; font.pixelSize: 14; font.bold: true }
                                        TextField { id: lin_tfLineId; Layout.fillWidth: true; placeholderText: qsTr("e.g. L001"); color: "white"; placeholderTextColor: "#BBBBBB" }
                                    }
                                }

                                // Step 1
                                Item {
                                    implicitHeight: lin_step1Col.implicitHeight
                                    ColumnLayout {
                                        id: lin_step1Col
                                        width: parent.width
                                        spacing: 10

                                        Label {
                                            Layout.fillWidth: true
                                            color: "white"
                                            font.pixelSize: 14
                                            font.bold: true
                                            text: toolLinear.needsTypeeSelection ? qsTr("Define erosion line type") : qsTr("Type (already defined)")
                                        }

                                        ComboBox {
                                            id: lin_cbLineType
                                            Layout.fillWidth: true
                                            visible: toolLinear.needsTypeeSelection
                                            model: [
                                                qsTr("Rills"),
                                                qsTr("Gullies"),
                                                qsTr("Rills/gullies in individual tracks"),
                                                qsTr("Parallel soil removal in rills"),
                                                qsTr("Parallel soil removal in gullies")
                                            ]
                                            contentItem: Text { text: lin_cbLineType.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                            popup: niceComboPopup.createObject(lin_cbLineType, { combo: lin_cbLineType })
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            visible: toolLinear.needsTypeeSelection
                                            spacing: 10
                                            Label { text: qsTr("In both wheel tracks?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: lin_swBothTracks; checked: false }
                                        }

                                        // Flow_Line asked here; saved for entire line
                                        RowLayout {
                                            Layout.fillWidth: true
                                            visible: toolLinear.needsTypeeSelection
                                            spacing: 10
                                            Label { text: qsTr("Erosion in thalweg?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: lin_swThalweg; checked: false }
                                        }

                                        Rectangle {
                                            Layout.fillWidth: true
                                            visible: !toolLinear.needsTypeeSelection
                                            radius: 12
                                            color: "#000000"
                                            opacity: 1.0
                                            border.width: 1
                                            border.color: "white"

                                            Rectangle { anchors.fill: parent; radius: 12; color: "#000000"; opacity: 0.18 }

                                            ColumnLayout {
                                                anchors.margins: 10
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.top: parent.top
                                                spacing: 6

                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; wrapMode: Text.WordWrap; font.pixelSize: 13
                                                    text: qsTr("Point %1 of line %2").arg(toolLinear.nextPointNumber).arg(toolLinear.currentLineId) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; wrapMode: Text.WordWrap; font.pixelSize: 13
                                                    text: qsTr("Selected type: %1").arg(toolLinear.currentLineTypee) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; wrapMode: Text.WordWrap; font.pixelSize: 13
                                                    text: qsTr("In both wheel tracks: %1").arg(toolLinear.currentLineBothTracks ? qsTr("Yes") : qsTr("No")) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; wrapMode: Text.WordWrap; font.pixelSize: 13
                                                    text: qsTr("Thalweg: %1").arg(toolLinear.currentLineFlow_Line ? qsTr("Yes") : qsTr("No")) }
                                            }

                                            implicitHeight: 10 + (4 * 18) + 40
                                        }
                                    }
                                }

                                // Step 2
                                Item {
                                    implicitHeight: lin_step2Col.implicitHeight
                                    ColumnLayout {
                                        id: lin_step2Col
                                        width: parent.width
                                        spacing: 10
                                        Label { text: qsTr("Measurements"); color: "white"; font.pixelSize: 14; font.bold: true }

                                        Label { text: qsTr("Depth (cm)"); color: "white"; font.pixelSize: 13 }
                                        TextField { id: lin_tfDepth; Layout.fillWidth: true; inputMethodHints: Qt.ImhDigitsOnly; color: "white" }

                                        Label { text: qsTr("Top width (cm)"); color: "white"; font.pixelSize: 13 }
                                        TextField { id: lin_tfTopWidth; Layout.fillWidth: true; inputMethodHints: Qt.ImhDigitsOnly; color: "white" }

                                        Label { text: qsTr("Bottom width (cm)"); color: "white"; font.pixelSize: 13 }
                                        TextField { id: lin_tfBottomWidth; Layout.fillWidth: true; inputMethodHints: Qt.ImhDigitsOnly; color: "white" }

                                        Label { text: qsTr("Side Wall"); color: "white"; font.pixelSize: 13 }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10

                                            Label { text: qsTr("Straight"); color: "white"; font.pixelSize: 13; opacity: lin_swSide_Wall.checked ? 0.6 : 1.0 }

                                            Switch { id: lin_swSide_Wall; checked: false }

                                            Label { text: qsTr("Curved"); color: "white"; font.pixelSize: 13; opacity: lin_swSide_Wall.checked ? 1.0 : 0.6 }

                                            Item { Layout.fillWidth: true }
                                        }
                                    }
                                }

                                // Step 3
                                Item {
                                    implicitHeight: lin_step3Col.implicitHeight
                                    ColumnLayout {
                                        id: lin_step3Col
                                        width: parent.width
                                        spacing: 10

                                        Label { text: qsTr("Summary"); color: "white"; font.pixelSize: 14; font.bold: true }

                                        Rectangle {
                                            Layout.fillWidth: true
                                            radius: 12
                                            color: "#000000"
                                            opacity: 1.0
                                            border.width: 1
                                            border.color: "white"

                                            Rectangle { anchors.fill: parent; radius: 12; color: "#000000"; opacity: 0.18 }

                                            ColumnLayout {
                                                anchors.margins: 10
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.top: parent.top
                                                spacing: 4

                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Line: %1").arg(toolLinear.currentLineId) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Point: %1").arg(toolLinear.nextPointNumber) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Type: %1").arg(toolLinear.currentLineTypee) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("In both wheel tracks: %1").arg(toolLinear.currentLineBothTracks ? qsTr("Yes") : qsTr("No")) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Thalweg: %1").arg(toolLinear.currentLineFlow_Line ? qsTr("Yes") : qsTr("No")) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Depth: %1 cm").arg(lin_tfDepth.text) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Top width: %1 cm").arg(lin_tfTopWidth.text) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Bottom width: %1 cm").arg(lin_tfBottomWidth.text) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap
                                                    text: qsTr("Side wall: %1").arg(lin_swSide_Wall.checked ? qsTr("Curved") : qsTr("Straight")) }
                                            }

                                            implicitHeight: 10 + (9 * 18) + 40
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10
                                            Label { text: qsTr("Last point of the line?"); color: "white"; font.bold: true; font.pixelSize: 15; Layout.fillWidth: true }
                                            Switch {
                                                id: lin_swLast
                                                checked: false
                                                onCheckedChanged: toolLinear.isLastPoint = checked
                                            }
                                        }

                                        Label {
                                            Layout.fillWidth: true
                                            visible: !toolLinear.isLastPoint
                                            color: "white"
                                            opacity: 0.90
                                            wrapMode: Text.WordWrap
                                            font.pixelSize: 12
                                            text: qsTr("Press \"Next\" to save the point.")
                                        }
                                    }
                                }

                                // Step 4 (only when last point) – end-of-line questions
                                Item {
                                    implicitHeight: lin_step4Col.implicitHeight
                                    ColumnLayout {
                                        id: lin_step4Col
                                        width: parent.width
                                        spacing: 8

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10
                                            Label { text: qsTr("Is sedimentation present?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: lin_swSed; checked: false }
                                        }
                                        ComboBox {
                                            id: lin_cbSed
                                            Layout.fillWidth: true
                                            visible: lin_swSed.checked
                                            model: [ qsTr("on adjacent parcel"), qsTr("on road"), qsTr("on structure") ]
                                            contentItem: Text { text: lin_cbSed.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                            popup: niceComboPopup.createObject(lin_cbSed, { combo: lin_cbSed })
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10
                                            Label { text: qsTr("Is there an input?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: lin_swEin; checked: false }
                                        }
                                        ComboBox {
                                            id: lin_cbEin
                                            Layout.fillWidth: true
                                            visible: lin_swEin.checked
                                            model: [ qsTr("into stream"), qsTr("into ditch"), qsTr("into protected biotope") ]
                                            contentItem: Text { text: lin_cbEin.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                            popup: niceComboPopup.createObject(lin_cbEin, { combo: lin_cbEin })
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10
                                            Label { text: qsTr("Is there an inflow?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: lin_swZuf; checked: false }
                                        }
                                        ComboBox {
                                            id: lin_cbZuf
                                            Layout.fillWidth: true
                                            visible: lin_swZuf.checked
                                            model: [ qsTr("Concentrated inflow"), qsTr("Inflow from another parcel"), qsTr("Diffuse inflow") ]
                                            contentItem: Text { text: lin_cbZuf.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                            popup: niceComboPopup.createObject(lin_cbZuf, { combo: lin_cbZuf })
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10
                                            Label { text: qsTr("Is there an outflow?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: lin_swAbf; checked: false }
                                        }
                                        ComboBox {
                                            id: lin_cbAbf
                                            Layout.fillWidth: true
                                            visible: lin_swAbf.checked
                                            model: [ qsTr("Outflow into rills"), qsTr("Outflow into inlet shaft"), qsTr("Outflow onto shoulder"), qsTr("Other outflow") ]
                                            contentItem: Text { text: lin_cbAbf.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                            popup: niceComboPopup.createObject(lin_cbAbf, { combo: lin_cbAbf })
                                        }

                                        Item { Layout.fillHeight: true; Layout.fillWidth: true }
                                    }
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: qsTr("Back")
                        Layout.fillWidth: true
                        enabled: toolLinear.step > 0
                        opacity: enabled ? 1.0 : 0.4
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: toolLinear.step = Math.max(0, toolLinear.step - 1)
                    }

                    Button {
                        text: qsTr("Next")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            if (toolLinear.step === 0) {
                                let proposed = (lin_tfLineId.text || "").trim()
                                if (proposed === "") { plugin.toast("Please enter an erosion line ID"); return }
                                let n = plugin.idToInt(proposed)
                                if (n === null) { plugin.toast("Please enter a valid ID such as L001"); return }
                                toolLinear.lineSeq = n
                                proposed = plugin.idWithPrefix("L", toolLinear.lineSeq)
                                lin_tfLineId.text = proposed

                                if (proposed !== toolLinear.currentLineId) {
                                    toolLinear.currentLineId = proposed
                                    toolLinear.nextPointNumber = 1
                                    toolLinear.currentLineTypee = ""
                                    toolLinear.currentLineBothTracks = false
                                    toolLinear.currentLineFlow_Line = false
                                    toolLinear.needsTypeeSelection = true
                                    lin_cbLineType.currentIndex = 0
                                    lin_swBothTracks.checked = false
                                    lin_swThalweg.checked = false
                                }
                                toolLinear.step = 1

                            } else if (toolLinear.step === 1) {
                                if (toolLinear.needsTypeeSelection) {
                                    toolLinear.currentLineTypee = lin_cbLineType.currentText
                                    toolLinear.currentLineBothTracks = lin_swBothTracks.checked
                                    toolLinear.currentLineFlow_Line = lin_swThalweg.checked
                                }
                                if ((toolLinear.currentLineTypee || "").trim() === "") { plugin.toast("Please select a type."); return }
                                toolLinear.step = 2

                            } else if (toolLinear.step === 2) {
                                if (!toolLinear.requireMeasures()) return
                                toolLinear.step = 3

                            } else if (toolLinear.step === 3) {
                                toolLinear.isLastPoint = lin_swLast.checked
                                if (toolLinear.isLastPoint) {
                                    toolLinear.step = 4
                                    return
                                }
                                toolLinear.savePoint(false)

                            } else if (toolLinear.step === 4) {
                                toolLinear.savePoint(true)
                            }
                        }
                    }
                }
            }
        }
    }


    // =========================================================
    // TOOL: SHEET-TO-LINEAR EROSION
    // =========================================================
    Item {
        id: toolAreaLine

        // layers
        property string areaLayerName: "Sheet_To_Linear_Area"
        property string lineLayerName: "Sheet_To_Linear_Linear_Measurement_Points"

        // mode inside this tool
        property string mode: "hub"   // "hub" | "area" | "line"

        property bool crosshairVisible: plugin.currentTool === "sheet_to_linear"
        property bool crosshairSmall: (mode === "line") // small in line mode
        property bool previewRunning: plugin.currentTool === "sheet_to_linear" && mode === "area" && areaVertices.length > 0

        // area state
        property var areaVertices: []
        property var areaPendingGeometry: null

        // line state
        property int lineSeq: 1
        property string currentLineId: ""
        property int nextPointNumber: 1

        property real pendingX: 0
        property real pendingY: 0

        // dialog wizard (LINE)
        property int step: 0

        // dialog wizard (AREA)  NEW
        property int areaStep: 0            // 0 = main (Type/Number_of_Tracks/BothTracks/Thalweg), 1 = Sed/Inf/Outf
        property bool areaFlow_Line: false

        function activate() {
            mode = "hub"
        }

        function deactivate() {
            if (sheetToLinearAreaDialog.opened) sheetToLinearAreaDialog.close()
            if (sheetToLinearLineDialog.opened) sheetToLinearLineDialog.close()
            mode = "hub"
            areaVertices = []
            areaPendingGeometry = null
        }

        function ensureLineInit() {
            if (!currentLineId || currentLineId === "") {
                currentLineId = plugin.idWithPrefix("FL", lineSeq)
                nextPointNumber = 1
            }
        }

        function totalSteps() { return 3 } // Step0: ID, Step1: Measurements, Step2: Summary/Save
        function pageLabel() { return qsTr("Page %1 of %2").arg(step + 1).arg(totalSteps()) }

        function areaTotalSteps() { return 2 }
        function areaPageLabel() { return qsTr("Page %1 of %2").arg(areaStep + 1).arg(areaTotalSteps()) }

        // Side_Wall is a switch -> always has a value
        function requireMeasures() {
            return plugin.requireFilled(sheetToLinearDepthField.text, qsTr("Depth (cm)"))
                && plugin.requireFilled(sheetToLinearTopWidthField.text, qsTr("Top width (cm)"))
                && plugin.requireFilled(sheetToLinearBottomWidthField.text, qsTr("Bottom width (cm)"))
        }

        // ---- AREA helpers -> build strings like in AREA/LINEAR ----
        function sheetToLinearSedimentationValue() {
            if (!sheetToLinearAreaSedimentationSwitch.checked) return "No sedimentation"
            let s = sheetToLinearAreaSedimentationCombo.currentText
            if (s === qsTr("on adjacent parcel")) return "Sedimentation on adjacent parcel"
            if (s === qsTr("on road")) return "Sedimentation on road"
            if (s === qsTr("on structure")) return "Sedimentation on structure"
            return "Sedimentation"
        }
        function sheetToLinearInputValue() {
            if (!sheetToLinearAreaInputSwitch.checked) return "No input"
            let e = sheetToLinearAreaInputCombo.currentText
            if (e === qsTr("into stream")) return "Input into stream"
            if (e === qsTr("into ditch")) return "Input into ditch"
            if (e === qsTr("into protected biotope")) return "Input into protected biotope"
            return "Input"
        }
        function sheetToLinearInflowValue() {
            if (!sheetToLinearAreaInflowSwitch.checked) return "No inflow"
            return sheetToLinearAreaInflowCombo.currentText
        }
        function sheetToLinearOutflowValue() {
            if (!sheetToLinearAreaOutflowSwitch.checked) return "No outflow"
            return sheetToLinearAreaOutflowCombo.currentText
        }

        // HUD (hub/area/line)
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "sheet_to_linear"
            z: 70

            width: Math.min(parent.width * 0.90, 560)
            height: (toolAreaLine.mode === "hub") ? 124 : 118
            radius: 18

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 6

                Label {
                    text: toolAreaLine.mode === "area"
                            ? qsTr("Create sheet-to-linear area")
                            : (toolAreaLine.mode === "line"
                            ? qsTr("Create sheet-to-linear line")
                            : qsTr("Sheet-to-linear erosion"))
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 14
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                StackLayout {
                    Layout.fillWidth: true
                    currentIndex: (toolAreaLine.mode === "hub") ? 0 : (toolAreaLine.mode === "area" ? 1 : 2)

                    // HUB
                    Item {
                        ColumnLayout {
                            width: parent.width
                            spacing: 6

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                Item {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 42
                                    Button {
                                        anchors.fill: parent
                                        text: qsTr("New area")
                                        onClicked: {
                                            toolAreaLine.mode = "area"
                                            toolAreaLine.areaVertices = []
                                            toolAreaLine.areaPendingGeometry = null
                                            plugin.clearPreview()
                                            plugin.switchToLayer(toolAreaLine.areaLayerName)
                                        }
                                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                                    }
                                }

                                Item {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 42
                                    Button {
                                        anchors.fill: parent
                                        text: qsTr("New line")
                                        onClicked: {
                                            toolAreaLine.mode = "line"
                                            plugin.switchToLayer(toolAreaLine.lineLayerName)
                                        }
                                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                                    }
                                }
                            }

                            Label {
                                Layout.fillWidth: true
                                color: "white"
                                opacity: 0.85
                                wrapMode: Text.WordWrap
                                font.pixelSize: 12
                                text: qsTr("Note: To create measurement points for a line, a corresponding area should be created first.")
                            }
                        }
                    }

                    // AREA mode
                    Item {
                        RowLayout {
                            width: parent.width
                            spacing: 8

                            Button {
                                text: "+"
                                Layout.preferredWidth: 46
                                Layout.preferredHeight: 42
                                onClicked: {
                                    if (!plugin.switchToLayer(toolAreaLine.areaLayerName)) return
                                    let c = plugin.centerProjected()
                                    if (!c) { plugin.toast("Map center not available"); return }
                                    toolAreaLine.areaVertices = toolAreaLine.areaVertices.concat([{ x: c.x, y: c.y }])
                                    plugin.updatePreviewFromVertices(toolAreaLine.areaVertices)
                                }
                                background: Rectangle { radius: 21; color: "#000000"; opacity: 0.25; border.width: 1; border.color: "white" }
                                contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 22 } }
                            }

                            Button {
                                text: "-"
                                Layout.preferredWidth: 46
                                Layout.preferredHeight: 42
                                enabled: toolAreaLine.areaVertices.length > 0
                                onClicked: {
                                    if (toolAreaLine.areaVertices.length === 0) return
                                    toolAreaLine.areaVertices = toolAreaLine.areaVertices.slice(0, toolAreaLine.areaVertices.length - 1)
                                    plugin.updatePreviewFromVertices(toolAreaLine.areaVertices)
                                }
                                background: Rectangle { radius: 21; color: "#000000"; opacity: enabled ? 0.25 : 0.12; border.width: 1; border.color: "white" }
                                contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 22 } }
                            }

                            Button {
                                text: qsTr("Create")
                                Layout.fillWidth: true
                                Layout.preferredHeight: 42
                                enabled: toolAreaLine.areaVertices.length >= 3
                                onClicked: {
                                    let wkt = plugin.polygonWktFinal(toolAreaLine.areaVertices)
                                    let geom = GeometryUtils.createGeometryFromWkt(wkt)
                                    if (!geom) { plugin.toast("Invalid polygon geometry"); return }
                                    toolAreaLine.areaPendingGeometry = geom

                                    // reset area wizard
                                    toolAreaLine.areaStep = 0
                                    sheetToLinearAreaTypeCombo.currentIndex = 0
                                    sheetToLinearAreaLineCountField.text = ""
                                    sheetToLinearAreaBothTracksSwitch.checked = false
                                    sheetToLinearAreaThalwegSwitch.checked = false
                                    toolAreaLine.areaFlow_Line = false

                                    sheetToLinearAreaSedimentationSwitch.checked = false; sheetToLinearAreaSedimentationCombo.currentIndex = 0
                                    sheetToLinearAreaInputSwitch.checked = false; sheetToLinearAreaInputCombo.currentIndex = 0
                                    sheetToLinearAreaInflowSwitch.checked = false; sheetToLinearAreaInflowCombo.currentIndex = 0
                                    sheetToLinearAreaOutflowSwitch.checked = false; sheetToLinearAreaOutflowCombo.currentIndex = 0

                                    sheetToLinearAreaDialog.open()
                                }
                                background: Rectangle { radius: 14; color: "white"; opacity: enabled ? 0.25 : 0.12; border.width: 1; border.color: "white" }
                                contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                            }
                        }
                    }

                    // LINE mode
                    Item {
                        RowLayout {
                            width: parent.width
                            spacing: 8

                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 42
                                Button {
                                    anchors.fill: parent
                                    text: qsTr("Current position")
                                    onClicked: {
                                        if (!plugin.switchToLayer(toolAreaLine.lineLayerName)) return
                                        toolAreaLine.ensureLineInit()

                                        let pt = plugin.pointFromGpsOrCenter(false)
                                        if (!pt) { plugin.toast("Invalid GPS position – please check"); return }
                                        toolAreaLine.pendingX = pt.x
                                        toolAreaLine.pendingY = pt.y

                                        sheetToLinearLineIdField.text = toolAreaLine.currentLineId
                                        toolAreaLine.step = 0

                                        sheetToLinearDepthField.text = ""
                                        sheetToLinearTopWidthField.text = ""
                                        sheetToLinearBottomWidthField.text = ""
                                        sheetToLinearSideWallSwitch.checked = false
                                        sheetToLinearLastPointSwitch.checked = false

                                        sheetToLinearLineDialog.open()
                                    }
                                    background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                                }
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 42
                                Button {
                                    anchors.fill: parent
                                    text: qsTr("Map center")
                                    onClicked: {
                                        if (!plugin.switchToLayer(toolAreaLine.lineLayerName)) return
                                        toolAreaLine.ensureLineInit()

                                        let pt = plugin.pointFromGpsOrCenter(true)
                                        if (!pt) { plugin.toast("Map center not available"); return }
                                        toolAreaLine.pendingX = pt.x
                                        toolAreaLine.pendingY = pt.y

                                        sheetToLinearLineIdField.text = toolAreaLine.currentLineId
                                        toolAreaLine.step = 0

                                        sheetToLinearDepthField.text = ""
                                        sheetToLinearTopWidthField.text = ""
                                        sheetToLinearBottomWidthField.text = ""
                                        sheetToLinearSideWallSwitch.checked = false
                                        sheetToLinearLastPointSwitch.checked = false

                                        sheetToLinearLineDialog.open()
                                    }
                                    background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                                }
                            }
                        }
                    }
                }

                Button {
                    visible: toolAreaLine.mode !== "hub"
                    text: qsTr("Back")
                    Layout.fillWidth: true
                    Layout.preferredHeight: 34
                    onClicked: { toolAreaLine.mode = "hub"; plugin.clearPreview() }
                    background: Rectangle { radius: 12; color: "#000000"; opacity: 0.20; border.width: 1; border.color: "white" }
                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 13 } }
                }
            }
        }

        // ---------------------------------------------------------
        // Sheet-to-linear area dialog (2 pages)
        // ---------------------------------------------------------
        Dialog {
            id: sheetToLinearAreaDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Record sheet-to-linear area")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 570)

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.leftMargin: plugin.dialogPadding
                anchors.rightMargin: plugin.dialogPadding
                anchors.bottomMargin: plugin.dialogPadding
                anchors.topMargin: plugin.dialogPadding
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    Label { text: toolAreaLine.areaPageLabel(); color: "white"; font.pixelSize: 12; opacity: 0.85 }
                    Item { Layout.fillWidth: true }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    ScrollBar.vertical.policy: ScrollBar.AsNeeded

                    contentItem: Flickable {
                        id: sheetToLinearAreaFlick
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.VerticalFlick
                        contentWidth: width

                        ColumnLayout {
                            width: sheetToLinearAreaFlick.width
                            spacing: 10

                            StackLayout {
                                Layout.fillWidth: true
                                currentIndex: toolAreaLine.areaStep

                                // ===== AREA Step 0 =====
                                Item {
                                    implicitHeight: sheetToLinearAreaStepOneColumn.implicitHeight
                                    ColumnLayout {
                                        id: sheetToLinearAreaStepOneColumn
                                        width: parent.width
                                        spacing: 10

                                        Label { text: qsTr("Type"); color: "white"; font.pixelSize: 14; font.bold: true }

                                        ComboBox {
                                            id: sheetToLinearAreaTypeCombo
                                            Layout.fillWidth: true
                                            model: [
                                                qsTr("Fan-shaped oriented rills"),
                                                qsTr("Fan-shaped oriented gullies"),
                                                qsTr("Parallel rills"),
                                                qsTr("Parallel gullies")
                                            ]
                                            contentItem: Text { text: sheetToLinearAreaTypeCombo.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                            popup: niceComboPopup.createObject(sheetToLinearAreaTypeCombo, { combo: sheetToLinearAreaTypeCombo })
                                            onCurrentIndexChanged: {
                                                if (!(sheetToLinearAreaTypeCombo.currentIndex === 2 || sheetToLinearAreaTypeCombo.currentIndex === 3)) {
                                                    sheetToLinearAreaBothTracksSwitch.checked = false
                                                }
                                            }
                                        }

                                        Label { text: qsTr("Number of lines"); color: "white"; font.pixelSize: 13 }
                                        TextField {
                                            id: sheetToLinearAreaLineCountField
                                            Layout.fillWidth: true
                                            inputMethodHints: Qt.ImhDigitsOnly
                                            placeholderText: qsTr("e.g. 1")
                                            color: "white"
                                            placeholderTextColor: "#BBBBBB"
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10
                                            visible: sheetToLinearAreaTypeCombo.currentIndex === 2 || sheetToLinearAreaTypeCombo.currentIndex === 3
                                            Label { text: qsTr("In both wheel tracks?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: sheetToLinearAreaBothTracksSwitch; checked: false }
                                        }

                                        // NEW: Flow_Line on first page
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10
                                            Label { text: qsTr("Erosion in thalweg?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: sheetToLinearAreaThalwegSwitch; checked: false }
                                        }

                                        Item { Layout.fillHeight: true; Layout.fillWidth: true }
                                    }
                                }

                                // ===== AREA Step 1 =====
                                Item {
                                    implicitHeight: sheetToLinearAreaStepTwoColumn.implicitHeight
                                    ColumnLayout {
                                        id: sheetToLinearAreaStepTwoColumn
                                        width: parent.width
                                        spacing: 5


                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Label { text: qsTr("Is sedimentation present?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: sheetToLinearAreaSedimentationSwitch; checked: false }
                                        }
                                        ComboBox {
                                            id: sheetToLinearAreaSedimentationCombo
                                            Layout.fillWidth: true
                                            visible: sheetToLinearAreaSedimentationSwitch.checked
                                            model: [ qsTr("on adjacent parcel"), qsTr("on road"), qsTr("on structure") ]
                                            contentItem: Text { text: sheetToLinearAreaSedimentationCombo.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                            popup: niceComboPopup.createObject(sheetToLinearAreaSedimentationCombo, { combo: sheetToLinearAreaSedimentationCombo })
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Label { text: qsTr("Is there an input?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: sheetToLinearAreaInputSwitch; checked: false }
                                        }
                                        ComboBox {
                                            id: sheetToLinearAreaInputCombo
                                            Layout.fillWidth: true
                                            visible: sheetToLinearAreaInputSwitch.checked
                                            model: [ qsTr("into stream"), qsTr("into ditch"), qsTr("into protected biotope") ]
                                            contentItem: Text { text: sheetToLinearAreaInputCombo.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                            popup: niceComboPopup.createObject(sheetToLinearAreaInputCombo, { combo: sheetToLinearAreaInputCombo })
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Label { text: qsTr("Is there an inflow?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: sheetToLinearAreaInflowSwitch; checked: false }
                                        }
                                        ComboBox {
                                            id: sheetToLinearAreaInflowCombo
                                            Layout.fillWidth: true
                                            visible: sheetToLinearAreaInflowSwitch.checked
                                            model: [ qsTr("Concentrated inflow"), qsTr("Inflow from another parcel"), qsTr("Diffuse inflow") ]
                                            contentItem: Text { text: sheetToLinearAreaInflowCombo.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                            popup: niceComboPopup.createObject(sheetToLinearAreaInflowCombo, { combo: sheetToLinearAreaInflowCombo })
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            Label { text: qsTr("Is there an outflow?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                                            Switch { id: sheetToLinearAreaOutflowSwitch; checked: false }
                                        }
                                        ComboBox {
                                            id: sheetToLinearAreaOutflowCombo
                                            Layout.fillWidth: true
                                            visible: sheetToLinearAreaOutflowSwitch.checked
                                            model: [ qsTr("Outflow into rills"), qsTr("Outflow into inlet shaft"), qsTr("Outflow onto shoulder"), qsTr("Other outflow") ]
                                            contentItem: Text { text: sheetToLinearAreaOutflowCombo.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                            popup: niceComboPopup.createObject(sheetToLinearAreaOutflowCombo, { combo: sheetToLinearAreaOutflowCombo })
                                        }

                                        Item { Layout.fillHeight: true; Layout.fillWidth: true }
                                    }
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: qsTr("Back")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            if (toolAreaLine.areaStep === 0) {
                                toolAreaLine.areaPendingGeometry = null
                                sheetToLinearAreaDialog.close()
                            } else {
                                toolAreaLine.areaStep = 0
                            }
                        }
                    }

                    Button {
                        text: (toolAreaLine.areaStep === 0) ? qsTr("Next") : qsTr("Save")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            if (toolAreaLine.areaStep === 0) {
                                if (!toolAreaLine.areaPendingGeometry) { plugin.toast("No geometry available"); return }

                                let lineCountText = (sheetToLinearAreaLineCountField.text || "").trim()
                                if (lineCountText === "") { plugin.toast("Please enter the number of lines"); return }
                                let lineCount = parseInt(lineCountText, 10)
                                if (!lineCount || lineCount < 1) { plugin.toast("Number_of_Tracks muss >= 1 sein"); return }

                                toolAreaLine.areaFlow_Line = sheetToLinearAreaThalwegSwitch.checked
                                toolAreaLine.areaStep = 1
                                return
                            }

                            // Step 1: save
                            if (!toolAreaLine.areaPendingGeometry) { plugin.toast("No geometry available"); return }
                            if (!plugin.switchToLayer(toolAreaLine.areaLayerName)) return
                            let layer = plugin.layerByName(toolAreaLine.areaLayerName)
                            if (!layer) { plugin.toast("Layer not available"); return }

                            let feature = FeatureUtils.createBlankFeature(layer.fields, toolAreaLine.areaPendingGeometry)

                            let validatedLineCount = parseInt((sheetToLinearAreaLineCountField.text || "0"), 10)
                            let isParallel = (sheetToLinearAreaTypeCombo.currentIndex === 2 || sheetToLinearAreaTypeCombo.currentIndex === 3)

                            feature.setAttribute("Type", sheetToLinearAreaTypeCombo.currentText)
                            feature.setAttribute("Number_of_Tracks", validatedLineCount)
                            feature.setAttribute("Both_Wheel_Tracks", isParallel ? sheetToLinearAreaBothTracksSwitch.checked : false)

                            // Flow-line and end-of-line fields for the sheet-to-linear area
                            feature.setAttribute("Thalweg", toolAreaLine.areaFlow_Line)
                            feature.setAttribute("Sedimentation", toolAreaLine.sheetToLinearSedimentationValue())
                            feature.setAttribute("Input", toolAreaLine.sheetToLinearInputValue())
                            feature.setAttribute("Inflow", toolAreaLine.sheetToLinearInflowValue())
                            feature.setAttribute("Outflow", toolAreaLine.sheetToLinearOutflowValue())

                            sheetToLinearAreaDialog.close()
                            plugin.commitViaDrawerAndHide(feature, null)

                            toolAreaLine.areaVertices = []
                            toolAreaLine.areaPendingGeometry = null
                            plugin.clearPreview()

                            toolAreaLine.mode = "hub"
                        }
                    }
                }
            }
        }

        // ---------------------------------------------------------
        // Sheet-to-linear line dialog (measurement points)
        // ---------------------------------------------------------
        Dialog {
            id: sheetToLinearLineDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Record sheet-to-linear line")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 560)

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent

                anchors.leftMargin: plugin.dialogPadding
                anchors.rightMargin: plugin.dialogPadding
                anchors.bottomMargin: plugin.dialogPadding
                anchors.topMargin: Math.max(0, plugin.dialogPadding - 12)

                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    Label { text: toolAreaLine.pageLabel(); color: "white"; font.pixelSize: 12; opacity: 0.85 }
                    Item { Layout.fillWidth: true }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    ScrollBar.vertical.policy: ScrollBar.AsNeeded

                    contentItem: Flickable {
                        id: sheetToLinearFlick
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.VerticalFlick
                        contentWidth: width

                        ColumnLayout {
                            width: sheetToLinearFlick.width
                            spacing: 10

                            Label {
                                Layout.fillWidth: true
                                color: "white"
                                font.pixelSize: 13
                                wrapMode: Text.WordWrap
                                text: qsTr("Point %1  •  Line %2")
                                    .arg(toolAreaLine.nextPointNumber)
                                    .arg(sheetToLinearLineIdField.text === "" ? toolAreaLine.currentLineId : sheetToLinearLineIdField.text)
                            }

                            StackLayout {
                                Layout.fillWidth: true
                                currentIndex: toolAreaLine.step

                                // Step 0: ID
                                Item {
                                    implicitHeight: flStep0Col.implicitHeight
                                    ColumnLayout {
                                        id: flStep0Col
                                        width: parent.width
                                        spacing: 10
                                        Label { text: qsTr("Erosion line"); color: "white"; font.pixelSize: 14; font.bold: true }
                                        TextField {
                                            id: sheetToLinearLineIdField
                                            Layout.fillWidth: true
                                            placeholderText: qsTr("e.g. FL001")
                                            color: "white"
                                            placeholderTextColor: "#BBBBBB"
                                        }
                                    }
                                }

                                // Step 1: Measurements
                                Item {
                                    implicitHeight: flStep1Col.implicitHeight
                                    ColumnLayout {
                                        id: flStep1Col
                                        width: parent.width
                                        spacing: 10
                                        Label { text: qsTr("Measurements"); color: "white"; font.pixelSize: 14; font.bold: true }

                                        Label { text: qsTr("Depth (cm)"); color: "white"; font.pixelSize: 13 }
                                        TextField { id: sheetToLinearDepthField; Layout.fillWidth: true; inputMethodHints: Qt.ImhDigitsOnly; color: "white" }

                                        Label { text: qsTr("Top width (cm)"); color: "white"; font.pixelSize: 13 }
                                        TextField { id: sheetToLinearTopWidthField; Layout.fillWidth: true; inputMethodHints: Qt.ImhDigitsOnly; color: "white" }

                                        Label { text: qsTr("Bottom width (cm)"); color: "white"; font.pixelSize: 13 }
                                        TextField { id: sheetToLinearBottomWidthField; Layout.fillWidth: true; inputMethodHints: Qt.ImhDigitsOnly; color: "white" }

                                        Label { text: qsTr("Side wall"); color: "white"; font.pixelSize: 13 }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10

                                            Label { text: qsTr("Straight"); color: "white"; font.pixelSize: 13; opacity: sheetToLinearSideWallSwitch.checked ? 0.6 : 1.0 }
                                            Switch { id: sheetToLinearSideWallSwitch; checked: false }
                                            Label { text: qsTr("Curved"); color: "white"; font.pixelSize: 13; opacity: sheetToLinearSideWallSwitch.checked ? 1.0 : 0.6 }
                                            Item { Layout.fillWidth: true }
                                        }
                                    }
                                }

                                // Step 2: Summary
                                Item {
                                    implicitHeight: flStep2Col.implicitHeight
                                    ColumnLayout {
                                        id: flStep2Col
                                        width: parent.width
                                        spacing: 10

                                        Label { text: qsTr("Summary"); color: "white"; font.pixelSize: 14; font.bold: true }

                                        Rectangle {
                                            Layout.fillWidth: true
                                            radius: 12
                                            color: "#000000"
                                            opacity: 1.0
                                            border.width: 1
                                            border.color: "white"

                                            Rectangle { anchors.fill: parent; radius: 12; color: "#000000"; opacity: 0.18 }

                                            ColumnLayout {
                                                anchors.margins: 8
                                                anchors.left: parent.left
                                                anchors.right: parent.right
                                                anchors.top: parent.top
                                                spacing: 3

                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Line: %1").arg(toolAreaLine.currentLineId) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Point: %1").arg(toolAreaLine.nextPointNumber) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Depth: %1 cm").arg(sheetToLinearDepthField.text) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Top width: %1 cm").arg(sheetToLinearTopWidthField.text) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap; text: qsTr("Bottom width: %1 cm").arg(sheetToLinearBottomWidthField.text) }
                                                Label { Layout.fillWidth: true; color: "#FFFFFF"; font.pixelSize: 13; wrapMode: Text.WordWrap
                                                    text: qsTr("Side wall: %1").arg(sheetToLinearSideWallSwitch.checked ? qsTr("Curved") : qsTr("Straight")) }
                                            }

                                            implicitHeight: 3 + (6 * 18) + 28
                                        }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10
                                            Label { text: qsTr("Last point of the line?"); color: "white"; font.bold: true; font.pixelSize: 15; Layout.fillWidth: true }
                                            Switch { id: sheetToLinearLastPointSwitch; checked: false }
                                        }

                                        Label {
                                            Layout.fillWidth: true
                                            color: "white"
                                            opacity: 0.85
                                            wrapMode: Text.WordWrap
                                            font.pixelSize: 12
                                            text: qsTr("Press \"Next\" to save the point.")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: qsTr("Back")
                        Layout.fillWidth: true
                        enabled: toolAreaLine.step > 0
                        opacity: enabled ? 1.0 : 0.4
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: toolAreaLine.step = Math.max(0, toolAreaLine.step - 1)
                    }

                    Button {
                        text: qsTr("Next")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            if (toolAreaLine.step === 0) {
                                let proposed = (sheetToLinearLineIdField.text || "").trim()
                                if (proposed === "") { plugin.toast("Please enter an erosion line ID"); return }
                                let n = plugin.idToInt(proposed)
                                if (n === null) { plugin.toast("Please enter a valid ID such as FL001"); return }
                                toolAreaLine.lineSeq = n
                                proposed = plugin.idWithPrefix("FL", toolAreaLine.lineSeq)
                                sheetToLinearLineIdField.text = proposed

                                if (proposed !== toolAreaLine.currentLineId) {
                                    toolAreaLine.currentLineId = proposed
                                    toolAreaLine.nextPointNumber = 1
                                }
                                toolAreaLine.step = 1

                            } else if (toolAreaLine.step === 1) {
                                if (!toolAreaLine.requireMeasures()) return
                                toolAreaLine.step = 2

                            } else if (toolAreaLine.step === 2) {
                                if (!plugin.switchToLayer(toolAreaLine.lineLayerName)) return
                                let layer = plugin.layerByName(toolAreaLine.lineLayerName)
                                if (!layer) { plugin.toast("Layer not available"); return }

                                let geom = GeometryUtils.createGeometryFromWkt("POINT(" + toolAreaLine.pendingX + " " + toolAreaLine.pendingY + ")")
                                if (!geom) { plugin.toast("Invalid geometry"); return }

                                let idInt = plugin.idToInt(toolAreaLine.currentLineId)
                                if (idInt === null) { plugin.toast("Invalid erosion line ID (e.g. FL001)"); return }

                                let feature = FeatureUtils.createBlankFeature(layer.fields, geom)

                                feature.setAttribute("SheetToLinear_Line_ID", idInt)
                                feature.setAttribute("Depth_cm", parseDecimal(sheetToLinearDepthField.text))
                                feature.setAttribute("Top_Width_cm", parseDecimal(sheetToLinearTopWidthField.text))
                                feature.setAttribute("Bottom_Width_cm", parseDecimal(sheetToLinearBottomWidthField.text))
                                feature.setAttribute("Side wall", sheetToLinearSideWallSwitch.checked ? "Curved" : "Straight")
                                feature.setAttribute("Last_Point", sheetToLinearLastPointSwitch.checked)

                                sheetToLinearLineDialog.close()

                                plugin.commitViaDrawerAndHide(feature, function(liveFeature) {
                                    liveFeature.setAttribute("SheetToLinear_Line_ID", idInt)
                                })

                                if (sheetToLinearLastPointSwitch.checked) {
                                    toolAreaLine.lineSeq = toolAreaLine.lineSeq + 1
                                    toolAreaLine.currentLineId = ""
                                    toolAreaLine.nextPointNumber = 1
                                } else {
                                    toolAreaLine.nextPointNumber = toolAreaLine.nextPointNumber + 1
                                }

                                toolAreaLine.mode = "line"
                            }
                        }
                    }
                }
            }
        }
    }


    // =========================================================
    // TOOL MODULE: Management Point (Layer: Management)
    // - Select parcel at map center
    // - Page 3: optional photos (Photo1, Photo2)
    // - Crop-specific growth stage reference image (zoom/pan)
    // - ? button next to "Crop type" -> 2-page crop identification guide
    // - ? button next to "Cover" -> cover guide
    // - Zoom buttons (+ / −) in both image dialogs
    // - No path label at top, no reset button
    // - Page buttons are responsive (two-row header) so they never overflow
    //
    // All helper images are expected locally in:
    //   DCIM/Resources/
    //     Pea_Growth_Stages.png
    //     Maize_Growth_Stages.png
    //     Potato_Growth_Stages.png
    //     SugarBeet_Growth_Stages.png
    //     Cereals_Growth_Stages.png
    //     Rapeseed_Growth_Stages.png
    //     Crop_Identification_1.png
    //     Crop_Identification_2.png
    //     Cover_Guide.png
    // =========================================================
    Item {
        id: toolManagement

        property string layerName: "Management"

        // Field names
        property string fCrop: "crop"
        property string fManagement: "management"
        property string fGrowthStage: "growth_stage"
        property string fCover: "cover"
        property string fMulchCover: "mulch_cover"
        property string fErosion: "erosion"

        // Photo fields
        property string fPhoto1: "photo1"
        property string fPhoto2: "photo2"

        // Pending feature to commit
        property var pendingFeature: null

        // Form state
        property int page: 0
        property int growthStageValue: 0
        property int coverValue: 0
        property int mulchCoverValue: 0
        property bool erosionValue: false

        // Photo state (relative paths stored into fields)
        property string photo1Path: ""
        property string photo2Path: ""
        property int photoTarget: 0   // 1 or 2

        // Growth stage resource image state
        property string resourceRelPath: ""
        property string resourceAbsPath: ""

        // Generic help viewer state
        property var helpRelPaths: []
        property int helpPageIndex: 0
        property string helpTitle: ""

        property var cropOptions: [
            "Field grass", "Pea", "Maize", "Sweet corn", "Fodder beet", "Yellow mustard",
            "Sown meadow", "Vegetables", "Green fallow / flower fallow", "Oat", "Potato",
            "Clover", "Oil radish", "Black fallow", "Soybean", "Spring barley",
            "Spring wheat", "Winter barley", "Winter wheat", "Rapeseed",
            "Sugar beet", "Catch crop", "Other"
        ]

        property var managementOptions: [
            "Harvested", "Arable crop with undersowing", "Direct seeding",
            "Freshly emerged crop", "Fresh seedbed", "Crop developing", "Crop fully developed",
            "Harrowed", "Cultivated", "Ploughed", "Green fallow", "Black fallow",
             "Stubble fallow", "Straw mulch", "Catch crop", "Dead catch crop", "Other"
        ]

        function activate() {
            pendingFeature = null
            plugin.switchToLayer(layerName)
        }

        function deactivate() {
            pendingFeature = null
            if (managementDialog.opened) managementDialog.close()
            if (cropCameraLoader.active) cropCameraLoader.active = false
            if (resourceDialog.opened) resourceDialog.close()
            if (helpDialog.opened) helpDialog.close()
        }

        function ensureResourcesDir() {
            if (!qgisProject || !qgisProject.homePath || qgisProject.homePath === "") return false
            platformUtilities.createDir(qgisProject.homePath, "DCIM")
            platformUtilities.createDir(qgisProject.homePath, "DCIM/Resources")
            return true
        }

        function absFromRel(rel) {
            if (!qgisProject || !qgisProject.homePath || qgisProject.homePath === "") return ""
            return qgisProject.homePath + "/" + rel
        }

        function startNewPointAtCenter() {
            if (!plugin.switchToLayer(layerName)) return
            let layer = plugin.layerByName(layerName)
            if (!layer) { plugin.toast("Layer not available"); return }

            let pt = plugin.pointFromGpsOrCenter(true)
            if (!pt) { plugin.toast("Map center not available"); return }

            let geom = GeometryUtils.createGeometryFromWkt("POINT(" + pt.x + " " + pt.y + ")")
            if (!geom) { plugin.toast("Invalid geometry"); return }

            pendingFeature = FeatureUtils.createBlankFeature(layer.fields, geom)

            page = 0
            cbCrop.currentIndex = 0
            cbManagement.currentIndex = 0
            growthStageValue = 0
            tfGrowthStage.text = ""
            coverValue = 0
            mulchCoverValue = 0
            erosionValue = false
            slCover.value = 0
            slMulchCover.value = 0
            swErosion.checked = false

            photo1Path = ""
            photo2Path = ""
            photoTarget = 0

            resourceRelPath = ""
            resourceAbsPath = ""
            helpRelPaths = []
            helpPageIndex = 0
            helpTitle = ""

            managementDialog.open()
        }

        function takePhoto(which) {
            if (!pendingFeature) { plugin.toast("No point available"); return }

            if (!qgisProject || !qgisProject.homePath || qgisProject.homePath === "") {
                plugin.toast("Project path not available – photo cannot be saved")
                return
            }

            photoTarget = which
            platformUtilities.createDir(qgisProject.homePath, "DCIM")
            cropCameraLoader.active = true
        }

        function onPhotoCaptured(tmpPath) {
            if (!tmpPath || tmpPath === "") return

            if (!qgisProject || !qgisProject.homePath || qgisProject.homePath === "") {
                plugin.toast("Project path not available – photo could not be imported")
                return
            }

            let suffix = FileUtils.fileSuffix(tmpPath)
            let rel = "DCIM/Management_" + Date.now().toString() + (photoTarget === 2 ? "_2" : "_1") + "." + suffix
            let targetAbs = qgisProject.homePath + "/" + rel

            platformUtilities.createDir(qgisProject.homePath, "DCIM")
            platformUtilities.renameFile(tmpPath, targetAbs)

            if (photoTarget === 1) photo1Path = rel
            else if (photoTarget === 2) photo2Path = rel

            plugin.toast("Photo saved: " + rel)
            photoTarget = 0
        }

        function resourceImageForCrop(cropText) {
            if (!cropText) return ""

            switch (cropText) {
                case "Pea":
                    return "DCIM/Resources/Pea_Growth_Stages.png"

                case "Maize":
                case "Sweet corn":
                    return "DCIM/Resources/Maize_Growth_Stages.png"

                case "Potato":
                    return "DCIM/Resources/Potato_Growth_Stages.png"

                case "Sugar beet":
                    return "DCIM/Resources/SugarBeet_Growth_Stages.png"

                case "Oat":
                case "Spring barley":
                case "Winter barley":
                case "Spring wheat":
                case "Winter wheat":
                    return "DCIM/Resources/Cereals_Growth_Stages.png"

                case "Rapeseed":
                    return "DCIM/Resources/Rapeseed_Growth_Stages.png"

                default:
                    return ""
            }
        }

        function openResourcesForCurrentCrop() {
            if (!ensureResourcesDir()) { plugin.toast("Project path not available"); return }

            let rel = resourceImageForCrop(cbCrop.currentText)
            if (!rel || rel === "") { plugin.toast("No resources for this crop type"); return }

            resourceRelPath = rel
            resourceAbsPath = absFromRel(rel)
            resourceDialog.open()
        }

        function openCropIdentificationHelp() {
            if (!ensureResourcesDir()) { plugin.toast("Project path not available"); return }
            helpTitle = "Crop identification"
            helpRelPaths = [
                "DCIM/Resources/Crop_Identification_1.png",
                "DCIM/Resources/Crop_Identification_2.png"
            ]
            helpPageIndex = 0
            helpDialog.open()
        }

        function openCoverGuideHelp() {
            if (!ensureResourcesDir()) { plugin.toast("Project path not available"); return }
            helpTitle = "Cover guide"
            helpRelPaths = [
                "DCIM/Resources/Cover_Guide.png"
            ]
            helpPageIndex = 0
            helpDialog.open()
        }

        Item {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "management"
            z: 60
            anchors.fill: parent

            Rectangle {
                width: 38
                height: 38
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                radius: 8
                color: "transparent"
                border.width: 2
                border.color: plugin.crosshairColor
                opacity: 0.95

                Rectangle { width: 10; height: 2; color: plugin.crosshairColor; anchors.left: parent.left; anchors.top: parent.top; anchors.leftMargin: 2; anchors.topMargin: 6 }
                Rectangle { width: 2; height: 10; color: plugin.crosshairColor; anchors.left: parent.left; anchors.top: parent.top; anchors.leftMargin: 6; anchors.topMargin: 2 }

                Rectangle { width: 10; height: 2; color: plugin.crosshairColor; anchors.right: parent.right; anchors.top: parent.top; anchors.rightMargin: 2; anchors.topMargin: 6 }
                Rectangle { width: 2; height: 10; color: plugin.crosshairColor; anchors.right: parent.right; anchors.top: parent.top; anchors.rightMargin: 6; anchors.topMargin: 2 }

                Rectangle { width: 10; height: 2; color: plugin.crosshairColor; anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.leftMargin: 2; anchors.bottomMargin: 6 }
                Rectangle { width: 2; height: 10; color: plugin.crosshairColor; anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.leftMargin: 6; anchors.bottomMargin: 2 }

                Rectangle { width: 10; height: 2; color: plugin.crosshairColor; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.rightMargin: 2; anchors.bottomMargin: 6 }
                Rectangle { width: 2; height: 10; color: plugin.crosshairColor; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.rightMargin: 6; anchors.bottomMargin: 2 }
            }
        }

        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "management"
            z: 70

            width: Math.min(parent.width * 0.90, 560)
            height: 114
            radius: 18

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 6

                Label {
                    text: qsTr("Record management")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 14
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                Button {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 44
                    onClicked: toolManagement.startNewPointAtCenter()
                    background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }

                    contentItem: Item {
                        anchors.fill: parent

                        Rectangle {
                            width: 22
                            height: 22
                            radius: 6
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            color: "transparent"
                            border.width: 2
                            border.color: plugin.crosshairColor
                            opacity: 0.95

                            Rectangle { width: 6; height: 2; color: plugin.crosshairColor; anchors.left: parent.left; anchors.top: parent.top; anchors.leftMargin: 2; anchors.topMargin: 4 }
                            Rectangle { width: 2; height: 6; color: plugin.crosshairColor; anchors.left: parent.left; anchors.top: parent.top; anchors.leftMargin: 4; anchors.topMargin: 2 }

                            Rectangle { width: 6; height: 2; color: plugin.crosshairColor; anchors.right: parent.right; anchors.top: parent.top; anchors.rightMargin: 2; anchors.topMargin: 4 }
                            Rectangle { width: 2; height: 6; color: plugin.crosshairColor; anchors.right: parent.right; anchors.top: parent.top; anchors.rightMargin: 4; anchors.topMargin: 2 }

                            Rectangle { width: 6; height: 2; color: plugin.crosshairColor; anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.leftMargin: 2; anchors.bottomMargin: 4 }
                            Rectangle { width: 2; height: 6; color: plugin.crosshairColor; anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.leftMargin: 4; anchors.bottomMargin: 2 }

                            Rectangle { width: 6; height: 2; color: plugin.crosshairColor; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.rightMargin: 2; anchors.bottomMargin: 4 }
                            Rectangle { width: 2; height: 6; color: plugin.crosshairColor; anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.rightMargin: 4; anchors.bottomMargin: 2 }
                        }

                        Text {
                            anchors.centerIn: parent
                            text: qsTr("Select parcel")
                            color: "white"
                            font.pixelSize: 15
                            font.bold: true
                            elide: Text.ElideRight
                        }
                    }
                }

                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    color: "white"
                    opacity: 0.85
                    font.pixelSize: 12
                    text: qsTr("Note: Drag the target frame over the corresponding parcel.")
                }
            }
        }

        Loader {
            id: cropCameraLoader
            active: false
            sourceComponent: Component {
                QFieldItems.QFieldCamera {
                    id: qfieldCamera
                    visible: false
                    Component.onCompleted: open()

                    onFinished: (path) => { close(); toolManagement.onPhotoCaptured(path) }
                    onCanceled: { close() }
                    onClosed: { cropCameraLoader.active = false }
                }
            }
        }

        Dialog {
            id: resourceDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Resources – growth stages")
            standardButtons: Dialog.Close

            anchors.centerIn: parent
            width: Math.min(parent.width * 0.95, 720)
            height: Math.min(parent.height * 0.85, 720)

            property real zoom: 1.0
            property real zoomMin: 1.0
            property real zoomMax: 4.0
            property real zoomStep: 0.25
            onOpened: zoom = 1.0

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 2
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Item { Layout.fillWidth: true }

                    Button {
                        text: qsTr("−")
                        Layout.preferredWidth: 52
                        enabled: resourceDialog.zoom > resourceDialog.zoomMin
                        opacity: enabled ? 1.0 : 0.35
                        onClicked: resourceDialog.zoom =
                            Math.max(resourceDialog.zoomMin, resourceDialog.zoom - resourceDialog.zoomStep)
                    }
                    Button {
                        text: qsTr("+")
                        Layout.preferredWidth: 52
                        enabled: resourceDialog.zoom < resourceDialog.zoomMax
                        opacity: enabled ? 1.0 : 0.35
                        onClicked: resourceDialog.zoom =
                            Math.min(resourceDialog.zoomMax, resourceDialog.zoom + resourceDialog.zoomStep)
                    }
                }

                Flickable {
                    id: stageFlick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    contentWidth: Math.max(width, stageImg.paintedWidth * resourceDialog.zoom)
                    contentHeight: Math.max(height, stageImg.paintedHeight * resourceDialog.zoom)

                    PinchArea {
                        anchors.fill: parent
                        pinch.minimumScale: resourceDialog.zoomMin
                        pinch.maximumScale: resourceDialog.zoomMax
                        onPinchUpdated: resourceDialog.zoom =
                            Math.max(resourceDialog.zoomMin, Math.min(resourceDialog.zoomMax, pinch.scale))

                        Image {
                            id: stageImg
                            source: toolManagement.resourceAbsPath
                            asynchronous: true
                            cache: true
                            fillMode: Image.PreserveAspectFit
                            width: stageFlick.width * resourceDialog.zoom
                            height: stageFlick.height * resourceDialog.zoom
                            onStatusChanged: {
                                if (status === Image.Error) plugin.toast("Image could not be loaded. Check naming conventions")
                            }
                        }
                    }
                }
            }
        }

        Dialog {
            id: helpDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: (toolManagement.helpTitle && toolManagement.helpTitle !== "") ? toolManagement.helpTitle : qsTr("Resources")
            standardButtons: Dialog.Close

            anchors.centerIn: parent
            width: Math.min(parent.width * 0.95, 720)
            height: Math.min(parent.height * 0.85, 720)

            property real zoom: 1.0
            property real zoomMin: 1.0
            property real zoomMax: 5.0
            property real zoomStep: 0.5
            onOpened: zoom = 1.0

            function currentRel() {
                if (!toolManagement.helpRelPaths || toolManagement.helpRelPaths.length === 0) return ""
                return toolManagement.helpRelPaths[Math.max(0, Math.min(toolManagement.helpRelPaths.length - 1, toolManagement.helpPageIndex))]
            }
            function currentAbs() {
                let rel = currentRel()
                if (!rel || rel === "") return ""
                return toolManagement.absFromRel(rel)
            }

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 2
                spacing: 8

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Item { Layout.fillWidth: true }

                        Button {
                            text: qsTr("Page 1")
                            visible: toolManagement.helpRelPaths.length > 1
                            enabled: toolManagement.helpPageIndex !== 0
                            opacity: enabled ? 1.0 : 0.35
                            onClicked: { toolManagement.helpPageIndex = 0; helpDialog.zoom = 1.0 }
                        }
                        Button {
                            text: qsTr("Page 2")
                            visible: toolManagement.helpRelPaths.length > 1
                            enabled: toolManagement.helpPageIndex !== 1
                            opacity: enabled ? 1.0 : 0.35
                            onClicked: { toolManagement.helpPageIndex = 1; helpDialog.zoom = 1.0 }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Item { Layout.fillWidth: true }

                        Button {
                            text: qsTr("−")
                            Layout.preferredWidth: 52
                            enabled: helpDialog.zoom > helpDialog.zoomMin
                            opacity: enabled ? 1.0 : 0.35
                            onClicked: helpDialog.zoom = Math.max(helpDialog.zoomMin, helpDialog.zoom - helpDialog.zoomStep)
                        }
                        Button {
                            text: qsTr("+")
                            Layout.preferredWidth: 52
                            enabled: helpDialog.zoom < helpDialog.zoomMax
                            opacity: enabled ? 1.0 : 0.35
                            onClicked: helpDialog.zoom = Math.min(helpDialog.zoomMax, helpDialog.zoom + helpDialog.zoomStep)
                        }
                    }
                }

                Flickable {
                    id: helpFlick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    contentWidth: Math.max(width, helpImg.paintedWidth * helpDialog.zoom)
                    contentHeight: Math.max(height, helpImg.paintedHeight * helpDialog.zoom)

                    PinchArea {
                        anchors.fill: parent
                        pinch.minimumScale: helpDialog.zoomMin
                        pinch.maximumScale: helpDialog.zoomMax
                        onPinchUpdated: helpDialog.zoom =
                            Math.max(helpDialog.zoomMin, Math.min(helpDialog.zoomMax, pinch.scale))

                        Image {
                            id: helpImg
                            source: helpDialog.currentAbs()
                            asynchronous: true
                            cache: true
                            fillMode: Image.PreserveAspectFit
                            width: helpFlick.width * helpDialog.zoom
                            height: helpFlick.height * helpDialog.zoom
                            onStatusChanged: {
                                if (status === Image.Error) plugin.toast("Image could not be loaded.")
                            }
                        }
                    }
                }
            }
        }

        Dialog {
            id: managementDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Management")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 540)

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: plugin.dialogPadding
                spacing: 10

                Label {
                    Layout.fillWidth: true
                    color: "white"
                    opacity: 0.85
                    font.pixelSize: 12
                    text: qsTr("Page %1 of 3").arg(toolManagement.page + 1)
                }

                StackLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: toolManagement.page

                    Item {
                        ColumnLayout {
                            width: parent.width
                            spacing: 10

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Label {
                                    text: qsTr("Crop type")
                                    color: "white"
                                    font.pixelSize: 14
                                    font.bold: true
                                    Layout.fillWidth: true
                                }
                                Button {
                                    text: "?"
                                    Layout.preferredWidth: 38
                                    Layout.preferredHeight: 34
                                    onClicked: toolManagement.openCropIdentificationHelp()
                                    background: Rectangle { radius: 10; color: "white"; opacity: 0.20; border.width: 1; border.color: "white" }
                                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                                }
                            }

                            ComboBox {
                                id: cbCrop
                                Layout.fillWidth: true
                                model: toolManagement.cropOptions
                                contentItem: Text { text: cbCrop.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                popup: niceComboPopup.createObject(cbCrop, { combo: cbCrop })
                            }

                            Label { text: qsTr("Management"); color: "white"; font.pixelSize: 14; font.bold: true }

                            ComboBox {
                                id: cbManagement
                                Layout.fillWidth: true
                                model: toolManagement.managementOptions
                                contentItem: Text { text: cbManagement.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                                popup: niceComboPopup.createObject(cbManagement, { combo: cbManagement })
                            }

                            Label { text: qsTr("Growth stage"); color: "white"; font.pixelSize: 14; font.bold: true }

                            TextField {
                                id: tfGrowthStage
                                Layout.fillWidth: true
                                inputMethodHints: Qt.ImhDigitsOnly
                                placeholderText: qsTr("Enter a number (1–99)")
                                color: "white"
                                placeholderTextColor: "#BBBBBB"
                                onTextChanged: {
                                    let n = parseInt(text)
                                    if (isNaN(n)) n = 0
                                    toolManagement.growthStageValue = n
                                }
                            }

                            Button {
                                Layout.fillWidth: true
                                visible: toolManagement.resourceImageForCrop(cbCrop.currentText) !== ""
                                text: qsTr("Show growth stages")
                                background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                                contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 14 } }
                                onClicked: toolManagement.openResourcesForCurrentCrop()
                            }

                            Item { Layout.fillHeight: true; Layout.fillWidth: true }
                        }
                    }

                    Item {
                        ColumnLayout {
                            width: parent.width
                            spacing: 10

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Label {
                                    text: qsTr("Cover")
                                    color: "white"
                                    font.pixelSize: 14
                                    font.bold: true
                                    Layout.fillWidth: true
                                }
                                Button {
                                    text: "?"
                                    Layout.preferredWidth: 38
                                    Layout.preferredHeight: 34
                                    onClicked: toolManagement.openCoverGuideHelp()
                                    background: Rectangle { radius: 10; color: "white"; opacity: 0.20; border.width: 1; border.color: "white" }
                                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Slider {
                                    id: slCover
                                    Layout.fillWidth: true
                                    from: 0; to: 100
                                    stepSize: 10
                                    value: 0
                                    onValueChanged: toolManagement.coverValue = Math.round(value / 10) * 10
                                }
                                Label { color: "white"; font.pixelSize: 14; text: toolManagement.coverValue + "%" }
                            }

                            Label { text: qsTr("Mulch cover"); color: "white"; font.pixelSize: 14; font.bold: true }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Slider {
                                    id: slMulchCover
                                    Layout.fillWidth: true
                                    from: 0; to: 100
                                    stepSize: 10
                                    value: 0
                                    onValueChanged: toolManagement.mulchCoverValue = Math.round(value / 10) * 10
                                }
                                Label { color: "white"; font.pixelSize: 14; text: toolManagement.mulchCoverValue + "%" }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10

                                Label {
                                    color: "white"
                                    font.pixelSize: 14
                                    font.bold: true
                                    text: qsTr("Erosion present?")
                                    Layout.fillWidth: true
                                }

                                Label { color: "white"; opacity: 0.9; font.pixelSize: 13; text: qsTr("No") }

                                Switch {
                                    id: swErosion
                                    checked: false
                                    onCheckedChanged: toolManagement.erosionValue = checked
                                }

                                Label { color: "white"; opacity: 0.9; font.pixelSize: 13; text: qsTr("Yes") }
                            }

                            Item { Layout.fillHeight: true; Layout.fillWidth: true }
                        }
                    }

                    Item {
                        ColumnLayout {
                            width: parent.width
                            spacing: 10

                            Label { text: qsTr("Photo documentation (optional)"); color: "white"; font.pixelSize: 14; font.bold: true }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Button {
                                    text: (toolManagement.photo1Path && toolManagement.photo1Path !== "") ? qsTr("Replace photo 1") : qsTr("Take photo 1")
                                    Layout.fillWidth: true
                                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                                    onClicked: toolManagement.takePhoto(1)
                                }
                                Label { text: (toolManagement.photo1Path && toolManagement.photo1Path !== "") ? qsTr("Available") : qsTr("—"); color: "white"; opacity: 0.85; font.pixelSize: 12 }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8
                                Button {
                                    text: (toolManagement.photo2Path && toolManagement.photo2Path !== "") ? qsTr("Replace photo 2") : qsTr("Take photo 2")
                                    Layout.fillWidth: true
                                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                                    onClicked: toolManagement.takePhoto(2)
                                }
                                Label { text: (toolManagement.photo2Path && toolManagement.photo2Path !== "") ? qsTr("Available") : qsTr("—"); color: "white"; opacity: 0.85; font.pixelSize: 12 }
                            }

                            Item { Layout.fillHeight: true; Layout.fillWidth: true }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: qsTr("Back")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            if (toolManagement.page === 0) {
                                toolManagement.pendingFeature = null
                                managementDialog.close()
                            } else {
                                toolManagement.page = toolManagement.page - 1
                            }
                        }
                    }

                    Button {
                        text: (toolManagement.page < 2) ? qsTr("Next") : qsTr("Save")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            if (toolManagement.page < 2) {
                                toolManagement.page = toolManagement.page + 1
                                return
                            }

                            if (!toolManagement.pendingFeature) { plugin.toast("No point available"); managementDialog.close(); return }

                            let cropVal = cbCrop.currentText
                            let managementVal = cbManagement.currentText
                            let growthStageVal = toolManagement.growthStageValue
                            let coverVal = toolManagement.coverValue
                            let mulchCoverVal = toolManagement.mulchCoverValue
                            let erosionVal = toolManagement.erosionValue

                            let photo1Val = toolManagement.photo1Path
                            let photo2Val = toolManagement.photo2Path

                            toolManagement.pendingFeature.setAttribute(toolManagement.fCrop, cropVal)
                            toolManagement.pendingFeature.setAttribute(toolManagement.fManagement, managementVal)
                            toolManagement.pendingFeature.setAttribute(toolManagement.fGrowthStage, growthStageVal)
                            toolManagement.pendingFeature.setAttribute(toolManagement.fCover, coverVal)
                            toolManagement.pendingFeature.setAttribute(toolManagement.fMulchCover, mulchCoverVal)
                            toolManagement.pendingFeature.setAttribute(toolManagement.fErosion, erosionVal)
                            toolManagement.pendingFeature.setAttribute(toolManagement.fPhoto1, photo1Val)
                            toolManagement.pendingFeature.setAttribute(toolManagement.fPhoto2, photo2Val)

                            let f = toolManagement.pendingFeature
                            toolManagement.pendingFeature = null
                            managementDialog.close()

                            plugin.commitViaDrawerAndHide(f, function(liveFeature) {
                                liveFeature.setAttribute(toolManagement.fCrop, cropVal)
                                liveFeature.setAttribute(toolManagement.fManagement, managementVal)
                                liveFeature.setAttribute(toolManagement.fGrowthStage, growthStageVal)
                                liveFeature.setAttribute(toolManagement.fCover, coverVal)
                                liveFeature.setAttribute(toolManagement.fMulchCover, mulchCoverVal)
                                liveFeature.setAttribute(toolManagement.fErosion, erosionVal)
                                liveFeature.setAttribute(toolManagement.fPhoto1, photo1Val)
                                liveFeature.setAttribute(toolManagement.fPhoto2, photo2Val)
                            })

                            Qt.createQmlObject(
                                'import QtQuick; Timer { interval: ' + plugin.drawerAutoCloseMsPhotos + '; running: true; repeat: false; onTriggered: { if (overlayFeatureFormDrawer && overlayFeatureFormDrawer.opened) overlayFeatureFormDrawer.close() } }',
                                plugin
                            )
                            plugin.toast(qsTr("Management saved"))
                        }
                    }
                }
            }
        }
    } // END toolManagement

    // =========================================================
    // TOOL: COPY LINEAR – choose ID -> start point (commit) -> end point (form) -> commit
    // =========================================================
    Item {
        id: toolCopyLinear

        property string layerName: "Copy_Linear"

        property bool crosshairVisible: plugin.currentTool === "copy_linear"
        property bool crosshairSmall: true

        property string selectedLineId: ""
        property int step: 0   // 0 = choose ID, 1 = start, 2 = end

        // NEW: pending end-point geometry (commit only after form)
        property var pendingEndGeometry: null
        property real pendingEndX: 0
        property real pendingEndY: 0

        // ---------------- lifecycle ----------------
        function activate() {
            plugin.switchToLayer(layerName)
            step = (selectedLineId !== "") ? 1 : 0
        }

        function deactivate() {
            if (copyLinearDialog.opened) copyLinearDialog.close()
            if (copyLinearPostDialog.opened) copyLinearPostDialog.close()
            pendingEndGeometry = null
        }

        // ---------------- ID handling ----------------
        function setLineIdFromText(txt) {
            let t = (txt || "").trim()
            if (t === "") { plugin.toast("Please enter an erosion line ID."); return false }

            // allow digits only → L001
            if (/^\d+$/.test(t)) t = plugin.idWithPrefix("L", parseInt(t, 10))

            let idInt = plugin.idToInt(t)
            if (idInt === null) { plugin.toast("Please enter a valid ID such as L001."); return false }

            selectedLineId = plugin.idWithPrefix("L", idInt)
            step = 1
            return true
        }

        // ---- mapping helpers (same text logic as other tools) ----
        function sedimentationValue() {
            if (!swCopySed.checked) return "No sedimentation"
            let s = cbCopySed.currentText
            if (s === qsTr("on adjacent parcel")) return "Sedimentation on adjacent parcel"
            if (s === qsTr("on road")) return "Sedimentation on road"
            if (s === qsTr("on structure")) return "Sedimentation on structure"
            return "Sedimentation"
        }

        function inputValue() {
            if (!swCopyEin.checked) return "No input"
            let e = cbCopyEin.currentText
            if (e === qsTr("into stream")) return "Input into stream"
            if (e === qsTr("into ditch")) return "Input into ditch"
            if (e === qsTr("into protected biotope")) return "Input into protected biotope"
            return "Input"
        }

        function inflowValue() {
            if (!swCopyZuf.checked) return "No inflow"
            return cbCopyZuf.currentText
        }

        function outflowValue() {
            if (!swCopyAbf.checked) return "No outflow"
            return cbCopyAbf.currentText
        }

        // ---------------- commit helper ----------------
        function commitPointWithAttrs(geom, attrsObj, afterCommitCb) {
            if (!plugin.switchToLayer(layerName)) return
            let layer = plugin.layerByName(layerName)
            if (!layer) { plugin.toast("Layer not available"); return }

            let feature = FeatureUtils.createBlankFeature(layer.fields, geom)

            // set all attrs
            for (let k in attrsObj) feature.setAttribute(k, attrsObj[k])

            plugin.commitViaDrawerAndHide(feature, function(liveFeature) {
                for (let kk in attrsObj) liveFeature.setAttribute(kk, attrsObj[kk])
                if (afterCommitCb) afterCommitCb(liveFeature)
            })
        }

        // ---------------- Start point (commit immediately) ----------------
        function commitStartPoint() {
            if (!plugin.switchToLayer(layerName)) return
            let c = plugin.centerProjected()
            if (!c) { plugin.toast("Map center not available"); return }

            let geom = GeometryUtils.createGeometryFromWkt("POINT(" + c.x + " " + c.y + ")")
            if (!geom) { plugin.toast("Invalid geometry"); return }

            let idInt = plugin.idToInt(selectedLineId)
            if (idInt === null) { plugin.toast("Invalid erosion line ID."); return }

            commitPointWithAttrs(geom, { "Erosion_Line_ID": idInt }, null)
            step = 2
            plugin.toast("Start point saved – define end point")
        }

        // ---------------- End point (store geometry, open form) ----------------
        function captureEndPointAndOpenForm() {
            if (!plugin.switchToLayer(layerName)) return
            let c = plugin.centerProjected()
            if (!c) { plugin.toast("Map center not available"); return }

            pendingEndX = c.x
            pendingEndY = c.y

            let geom = GeometryUtils.createGeometryFromWkt("POINT(" + c.x + " " + c.y + ")")
            if (!geom) { plugin.toast("Invalid geometry"); return }

            pendingEndGeometry = geom

            // reset form defaults
            swCopyFlow_Line.checked = false

            swCopySed.checked = false; cbCopySed.currentIndex = 0
            swCopyEin.checked = false; cbCopyEin.currentIndex = 0
            swCopyZuf.checked = false; cbCopyZuf.currentIndex = 0
            swCopyAbf.checked = false; cbCopyAbf.currentIndex = 0

            copyLinearPostDialog.open()
        }

        // ---------------- Final commit of end point ----------------
        function commitEndPointFromForm() {
            if (!pendingEndGeometry) { plugin.toast("No end point available"); return }

            let idInt = plugin.idToInt(selectedLineId)
            if (idInt === null) { plugin.toast("Invalid erosion line ID."); return }

            let attrs = {
                "Erosion_Line_ID": idInt,
                "Thalweg": swCopyFlow_Line.checked,
                "Sedimentation": sedimentationValue(),
                "Input": inputValue(),
                "Inflow": inflowValue(),
                "Outflow": outflowValue()
            }

            commitPointWithAttrs(pendingEndGeometry, attrs, null)

            // cleanup + reset tool
            pendingEndGeometry = null
            selectedLineId = ""
            step = 0

            plugin.toast("End point + additional information saved")
        }

        // =====================================================
        // HUB 1: choose ID
        // =====================================================
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "copy_linear" && toolCopyLinear.step === 0
            z: 70

            width: Math.min(parent.width * 0.90, 560)
            height: 120
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 6

                Label {
                    text: qsTr("Copy linear erosion")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 14
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                Button {
                    id: btnChooseId_copy
                    Layout.fillWidth: true
                    Layout.preferredHeight: 42
                    text: qsTr("Enter erosion line ID")
                    onClicked: copyLinearDialog.open()
                    background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = btnChooseId_copy.text }
                }

                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    color: "white"
                    opacity: 0.85
                    font.pixelSize: 12
                    text: qsTr("Note: Enter the ID of the erosion line whose measurements should be copied.")
                }
            }
        }

        // =====================================================
        // HUB 2: start point
        // =====================================================
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "copy_linear" && toolCopyLinear.step === 1
            z: 70

            width: Math.min(parent.width * 0.90, 560)
            height: 110
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 6

                Label {
                    text: qsTr("Set start point (%1)").arg(toolCopyLinear.selectedLineId)
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 14
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                Button {
                    id: btnStart_copy
                    Layout.fillWidth: true
                    Layout.preferredHeight: 42
                    text: qsTr("Save start point")
                    onClicked: toolCopyLinear.commitStartPoint()
                    background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = btnStart_copy.text }
                }
            }
        }

        // =====================================================
        // HUB 3: end point
        // =====================================================
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "copy_linear" && toolCopyLinear.step === 2
            z: 70

            width: Math.min(parent.width * 0.90, 560)
            height: 110
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 6

                Label {
                    text: qsTr("Set end point (%1)").arg(toolCopyLinear.selectedLineId)
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 14
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                Button {
                    id: btnEnd_copy
                    Layout.fillWidth: true
                    Layout.preferredHeight: 42
                    text: qsTr("Save end point")
                    onClicked: toolCopyLinear.captureEndPointAndOpenForm()
                    background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = btnEnd_copy.text }
                }
            }
        }

        // =====================================================
        // Dialog: enter ID
        // =====================================================
        Dialog {
            id: copyLinearDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Enter erosion line ID")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: 240

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: plugin.dialogPadding
                spacing: 10

                TextField {
                    id: tfCopyLine_copy
                    color: "white" 
                    Layout.fillWidth: true
                    placeholderText: qsTr("e.g. L001")
                    placeholderTextColor: "#BBBBBB"
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        id: btnCancel_copy
                        text: qsTr("Cancel")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = btnCancel_copy.text }
                        onClicked: copyLinearDialog.close()
                    }

                    Button {
                        id: btnOk_copy
                        text: qsTr("OK")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = btnOk_copy.text }
                        onClicked: {
                            if (!toolCopyLinear.setLineIdFromText(tfCopyLine_copy.text)) return
                            copyLinearDialog.close()
                        }
                    }
                }
            }
        }

        // =====================================================
        // Dialog: additional information after the end point (commit occurs on "Save")
        // =====================================================
        Dialog {
            id: copyLinearPostDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Additional information")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 590)

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: plugin.dialogPadding
                spacing: 5


                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label { text: qsTr("Erosion in thalweg?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                    Switch { id: swCopyFlow_Line; checked: false }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label { text: qsTr("Is sedimentation present?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                    Switch { id: swCopySed; checked: false }
                }
                ComboBox {
                    id: cbCopySed
                    Layout.fillWidth: true
                    visible: swCopySed.checked
                    model: [ qsTr("on adjacent parcel"), qsTr("on road"), qsTr("on structure") ]
                    contentItem: Text { text: cbCopySed.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                    popup: niceComboPopup.createObject(cbCopySed, { combo: cbCopySed })
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label { text: qsTr("Is there an input?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                    Switch { id: swCopyEin; checked: false }
                }
                ComboBox {
                    id: cbCopyEin
                    Layout.fillWidth: true
                    visible: swCopyEin.checked
                    model: [ qsTr("into stream"), qsTr("into ditch"), qsTr("into protected biotope") ]
                    contentItem: Text { text: cbCopyEin.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                    popup: niceComboPopup.createObject(cbCopyEin, { combo: cbCopyEin })
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label { text: qsTr("Is there an inflow?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                    Switch { id: swCopyZuf; checked: false }
                }
                ComboBox {
                    id: cbCopyZuf
                    Layout.fillWidth: true
                    visible: swCopyZuf.checked
                    model: [ qsTr("Concentrated inflow"), qsTr("Inflow from another parcel"), qsTr("Diffuse inflow") ]
                    contentItem: Text { text: cbCopyZuf.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                    popup: niceComboPopup.createObject(cbCopyZuf, { combo: cbCopyZuf })
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label { text: qsTr("Is there an outflow?"); color: "white"; font.pixelSize: 13; Layout.fillWidth: true }
                    Switch { id: swCopyAbf; checked: false }
                }
                ComboBox {
                    id: cbCopyAbf
                    Layout.fillWidth: true
                    visible: swCopyAbf.checked
                    model: [ qsTr("Outflow into rills"), qsTr("Outflow into inlet shaft"), qsTr("Outflow onto shoulder"), qsTr("Other outflow") ]
                    contentItem: Text { text: cbCopyAbf.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                    popup: niceComboPopup.createObject(cbCopyAbf, { combo: cbCopyAbf })
                }

                Item { Layout.fillHeight: true; Layout.fillWidth: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        id: btnCopyPostBack
                        text: qsTr("Back")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = btnCopyPostBack.text }
                        onClicked: {
                            copyLinearPostDialog.close()
                            // user can re-pick end point
                            pendingEndGeometry = null
                            toolCopyLinear.step = 2
                        }
                    }

                    Button {
                        id: btnCopyPostSave
                        text: qsTr("Save")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = btnCopyPostSave.text }
                        onClicked: {
                            copyLinearPostDialog.close()
                            toolCopyLinear.commitEndPointFromForm()
                        }
                    }
                }
            }
        }
    } // End Copy linear tool


    // =========================================================
    // TOOL: DEPOSITION (small and large) — includes an intermediate step after saving the area
    //       (keeps the area layer active; switches to measurement points only after "Next")
    // =========================================================
    Item {
        id: toolDeposition

        // ---------------- STATE ----------------
        property string depositionMode: "choose"
        // choose | small | big_area | big_area_done | big_points | summary

        property string smallDepositionLayer: "Small_Deposition"
        property string largeDepositionAreaLayer: "Large_Deposition_Area"
        property string largeDepositionPointsLayer: "Large_Deposition_Measurement_Points"

        property string depositionIdText: ""
        property int depositionIdNumber: -1
        property int depositionPointIndex: 0

        // polygon drawing (big area)
        property var depositionVertices: []
        property var depositionPendingGeometry: null

        // point placement
        property bool useCenterForNextDepositionPoint: true

        // show crosshair for center-digitizing + points
        property bool crosshairVisible: plugin.currentTool === "deposition"
            && (toolDeposition.depositionMode === "small"
                || toolDeposition.depositionMode === "big_area"
                || toolDeposition.depositionMode === "big_area_done"
                || toolDeposition.depositionMode === "big_points")
        property bool previewRunning: plugin.currentTool === "deposition"
            && toolDeposition.depositionMode === "big_area"
            && toolDeposition.depositionVertices.length > 0
        property bool crosshairSmall: true

        // ---------------- LIFECYCLE ----------------
        function activate() {
            toolDeposition.depositionMode = "choose"
            toolDeposition.depositionVertices = []
            toolDeposition.depositionPendingGeometry = null
            toolDeposition.depositionIdText = ""
            toolDeposition.depositionIdNumber = -1
            toolDeposition.depositionPointIndex = 0
            if (plugin.clearPreview) plugin.clearPreview()
        }

        function deactivate() {
            if (depositionIdDialog.opened) depositionIdDialog.close()
            if (depositionDepthDialog.opened) depositionDepthDialog.close()
            toolDeposition.depositionVertices = []
            toolDeposition.depositionPendingGeometry = null
            if (plugin.clearPreview) plugin.clearPreview()
        }

        // ---------------- HELPERS ----------------
        function parseDepositionId(txt) {
            let t = (txt || "").trim()
            if (t === "") return false
            if (/^\d+$/.test(t)) t = plugin.idWithPrefix("A", parseInt(t, 10))
            let n = plugin.idToInt(t)
            if (n === null) return false
            toolDeposition.depositionIdNumber = n
            toolDeposition.depositionIdText = plugin.idWithPrefix("A", n)
            return true
        }

        // Polygon digitizing like your working Area tool
        function depositionAddVertex() {
            if (!plugin.switchToLayer(toolDeposition.largeDepositionAreaLayer)) return
            let c = plugin.centerProjected()
            if (!c) { plugin.toast("Map center not available"); return }
            toolDeposition.depositionVertices = toolDeposition.depositionVertices.concat([{ x: c.x, y: c.y }])
            if (plugin.updatePreviewFromVertices) plugin.updatePreviewFromVertices(toolDeposition.depositionVertices)
        }

        function depositionRemoveVertex() {
            if (toolDeposition.depositionVertices.length === 0) return
            toolDeposition.depositionVertices = toolDeposition.depositionVertices.slice(0, toolDeposition.depositionVertices.length - 1)
            if (plugin.updatePreviewFromVertices) plugin.updatePreviewFromVertices(toolDeposition.depositionVertices)
        }

        function openDepositionDepth(useCenter) {
            toolDeposition.useCenterForNextDepositionPoint = useCenter
            depositionDepthField.text = ""
            depositionDepthDialog.open()
        }

        function createSmallDepositionPoint(useCenter) {
            if (!plugin.switchToLayer(toolDeposition.smallDepositionLayer)) return
            let pt = plugin.pointFromGpsOrCenter(useCenter)
            if (!pt) { plugin.toast("Position not available"); return }

            let geom = GeometryUtils.createGeometryFromWkt("POINT(" + pt.x + " " + pt.y + ")")
            if (!geom) { plugin.toast("Invalid geometry"); return }

            let layer = plugin.layerByName(toolDeposition.smallDepositionLayer)
            if (!layer) { plugin.toast("Layer not available"); return }

            let f = FeatureUtils.createBlankFeature(layer.fields, geom)
            plugin.commitViaDrawerAndHide(f)
            plugin.toast("Small Deposition saved")

            toolDeposition.depositionMode = "choose"
        }

        // =====================================================
        // HUB: Auswahl
        // =====================================================
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "deposition" && toolDeposition.depositionMode === "choose"
            z: 70

            width: Math.min(parent.width * 0.84, 420)
            height: 110
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 6

                Label {
                    text: qsTr("Add Deposition")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 15
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: qsTr("Small")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: {
                            if (!plugin.switchToLayer(toolDeposition.smallDepositionLayer)) return
                            toolDeposition.depositionMode = "small"
                        }
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                    }

                    Button {
                        text: qsTr("Large")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: {
                            if (!plugin.switchToLayer(toolDeposition.largeDepositionAreaLayer)) return
                            toolDeposition.depositionVertices = []
                            toolDeposition.depositionPendingGeometry = null
                            if (plugin.clearPreview) plugin.clearPreview()
                            toolDeposition.depositionMode = "big_area"
                        }
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                    }
                }

                Label {
                    text: qsTr("Note: Large Depositions are larger than 20 m².")
                    color: "white"
                    opacity: 0.85
                    font.pixelSize: 12
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
        }

        // =====================================================
        // MODE: Small Deposition
        // =====================================================
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "deposition" && toolDeposition.depositionMode === "small"
            z: 70

            width: Math.min(parent.width * 0.78, 420)
            height: 98
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 4

                Label {
                    text: qsTr("Create point")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 13
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 8

                    Button {
                        text: qsTr("Current position")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolDeposition.createSmallDepositionPoint(false)
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }

                    Button {
                        text: qsTr("Map center")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolDeposition.createSmallDepositionPoint(true)
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }
                }
            }
        }

        // =====================================================
        // MODE: Large Deposition – create area
        // =====================================================
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "deposition" && toolDeposition.depositionMode === "big_area"
            z: 70

            width: Math.min(parent.width * 0.84, 420)
            height: 100
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 4

                Label {
                    text: qsTr("Large Deposition – create area")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 15
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: "+"
                        Layout.preferredWidth: 46
                        Layout.preferredHeight: 42
                        onClicked: toolDeposition.depositionAddVertex()
                        background: Rectangle { radius: 21; color: "#000000"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 22 } }
                    }

                    Button {
                        text: "-"
                        Layout.preferredWidth: 46
                        Layout.preferredHeight: 42
                        enabled: toolDeposition.depositionVertices.length > 0
                        onClicked: toolDeposition.depositionRemoveVertex()
                        background: Rectangle { radius: 21; color: "#000000"; opacity: enabled ? 0.25 : 0.12; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 22 } }
                    }

                    Button {
                        text: qsTr("Create")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        enabled: toolDeposition.depositionVertices.length >= 3
                        onClicked: {
                            let wkt = plugin.polygonWktFinal ? plugin.polygonWktFinal(toolDeposition.depositionVertices) : null
                            if (!wkt) { plugin.toast("Invalid polygon geometry"); return }
                            let geom = GeometryUtils.createGeometryFromWkt(wkt)
                            if (!geom) { plugin.toast("Invalid polygon geometry"); return }

                            toolDeposition.depositionPendingGeometry = geom
                            depositionIdField.text = "A001"
                            depositionIdDialog.open()
                        }
                        background: Rectangle { radius: 14; color: "white"; opacity: enabled ? 0.25 : 0.12; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                    }
                }
            }
        }

        // =====================================================
        // Dialog: enter deposition ID and save area
        // =====================================================
        Dialog {
            id: depositionIdDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Enter deposition ID")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 300)

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: plugin.dialogPadding
                spacing: 10

                Label { text: qsTr("Deposition ID"); color: "white"; font.pixelSize: 14; font.bold: true }

                TextField {
                    id: depositionIdField
                    Layout.fillWidth: true
                    placeholderText: qsTr("e.g. A001")
                    color: "white"
                    placeholderTextColor: "#BBBBBB"
                }

                Item { Layout.fillWidth: true; Layout.fillHeight: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: qsTr("Cancel")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            toolDeposition.depositionPendingGeometry = null
                            depositionIdDialog.close()
                        }
                    }

                    Button {
                        text: qsTr("Save")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            if (!toolDeposition.depositionPendingGeometry) { plugin.toast("No geometry available"); return }
                            if (!toolDeposition.parseDepositionId(depositionIdField.text)) { plugin.toast("Invalid ID"); return }

                            // IMPORTANT: stay on Area layer for commit
                            if (!plugin.switchToLayer(toolDeposition.largeDepositionAreaLayer)) return
                            let layer = plugin.layerByName(toolDeposition.largeDepositionAreaLayer)
                            if (!layer) { plugin.toast("Layer not available"); return }

                            let feature = FeatureUtils.createBlankFeature(layer.fields, toolDeposition.depositionPendingGeometry)
                            feature.setAttribute("Large_Deposition_ID", toolDeposition.depositionIdNumber)

                            depositionIdDialog.close()

                            // Commit FIRST, then show an intermediate hub (no layer switch yet)
                            plugin.commitViaDrawerAndHide(feature, function(live) {
                                live.setAttribute("Large_Deposition_ID", toolDeposition.depositionIdNumber)

                                toolDeposition.depositionVertices = []
                                toolDeposition.depositionPendingGeometry = null
                                if (plugin.clearPreview) plugin.clearPreview()

                                // Keep Area layer active here. Next step via "Next".
                                toolDeposition.depositionMode = "big_area_done"
                            })
                        }
                    }
                }
            }
        }

        // =====================================================
        // MODE: area created — show a message and continue (switch to measurement points only here)
        // =====================================================
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "deposition" && toolDeposition.depositionMode === "big_area_done"
            z: 70

            width: Math.min(parent.width * 0.78, 420)
            height: 130
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 6

                Label {
                    text: qsTr("Area created")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 15
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                Label {
                    text: qsTr("Now determine the depth at 5 points within the area.")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 12
                    color: "white"
                    opacity: 0.9
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                Button {
                    text: qsTr("Next")
                    Layout.fillWidth: true
                    Layout.preferredHeight: 42
                    onClicked: {
                        toolDeposition.depositionPointIndex = 1
                        if (!plugin.switchToLayer(toolDeposition.largeDepositionPointsLayer)) return
                        toolDeposition.depositionMode = "big_points"
                    }
                    background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                }
            }
        }

        // =====================================================
        // MODE: measurement points (5)
        // =====================================================
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "deposition" && toolDeposition.depositionMode === "big_points"
            z: 70

            width: Math.min(parent.width * 0.78, 420)
            height: 95
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 4

                Label {
                    text: qsTr("Create Point")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 13
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                Label {
                    text: qsTr("Measurement point %1 of 5 (%2)")
                        .arg(toolDeposition.depositionPointIndex)
                        .arg(toolDeposition.depositionIdText)
                    color: "white"
                    font.bold: true
                    font.pixelSize: 13
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 8

                    Button {
                        text: qsTr("Current position")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolDeposition.openDepositionDepth(false)
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }

                    Button {
                        text: qsTr("Map center")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolDeposition.openDepositionDepth(true)
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }
                }
            }
        }

        // =====================================================
        // Dialog: depth
        // =====================================================
        Dialog {
            id: depositionDepthDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Depth (cm)")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 300)

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: plugin.dialogPadding
                spacing: 10

                Label { text: qsTr("Depth (cm)"); color: "white"; font.pixelSize: 14; font.bold: true }

                TextField {
                    id: depositionDepthField
                    Layout.fillWidth: true
                    placeholderText: qsTr("e.g. 4.2")
                    color: "white"
                    placeholderTextColor: "#BBBBBB"
                }

                Item { Layout.fillWidth: true; Layout.fillHeight: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: qsTr("Cancel")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: depositionDepthDialog.close()
                    }

                    Button {
                        text: qsTr("Save")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            let v = plugin.parseDecimal(depositionDepthField.text)
                            if (v === null) { plugin.toast("Please enter a depth"); return }

                            if (!plugin.switchToLayer(toolDeposition.largeDepositionPointsLayer)) return
                            let layer = plugin.layerByName(toolDeposition.largeDepositionPointsLayer)
                            if (!layer) { plugin.toast("Layer not available"); return }

                            let pt = plugin.pointFromGpsOrCenter(toolDeposition.useCenterForNextDepositionPoint)
                            if (!pt) { plugin.toast("Position not available"); return }

                            let geom = GeometryUtils.createGeometryFromWkt("POINT(" + pt.x + " " + pt.y + ")")
                            if (!geom) { plugin.toast("Invalid geometry"); return }

                            let f = FeatureUtils.createBlankFeature(layer.fields, geom)
                            f.setAttribute("Large_Deposition_ID", toolDeposition.depositionIdNumber)
                            f.setAttribute("Depth_cm", v)

                            plugin.commitViaDrawerAndHide(f, function(live) {
                                live.setAttribute("Large_Deposition_ID", toolDeposition.depositionIdNumber)
                                live.setAttribute("Depth_cm", v)
                            })

                            depositionDepthDialog.close()
                            depositionDepthField.text = ""

                            if (toolDeposition.depositionPointIndex >= 5) {
                                toolDeposition.depositionMode = "summary"
                            } else {
                                toolDeposition.depositionPointIndex += 1
                            }
                        }
                    }
                }
            }
        }

        // =====================================================
        // MODE: Summary
        // =====================================================
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "deposition" && toolDeposition.depositionMode === "summary"
            z: 70

            width: Math.min(parent.width * 0.78, 420)
            height: 120
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 6

                Label {
                    text: qsTr("Large Deposition completed")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 14
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                Label {
                    text: qsTr("ID: %1").arg(toolDeposition.depositionIdText)
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 13
                    color: "white"
                    Layout.fillWidth: true
                }

                Button {
                    text: qsTr("Done")
                    Layout.fillWidth: true
                    Layout.preferredHeight: 42
                    onClicked: toolDeposition.activate()
                    background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                }
            }
        }
    }
    // =========================================================
    // TOOL: RUNOFF (point) — place a point and choose a type
    // Layer: "Runoff", field: "Type"
    // =========================================================
    Item {
        id: toolRunoffPoint

        property string layerName: "Runoff"
        property string fieldType: "Type"

        // show crosshair while this tool is active (helps Map center)
        property bool crosshairVisible: plugin.currentTool === "runoff_point"
        property bool crosshairSmall: true

        // pending feature while form open
        property var pendingFeature: null

        // options
        property var typeOptions: [
            "into ditch",
            "on road",
            "into stream",
            "onto adjacent parcel"
        ]

        function activate() {
            pendingFeature = null
            plugin.switchToLayer(layerName)
        }

        function deactivate() {
            pendingFeature = null
            if (runoffDialog.opened) runoffDialog.close()
        }

        function startNewPoint(useCenter) {
            if (!plugin.switchToLayer(layerName)) return
            let layer = plugin.layerByName(layerName)
            if (!layer) { plugin.toast("Layer not available"); return }

            let pt = plugin.pointFromGpsOrCenter(useCenter)
            if (!pt) {
                plugin.toast(useCenter ? "Map center not available" : "Invalid GPS position – please check")
                return
            }

            let geom = GeometryUtils.createGeometryFromWkt("POINT(" + pt.x + " " + pt.y + ")")
            if (!geom) { plugin.toast("Invalid geometry"); return }

            pendingFeature = FeatureUtils.createBlankFeature(layer.fields, geom)

            cbRunoffType.currentIndex = 0
            runoffDialog.open()
        }

        // ---------------------------------------------------------
        // HUD
        // ---------------------------------------------------------
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "runoff_point"
            z: 70

            width: Math.min(parent.width * 0.78, 420)
            height: 98
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 4

                Label {
                    text: qsTr("Runoff (point)")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 14
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 8

                    Button {
                        text: qsTr("Current position")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolRunoffPoint.startNewPoint(false)
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }

                    Button {
                        text: qsTr("Map center")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolRunoffPoint.startNewPoint(true)
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }
                }
            }
        }

        // ---------------------------------------------------------
        // Dialog: choose type
        // ---------------------------------------------------------
        Dialog {
            id: runoffDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Runoff – choose type")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 280)

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: plugin.dialogPadding
                spacing: 10

                Label {
                    text: qsTr("Type")
                    color: "white"
                    font.pixelSize: 14
                    font.bold: true
                }

                ComboBox {
                    id: cbRunoffType
                    Layout.fillWidth: true
                    model: toolRunoffPoint.typeOptions

                    contentItem: Text {
                        text: cbRunoffType.currentText
                        color: "white"
                        font.pixelSize: 14
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }

                    popup: niceComboPopup.createObject(cbRunoffType, { combo: cbRunoffType })
                }

                Item { Layout.fillWidth: true; Layout.fillHeight: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: qsTr("Cancel")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            toolRunoffPoint.pendingFeature = null
                            runoffDialog.close()
                        }
                    }

                    Button {
                        text: qsTr("Save")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            if (!toolRunoffPoint.pendingFeature) {
                                plugin.toast("No point available")
                                runoffDialog.close()
                                return
                            }

                            let typeValue = cbRunoffType.currentText

                            // set attribute on pending feature
                            toolRunoffPoint.pendingFeature.setAttribute(toolRunoffPoint.fieldType, typeValue)

                            let f = toolRunoffPoint.pendingFeature
                            toolRunoffPoint.pendingFeature = null
                            runoffDialog.close()

                            // commit via drawer + reapply important attribute
                            plugin.commitViaDrawerAndHide(f, function(liveFeature) {
                                liveFeature.setAttribute(toolRunoffPoint.fieldType, typeValue)
                            })

                            plugin.toast(qsTr("Runoff saved"))
                            plugin.setTool("none")
                        }
                    }
                }
            }
        }
    }   // END toolRunoffPoint
    // =========================================================
    // TOOL: OVERLAND WATER FLOW (point) — place a point and choose a type
    // Layer: "Overland_water_flow", field: "Type"
    // =========================================================
    Item {
        id: toolOverlandWaterFlowPoint

        property string layerName: "Overland_water_flow"
        property string fieldType: "Type"

        // show crosshair while this tool is active (helps Map center)
        property bool crosshairVisible: plugin.currentTool === "overland_water_flow_point"
        property bool crosshairSmall: true

        // pending feature while form open
        property var pendingFeature: null

        // options
        property var typeOptions: [
            "Concentrated water inflow",
            "Inlet shaft",
            "Water outlet"
        ]

        function activate() {
            pendingFeature = null
            plugin.switchToLayer(layerName)
        }

        function deactivate() {
            pendingFeature = null
            if (overlandWaterFlowDialog.opened) overlandWaterFlowDialog.close()
        }

        function startNewPoint(useCenter) {
            if (!plugin.switchToLayer(layerName)) return
            let layer = plugin.layerByName(layerName)
            if (!layer) { plugin.toast("Layer not available"); return }

            let pt = plugin.pointFromGpsOrCenter(useCenter)
            if (!pt) {
                plugin.toast(useCenter ? "Map center not available" : "Invalid GPS position – please check")
                return
            }

            let geom = GeometryUtils.createGeometryFromWkt("POINT(" + pt.x + " " + pt.y + ")")
            if (!geom) { plugin.toast("Invalid geometry"); return }

            pendingFeature = FeatureUtils.createBlankFeature(layer.fields, geom)

            cbOverlandWaterFlowType.currentIndex = 0
            overlandWaterFlowDialog.open()
        }

        // ---------------------------------------------------------
        // HUD
        // ---------------------------------------------------------
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "overland_water_flow_point"
            z: 70

            width: Math.min(parent.width * 0.78, 420)
            height: 98
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 4

                Label {
                    text: qsTr("Overland water flow (point)")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 14
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 8

                    Button {
                        text: qsTr("Current position")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolOverlandWaterFlowPoint.startNewPoint(false)
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }

                    Button {
                        text: qsTr("Map center")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolOverlandWaterFlowPoint.startNewPoint(true)
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }
                }
            }
        }

        // ---------------------------------------------------------
        // Dialog: choose type
        // ---------------------------------------------------------
        Dialog {
            id: overlandWaterFlowDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Overland water flow – choose type")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 280)

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: plugin.dialogPadding
                spacing: 10

                Label {
                    text: qsTr("Type")
                    color: "white"
                    font.pixelSize: 14
                    font.bold: true
                }

                ComboBox {
                    id: cbOverlandWaterFlowType
                    Layout.fillWidth: true
                    model: toolOverlandWaterFlowPoint.typeOptions

                    contentItem: Text {
                        text: cbOverlandWaterFlowType.currentText
                        color: "white"
                        font.pixelSize: 14
                        verticalAlignment: Text.AlignVCenter
                        elide: Text.ElideRight
                    }

                    popup: niceComboPopup.createObject(cbOverlandWaterFlowType, { combo: cbOverlandWaterFlowType })
                }

                Item { Layout.fillWidth: true; Layout.fillHeight: true }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: qsTr("Cancel")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            toolOverlandWaterFlowPoint.pendingFeature = null
                            overlandWaterFlowDialog.close()
                        }
                    }

                    Button {
                        text: qsTr("Save")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: {
                            if (!toolOverlandWaterFlowPoint.pendingFeature) {
                                plugin.toast("No point available")
                                overlandWaterFlowDialog.close()
                                return
                            }

                            let typeValue = cbOverlandWaterFlowType.currentText

                            // set attribute on pending feature
                            toolOverlandWaterFlowPoint.pendingFeature.setAttribute(toolOverlandWaterFlowPoint.fieldType, typeValue)

                            let f = toolOverlandWaterFlowPoint.pendingFeature
                            toolOverlandWaterFlowPoint.pendingFeature = null
                            overlandWaterFlowDialog.close()

                            // commit via drawer + reapply important attribute
                            plugin.commitViaDrawerAndHide(f, function(liveFeature) {
                                liveFeature.setAttribute(toolOverlandWaterFlowPoint.fieldType, typeValue)
                            })

                            plugin.toast(qsTr("Overland water flow saved"))
                            plugin.setTool("none")
                        }
                    }
                }
            }
        }
    }   // END toolOverlandWaterFlowPoint

// =========================================================
// TOOL: ADD NOTE — area or point
// IDs are unique because the same note-specific prefix is used throughout
// =========================================================
Item {
    id: toolNote

    property string layerPolygon: "Note_Area"
    property string layerPoint: "Note_Point"
    property string fieldText: "Note"

    // Management fields (same as Management layer)
    property string fCrop: "crop"
    property string fManagement: "management"
    property string fieldGrowthStage: "growth_stage"
    property string fCover: "cover"
    property string fMulch_Cover: "Mulch_Cover"
    property string fErosion: "Erosion"
    property string fPhoto1: "Photo1"
    property string fPhoto2: "Photo2"

    // "hub" | "area" | "point"
    property string mode: "hub"

    // polygon digitizing state
    property var areaVertices: []
    property var pendingGeometry: null
    property string pendingLayerName: ""

    // module signals
    property bool crosshairVisible: plugin.currentTool === "note" && (mode === "area" || mode === "point")
    property bool crosshairSmall: true
    property bool previewRunning: plugin.currentTool === "note" && mode === "area" && areaVertices.length > 0

    // ------------------------------------------
    // Management wizard state (for Area)
    // ------------------------------------------
    property int noteManagementPage: 0
    property int noteGrowthStageValue: 0
    property int noteCoverValue: 0
    property int noteMulch_CoverValue: 0
    property bool noteErosionValue: false

    // photos (relative paths stored into fields)
    property string notePhoto1Path: ""
    property string notePhoto2Path: ""
    property int notePhotoTarget: 0   // 1 or 2

    // ------------------------------------------
    // Resources state
    // ------------------------------------------
    property string noteResourceRelativePath: ""
    property string noteResourceAbsolutePath: ""

    property var noteHelpRelPaths: []
    property int noteHelpPageIndex: 0
    property string noteHelpTitle: ""

    property var noteCropOptions: [
        "Field grass", "Pea", "Maize", "Sweet corn", "Fodder beet", "Yellow mustard",
        "Sown meadow", "Vegetables", "Green fallow / flower fallow", "Oat", "Potato",
        "Clover", "Oil radish", "Black fallow", "Soybean", "Spring barley",
        "Spring wheat", "Winter barley", "Winter wheat", "Rapeseed",
        "Sugar beet", "Catch crop", "Other"
    ]

    property var noteManagementOptions: [
        "Harvested", "Arable crop with undersowing", "Direct seeding",
        "Freshly emerged crop", "Fresh seedbed", "Crop developing", "Crop fully developed",
        "Harrowed", "Cultivated", "Ploughed", "Green fallow", "Black fallow",
        "Stubble fallow", "Straw mulch", "Catch crop", "Dead catch crop", "Other"
    ]

    function activate() {
        goHub()
    }

    function deactivate() {
        if (note_textDialog.opened) note_textDialog.close()
        if (note_areaChoiceDialog.opened) note_areaChoiceDialog.close()
        if (noteManagementDialog.opened) noteManagementDialog.close()
        if (note_cameraLoader.active) note_cameraLoader.active = false
        if (noteResourceDialog.opened) noteResourceDialog.close()
        if (note_helpDialog.opened) note_helpDialog.close()
        goHub()
    }

    // ---------------- HUB actions ----------------
    function goHub() {
        mode = "hub"
        areaVertices = []
        pendingGeometry = null
        pendingLayerName = ""
        if (plugin.clearPreview) plugin.clearPreview()

        noteResourceRelativePath = ""
        noteResourceAbsolutePath = ""
        noteHelpRelPaths = []
        noteHelpPageIndex = 0
        noteHelpTitle = ""
    }

    function chooseArea() {
        mode = "area"
        areaVertices = []
        pendingGeometry = null
        pendingLayerName = ""
        if (plugin.clearPreview) plugin.clearPreview()
        plugin.switchToLayer(layerPolygon)
    }

    function choosePoint() {
        mode = "point"
        areaVertices = []
        pendingGeometry = null
        pendingLayerName = ""
        if (plugin.clearPreview) plugin.clearPreview()
        plugin.switchToLayer(layerPoint)
    }

    // ---------------- Area (+ / - / Create) ----------------
    function areaAddVertex() {
        if (!plugin.switchToLayer(layerPolygon)) return
        let c = plugin.centerProjected()
        if (!c) { plugin.toast("Map center not available"); return }
        areaVertices = areaVertices.concat([{ x: c.x, y: c.y }])
        if (plugin.updatePreviewFromVertices) plugin.updatePreviewFromVertices(areaVertices)
    }

    function areaRemoveVertex() {
        if (areaVertices.length === 0) return
        areaVertices = areaVertices.slice(0, areaVertices.length - 1)
        if (plugin.updatePreviewFromVertices) plugin.updatePreviewFromVertices(areaVertices)
    }

    function areaCreate() {
        if (areaVertices.length < 3) { plugin.toast("At least 3 points required"); return }
        let wkt = plugin.polygonWktFinal(areaVertices)
        if (!wkt) { plugin.toast("Invalid polygon geometry"); return }
        let geom = GeometryUtils.createGeometryFromWkt(wkt)
        if (!geom) { plugin.toast("Invalid polygon geometry"); return }

        pendingGeometry = geom
        pendingLayerName = layerPolygon
        note_areaChoiceDialog.open()
    }

    // ---------------- Point (Current position / Map center) ----------------
    function pointCreate(useCenter) {
        if (!plugin.switchToLayer(layerPoint)) return
        let pt = plugin.pointFromGpsOrCenter(useCenter)
        if (!pt) {
            plugin.toast(useCenter ? "Map center not available" : "Invalid GPS position – please check")
            return
        }

        let geom = GeometryUtils.createGeometryFromWkt("POINT(" + pt.x + " " + pt.y + ")")
        if (!geom) { plugin.toast("Invalid geometry"); return }

        pendingGeometry = geom
        pendingLayerName = layerPoint

        note_taText.text = ""
        note_textDialog.open()
    }

    // ---------------- Save other note / point text ----------------
    function saveTextAndCommit() {
        let txt = (note_taText.text || "").trim()
        if (txt.length === 0) { plugin.toast("Please enter text"); return }

        if (!pendingGeometry || !pendingLayerName) {
            plugin.toast("No geometry available")
            note_textDialog.close()
            return
        }

        if (!plugin.switchToLayer(pendingLayerName)) return
        let layer = plugin.layerByName(pendingLayerName)
        if (!layer) { plugin.toast("Layer not available"); return }

        let feature = FeatureUtils.createBlankFeature(layer.fields, pendingGeometry)
        feature.setAttribute(fieldText, txt)

        note_textDialog.close()

        plugin.commitViaDrawerAndHide(feature, function(liveFeature) {
            liveFeature.setAttribute(fieldText, txt)
        })

        plugin.toast(qsTr("Note saved"))
        goHub()
        plugin.setTool("none")
    }

    // ------------------------------------------
    // Resources helpers
    // ------------------------------------------
    function ensureResourcesDir() {
        if (!qgisProject || !qgisProject.homePath || qgisProject.homePath === "") return false
        platformUtilities.createDir(qgisProject.homePath, "DCIM")
        platformUtilities.createDir(qgisProject.homePath, "DCIM/Resources")
        return true
    }

    function absFromRel(rel) {
        if (!qgisProject || !qgisProject.homePath || qgisProject.homePath === "") return ""
        return qgisProject.homePath + "/" + rel
    }

    function resourceImageForCrop(cropText) {
        if (!cropText) return ""

        switch (cropText) {
            case "Pea":
                return "DCIM/Resources/Pea_Growth_Stages.png"

            case "Maize":
            case "Sweet corn":
                return "DCIM/Resources/Maize_Growth_Stages.png"

            case "Potato":
                return "DCIM/Resources/Potato_Growth_Stages.png"

            case "Sugar beet":
                return "DCIM/Resources/SugarBeet_Growth_Stages.png"

            case "Oat":
            case "Spring barley":
            case "Winter barley":
            case "Spring wheat":
            case "Winter wheat":
                return "DCIM/Resources/Cereals_Growth_Stages.png"

            case "Rapeseed":
                return "DCIM/Resources/Rapeseed_Growth_Stages.png"

            default:
                return ""
        }
    }

    function openResourcesForCurrentCrop() {
        if (!ensureResourcesDir()) { plugin.toast("Project path not available"); return }

        let rel = resourceImageForCrop(note_cbCrop.currentText)
        if (!rel || rel === "") { plugin.toast("No resources for this crop type"); return }

        noteResourceRelativePath = rel
        noteResourceAbsolutePath = absFromRel(rel)
        noteResourceDialog.open()
    }

    function openCropIdentificationHelp() {
        if (!ensureResourcesDir()) { plugin.toast("Project path not available"); return }
        noteHelpTitle = "Crop identification"
        noteHelpRelPaths = [
            "DCIM/Resources/Crop_Identification_1.png",
            "DCIM/Resources/Crop_Identification_2.png"
        ]
        noteHelpPageIndex = 0
        note_helpDialog.open()
    }

    function openCoverGuideHelp() {
        if (!ensureResourcesDir()) { plugin.toast("Project path not available"); return }
        noteHelpTitle = "Cover guide"
        noteHelpRelPaths = [
            "DCIM/Resources/Cover_Guide.png" // adjust if different
        ]
        noteHelpPageIndex = 0
        note_helpDialog.open()
    }

    // ---------------- Management flow (Area) ----------------
    function resetManagementFormDefaults() {
        noteManagementPage = 0

        note_cbCrop.currentIndex = 0
        note_cbManagement.currentIndex = 0

        noteGrowthStageValue = 0
        noteGrowthStageField.text = ""

        noteCoverValue = 0
        noteMulch_CoverValue = 0
        noteErosionValue = false

        note_slCover.value = 0
        note_slMulch_Cover.value = 0
        note_swErosion.checked = false

        notePhoto1Path = ""
        notePhoto2Path = ""
        notePhotoTarget = 0

        noteManagementTextArea.text = ""

        noteResourceRelativePath = ""
        noteResourceAbsolutePath = ""
        noteHelpRelPaths = []
        noteHelpPageIndex = 0
        noteHelpTitle = ""
    }

    function startManagementForArea() {
        if (!pendingGeometry || pendingLayerName !== layerPolygon) {
            plugin.toast("No area available")
            return
        }
        resetManagementFormDefaults()
        noteManagementDialog.open()
    }

    function takePhoto(which) {
        if (!pendingGeometry || pendingLayerName !== layerPolygon) { plugin.toast("No area available"); return }

        if (!qgisProject || !qgisProject.homePath || qgisProject.homePath === "") {
            plugin.toast("Project path not available – photo cannot be saved")
            return
        }

        notePhotoTarget = which
        platformUtilities.createDir(qgisProject.homePath, "DCIM")
        note_cameraLoader.active = true
    }

    function onPhotoCaptured(tmpPath) {
        if (!tmpPath || tmpPath === "") return

        if (!qgisProject || !qgisProject.homePath || qgisProject.homePath === "") {
            plugin.toast("Project path not available – photo could not be imported")
            return
        }

        let suffix = FileUtils.fileSuffix(tmpPath)
        let rel = "DCIM/NoteManagement_" + Date.now().toString() + (notePhotoTarget === 2 ? "_2" : "_1") + "." + suffix
        let targetAbs = qgisProject.homePath + "/" + rel

        platformUtilities.createDir(qgisProject.homePath, "DCIM")
        platformUtilities.renameFile(tmpPath, targetAbs)

        if (notePhotoTarget === 1) notePhoto1Path = rel
        else if (notePhotoTarget === 2) notePhoto2Path = rel

        notePhotoTarget = 0
    }

    function commitManagementArea() {
        if (!pendingGeometry || pendingLayerName !== layerPolygon) {
            plugin.toast("No area available")
            noteManagementDialog.close()
            return
        }

        if (!plugin.switchToLayer(layerPolygon)) return
        let layer = plugin.layerByName(layerPolygon)
        if (!layer) { plugin.toast("Layer not available"); return }

        let cropVal = note_cbCrop.currentText
        let bearbVal = note_cbManagement.currentText
        let growth_stageVal = noteGrowthStageValue
        let coverVal = noteCoverValue
        let mulchVal = noteMulch_CoverValue
        let erosVal = noteErosionValue

        let photo1Value = notePhoto1Path
        let photo2Value = notePhoto2Path

        let txtVal = (noteManagementTextArea.text || "").trim()   // may be ""

        let feature = FeatureUtils.createBlankFeature(layer.fields, pendingGeometry)
        feature.setAttribute(fCrop, cropVal)
        feature.setAttribute(fManagement, bearbVal)
        feature.setAttribute(fieldGrowthStage, growth_stageVal)
        feature.setAttribute(fCover, coverVal)
        feature.setAttribute(fMulch_Cover, mulchVal)
        feature.setAttribute(fErosion, erosVal)
        feature.setAttribute(fPhoto1, photo1Value)
        feature.setAttribute(fPhoto2, photo2Value)
        feature.setAttribute(fieldText, txtVal)

        noteManagementDialog.close()

        plugin.commitViaDrawerAndHide(feature, function(liveFeature) {
            liveFeature.setAttribute(fCrop, cropVal)
            liveFeature.setAttribute(fManagement, bearbVal)
            liveFeature.setAttribute(fieldGrowthStage, growth_stageVal)
            liveFeature.setAttribute(fCover, coverVal)
            liveFeature.setAttribute(fMulch_Cover, mulchVal)
            liveFeature.setAttribute(fErosion, erosVal)
            liveFeature.setAttribute(fPhoto1, photo1Value)
            liveFeature.setAttribute(fPhoto2, photo2Value)
            liveFeature.setAttribute(fieldText, txtVal)
        })

        Qt.createQmlObject(
            'import QtQuick; Timer { interval: ' + plugin.drawerAutoCloseMsPhotos + '; running: true; repeat: false; onTriggered: { if (overlayFeatureFormDrawer && overlayFeatureFormDrawer.opened) overlayFeatureFormDrawer.close() } }',
            plugin
        )

        plugin.toast(qsTr("Note (Management) saved"))
        goHub()
        plugin.setTool("none")
    }

    // ---------------------------------------------------------
    // HUD (3 modes)
    // ---------------------------------------------------------
    Rectangle {
        id: note_hud
        parent: plugin.mainWindow.contentItem
        visible: plugin.currentTool === "note"
        z: 70

        width: Math.min(parent.width * 0.70, 460)
        height: (toolNote.mode === "hub") ? 100 : 98
        radius: 18
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: plugin.hudBottomOffset

        color: Theme.darkGray
        opacity: 0.94

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 6
            spacing: 6

            Label {
                text: (toolNote.mode === "hub")
                    ? qsTr("Add note")
                    : (toolNote.mode === "area"
                        ? qsTr("Create area")
                        : qsTr("Create point"))
                horizontalAlignment: Text.AlignHCenter
                font.pixelSize: 14
                font.bold: true
                color: "white"
                Layout.fillWidth: true
            }

            // HUB mode: choose Area / Point
            Item {
                visible: toolNote.mode === "hub"
                Layout.fillWidth: true
                implicitHeight: 46

                GridLayout {
                    anchors.fill: parent
                    columns: 2
                    columnSpacing: 8

                    Button {
                        id: note_btnHubArea
                        text: qsTr("Area")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolNote.chooseArea()
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }

                    Button {
                        id: note_btnHubPoint
                        text: qsTr("Point")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolNote.choosePoint()
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }
                }
            }

            // AREA mode: + / - / Create
            Item {
                visible: toolNote.mode === "area"
                Layout.fillWidth: true
                implicitHeight: 46

                RowLayout {
                    anchors.fill: parent
                    spacing: 8

                    Button {
                        id: note_btnAreaPlus
                        text: "+"
                        Layout.preferredWidth: 46
                        Layout.preferredHeight: 42
                        onClicked: toolNote.areaAddVertex()
                        background: Rectangle { radius: 21; color: "#000000"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 22 } }
                    }

                    Button {
                        id: note_btnAreaMinus
                        text: "-"
                        Layout.preferredWidth: 46
                        Layout.preferredHeight: 42
                        enabled: toolNote.areaVertices.length > 0
                        onClicked: toolNote.areaRemoveVertex()
                        background: Rectangle { radius: 21; color: "#000000"; opacity: enabled ? 0.25 : 0.12; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 22 } }
                    }

                    Button {
                        id: note_btnAreaCreate
                        text: qsTr("Create")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        enabled: toolNote.areaVertices.length >= 3
                        onClicked: toolNote.areaCreate()
                        background: Rectangle { radius: 14; color: "white"; opacity: enabled ? 0.25 : 0.12; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                    }
                }
            }

            // POINT mode: Current position / Map center
            Item {
                visible: toolNote.mode === "point"
                Layout.fillWidth: true
                implicitHeight: 46

                GridLayout {
                    anchors.fill: parent
                    columns: 2
                    columnSpacing: 8

                    Button {
                        id: note_btnPointGps
                        text: qsTr("Current position")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolNote.pointCreate(false)
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }

                    Button {
                        id: note_btnPointCenter
                        text: qsTr("Map center")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 42
                        onClicked: toolNote.pointCreate(true)
                        background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------
    // Dialog 1: Area -> Select Management / MISC
    // ---------------------------------------------------------
    Dialog {
        id: note_areaChoiceDialog
        modal: true
        parent: plugin.mainWindow.contentItem
        title: qsTr("Area: selection")
        standardButtons: Dialog.NoButton

        anchors.centerIn: parent
        width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
        height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 240)

        background: Rectangle {
            anchors.fill: parent
            radius: 16
            color: Theme.darkGray
            border.width: 1
            border.color: "white"
            opacity: 0.98
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: plugin.dialogPadding
            spacing: 12

            Label {
                Layout.fillWidth: true
                text: qsTr("What should be recorded/added?")
                color: "white"
                font.pixelSize: 14
                font.bold: true
                wrapMode: Text.WordWrap
            }

            Item { Layout.fillWidth: true; Layout.fillHeight: true }

            Button {
                id: noteChooseManagementButton
                text: qsTr("Management")
                Layout.fillWidth: true
                Layout.preferredHeight: 42
                background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                onClicked: {
                    note_areaChoiceDialog.close()
                    toolNote.startManagementForArea()
                }
            }

            Button {
                id: note_btnChoiceText
                text: qsTr("Other (Text)")
                Layout.fillWidth: true
                Layout.preferredHeight: 42
                background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                onClicked: {
                    note_areaChoiceDialog.close()
                    note_taText.text = ""
                    note_textDialog.open()
                }
            }

            Button {
                id: note_btnChoiceCancel
                text: qsTr("Cancel")
                Layout.fillWidth: true
                Layout.preferredHeight: 38
                background: Rectangle { radius: 14; color: "#000000"; opacity: 0.20; border.width: 1; border.color: "white" }
                contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                onClicked: {
                    toolNote.pendingGeometry = null
                    toolNote.pendingLayerName = ""
                    note_areaChoiceDialog.close()
                }
            }
        }
    }

    // ---------------------------------------------------------
    // Camera loader (self-contained)
    // Requires: import "qrc:/qml" as QFieldItems
    // ---------------------------------------------------------
    Loader {
        id: note_cameraLoader
        active: false
        sourceComponent: Component {
            QFieldItems.QFieldCamera {
                id: note_qfieldCamera
                visible: false

                Component.onCompleted: open()

                onFinished: (path) => { close(); toolNote.onPhotoCaptured(path) }
                onCanceled: { close() }
                onClosed: { note_cameraLoader.active = false }
            }
        }
    }

    // ---------------------------------------------------------
    // Growth Stages dialog (unique IDs)
    // ---------------------------------------------------------
    Dialog {
        id: noteResourceDialog
        modal: true
        parent: plugin.mainWindow.contentItem
        title: qsTr("Resources – growth stages")
        standardButtons: Dialog.Close

        anchors.centerIn: parent
        width: Math.min(parent.width * 0.95, 720)
        height: Math.min(parent.height * 0.85, 720)

        property real zoom: 1.0
        property real zoomMin: 1.0
        property real zoomMax: 4.0
        property real zoomStep: 0.25
        onOpened: zoom = 1.0

        background: Rectangle {
            anchors.fill: parent
            radius: 16
            color: Theme.darkGray
            border.width: 1
            border.color: "white"
            opacity: 0.98
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 2
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }

                Button {
                    id: note_btnStageMinus
                    text: qsTr("−")
                    Layout.preferredWidth: 52
                    enabled: noteResourceDialog.zoom > noteResourceDialog.zoomMin
                    opacity: enabled ? 1.0 : 0.35
                    onClicked: noteResourceDialog.zoom =
                                Math.max(noteResourceDialog.zoomMin,
                                         noteResourceDialog.zoom - noteResourceDialog.zoomStep)
                }
                Button {
                    id: note_btnStagePlus
                    text: qsTr("+")
                    Layout.preferredWidth: 52
                    enabled: noteResourceDialog.zoom < noteResourceDialog.zoomMax
                    opacity: enabled ? 1.0 : 0.35
                    onClicked: noteResourceDialog.zoom =
                                Math.min(noteResourceDialog.zoomMax,
                                         noteResourceDialog.zoom + noteResourceDialog.zoomStep)
                }
            }

            Flickable {
                id: note_stageFlick
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                contentWidth: Math.max(width, note_stageImg.paintedWidth * noteResourceDialog.zoom)
                contentHeight: Math.max(height, note_stageImg.paintedHeight * noteResourceDialog.zoom)

                PinchArea {
                    id: note_stagePinch
                    anchors.fill: parent
                    pinch.minimumScale: noteResourceDialog.zoomMin
                    pinch.maximumScale: noteResourceDialog.zoomMax
                    onPinchUpdated: noteResourceDialog.zoom =
                                        Math.max(noteResourceDialog.zoomMin,
                                                 Math.min(noteResourceDialog.zoomMax, pinch.scale))

                    Image {
                        id: note_stageImg
                        source: toolNote.noteResourceAbsolutePath
                        asynchronous: true
                        cache: true
                        fillMode: Image.PreserveAspectFit
                        width: note_stageFlick.width * noteResourceDialog.zoom
                        height: note_stageFlick.height * noteResourceDialog.zoom
                        onStatusChanged: {
                            if (status === Image.Error) plugin.toast("The image could not be loaded.")
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------
    // Help dialog (unique IDs)
    // ---------------------------------------------------------
    Dialog {
        id: note_helpDialog
        modal: true
        parent: plugin.mainWindow.contentItem
        title: (toolNote.noteHelpTitle && toolNote.noteHelpTitle !== "") ? toolNote.noteHelpTitle : qsTr("Resources")
        standardButtons: Dialog.Close

        anchors.centerIn: parent
        width: Math.min(parent.width * 0.95, 720)
        height: Math.min(parent.height * 0.85, 720)

        property real zoom: 1.0
        property real zoomMin: 1.0
        property real zoomMax: 5.0
        property real zoomStep: 0.5
        onOpened: zoom = 1.0

        function currentRel() {
            if (!toolNote.noteHelpRelPaths || toolNote.noteHelpRelPaths.length === 0) return ""
            return toolNote.noteHelpRelPaths[Math.max(0, Math.min(toolNote.noteHelpRelPaths.length - 1, toolNote.noteHelpPageIndex))]
        }
        function currentAbs() {
            let rel = currentRel()
            if (!rel || rel === "") return ""
            return toolNote.absFromRel(rel)
        }

        background: Rectangle {
            anchors.fill: parent
            radius: 16
            color: Theme.darkGray
            border.width: 1
            border.color: "white"
            opacity: 0.98
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 2
            spacing: 8

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Item { Layout.fillWidth: true }

                    Button {
                        id: note_btnHelpPage1
                        text: qsTr("Page 1")
                        visible: toolNote.noteHelpRelPaths.length > 1
                        enabled: toolNote.noteHelpPageIndex !== 0
                        opacity: enabled ? 1.0 : 0.35
                        onClicked: { toolNote.noteHelpPageIndex = 0; note_helpDialog.zoom = 1.0 }
                    }
                    Button {
                        id: note_btnHelpPage2
                        text: qsTr("Page 2")
                        visible: toolNote.noteHelpRelPaths.length > 1
                        enabled: toolNote.noteHelpPageIndex !== 1
                        opacity: enabled ? 1.0 : 0.35
                        onClicked: { toolNote.noteHelpPageIndex = 1; note_helpDialog.zoom = 1.0 }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Item { Layout.fillWidth: true }

                    Button {
                        id: note_btnHelpMinus
                        text: qsTr("−")
                        Layout.preferredWidth: 52
                        enabled: note_helpDialog.zoom > note_helpDialog.zoomMin
                        opacity: enabled ? 1.0 : 0.35
                        onClicked: note_helpDialog.zoom = Math.max(note_helpDialog.zoomMin, note_helpDialog.zoom - note_helpDialog.zoomStep)
                    }
                    Button {
                        id: note_btnHelpPlus
                        text: qsTr("+")
                        Layout.preferredWidth: 52
                        enabled: note_helpDialog.zoom < note_helpDialog.zoomMax
                        opacity: enabled ? 1.0 : 0.35
                        onClicked: note_helpDialog.zoom = Math.min(note_helpDialog.zoomMax, note_helpDialog.zoom + note_helpDialog.zoomStep)
                    }
                }
            }

            Flickable {
                id: note_helpFlick
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                contentWidth: Math.max(width, note_helpImg.paintedWidth * note_helpDialog.zoom)
                contentHeight: Math.max(height, note_helpImg.paintedHeight * note_helpDialog.zoom)

                PinchArea {
                    id: note_helpPinch
                    anchors.fill: parent
                    pinch.minimumScale: note_helpDialog.zoomMin
                    pinch.maximumScale: note_helpDialog.zoomMax
                    onPinchUpdated: note_helpDialog.zoom =
                                        Math.max(note_helpDialog.zoomMin,
                                                 Math.min(note_helpDialog.zoomMax, pinch.scale))

                    Image {
                        id: note_helpImg
                        source: note_helpDialog.currentAbs()
                        asynchronous: true
                        cache: true
                        fillMode: Image.PreserveAspectFit
                        width: note_helpFlick.width * note_helpDialog.zoom
                        height: note_helpFlick.height * note_helpDialog.zoom
                        onStatusChanged: {
                            if (status === Image.Error) plugin.toast("The image could not be loaded.")
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------
    // Dialog 2: MISC Text / Point Text (unique IDs)
    // ---------------------------------------------------------
    Dialog {
        id: note_textDialog
        modal: true
        parent: plugin.mainWindow.contentItem
        title: qsTr("Note")
        standardButtons: Dialog.NoButton

        anchors.centerIn: parent
        width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
        height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 380)

        background: Rectangle {
            anchors.fill: parent
            radius: 16
            color: Theme.darkGray
            border.width: 1
            border.color: "white"
            opacity: 0.98
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: plugin.dialogPadding
            spacing: 12

            Label {
                text: qsTr("Enter note …")
                color: "white"
                font.pixelSize: 13
                opacity: 0.9
            }

            Item { Layout.fillWidth: true; implicitHeight: 6 }

            TextArea {
                id: note_taText
                Layout.fillWidth: true
                Layout.fillHeight: true
                wrapMode: TextArea.Wrap
                color: "white"
                placeholderText: ""
                leftPadding: 12
                rightPadding: 12
                topPadding: 14
                bottomPadding: 12

                background: Rectangle {
                    radius: 12
                    color: "white"
                    opacity: 0.12
                    border.width: 1
                    border.color: "white"
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Button {
                    id: note_btnTextCancel
                    text: qsTr("Cancel")
                    Layout.fillWidth: true
                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                    onClicked: {
                        toolNote.pendingGeometry = null
                        toolNote.pendingLayerName = ""
                        note_textDialog.close()
                        toolNote.goHub()
                    }
                }

                Button {
                    id: note_btnTextSave
                    text: qsTr("Save")
                    Layout.fillWidth: true
                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                    onClicked: toolNote.saveTextAndCommit()
                }
            }
        }
    }

    // ---------------------------------------------------------
    // Dialog 3: Management (Area) – 4 pages (unique IDs)
    // ---------------------------------------------------------
    Dialog {
        id: noteManagementDialog
        modal: true
        parent: plugin.mainWindow.contentItem
        title: qsTr("Note (Management)")
        standardButtons: Dialog.NoButton

        anchors.centerIn: parent
        width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
        height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 490)

        background: Rectangle {
            anchors.fill: parent
            radius: 16
            color: Theme.darkGray
            border.width: 1
            border.color: "white"
            opacity: 0.98
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: plugin.dialogPadding
            spacing: 10

            Label {
                Layout.fillWidth: true
                color: "white"
                opacity: 0.85
                font.pixelSize: 12
                text: qsTr("Page %1 of 4").arg(toolNote.noteManagementPage + 1)
            }

            StackLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: toolNote.noteManagementPage

                // ===================== PAGE 1 =====================
                Item {
                    ColumnLayout {
                        width: parent.width
                        spacing: 10

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Label {
                                text: qsTr("Crop type")
                                color: "white"
                                font.pixelSize: 14
                                font.bold: true
                                Layout.fillWidth: true
                            }
                            Button {
                                id: note_btnHelpCrop
                                text: "?"
                                Layout.preferredWidth: 38
                                Layout.preferredHeight: 34
                                onClicked: toolNote.openCropIdentificationHelp()
                                background: Rectangle { radius: 10; color: "white"; opacity: 0.20; border.width: 1; border.color: "white" }
                                contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                            }
                        }

                        ComboBox {
                            id: note_cbCrop
                            Layout.fillWidth: true
                            model: toolNote.noteCropOptions
                            contentItem: Text { text: note_cbCrop.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                            popup: niceComboPopup.createObject(note_cbCrop, { combo: note_cbCrop })
                        }

                        Label { text: qsTr("Management"); color: "white"; font.pixelSize: 14; font.bold: true }

                        ComboBox {
                            id: note_cbManagement
                            Layout.fillWidth: true
                            model: toolNote.noteManagementOptions
                            contentItem: Text { text: note_cbManagement.displayText; color: "white"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight; font.pixelSize: 14 }
                            popup: niceComboPopup.createObject(note_cbManagement, { combo: note_cbManagement })
                        }

                        Label { text: qsTr("Growth stage"); color: "white"; font.pixelSize: 14; font.bold: true }

                        TextField {
                            id: noteGrowthStageField
                            Layout.fillWidth: true
                            inputMethodHints: Qt.ImhDigitsOnly
                            placeholderText: qsTr("Enter a number (1–99)")
                            color: "white"
                            placeholderTextColor: "#BBBBBB"
                            onTextChanged: {
                                let n = parseInt(text)
                                if (isNaN(n)) n = 0
                                toolNote.noteGrowthStageValue = n
                            }
                        }

                        Button {
                            id: note_btnStageOpen
                            Layout.fillWidth: true
                            visible: toolNote.resourceImageForCrop(note_cbCrop.currentText) !== ""
                            text: qsTr("Show growth stages")
                            background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                            contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 14 } }
                            onClicked: toolNote.openResourcesForCurrentCrop()
                        }

                        Item { Layout.fillHeight: true; Layout.fillWidth: true }
                    }
                }

                // ===================== PAGE 2 =====================
                Item {
                    ColumnLayout {
                        width: parent.width
                        spacing: 10

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8
                            Label {
                                text: qsTr("Cover")
                                color: "white"
                                font.pixelSize: 14
                                font.bold: true
                                Layout.fillWidth: true
                            }
                            Button {
                                id: noteCoverHelpButton
                                text: "?"
                                Layout.preferredWidth: 38
                                Layout.preferredHeight: 34
                                onClicked: toolNote.openCoverGuideHelp()
                                background: Rectangle { radius: 10; color: "white"; opacity: 0.20; border.width: 1; border.color: "white" }
                                contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 16 } }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Slider {
                                id: note_slCover
                                Layout.fillWidth: true
                                from: 0; to: 100
                                stepSize: 10
                                value: 0
                                onValueChanged: toolNote.noteCoverValue = Math.round(value / 10) * 10
                            }
                            Label { id: noteCoverLabel; color: "white"; font.pixelSize: 14; text: toolNote.noteCoverValue + "%" }
                        }

                        Label { text: qsTr("Mulch cover"); color: "white"; font.pixelSize: 14; font.bold: true }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            Slider {
                                id: note_slMulch_Cover
                                Layout.fillWidth: true
                                from: 0; to: 100
                                stepSize: 10
                                value: 0
                                onValueChanged: toolNote.noteMulch_CoverValue = Math.round(value / 10) * 10
                            }
                            Label { id: note_lblMulch; color: "white"; font.pixelSize: 14; text: toolNote.noteMulch_CoverValue + "%" }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            Label {
                                color: "white"
                                font.pixelSize: 14
                                font.bold: true
                                text: qsTr("Erosion present?")
                                Layout.fillWidth: true
                            }

                            Label { color: "white"; opacity: 0.9; font.pixelSize: 13; text: qsTr("No") }

                            Switch {
                                id: note_swErosion
                                checked: false
                                onCheckedChanged: toolNote.noteErosionValue = checked
                            }

                            Label { color: "white"; opacity: 0.9; font.pixelSize: 13; text: qsTr("Yes") }
                        }

                        Item { Layout.fillHeight: true; Layout.fillWidth: true }
                    }
                }

                // ===================== PAGE 3 (Photos optional) =====================
                Item {
                    ColumnLayout {
                        width: parent.width
                        spacing: 10

                        Label { text: qsTr("Photo documentation (optional)"); color: "white"; font.pixelSize: 14; font.bold: true }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Button {
                                id: note_btnPhoto1
                                text: (toolNote.notePhoto1Path && toolNote.notePhoto1Path !== "") ? qsTr("Replace photo 1") : qsTr("Take photo 1")
                                Layout.fillWidth: true
                                contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                                onClicked: toolNote.takePhoto(1)
                            }

                            Label {
                                id: note_lblPhoto1
                                text: (toolNote.notePhoto1Path && toolNote.notePhoto1Path !== "") ? qsTr("Available") : qsTr("—")
                                color: "white"
                                opacity: 0.85
                                font.pixelSize: 12
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 8

                            Button {
                                id: note_btnPhoto2
                                text: (toolNote.notePhoto2Path && toolNote.notePhoto2Path !== "") ? qsTr("Replace photo 2") : qsTr("Take photo 2")
                                Layout.fillWidth: true
                                contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                                onClicked: toolNote.takePhoto(2)
                            }

                            Label {
                                id: note_lblPhoto2
                                text: (toolNote.notePhoto2Path && toolNote.notePhoto2Path !== "") ? qsTr("Available") : qsTr("—")
                                color: "white"
                                opacity: 0.85
                                font.pixelSize: 12
                            }
                        }

                        Item { Layout.fillHeight: true; Layout.fillWidth: true }
                    }
                }

                // ===================== PAGE 4 (optional Text) =====================
                Item {
                    ColumnLayout {
                        width: parent.width
                        spacing: 10

                        Label { text: qsTr("Additional note (optional)"); color: "white"; font.pixelSize: 14; font.bold: true }

                        TextArea {
                            id: noteManagementTextArea
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            wrapMode: TextArea.Wrap
                            color: "white"
                            placeholderText: ""
                            leftPadding: 12
                            rightPadding: 12
                            topPadding: 14
                            bottomPadding: 12

                            background: Rectangle {
                                radius: 12
                                color: "white"
                                opacity: 0.12
                                border.width: 1
                                border.color: "white"
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            color: "white"
                            opacity: 0.85
                            font.pixelSize: 12
                            text: qsTr("Press \"Next\" to save the area.")
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Button {
                    id: note_btnBack
                    text: qsTr("Back")
                    Layout.fillWidth: true
                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                    onClicked: {
                        if (toolNote.noteManagementPage === 0) {
                            toolNote.pendingGeometry = null
                            toolNote.pendingLayerName = ""
                            noteManagementDialog.close()
                            toolNote.goHub()
                        } else {
                            toolNote.noteManagementPage = toolNote.noteManagementPage - 1
                        }
                    }
                }

                Button {
                    id: note_btnNext
                    text: (toolNote.noteManagementPage < 3) ? qsTr("Next") : qsTr("Save")
                    Layout.fillWidth: true
                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                    onClicked: {
                        if (toolNote.noteManagementPage < 3) {
                            toolNote.noteManagementPage = toolNote.noteManagementPage + 1
                            return
                        }
                        toolNote.commitManagementArea()
                    }
                }
            }
        }
    }
} // END toolNote



    // =========================================================
    // TOOL: PHOTOS (point) — GPS point and photo capture
    // Layer: "Photos"
    // Field (Attachment): "Photos"
    // =========================================================
    Item {
        id: toolPhotoPoint

        property string layerName: "Photos"
        property string fieldPhoto: "Photos"

        // store pending position while camera is open
        property var pendingPoint: null      // {x, y} in layer CRS/map projected as returned by helper
        property real pendingElevation: 0

        function activate() {
            pendingPoint = null
            // optional: auto-switch layer so user sees target layer immediately
            plugin.switchToLayer(layerName)
        }

        function deactivate() {
            pendingPoint = null
            // close camera if still open
            if (cameraLoader.active) cameraLoader.active = false
        }

        function startSnap() {
            if (!plugin.switchToLayer(layerName)) return
            let layer = plugin.layerByName(layerName)
            if (!layer) { plugin.toast("Layer not available"); return }

            // require valid GPS position (current location only)
            let pt = plugin.pointFromGpsOrCenter(false)
            if (!pt) { plugin.toast("Invalid GPS position – please check"); return }

            pendingPoint = pt

            // try to read elevation if available (safe fallback)
            try {
                if (plugin.positionSource && plugin.positionSource.positionInformation)
                    pendingElevation = plugin.positionSource.positionInformation.elevation
                else
                    pendingElevation = 0
            } catch(e) {
                pendingElevation = 0
            }

            // ensure DCIM folder exists in project home
            platformUtilities.createDir(qgisProject.homePath, "DCIM")

            // open camera
            cameraLoader.active = true
        }

        function snap(path) {
            if (!pendingPoint) {
                plugin.toast("No position available")
                cameraLoader.active = false
                return
            }

            // create a timestamped filename
            let today = new Date()
            let relativePath = "DCIM/"
                             + today.getFullYear()
                             + (today.getMonth() + 1).toString().padStart(2, "0")
                             + today.getDate().toString().padStart(2, "0")
                             + today.getHours().toString().padStart(2, "0")
                             + today.getMinutes().toString().padStart(2, "0")
                             + today.getSeconds().toString().padStart(2, "0")
                             + "." + FileUtils.fileSuffix(path)

            // move photo into the project folder
            platformUtilities.renameFile(path, qgisProject.homePath + "/" + relativePath)

            if (!plugin.switchToLayer(layerName)) return
            let layer = plugin.layerByName(layerName)
            if (!layer) { plugin.toast("Layer not available"); return }

            // Build WKT depending on layer type (POINT / POINTZ / POINTM / POINTZM / MultiPoint*)
            let wkt = ""
            let x = pendingPoint.x
            let y = pendingPoint.y
            let z = pendingElevation

            switch (layer.wkbTypee()) {
                case Qgis.WkbTypee.MultiPointZ:
                    wkt = "MULTIPOINTZ((" + x + " " + y + " " + z + "))"
                    break
                case Qgis.WkbTypee.MultiPointM:
                    wkt = "MULTIPOINTM((" + x + " " + y + " 0))"
                    break
                case Qgis.WkbTypee.MultiPointZM:
                    wkt = "MULTIPOINTZM((" + x + " " + y + " " + z + " 0))"
                    break
                case Qgis.WkbTypee.MultiPoint:
                    wkt = "MULTIPOINT((" + x + " " + y + "))"
                    break

                case Qgis.WkbTypee.PointZ:
                    wkt = "POINTZ(" + x + " " + y + " " + z + ")"
                    break
                case Qgis.WkbTypee.PointM:
                    wkt = "POINTM(" + x + " " + y + " 0)"
                    break
                case Qgis.WkbTypee.PointZM:
                    wkt = "POINTZM(" + x + " " + y + " " + z + " 0)"
                    break
                case Qgis.WkbTypee.Point:
                default:
                    wkt = "POINT(" + x + " " + y + ")"
                    break
            }

            let geom = GeometryUtils.createGeometryFromWkt(wkt)
            if (!geom) { plugin.toast("Invalid geometry"); return }

            let feature = FeatureUtils.createBlankFeature(layer.fields, geom)

            // set attachment path into the "Photos" field
            feature.setAttribute(fieldPhoto, relativePath)

            pendingPoint = null

            // commit (and reapply attribute to live feature)
            plugin.commitViaDrawerAndHide(feature, function(liveFeature) {
                liveFeature.setAttribute(fieldPhoto, relativePath)
            })

            // give the drawer a bit more time for photo/attachment workflows
            Qt.createQmlObject(
                'import QtQuick; Timer { interval: ' + plugin.drawerAutoCloseMsPhotos + '; running: true; repeat: false; onTriggered: { if (overlayFeatureFormDrawer && overlayFeatureFormDrawer.opened) overlayFeatureFormDrawer.close() } }',
                plugin
            )

            plugin.toast(qsTr("Photo saved"))
            plugin.setTool("none")

        }

        // ---------------------------------------------------------
        // Camera loader (self-contained)
        // ---------------------------------------------------------
        Loader {
            id: cameraLoader
            active: false
            sourceComponent: Component {
                QFieldItems.QFieldCamera {
                    id: qfieldCamera
                    visible: false

                    Component.onCompleted: open()

                    onFinished: (path) => {
                        close()
                        toolPhotoPoint.snap(path)
                    }

                    onCanceled: {
                        close()
                    }

                    onClosed: {
                        cameraLoader.active = false
                    }
                }
            }
        }

        // ---------------------------------------------------------
        // HUD: one action button
        // ---------------------------------------------------------
        Rectangle {
            parent: plugin.mainWindow.contentItem
            visible: plugin.currentTool === "photos_point"
            z: 70

            width: Math.min(parent.width * 0.70, 420)
            height: 87
            radius: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: plugin.hudBottomOffset

            color: Theme.darkGray
            opacity: 0.94

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 6

                Label {
                    text: qsTr("Take photo")
                    horizontalAlignment: Text.AlignHCenter
                    font.pixelSize: 14
                    font.bold: true
                    color: "white"
                    Layout.fillWidth: true
                }

                Button {
                    text: qsTr("Current position")
                    Layout.fillWidth: true
                    Layout.preferredHeight: 42
                    onClicked: toolPhotoPoint.startSnap()
                    background: Rectangle { radius: 14; color: "white"; opacity: 0.25; border.width: 1; border.color: "white" }
                    contentItem: Loader { sourceComponent: boldBtnText; onLoaded: { item.text = parent.text; item.font.pixelSize = 15 } }
                }
            }
        }
    }   // END toolPhotoPoint
    // =========================================================
    // TOOL: GLOSSARY / HELP — explains all buttons
    // Icon: ic_book_white_24dp
    // =========================================================
    Item {
        id: toolGlossary

        // icon: Theme Icon Name (wie in toolSpecs)
        property var entries: [
            {
                key: "crop",
                icon: "ic_baseline-list_white_24dp",
                title: "Management",
                text:
                    "Records management and land use details of the selected parcel, including crop type, management, cover, etc.\n" +
                    "Information is saved as a point layer.\n\n " +
                    "Note: The underlying parcel can be divided into multiple management forms (e.g. different crops) using the \"Notes\" tool (see below)."
            },
            {
                key: "area",
                icon: "ic_geometry_polygon_24dp",
                title: "Sheet erosion (area)",
                text:
                    "Represents an area where sheet erosion has occurred.\n\n" +
                    "The geometry describes the spatial outline of the affected area. " +
                    "The attributes characterize the type and extent of sheet erosion. " +
                    "and form the basis for area-based evaluations."
            },
            {
                key: "linear",
                icon: "ic_geometry_line_24dp",
                title: "Linear erosion (line)",
                text:
                    "For recording linear erosion forms (e.g. rills, gullies, ditches).\n\n" +
                    "Measuring points are recorded multiple times along the line. " +
                    "At each point, information about the erosion form (e.g. type, width, depth) is stored. " +
                    "All points of a line share one Line-ID. The last point of a line has to be marked in the form." +
                    "During post-processing these points will be connected by a line."
            },
            {
                key: "copy_linear",
                icon: "ic_transfer_into_black_24dp",
                title: "Copy linear erosion",
                text:
                    "Copies the measurements and attributes of an already recorded linear erosion line.\n\n" +
                    "Only the start and end points of the copied segment have to be recorded. " +
                    "Average measurements of the original line (for example width and depth) " +
                    "are adopted during post-processing."
            },
            {
                key: "sheet_to_linear",
                icon: "ic_camera_resolution_black_24dp",
                title: "Sheet-linear erosion (combination)",
                text:
                    "Records combined erosion forms in which area-based and linear processes occur together.\n\n" +
                    "Areas and lines are linked by an ID (e.g. FL001) and processed together."
            },
            {
                key: "deposition",
                icon: "ic_ring_tool_white_24dp",
                title: "Deposition",
                text:
                    "Enables recording of small and large (> 20 m²) Deposition areas.\n" +
                    "Small Deposition areas are recorded as points.\n" +
                    "Large Deposition areas require recording the affected area and five measurement points for deposit depth" 
            },
            {
                key: "runoff_point",
                icon: "ic_redo_black_24dp",
                title: "Runoff (point)",
                text:
                    "Records a runoff or sediment-transfer point into an adjacent ditch, road, stream, or parcel.\n\n" +
                    "Saved as a point."
            },
            {
                key: "overland_water_flow_point",
                icon: "ic_opacity_black_24dp",
                title: "Overland water flow (point)",
                text:
                    "Records observations related to overland water flow.\n\n" +
                    "Available types include concentrated water inflow, inlet shaft, and water outlet. " +
                    "Each observation is saved as a point."
            },
            {
                key: "note",
                icon: "ic_pin_black_24dp",
                title: "Notes (point / area)",
                text:
                    "Used for free documentation of additional observations and notes during mapping.\n\n" +
                    "Notes can be recorded as a point or area. A separate management area can be recorded via Note -> Area -> Create area -> Management." 
            },
            {
                key: "photos_point",
                icon: "ic_camera_photo_black_24dp",
                title: "Photo documentation (point)",
                text:
                    "A picture can be taken for documentation of crop types, .\n\n" +
                    "Saved as a point. " 
            }
        ]


        function activate() {
            glossaryDialog.open()
        }

        function deactivate() {
            if (glossaryDialog.opened) glossaryDialog.close()
        }

        Dialog {
            id: glossaryDialog
            modal: true
            parent: plugin.mainWindow.contentItem
            title: qsTr("Glossary")
            standardButtons: Dialog.NoButton

            anchors.centerIn: parent
            width: Math.min(plugin.mainWindow.width * plugin.dialogWidthFactor, plugin.dialogMaxWidth)
            height: Math.min(plugin.mainWindow.height * plugin.dialogHeightFactor, 600)

            onClosed: {
                if (plugin.currentTool === "glossary") plugin.setTool("none")
            }

            background: Rectangle {
                anchors.fill: parent
                radius: 16
                color: Theme.darkGray
                border.width: 1
                border.color: "white"
                opacity: 0.98
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: plugin.dialogPadding
                spacing: 10


                // Robust scroll list
                ListView {
                    id: glossaryList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 10

                    model: toolGlossary.entries

                    delegate: Rectangle {
                        width: glossaryList.width
                        radius: 12
                        color: "#2E2E2E"         
                        opacity: 1.0
                        border.width: 1
                        border.color: "#AAAAAA"  


                        // CRITICAL: give the delegate a real height
                        height: contentCol.implicitHeight + 24

                        Column {
                            id: contentCol
                            x: 12
                            y: 12
                            width: parent.width - 24
                            spacing: 10

                            Row {
                                width: parent.width
                                spacing: 10

                                // icon badge
                                Rectangle {
                                    width: 34
                                    height: 34
                                    radius: 10
                                    color: "#2E2E2E"
                                    border.width: 1
                                    border.color: "#AAAAAA"

                                    QfToolButton {
                                        anchors.centerIn: parent
                                        width: 40
                                        height: 40

                                        // Icon only — no button behavior
                                        iconSource: Theme.getThemeVectorIcon(modelData.icon)
                                        iconColor: Theme.mainColor   // Use the same green as the plugin toolbar
                                        bgcolor: "transparent"
                                        round: false
                                        enabled: false               // <-- prevents interaction
                                        opacity: 1.0
                                    }
                                }


                                Column {
                                    width: parent.width - 34 - 10
                                    spacing: 2

                                    Text {
                                        text: modelData.title
                                        color: "white"
                                        font.pixelSize: 14
                                        font.bold: true
                                        wrapMode: Text.WordWrap
                                        width: parent.width
                                    }

                                }
                            }

                            Text {
                                text: modelData.text
                                color: "white"
                                opacity: 0.92
                                font.pixelSize: 13
                                wrapMode: Text.WordWrap
                                width: parent.width
                            }
                        }
                    }
                }


                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Button {
                        text: qsTr("Close")
                        Layout.fillWidth: true
                        contentItem: Loader { sourceComponent: boldBtnText; onLoaded: item.text = parent.text }
                        onClicked: glossaryDialog.close()
                    }
                }
            }
        }
    } // END toolGlossary

}   // END root plugin Item
