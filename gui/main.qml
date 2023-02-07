// --------------------------------------------------------------------------
//  _____       ______________
// |  __ \   /\|__   ____   __|
// | |__) | /  \  | |    | |
// |  _  / / /\ \ | |    | |
// | | \ \/ ____ \| |    | |
// |_|  \_\/    \_\_|    |_|    ... RFID ALL THE THINGS!
//
// A resource access control and telemetry solution for Makerspaces
//
// Developed at MakeIt Labs - New Hampshire's First & Largest Makerspace
// http://www.makeitlabs.com/
//
// Copyright 2018 MakeIt Labs
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
// --------------------------------------------------------------------------
//
// Author: Steve Richardson (steve.richardson@makeitlabs.com)
//

import QtQuick 2.5
import QtQuick.Controls 1.4
import QtQuick.Layouts 1.2
import QtGraphicalEffects 1.12
import RATT 1.0

ApplicationWindow {
    id: appWindow
    visible: true
    color: "#004488"
    width: 1024
    height: 768

    signal uiEvent(string evt)
    signal mqttPublishSubtopicEvent(string subtopic, string msg)

    property string idleBusyView: ""
    property bool simLED1: false
    property bool simLED2: false

        function updateSimGPIO(pinName, value)
        {
            switch (pinName) {
                case 'LED1':
                simLED1 = value;
                break;
                case 'LED2':
                simLED2 = value;
                break;
            }

        }

        Component.onCompleted: {
            appWindow.uiEvent.connect(personality.slotUIEvent)
            appWindow.mqttPublishSubtopicEvent.connect(mqtt.slotPublishSubtopic)

            personality.slotSimGPIOChangePin('POWER_PRESENT', true);
            personality.slotSimGPIOChangePin('CHARGE_STATE', true);
            personality.slotSimGPIOChangePin('IN0', true);
            personality.slotSimGPIOChangePin('IN1', true);
            personality.slotSimGPIOChangePin('IN2', true);
            personality.slotSimGPIOChangePin('IN3', true);


        }

        Connections {
            target: personality

            onSimGPIOPinChanged: updateSimGPIO(pinName, value)

            // switch to the view if not already there
            function switchTo(newItem)
            {
                if (stack.currentItem !== newItem)
                {
                    stack.currentItem.hide();
                    stack.replace(newItem);
                }
            }

            function showCurrentStateView()
            {
                var curState = personality.currentState;

                var sp = curState.split(".");

                if (sp.length >= 2)
                {
                    var state = sp[0];
                    var phase = sp[1];

                    switch (state) {
                        case "Idle":
                        case "NotPowered":
                        switchTo(viewIdle);
                        break;
                        case "IdleBusy":
                        switch (idleBusyView) {
                            case "memberList":
                            switchTo(viewMemberList);
                            break;
                            default:
                            switchTo(viewIdle);
                        }
                        break;
                        case "NotPoweredDenied":
                        switchTo(viewAccess);
                        break;
                        case "AccessAllowed":
                        case "RFIDError":
                        switchTo(viewAccess);
                        break;
                        case "AccessDenied":
                        if (config.Personality_PasswordEnabled)
                        {
                            switchTo(viewPassword);
                        } else {
                        switchTo(viewAccess);
                    }
                    break;
                    case "ReportIssue":
                    switchTo(viewIssue);
                    break;
                    case "Homing":
                    switchTo(viewHoming);
                    break;
                    case "HomingFailed":
                    switchTo(viewHomingFailed);
                    break;
                    case "HomingOverride":
                    switchTo(viewHomingOverride);
                    break;
                    case "WaitEstopActive":
                    switchTo(viewWaitEstopActive);
                    break;
                    case "SafetyCheck":
                    switchTo(viewSafetyCheck);
                    break;
                    case "SafetyCheckFailed":
                    switchTo(viewSafetyFailed);
                    break;
                    case "ToolEnabledInactive":
                    case "ToolEnabledActive":
                    case "ToolEnabledNotPowered":
                    case "ToolEnabledEmergencyStop":
                    switchTo(viewEnabled);
                    break;
                    case "ToolEmergencyStop":
                    switchTo(viewEmergencyStop);
                    break;
                    case "PowerLoss":
                    switchTo(viewPowerLoss);
                    break;
                    case "ShutDown":
                    break;
                    case "LockOut":
                    switchTo(viewLockedOut);
                    break;
                }
            }
        }

        Component.onCompleted: {
            showCurrentStateView();
        }

        onCurrentStateChanged: {
            showCurrentStateView();
        }

        onStateChanged: {
            console.info("current state changed " + state + ":" + phase);

        }
    }

    RattSounds {
        id: sound
    }

    Image {
        source: 'images/RATT-Overlay-1024.png'



        Image {
            width: 36
            height: 36
            x: 278
            y: 472
            source: 'images/Green-LED-36.png'
            visible: simLED1
        }

        Image {
            width: 36
            height: 36
            x: 712
            y: 470
            source: 'images/Red-LED-36.png'
            visible: simLED2
        }


        Rectangle {
            // yellow
            x: 329
            y: 522
            width: 79
            height: 79
            color: 'black'
            Rectangle {
                anchors.fill: parent
                anchors.centerIn: parent
                radius: 8
                color: '#daa43f'
                border.color: '#000000'
                border.width: ma1.pressed ? '4' : '2'

                Rectangle {
                    anchors.centerIn: parent
                    width: ma1.pressed ? 54 : 60
                    height: ma1.pressed ? 54 : 60
                    radius: ma1.pressed ? 27 : 30
                    opacity: 0.1

                    LinearGradient {
                        visible: !ma1.pressed
                        source: parent
                        anchors.fill: parent
                        start: Qt.point(0, 0)
                        end: Qt.point(30, 30)
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 1) }
                            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 1) }
                        }
                    }
                }
            }
            MouseArea {
                id: ma1
                anchors.fill: parent
                onPressed: {
                    appEngine.syntheticKeypressHandler(Qt.Key_Escape, true);
                }
                onReleased: {
                    appEngine.syntheticKeypressHandler(Qt.Key_Escape, false);
                }
            }
        }

        Rectangle {
            // gray1
            x: 425
            y: 522
            width: 79
            height: 79
            color: 'black'
            Rectangle {
                anchors.fill: parent
                anchors.centerIn: parent
                radius: 8
                color: '#aaa9a8'
                border.color: '#000000'
                border.width: ma2.pressed ? '4' : '2'

                Rectangle {
                    anchors.centerIn: parent
                    width: ma2.pressed ? 54 : 60
                    height: ma2.pressed ? 54 : 60
                    radius: ma2.pressed ? 27 : 30
                    opacity: 0.1

                    LinearGradient {
                        visible: !ma2.pressed
                        source: parent
                        anchors.fill: parent
                        start: Qt.point(0, 0)
                        end: Qt.point(30, 30)
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 1) }
                            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 1) }
                        }
                    }
                }
            }
            MouseArea {
                id: ma2
                anchors.fill: parent
                onPressed: {
                    appEngine.syntheticKeypressHandler(Qt.Key_Down, true);
                }
                onReleased: {
                    appEngine.syntheticKeypressHandler(Qt.Key_Down, false);
                }
            }
        }

        Rectangle {
            // gray2
            x: 521
            y: 522
            width: 79
            height: 79
            color: 'black'
            Rectangle {
                anchors.fill: parent
                anchors.centerIn: parent
                radius: 8
                color: '#aaa9a8'
                border.color: '#000000'
                border.width: ma3.pressed ? '4' : '2'

                Rectangle {
                    anchors.centerIn: parent
                    width: ma3.pressed ? 54 : 60
                    height: ma3.pressed ? 54 : 60
                    radius: ma3.pressed ? 27 : 30
                    opacity: 0.1

                    LinearGradient {
                        visible: !ma3.pressed
                        source: parent
                        anchors.fill: parent
                        start: Qt.point(0, 0)
                        end: Qt.point(30, 30)
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 1) }
                            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 1) }
                        }
                    }
                }
            }
            MouseArea {
                id: ma3
                anchors.fill: parent
                onPressed: {
                    appEngine.syntheticKeypressHandler(Qt.Key_Up, true);
                }
                onReleased: {
                    appEngine.syntheticKeypressHandler(Qt.Key_Up, false);
                }
            }
        }



        Rectangle {
            // blue
            x: 617
            y: 522
            width: 79
            height: 79
            color: 'black'
            Rectangle {
                anchors.fill: parent
                anchors.centerIn: parent
                radius: 8
                color: '#3a3e73'
                border.color: '#000000'
                border.width: ma4.pressed ? '4' : '2'

                Rectangle {
                    anchors.centerIn: parent
                    width: ma4.pressed ? 54 : 60
                    height: ma4.pressed ? 54 : 60
                    radius: ma4.pressed ? 27 : 30
                    opacity: 0.1

                    LinearGradient {
                        visible: !ma4.pressed
                        source: parent
                        anchors.fill: parent
                        start: Qt.point(0, 0)
                        end: Qt.point(30, 30)
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 1) }
                            GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 1) }
                        }
                    }
                }
            }
            MouseArea {
                id: ma4
                anchors.fill: parent
                onPressed: {
                    appEngine.syntheticKeypressHandler(Qt.Key_Return, true);
                }
                onReleased: {
                    appEngine.syntheticKeypressHandler(Qt.Key_Return, false);
                }
            }
        }




        Rectangle {
            id: root
            //anchors.top: parent.top
            y: 257
            scale: 1.65
            radius: 10
            anchors.horizontalCenter: parent.horizontalCenter
            color: "black"
            width: tftWindow.width + 4
            height: tftWindow.height + 4

            Item {
                id: tftWindow
                focus: true
                anchors.centerIn: parent
                width: 160
                height: 128

                RattToolBar {
                    id: tool
                    width: parent.width
                    anchors.top: parent.top
                }

                RattStatusBar {
                    id: status
                    width: parent.width
                    anchors.bottom: parent.bottom
                }

                StackView {
                    id: stack
                    anchors.top: tool.bottom
                    anchors.bottom: status.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    initialItem: viewSplash

                    onCurrentItemChanged: {
                        if (currentItem)
                            currentItem.show();
                    }
                    focus: true

                    delegate: StackViewDelegate {

                        replaceTransition: StackViewTransition {
                            SequentialAnimation {
                                ScriptAction {
                                    script: enterItem.scale = 1
                                }
                                PropertyAnimation {
                                    target: enterItem
                                    property: "scale"
                                    from: 0
                                    to: 1
                                    duration: 350
                                }
                            }
                            PropertyAnimation {
                                target: exitItem
                                property: "scale"
                                from: 1
                                to: 0
                                duration: 100
                            }
                        }
                    }

                    ViewSplash {
                        id: viewSplash
                        visible: false
                    }
                    ViewIdle {
                        id: viewIdle
                        visible: false
                    }
                    ViewMemberList {
                        id: viewMemberList
                        visible: false
                    }
                    ViewAccess {
                        id: viewAccess
                        visible: false
                    }
                    ViewPassword {
                        id: viewPassword
                        visible: false
                    }
                    ViewHoming {
                        id: viewHoming
                        visible: false
                    }
                    ViewHomingFailed {
                        id: viewHomingFailed
                        visible: false
                    }
                    ViewHomingOverride {
                        id: viewHomingOverride
                        visible: false
                    }
                    ViewWaitEstopActive {
                        id: viewWaitEstopActive
                        visible: false
                    }
                    ViewSafetyCheck {
                        id: viewSafetyCheck
                        visible: false
                    }
                    ViewSafetyFailed {
                        id: viewSafetyFailed
                        visible: false
                    }
                    ViewEnabled {
                        id: viewEnabled
                        visible: false
                    }
                    ViewEmergencyStop {
                        id: viewEmergencyStop
                        visible: false
                    }
                    ViewIssue {
                        id: viewIssue
                        visible: false
                    }
                    ViewPowerLoss {
                        id: viewPowerLoss
                        visible: false
                    }
                    ViewLockedOut {
                        id: viewLockedOut
                        visible: false
                    }
                }
            }
        }
    }

    Loader {
        id: diagsLoader
        anchors.top: root.bottom
        anchors.left: parent.left
        width: parent.width
        height: parent.height - root.height
        anchors.margins: 4

        Component.onCompleted: {
            if (config.General_Diags)
            {
                diagsLoader.source = "RattDiags.qml"
            }
        }
    }



    Label {
        id: mver
        width: 150
        visible: !config.General_Virt
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.margins: 5
        font.family: "mono"
        font.weight: Font.Bold
        font.pixelSize: 14
        color: "#00ffff"
        text: "Mender Artifact=" + menderArtifact
    }
    Label {
        id: aver
        width: 150
        visible: !config.General_Virt
        anchors.top: mver.bottom
        anchors.left: parent.left
        anchors.margins: 5
        font.family: "mono"
        font.weight: Font.Bold
        font.pixelSize: 14
        color: "#ffff00"
        text: "App Version=" + appVersion
    }
}
