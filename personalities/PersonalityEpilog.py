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
    ## Tool Personality: Epilog Laser
    #############################################
    PERSONALITY_DESCRIPTION = 'Epilog'

    def __init__(self, *args, **kwargs):
        PersonalitySimple.__init__(self, *args, **kwargs)
        self.pins_out[0].set(LOW)
        self.pins_out[1].set(LOW)
        self.pins_out[2].set(HIGH)

    # enable tool
    def enableTool(self):
        self.logger.debug('EPILOG ENABLE TOOL')
        self.pins_out[0].set(HIGH)
        self.pins_out[1].set(HIGH)
        self.pins_out[2].set(LOW)


    # disable tool
    def disableTool(self):
        self.logger.debug('EPILOG DISABLE TOOL')
        self.pins_out[0].set(LOW)
        self.pins_out[1].set(LOW)
        self.pins_out[2].set(HIGH)



    # returns true if the tool is currently active
    def toolActive(self):
        return (self.pins_in[1].get() == 0)

