// Main.qml — HWE SDDM greeter.
//
// Palette-driven: every colour and the background come from theme.conf, which
// `hwe theme` regenerates from the active theme's semantic palette (so the login
// screen recolours with the rest of the desktop). Built on bare QtQuick — no
// QtQuick.Controls style dependency — so it can't break on a missing style: a
// login screen is the one surface we can't hot-fix from inside a session.
import QtQuick 2.15

Rectangle {
    id: root
    width: 1920
    height: 1080
    color: config.BgColor || "#11111b"

    // ── palette (strings from theme.conf, with safe fallbacks) ──────────────
    readonly property color cBg:    config.BgColor  || "#11111b"
    readonly property color cField: config.FieldBg  || "#1e1e2e"
    readonly property color cFg:    config.FgColor  || "#cdd6f4"
    readonly property color cFgDim: config.FgDim    || "#9399b2"
    readonly property color cAccent:config.Accent   || "#cba6f7"
    readonly property color cErr:   config.Error    || "#f38ba8"
    readonly property string uiFont: config.FontFamily || "sans-serif"
    readonly property int radius: config.Radius ? Number(config.Radius) : 12

    property int sessionIndex: sessionModel.lastIndex
    property var sessionNames: []

    // ── background image + darkening scrim ──────────────────────────────────
    Image {
        anchors.fill: parent
        source: config.Background || ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        visible: source != ""
    }
    Rectangle { anchors.fill: parent; color: "#000000"; opacity: 0.45 }

    // ── clock ───────────────────────────────────────────────────────────────
    Timer {
        id: ticker
        property var now: new Date()
        interval: 1000; running: true; repeat: true
        onTriggered: now = new Date()
    }
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: parent.height * 0.15
        spacing: 6
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatTime(ticker.now, "HH:mm")
            color: cFg; font.family: uiFont; font.pixelSize: 104; font.bold: true
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDate(ticker.now, "dddd, d MMMM")
            color: cFgDim; font.family: uiFont; font.pixelSize: 22
        }
    }

    // ── login card ──────────────────────────────────────────────────────────
    function doLogin() {
        message.text = "";
        sddm.login(userField.text, passField.text, root.sessionIndex);
    }

    Column {
        anchors.centerIn: parent
        width: 340
        spacing: 16

        // username
        Rectangle {
            width: parent.width; height: 50; radius: root.radius; color: cField
            border.width: 2
            border.color: userField.activeFocus ? cAccent : "transparent"
            TextInput {
                id: userField
                anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16
                verticalAlignment: TextInput.AlignVCenter
                color: cFg; font.family: uiFont; font.pixelSize: 18
                clip: true; text: userModel.lastUser || ""
                onAccepted: passField.forceActiveFocus()
            }
            Text {
                anchors.left: parent.left; anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: "username"; color: cFgDim; font.family: uiFont; font.pixelSize: 18
                visible: userField.text.length === 0 && !userField.activeFocus
            }
        }

        // password
        Rectangle {
            width: parent.width; height: 50; radius: root.radius; color: cField
            border.width: 2
            border.color: passField.activeFocus ? cAccent : "transparent"
            TextInput {
                id: passField
                anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16
                verticalAlignment: TextInput.AlignVCenter
                color: cFg; font.family: uiFont; font.pixelSize: 18
                clip: true; echoMode: TextInput.Password; passwordCharacter: "•"
                onAccepted: root.doLogin()
            }
            Text {
                anchors.left: parent.left; anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: "password"; color: cFgDim; font.family: uiFont; font.pixelSize: 18
                visible: passField.text.length === 0 && !passField.activeFocus
            }
        }

        // login button
        Rectangle {
            width: parent.width; height: 50; radius: root.radius
            color: loginMouse.containsMouse ? cAccent : Qt.darker(cAccent, 1.15)
            Text {
                anchors.centerIn: parent
                text: "Log In"; color: cBg
                font.family: uiFont; font.pixelSize: 18; font.bold: true
            }
            MouseArea {
                id: loginMouse
                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: root.doLogin()
            }
        }

        // status / error line
        Text {
            id: message
            width: parent.width; horizontalAlignment: Text.AlignHCenter
            color: cErr; font.family: uiFont; font.pixelSize: 15
            wrapMode: Text.WordWrap; text: ""
        }
    }

    // ── session selector (bottom-left) ──────────────────────────────────────
    Repeater {
        model: sessionModel
        Item { Component.onCompleted: root.sessionNames.push(model.name) }
    }
    Text {
        anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 28
        color: cFgDim; font.family: uiFont; font.pixelSize: 15
        text: "→ " + (root.sessionNames[root.sessionIndex] || "session")
        MouseArea {
            anchors.fill: parent; anchors.margins: -8
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                if (root.sessionNames.length > 0)
                    root.sessionIndex = (root.sessionIndex + 1) % root.sessionNames.length;
            }
        }
    }

    // ── power controls (bottom-right) ───────────────────────────────────────
    Row {
        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 24
        spacing: 20
        Text {
            text: "⏻ Shutdown"; color: cFgDim; font.family: uiFont; font.pixelSize: 15
            visible: sddm.canPowerOff
            MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: sddm.powerOff() }
        }
        Text {
            text: "↻ Reboot"; color: cFgDim; font.family: uiFont; font.pixelSize: 15
            visible: sddm.canReboot
            MouseArea { anchors.fill: parent; anchors.margins: -8; cursorShape: Qt.PointingHandCursor; onClicked: sddm.reboot() }
        }
    }

    // ── SDDM signals ────────────────────────────────────────────────────────
    Connections {
        target: sddm
        function onLoginFailed() {
            message.text = "Login failed";
            passField.text = "";
            passField.forceActiveFocus();
        }
        function onInformationMessage(msg) { message.text = msg; }
    }

    Component.onCompleted: {
        if (userField.text.length > 0) passField.forceActiveFocus();
        else userField.forceActiveFocus();
    }
}
