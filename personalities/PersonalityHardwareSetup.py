# -*- coding: utf-8 -*-
from PyQt5.QtCore import pyqtSlot, pyqtSignal
from QtGPIO import LOW, HIGH
from PersonalityBase import PersonalityBase

class Personality(PersonalityBase):
    PERSONALITY_DESCRIPTION = 'Hardware Setup Personality'

    STATE_INIT = 'Init'
    STATE_IDLE = 'Idle'

    gpioInputsChanged = pyqtSignal(bool, bool, bool, bool, arguments=['in0_val', 'in1_val', 'in2_val', 'in3_val'])
    gpioOutputsChanged = pyqtSignal(bool, bool, bool, bool, arguments=['out0_val', 'out1_val', 'out2_val', 'out3_val'])

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

        self.states = {
            self.STATE_INIT: self.stateInit,
            self.STATE_IDLE: self.stateIdle,
            self.STATE_POWER_LOSS: self.statePowerLoss,
            self.STATE_SHUT_DOWN: self.stateShutDown,
            self.STATE_LOCK_OUT: self.stateLockOut
        }

        self.state = self.STATE_IDLE
        self.statePhase = self.PHASE_ACTIVE

    @pyqtSlot()
    def updateAllGPIO(self):
        # self.logger.debug("updateAllGPIO called")
        # Notify QML of input states
        # pins_in[].get() returns python int matching sysfs
        self.gpioInputsChanged.emit(
            bool(self.pins_in[0].get() == int(LOW)),
            bool(self.pins_in[1].get() == int(LOW)),
            bool(self.pins_in[2].get() == int(LOW)),
            bool(self.pins_in[3].get() == int(LOW))
        )
        
        # Notify QML of output states
        self.gpioOutputsChanged.emit(
            bool(self.pins_out[0].get() == int(HIGH)),
            bool(self.pins_out[1].get() == int(HIGH)),
            bool(self.pins_out[2].get() == int(HIGH)),
            bool(self.pins_out[3].get() == int(HIGH))
        )

    @pyqtSlot(int, bool)
    def setOutput(self, index, value):
        self.logger.warning("setOutput called from QML! index=%d, value=%s", index, value)
        if 0 <= index <= 3:
            self.pins_out[index].set(HIGH if value else LOW)
            self.updateAllGPIO() # Broadcast new states

    def stateInit(self):
        return self.goto(self.STATE_IDLE)

    def stateIdle(self):
        if self.phENTER:
            self.updateAllGPIO()
            self.pin_led1.set(HIGH)
            self.pin_led2.set(LOW)
            self.wakeOnTimer(enabled=True, interval=1000, singleShot=False)
            return self.goActive()

        elif self.phACTIVE:
            if self.wakereason == self.REASON_GPIO:
                self.updateAllGPIO()
            elif self.wakereason == self.REASON_TIMER:
                if self.pin_led1.get() == HIGH:
                    self.pin_led1.set(LOW)
                    self.pin_led2.set(HIGH)
                else:
                    self.pin_led1.set(HIGH)
                    self.pin_led2.set(LOW)
            return False

        elif self.phEXIT:
            self.wakeOnTimer(enabled=False)
            self.pin_led1.set(LOW)
            self.pin_led2.set(LOW)
            return self.goNextState()

    def statePowerLoss(self):
        return self.goto(self.STATE_IDLE)

    def stateShutDown(self):
        self.app.shutdown()
        return False

    def stateLockOut(self):
        return self.goto(self.STATE_IDLE)
