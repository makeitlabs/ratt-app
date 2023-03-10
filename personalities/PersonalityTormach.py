# -*- coding: utf-8 -*-
# --------------------------------------------------------------------------
#  _____       ______________
# |  __ \   /\|__   ____   __|
# | |__) | /  \  | |    | |
# |  _  / / /\ \ | |    | |
# | | \ \/ ____ \| |    | |
# |_|  \_\/    \_\_|    |_|    ... RFID ALL THE THINGS!
#
# A resource access control and telemetry solution for Makerspaces
#
# Developed at MakeIt Labs - New Hampshire's First & Largest Makerspace
# http://www.makeitlabs.com/
#
# Copyright 2018 MakeIt Labs
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and assoceiated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# --------------------------------------------------------------------------
#
# Author: Steve Richardson (steve.richardson@makeitlabs.com)
#

from QtGPIO import LOW, HIGH
from PersonalitySimple import Personality as PersonalitySimple
import json

class Personality(PersonalitySimple):
    #############################################
    ## Tool Personality: Tormach 1100 CNC Mill
    #############################################
    PERSONALITY_DESCRIPTION = 'Tormach'

    STATE_TOOL_SPINDLE_LOCK_REQUEST = 'ToolSpindleLockRequest'
    STATE_TOOL_SPINDLE_LOCKED = 'ToolSpindleLocked'
    STATE_TOOL_SPINDLE_UNLOCK_FAILED = 'ToolSpindleUnlockFailed'
    STATE_TOOL_SPINDLE_UNLOCK = 'ToolSpindleUnlock'
   
    def __init__(self, *args, **kwargs):
        PersonalitySimple.__init__(self, *args, **kwargs)
        self.pins_out[0].set(LOW)

        self._monitorToolPower = False
        self._performSafetyCheck = False
        self._monitorEstop = True

        # a personality may define additional states        
        states = {
            self.STATE_TOOL_SPINDLE_LOCK_REQUEST: self.stateToolSpindleLockRequest,
            self.STATE_TOOL_SPINDLE_LOCKED : self.stateToolSpindleLocked,
            self.STATE_TOOL_SPINDLE_UNLOCK_FAILED : self.stateToolSpindleUnlockFailed,
            self.STATE_TOOL_SPINDLE_UNLOCK : self.stateToolSpindleUnlock
        }
        
        # ...and merge the additional states into the state table defined in the base class
        self.states.update(states)

    # enable tool
    def enableTool(self):
        self.logger.debug('TORMACH ENABLE TOOL')
        self.pins_out[0].set(HIGH)

    # disable tool
    def disableTool(self):
        self.logger.debug('TORMACH DISABLE TOOL')
        self.pins_out[0].set(LOW)
        self.disableSpindle()

    # enable spindle
    def enableSpindle(self):
        self.logger.debug('TORMACH ENABLE SPINDLE')
        self.pins_out[1].set(HIGH)

    # disable spindle
    def disableSpindle(self):
        self.logger.debug('TORMACH DISABLE SPINDLE')
        self.pins_out[1].set(LOW)


    # returns true if the tool's E-Stop loop is latched and ready
    def toolSpindleLockReq(self):
        return (self.pins_in[2].get() == 0)

    #############################################
    ## STATE_TOOL_ENABLED_INACTIVE
    #############################################
    def stateToolEnabledInactive(self):
        if self.phENTER:
            self.telemetryEvent.emit('personality/activity', json.dumps({'active': False, 'member': self.activeMemberRecord.name}))
            self.toolActiveFlag = False
            self.pin_led1.set(HIGH)
            self.enableTool()
            self.enableSpindle()
            return self.goActive()

        elif self.phACTIVE:
            if self.toolActive():
                return self.exitAndGoto(self.STATE_TOOL_ENABLED_ACTIVE)

            if self.wakereason == self.REASON_UI and self.uievent == 'ToolEnabledDone':
                return self.exitAndGoto(self.STATE_TOOL_DISABLED)

            if self._monitorEstop and not self.toolEstopEnabled():
                return self.exitAndGoto(self.STATE_TOOL_ENABLED_EMERGENCY_STOP)

            if self.toolSpindleLockReq():
                return self.exitAndGoto(self.STATE_TOOL_SPINDLE_LOCK_REQUEST)

            return False

        elif self.phEXIT:
            self.pin_led1.set(LOW)
            return self.goNextState()


    #############################################
    ## STATE_TOOL_SPINDLE_LOCK_REQUEST
    #############################################
    def stateToolSpindleLockRequest(self):
        if self.phENTER:
            self.pin_led1.set(LOW)
            self.pin_led2.set(LOW)
            self.wakeOnTimer(enabled=True, interval=500, singleShot=False)
            self._lock_counter = 0
            return self.goActive()

        elif self.phACTIVE:
            if self._monitorEstop and not self.toolEstopEnabled():
                return self.exitAndGoto(self.STATE_TOOL_ENABLED_EMERGENCY_STOP)
            
            elif self.wakereason == self.REASON_TIMER:
                if self.toolSpindleLockReq():
                    self._lock_counter = self._lock_counter + 1
                    
                    if self._lock_counter >= 6:
                        self.exitAndGoto(self.STATE_TOOL_SPINDLE_LOCKED)
                    
                else:
                    return self.exitAndGoto(self.STATE_TOOL_ENABLED_INACTIVE)
                
                return False

        elif self.phEXIT:
            self.pin_led1.set(HIGH)
            self.pin_led2.set(HIGH)
            self.wakeOnTimer(enabled=False)
            return self.goNextState()

    #############################################
    ## STATE_TOOL_SPINDLE_LOCKED
    #############################################
    def stateToolSpindleLocked(self):
        if self.phENTER:
            self.disableSpindle()
            self.wakeOnRFID(True)
            self.wakeOnTimer(enabled=True, interval=500, singleShot=True)
            return self.goActive()
        
        elif self.phACTIVE:
            if self._monitorEstop and not self.toolEstopEnabled():
                return self.exitAndGoto(self.STATE_TOOL_ENABLED_EMERGENCY_STOP)
            
            elif self.wakereason == self.REASON_RFID_ALLOWED_RESCAN:
                return self.exitAndGoto(self.STATE_TOOL_SPINDLE_UNLOCK)

            elif self.wakereason == self.REASON_RFID_DENIED_RESCAN or self.wakereason == self.REASON_RFID_ERROR_RESCAN:
                return self.exitAndGoto(self.STATE_TOOL_SPINDLE_UNLOCK_FAILED)

            elif self.wakereason == self.REASON_TIMER:            
                if self.pin_led1.get() == LOW:
                    self.pin_led1.set(HIGH)
                    self.pin_led2.set(LOW)
                    self.wakeOnTimer(enabled=True, interval=500, singleShot=True)
                else:
                    self.pin_led1.set(LOW)
                    self.pin_led2.set(HIGH)
                    self.wakeOnTimer(enabled=True, interval=500, singleShot=True)
            return False
        
        elif self.phEXIT:
            self.wakeOnTimer(enabled=False)
            self.pin_led1.set(HIGH)
            self.pin_led2.set(HIGH)
            self.wakeOnRFID(False)
            return self.goNextState()
        
        return False

    #############################################
    ## STATE_TOOL_SPINDLE_UNLOCK_FAILED
    #############################################
    def stateToolSpindleUnlockFailed(self):
        if self.phENTER:
            self.wakeOnTimer(enabled=True, interval=2500, singleShot=True)
            return self.goActive()
        
        elif self.phACTIVE:
            if self.wakereason == self.REASON_TIMER:
                return self.exitAndGoto(self.STATE_TOOL_SPINDLE_LOCKED)
            return False
        
        elif self.phEXIT:
            self.wakeOnTimer(enabled=False)
            return self.goNextState()
        
        return False

    
    #############################################
    ## STATE_TOOL_SPINDLE_UNLOCK
    #############################################
    def stateToolSpindleUnlock(self):
        if self.phENTER:
            self.enableSpindle()
            return self.goActive()
        
        elif self.phACTIVE:
            if self._monitorEstop and not self.toolEstopEnabled():
                return self.exitAndGoto(self.STATE_TOOL_ENABLED_EMERGENCY_STOP)

            if not self.toolSpindleLockReq():
                return self.exitAndGoto(self.STATE_TOOL_ENABLED_INACTIVE)
        
            return False
        
        elif self.phEXIT:
            return self.goNextState()
        
        return False
        
