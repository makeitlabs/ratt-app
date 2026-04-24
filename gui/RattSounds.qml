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

Item {
    property alias keyAudio: keyAudio
    property alias generalAlertAudio: generalAlertAudio
    property alias general2AlertAudio: general2AlertAudio
    property alias general3AlertAudio: general3AlertAudio
    property alias general4AlertAudio: general4AlertAudio
    property alias safetyFailedAudio: safetyFailedAudio
    property alias enableAudio: enableAudio
    property alias disableAudio: disableAudio
    property alias timeoutWarningAudio: timeoutWarningAudio
    property alias reportSuccessAudio: reportSuccessAudio
    property alias rfidSuccessAudio: rfidSuccessAudio
    property alias rfidFailureAudio: rfidFailureAudio
    property alias rfidErrorAudio: rfidErrorAudio
    property alias liftInstructionsAudio: liftInstructionsAudio
    property alias liftCorrectAudio: liftCorrectAudio
    property alias liftIncorrectAudio: liftIncorrectAudio
    property alias homingInstructionsAudio: homingInstructionsAudio
    property alias homingWarningAudio: homingWarningAudio
    property alias homingOverrideAudio: homingOverrideAudio
    property alias enableEstopAudio: enableEstopAudio
    
    function playSfx(sfxPath) {
        // Ensure we have the gui/ prefix if it isn't absolute
        var path = sfxPath;
        if (path.indexOf("/") !== 0 && path.indexOf("gui/") !== 0) {
            path = "gui/" + path;
        }
        audioPlayer.play(path);
    }

    Timer {
        id: silenceTimer
        interval: 5000 // Approximate length of silence.wav (5s)
        repeat: true
        running: config.Sound_EnableSilenceLoop
        triggeredOnStart: false // Delay the first start to avoid startup blink
        onTriggered: playSfx(config.Sound_Silence)
    }

    QtObject {
        id: silence
        function play() { silenceTimer.start() }
        function stop() { silenceTimer.stop() }
    }

    QtObject {
        id: keyAudio
        function play() { playSfx(config.Sound_KeyPress) }
    }
    QtObject {
        id: generalAlertAudio
        function play() { playSfx(config.Sound_GeneralAlert) }
    }
    QtObject {
        id: general2AlertAudio
        function play() { playSfx(config.Sound_General2Alert) }
    }        
    QtObject {
        id: general3AlertAudio
        function play() { playSfx(config.Sound_General3Alert) }
    }
    QtObject {
        id: general4AlertAudio
        function play() { playSfx(config.Sound_General4Alert) }
    }
    QtObject {
        id: rfidSuccessAudio
        function play() { playSfx(config.Sound_RFIDSuccess) }
    }
    QtObject {
        id: rfidFailureAudio
        function play() { playSfx(config.Sound_RFIDFailure) }
    }
    QtObject {
        id: rfidErrorAudio
        function play() { playSfx(config.Sound_RFIDError) }
    }
    QtObject {
        id: safetyFailedAudio
        function play() { playSfx(config.Sound_SafetyFailed) }
    }
    QtObject {
        id: enableAudio
        function play() { playSfx(config.Sound_Enable) }
    }
    QtObject {
        id: disableAudio
        function play() { playSfx(config.Sound_Disable) }
    }
    QtObject {
        id: timeoutWarningAudio
        function play() { playSfx(config.Sound_TimeoutWarning) }
    }
    QtObject {
        id: reportSuccessAudio
        function play() { playSfx(config.Sound_ReportSuccess) }
    }
    QtObject {
        id: liftInstructionsAudio
        function play() { playSfx(config.Sound_LiftInstructions) }
    }
    QtObject {
        id: liftCorrectAudio
        function play() { playSfx(config.Sound_LiftCorrect) }
    }
    QtObject {
        id: liftIncorrectAudio
        function play() { playSfx(config.Sound_LiftIncorrect) }
    }
    QtObject {
        id: homingInstructionsAudio
        function play() { playSfx(config.Sound_HomingInstructions) }
    }
    QtObject {
        id: homingWarningAudio
        function play() { playSfx(config.Sound_HomingWarning) }
    }
    QtObject {
        id: homingOverrideAudio
        function play() { playSfx(config.Sound_HomingOverride) }
    }
    QtObject {
        id: enableEstopAudio
        function play() { playSfx(config.Sound_EnableEstop) }
    }
}
