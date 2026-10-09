#!/usr/bin/env python3
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
# copy of this software and associated documentation files (the "Software"),
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

import sys
import os
import signal
import atexit
from PyQt5.QtGui import QGuiApplication, QFont
from PyQt5.QtCore import QObject, pyqtSignal, pyqtSlot, QUrl, QTimer, QSocketNotifier
from RattAppEngine import RattAppEngine


class MainApp(QObject):
    app = None
    engine = None

    def __init__(self):
        QObject.__init__(self)
        self.enableBacklight()
        self.createApp()
        self.setupSignalWakeup()
        self.createEngine()

    def setupSignalWakeup(self):
        # Create self-pipe and notify Qt whenever OS signals arrive
        self.r_fd, self.w_fd = os.pipe()
        os.set_blocking(self.r_fd, False)
        os.set_blocking(self.w_fd, False)
        signal.set_wakeup_fd(self.w_fd)

        self.notifier = QSocketNotifier(self.r_fd, QSocketNotifier.Read, self)
        self.notifier.activated.connect(self.drainWakeup)

        signal.signal(signal.SIGINT, self.sig_handler)
        signal.signal(signal.SIGTERM, self.sig_handler)
        signal.signal(signal.SIGHUP, self.sig_handler)
        atexit.register(self.clearScreen)

    def drainWakeup(self):
        try:
            os.read(self.r_fd, 512)
        except Exception:
            pass

    def enableBacklight(self):
        try:
            # turn on backlight
            fd = open('/sys/class/backlight/fb_st7735r/bl_power', 'w+')
            fd.write('0')
            fd.close()
        except:
            pass

    def clearScreen(self):
        try:
            if self.engine:
                root_objs = self.engine.rootObjects()
                if root_objs:
                    for obj in root_objs:
                        try:
                            from PyQt5.QtCore import QMetaObject
                            QMetaObject.invokeMethod(obj, "showExitScreen")
                        except Exception:
                            pass
            if self.app:
                for _ in range(20):
                    self.app.processEvents()
        except Exception as e:
            print("Error rendering exit screen:", e)

    def createApp(self):
        if not self.app:
            self.app = QGuiApplication(sys.argv)

            # Available fonts on RATT image:
            # AR PL UMing CN, AR PL UMing HK, AR PL UMing TW, AR PL UMing TW MBE,
            # Bitstream Vera Sans, Bitstream Vera Sans Mono, Bitstream Vera Serif,
            # DejaVu Sans, DejaVu Sans Condensed, DejaVu Sans Mono,
            # Liberation Mono, Liberation Sans,
            # Monospace, Sans Serif, Serif,
            # Sazanami Gothic, Sazanami Mincho,
            # Ubuntu, Ubuntu Condensed, Ubuntu Light,Ubuntu Mono
            font = QFont("Ubuntu", 12)
            self.app.setFont(font)

    def createEngine(self):
        if not self.engine:
            print("creating engine")
            self.engine = RattAppEngine()
            self.engine.exit.connect(self.exit)

    def sig_handler(self, sig, frame):
        print('Caught signal %d, exiting.' % sig)
        self.clearScreen()
        import time
        time.sleep(0.1)
        if self.app:
            self.app.exit(0)
        else:
            sys.exit(0)

    @pyqtSlot(int)
    def exit(self, exitCode):
        print("exit, code=", exitCode)
        if exitCode == 2 and self.engine:
            print("reloading qml")
            self.engine.load(QUrl('gui/main.qml'))
        elif self.app:
            self.clearScreen()
            self.app.exit(exitCode)

    def run(self):
        return self.app.exec_()

    def cleanup(self):
        self.clearScreen()
        del self.engine
        del self.app



if __name__ == '__main__':
    ma = MainApp()
    running = True
    while running:
        r = ma.run()
        if r != 2:
            running = False

    ma.cleanup()
    del ma
    sys.exit(r)
