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

    Component {
        id: indicatorStyle
        Rectangle {
            width: 80
            height: 30
            color: activeState ? "red" : "#222222"
            border.color: "white"
            border.width: 1
            property bool activeState: false
            Label {
                anchors.centerIn: parent
                text: activeState ? "HIGH" : "LOW"
                color: "white"
                font.bold: true
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10

        Label {
            Layout.fillWidth: true
            text: "Hardware Setup Mode"
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 24
            font.weight: Font.Bold
            color: "#ffff00"
        }

        Label {
            Layout.fillWidth: true
            text: "IP Address: " + (netWorker ? netWorker.currentIfcAddr : "Checking...")
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 18
            color: "#00ffff"
        }

        Item { Layout.preferredHeight: 10 }

        GridLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            columns: 2
            columnSpacing: 10

            // INPUTS
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#111111"
                border.width: 2
                border.color: "#444444"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 10

                    Label {
                        Layout.fillWidth: true
                        text: "GPIO Inputs (Dynamic)"
                        font.pixelSize: 16
                        font.bold: true
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                    }

                    // IN0
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: (config.GPIO_InputNames[0] ? config.GPIO_InputNames[0] : "") + " (IN0)"; color: "white"; font.pixelSize: 14; Layout.fillWidth: true }
                        Loader { sourceComponent: indicatorStyle; property bool activeState: in0Prop }
                    }
                    // IN1
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: (config.GPIO_InputNames[1] ? config.GPIO_InputNames[1] : "") + " (IN1)"; color: "white"; font.pixelSize: 14; Layout.fillWidth: true }
                        Loader { sourceComponent: indicatorStyle; property bool activeState: in1Prop }
                    }
                    // IN2
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: (config.GPIO_InputNames[2] ? config.GPIO_InputNames[2] : "") + " (IN2)"; color: "white"; font.pixelSize: 14; Layout.fillWidth: true }
                        Loader { sourceComponent: indicatorStyle; property bool activeState: in2Prop }
                    }
                    // IN3
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: (config.GPIO_InputNames[3] ? config.GPIO_InputNames[3] : "") + " (IN3)"; color: "white"; font.pixelSize: 14; Layout.fillWidth: true }
                        Loader { sourceComponent: indicatorStyle; property bool activeState: in3Prop }
                    }
                    
                    Item { Layout.fillHeight: true }
                }
            }

            // OUTPUTS
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#111111"
                border.width: 2
                border.color: "#444444"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 10

                    Label {
                        Layout.fillWidth: true
                        text: "GPIO Outputs (Click to Toggle)"
                        font.pixelSize: 16
                        font.bold: true
                        color: "white"
                        horizontalAlignment: Text.AlignHCenter
                    }

                    // OUT0
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: (config.GPIO_OutputNames[0] ? config.GPIO_OutputNames[0] : "") + " (OUT0)"; color: "white"; font.pixelSize: 14; Layout.fillWidth: true }
                        Button { width: 80; text: out0Prop ? "HIGH" : "LOW"; onClicked: { personality.setOutput(0, !out0Prop) } }
                    }
                    // OUT1
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: (config.GPIO_OutputNames[1] ? config.GPIO_OutputNames[1] : "") + " (OUT1)"; color: "white"; font.pixelSize: 14; Layout.fillWidth: true }
                        Button { width: 80; text: out1Prop ? "HIGH" : "LOW"; onClicked: { personality.setOutput(1, !out1Prop) } }
                    }
                    // OUT2
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: (config.GPIO_OutputNames[2] ? config.GPIO_OutputNames[2] : "") + " (OUT2)"; color: "white"; font.pixelSize: 14; Layout.fillWidth: true }
                        Button { width: 80; text: out2Prop ? "HIGH" : "LOW"; onClicked: { personality.setOutput(2, !out2Prop) } }
                    }
                    // OUT3
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: (config.GPIO_OutputNames[3] ? config.GPIO_OutputNames[3] : "") + " (OUT3)"; color: "white"; font.pixelSize: 14; Layout.fillWidth: true }
                        Button { width: 80; text: out3Prop ? "HIGH" : "LOW"; onClicked: { personality.setOutput(3, !out3Prop) } }
                    }
                    
                    Item { Layout.fillHeight: true }
                }
            }
        }
    }
}
