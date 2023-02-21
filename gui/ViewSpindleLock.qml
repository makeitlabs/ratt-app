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
// Copyright 2022 MakeIt Labs
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

import QtQuick 2.6
import QtQuick.Controls 1.4
import QtQuick.Layouts 1.3
import QtGraphicalEffects 1.0

View {
    id: root
    name: "Spindle Lock"
    property bool isLocked: false
    property bool failedRFID : false

    color: isLocked ? "#883333" : "#333333"



    function _show() {
    }

    function _hide() {
    }

    function done() {
    }

    Connections {
        target: personality

        function checkPersonalityState() {
            var curState = personality.currentState;
            var sp = curState.split(".");

            if (sp.length >= 2) {
                var state = sp[0];
                var phase = sp[1];

                isLocked = state == "ToolSpindleLocked" || state == "ToolSpindleUnlockFailed";
                failedRFID = state == "ToolSpindleUnlockFailed"

                if (state == "ToolSpindleLocked") {
                    sound.safetyFailedAudio.play();
                } else if (state == "ToolSpindleUnlockFailed") {
                    sound.rfidFailureAudio.play();
                }
            }
        }

        Component.onCompleted: {
            checkPersonalityState();
        }

        onCurrentStateChanged: {
            checkPersonalityState();
        }
    }


    SequentialAnimation {
        running: true
        loops: Animation.Infinite
        PropertyAnimation {
            targets: isLocked ? [item1] : [item1, item2]
            property: "opacity"
            from: 1.0
            to: 0.2
            duration: isLocked ? 1500 : 500
        }
        PropertyAnimation {
            targets: isLocked ? [item1] : [item1, item2]
            property: "opacity"
            from: 0.2
            to: 1.0
            duration: isLocked ? 1500 : 500
        }
        PauseAnimation {
            duration: isLocked ? 1000 : 250
        }
    }

    ColumnLayout {
        anchors.fill: parent
        Item {
          id: item1
          visible: !failedRFID
          Layout.fillWidth: true
          Layout.preferredHeight: 18
          Label {
              id: label1
              width: parent.width
              text: isLocked ? "SPINDLE LOCKED" : "SPINDLE LOCK"
              horizontalAlignment: Text.AlignHCenter
              font.pixelSize: 18
              font.weight: Font.Bold
              color: "#FF3300"
          }
          Glow {
            anchors.fill: label1
            source: label1
            radius: 4
            color: "black"
          }
        }

        Item {
          id: itemFF
          visible: failedRFID
          Layout.fillWidth: true
          Layout.preferredHeight: 14
          Label {
              id: labelFF
              width: parent.width
              text: "Must be unlocked by"
              horizontalAlignment: Text.AlignHCenter
              font.pixelSize: 14
              font.weight: Font.Bold
              color: "#FFFF00"
          }
          Glow {
            anchors.fill: labelFF
            source: labelFF
            radius: 4
            color: "black"
          }
        }

        Item {
          id: item3
          Layout.fillWidth: true
          Layout.preferredHeight: 14
          Label {
              id: label3
              width: parent.width
              text: isLocked ? activeMemberRecord.name : "Hold Button"
              horizontalAlignment: Text.AlignHCenter
              font.pixelSize: 14
              font.weight: Font.Bold
              color: isLocked ? "#33ccff" : "#ffffff"
          }
          Glow {
            anchors.fill: label3
            source: label3
            radius: 4
            color: "black"
          }
        }
        Item {
          id: item2
          visible: !failedRFID
          Layout.fillWidth: true
          Layout.preferredHeight: 16
          Label {
              id: label2
              width: parent.width
              text: isLocked ? "Scan RFID" : "5 Seconds"
              horizontalAlignment: Text.AlignHCenter
              font.pixelSize: 16
              font.weight: Font.Bold
              color: "#ffffff"
          }
          Glow {
            anchors.fill: label2
            source: label2
            radius: 4
            color: "black"
          }
        }

    }
}
