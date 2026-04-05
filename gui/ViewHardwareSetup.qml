import QtQuick 2.5
import QtQuick.Controls 1.4
import QtQuick.Layouts 1.2
import QtQuick.Controls.Styles 1.4

View {
    id: root
    name: "Hardware Setup"
    color: "#222222"

    property bool in0Prop: false
    property bool in1Prop: false
    property bool in2Prop: false
    property bool in3Prop: false

    property bool out0Prop: false
    property bool out1Prop: false
    property bool out2Prop: false
    property bool out3Prop: false

    Connections {
        target: personality
        onGpioInputsChanged: {
            in0Prop = in0_val;
            in1Prop = in1_val;
            in2Prop = in2_val;
            in3Prop = in3_val;
        }
        onGpioOutputsChanged: {
            out0Prop = out0_val;
            out1Prop = out1_val;
            out2Prop = out2_val;
            out3Prop = out3_val;
        }
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: {
            if (personality && personality.updateAllGPIO) {
                personality.updateAllGPIO();
            }
        }
    }

    // indicatorStyle removed as we now inline the Rectangles for better compact formatting

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 2
        spacing: 2

        Label {
            Layout.fillWidth: true
            text: netWorker ? ("IP: " + netWorker.currentIfcAddr) : "IP: Checking..."
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 10
            color: "#00ffff"
            font.bold: true
        }

        GridLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 2
            columnSpacing: 4
            rowSpacing: 4

            // Headers
            Label { text: "INPUTS"; font.pixelSize: 10; color: "yellow"; font.bold: true; Layout.alignment: Qt.AlignHCenter }
            Label { text: "OUTPUTS"; font.pixelSize: 10; color: "yellow"; font.bold: true; Layout.alignment: Qt.AlignHCenter }

            // Row 0
            Rectangle {
                Layout.preferredWidth: 72; Layout.preferredHeight: 18; color: in0Prop ? "#aa0000" : "#222222"
                border.color: "white"; border.width: 1
                Label { text: "IN0:" + (in0Prop ? "HI" : "LO"); color: "white"; anchors.centerIn:parent; font.pixelSize: 10; font.bold: true }
            }
            Rectangle {
                Layout.preferredWidth: 72; Layout.preferredHeight: 18; color: out0Prop ? "#aa0000" : "#222222"
                border.color: "white"; border.width: 1
                Label { text: "OUT0:" + (out0Prop ? "HI" : "LO"); color: "white"; anchors.centerIn:parent; font.pixelSize: 10; font.bold: true }
                MouseArea { anchors.fill: parent; onClicked: personality.setOutput(0, !out0Prop) }
            }

            // Row 1
            Rectangle {
                Layout.preferredWidth: 72; Layout.preferredHeight: 18; color: in1Prop ? "#aa0000" : "#222222"
                border.color: "white"; border.width: 1
                Label { text: "IN1:" + (in1Prop ? "HI" : "LO"); color: "white"; anchors.centerIn:parent; font.pixelSize: 10; font.bold: true }
            }
            Rectangle {
                Layout.preferredWidth: 72; Layout.preferredHeight: 18; color: out1Prop ? "#aa0000" : "#222222"
                border.color: "white"; border.width: 1
                Label { text: "OUT1:" + (out1Prop ? "HI" : "LO"); color: "white"; anchors.centerIn:parent; font.pixelSize: 10; font.bold: true }
                MouseArea { anchors.fill: parent; onClicked: personality.setOutput(1, !out1Prop) }
            }

            // Row 2
            Rectangle {
                Layout.preferredWidth: 72; Layout.preferredHeight: 18; color: in2Prop ? "#aa0000" : "#222222"
                border.color: "white"; border.width: 1
                Label { text: "IN2:" + (in2Prop ? "HI" : "LO"); color: "white"; anchors.centerIn:parent; font.pixelSize: 10; font.bold: true }
            }
            Rectangle {
                Layout.preferredWidth: 72; Layout.preferredHeight: 18; color: out2Prop ? "#aa0000" : "#222222"
                border.color: "white"; border.width: 1
                Label { text: "OUT2:" + (out2Prop ? "HI" : "LO"); color: "white"; anchors.centerIn:parent; font.pixelSize: 10; font.bold: true }
                MouseArea { anchors.fill: parent; onClicked: personality.setOutput(2, !out2Prop) }
            }

            // Row 3
            Rectangle {
                Layout.preferredWidth: 72; Layout.preferredHeight: 18; color: in3Prop ? "#aa0000" : "#222222"
                border.color: "white"; border.width: 1
                Label { text: "IN3:" + (in3Prop ? "HI" : "LO"); color: "white"; anchors.centerIn:parent; font.pixelSize: 10; font.bold: true }
            }
            Rectangle {
                Layout.preferredWidth: 72; Layout.preferredHeight: 18; color: out3Prop ? "#aa0000" : "#222222"
                border.color: "white"; border.width: 1
                Label { text: "OUT3:" + (out3Prop ? "HI" : "LO"); color: "white"; anchors.centerIn:parent; font.pixelSize: 10; font.bold: true }
                MouseArea { anchors.fill: parent; onClicked: personality.setOutput(3, !out3Prop) }
            }
            
            Item { Layout.fillHeight: true }
        }
    }
}
