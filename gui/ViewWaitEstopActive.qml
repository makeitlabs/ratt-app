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

View {
    id: root
    name: "E-Stop Wait"
    color: "#444444"

    function _show() {
        waitTimer.start();
        audioHelperTimer.start();
    }

    function _hide() {
        sound.enableEstopAudio.stop();
        audioHelperTimer.stop();
        waitTimer.stop();
    }

    function done() {
        sound.timeoutWarningAudio.play();

        var jo = {reason: 'timeout',
                  member: activeMemberRecord.name,
                  enabledSecs: 0,
                  activeSecs: 0,
                  idleSecs: 0
                  };
        appWindow.mqttPublishSubtopicEvent('personality/logout', JSON.stringify(jo));
        activeMemberRecord.loggedIn = false;

        appWindow.uiEvent('WaitEstopTimeout');
    }

    Timer {
        id: audioHelperTimer
        interval: 10000
        repeat: false
        running: false
        onTriggered: {
            sound.enableEstopAudio.play();
        }
    }

    Timer {
        id: waitTimer
        interval: 60000
        repeat: false
        running: false
        onTriggered: {
            done();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        Label {
            Layout.fillWidth: true
            text: "DISENGAGE"
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 24
            font.weight: Font.Bold
            color: "#FF3300"
        }
        Label {
            Layout.fillWidth: true
            text: "E-STOP"
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 24
            font.weight: Font.Bold
            color: "#FF3300"
        }
        Label {
            Layout.fillWidth: true
            text: "THEN PRESS RESET"
            horizontalAlignment: Text.AlignHCenter
            font.pixelSize: 16
            font.weight: Font.DemiBold
            color: "#FFFF00"
        }
    }
}
