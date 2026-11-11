// Main.qml — HWE SDDM greeter. Bare QtQuick; no optional Controls style.
import QtQuick 2.15

Rectangle {
    id: root
    width: 1920
    height: 1080
    color: config.BgColor || "#11111b"

    readonly property color cBg: config.BgColor || "#11111b"
    readonly property color cField: config.FieldBg || "#1e1e2e"
    readonly property color cFg: config.FgColor || "#cdd6f4"
    readonly property color cFgDim: config.FgDim || "#9399b2"
    readonly property color cAccent: config.Accent || "#cba6f7"
    readonly property color cOnAccent: config.OnAccent || cBg
    readonly property color cErr: config.Error || "#f38ba8"
    readonly property color cScrim: config.ScrimColor || cBg
    readonly property string uiFont: config.FontFamily || "sans-serif"
    readonly property int radius: config.Radius ? Number(config.Radius) : 12
    readonly property string currentLayout: {
        if (!keyboard.enabled || keyboard.layouts.length === 0)
            return "—";
        var index = Math.max(0, Math.min(keyboard.currentLayout, keyboard.layouts.length - 1));
        return keyboard.layouts[index].shortName.toUpperCase();
    }

    property int sessionIndex: sessionModel.lastIndex
    property var sessionNames: []
    property bool showPassword: false

    function doLogin() {
        message.text = "";
        sddm.login(userField.text, passField.text, root.sessionIndex);
    }

    function nextLayout() {
        if (keyboard.enabled && keyboard.layouts.length > 0)
            keyboard.currentLayout = (keyboard.currentLayout + 1) % keyboard.layouts.length;
    }

    function nextSession() {
        if (root.sessionNames.length > 0)
            root.sessionIndex = (root.sessionIndex + 1) % root.sessionNames.length;
    }

    Image {
        anchors.fill: parent
        source: config.Background || ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        visible: source != ""
    }
    Rectangle {
        anchors.fill: parent
        color: cScrim
        opacity: Number(config.ScrimOpacity) || 0.94
    }

    Timer {
        id: ticker
        property var now: new Date()
        interval: 1000
        running: true
        repeat: true
        onTriggered: now = new Date()
    }
    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: parent.height * 0.13
        spacing: 6
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatTime(ticker.now, "HH:mm")
            color: cFg
            font.family: uiFont
            font.pixelSize: 104
            font.bold: true
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: Qt.formatDate(ticker.now, "dddd, d MMMM")
            color: cFgDim
            font.family: uiFont
            font.pixelSize: 22
        }
    }

    Column {
        anchors.centerIn: parent
        width: 360
        spacing: 14

        Rectangle {
            width: parent.width
            height: 50
            radius: root.radius
            color: cField
            border.width: 2
            border.color: userField.activeFocus ? cAccent : "transparent"
            TextInput {
                id: userField
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: TextInput.AlignVCenter
                color: cFg
                font.family: uiFont
                font.pixelSize: 18
                clip: true
                text: userModel.lastUser || ""
                activeFocusOnTab: true
                KeyNavigation.down: passField
                onAccepted: passField.forceActiveFocus()
            }
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: "username"
                color: cFgDim
                font.family: uiFont
                font.pixelSize: 18
                visible: userField.text.length === 0 && !userField.activeFocus
            }
        }

        Rectangle {
            width: parent.width
            height: 50
            radius: root.radius
            color: cField
            border.width: 2
            border.color: passField.activeFocus ? cAccent : "transparent"
            TextInput {
                id: passField
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 108
                verticalAlignment: TextInput.AlignVCenter
                color: cFg
                font.family: uiFont
                font.pixelSize: 18
                clip: true
                echoMode: root.showPassword ? TextInput.Normal : TextInput.Password
                passwordCharacter: "•"
                activeFocusOnTab: true
                KeyNavigation.down: loginButton
                onAccepted: root.doLogin()
            }
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: "password"
                color: cFgDim
                font.family: uiFont
                font.pixelSize: 18
                visible: passField.text.length === 0 && !passField.activeFocus
            }
            Text {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: root.showPassword ? "Hide" : "Show"
                color: cFgDim
                font.family: uiFont
                font.pixelSize: 14
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -8
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.showPassword = !root.showPassword
                }
            }
        }

        Item {
            width: parent.width
            height: 22
            Text {
                text: "Layout: " + root.currentLayout
                color: cFgDim
                font.family: uiFont
                font.pixelSize: 14
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.nextLayout()
                }
            }
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 120
                text: "CAPS LOCK"
                visible: keyboard.capsLock
                color: cErr
                font.family: uiFont
                font.pixelSize: 14
                font.bold: true
            }
            Text {
                anchors.right: parent.right
                text: "Ctrl+H: show password"
                color: cFgDim
                font.family: uiFont
                font.pixelSize: 12
            }
        }

        Rectangle {
            id: loginButton
            width: parent.width
            height: 50
            radius: root.radius
            color: loginMouse.containsMouse || activeFocus ? cAccent : Qt.darker(cAccent, 1.15)
            border.width: activeFocus ? 3 : 0
            border.color: cFg
            activeFocusOnTab: true
            KeyNavigation.down: sessionButton
            Keys.onReturnPressed: root.doLogin()
            Keys.onEnterPressed: root.doLogin()
            Text {
                anchors.centerIn: parent
                text: "Log In"
                color: cOnAccent
                font.family: uiFont
                font.pixelSize: 18
                font.bold: true
            }
            MouseArea {
                id: loginMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    loginButton.forceActiveFocus();
                    root.doLogin();
                }
            }
        }

        Text {
            id: message
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            color: cErr
            font.family: uiFont
            font.pixelSize: 15
            wrapMode: Text.WordWrap
            text: ""
        }
    }

    Repeater {
        model: sessionModel
        Item { Component.onCompleted: root.sessionNames.push(model.name) }
    }
    Rectangle {
        id: sessionButton
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: 24
        width: 210
        height: 44
        radius: root.radius
        color: cField
        border.width: 2
        border.color: activeFocus ? cAccent : "transparent"
        activeFocusOnTab: true
        KeyNavigation.right: shutdownButton
        KeyNavigation.down: shutdownButton
        Keys.onReturnPressed: root.nextSession()
        Keys.onEnterPressed: root.nextSession()
        Text {
            anchors.centerIn: parent
            color: cFgDim
            font.family: uiFont
            font.pixelSize: 14
            text: "Session: " + (root.sessionNames[root.sessionIndex] || "default")
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                sessionButton.forceActiveFocus();
                root.nextSession();
            }
        }
    }

    Row {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 24
        spacing: 12
        Rectangle {
            id: shutdownButton
            width: 126
            height: 44
            radius: root.radius
            color: cField
            border.width: 2
            border.color: activeFocus ? cAccent : "transparent"
            visible: sddm.canPowerOff
            activeFocusOnTab: true
            KeyNavigation.right: rebootButton
            Keys.onReturnPressed: sddm.powerOff()
            Keys.onEnterPressed: sddm.powerOff()
            Text {
                anchors.centerIn: parent
                text: "⏻ Shutdown"
                color: cFgDim
                font.family: uiFont
                font.pixelSize: 14
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: sddm.powerOff()
            }
        }
        Rectangle {
            id: rebootButton
            width: 112
            height: 44
            radius: root.radius
            color: cField
            border.width: 2
            border.color: activeFocus ? cAccent : "transparent"
            visible: sddm.canReboot
            activeFocusOnTab: true
            KeyNavigation.left: shutdownButton
            KeyNavigation.up: loginButton
            Keys.onReturnPressed: sddm.reboot()
            Keys.onEnterPressed: sddm.reboot()
            Text {
                anchors.centerIn: parent
                text: "↻ Reboot"
                color: cFgDim
                font.family: uiFont
                font.pixelSize: 14
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: sddm.reboot()
            }
        }
    }

    Shortcut {
        sequence: "Ctrl+H"
        onActivated: root.showPassword = !root.showPassword
    }

    Connections {
        target: sddm
        function onLoginFailed() {
            message.text = "Login failed — check username, password, layout and Caps Lock";
            passField.text = "";
            passField.forceActiveFocus();
        }
        function onInformationMessage(msg) { message.text = msg; }
    }

    Component.onCompleted: {
        if (userField.text.length > 0)
            passField.forceActiveFocus();
        else
            userField.forceActiveFocus();
    }
}
