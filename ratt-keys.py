#!/usr/bin/env python3
import time
import sys
import argparse

try:
    import gpiod
    from gpiod.line import Direction, Value
except ImportError:
    print("python3-libgpiod is required.")
    sys.exit(1)

try:
    import evdev
    from evdev import UInput, ecodes as e
except ImportError:
    print("python3-evdev is required.")
    sys.exit(1)

CHIP_PATH = "/dev/gpiochip1"
KEYS = {
    8: {"code": e.KEY_ESC, "name": "ESC (8)"},
    9: {"code": e.KEY_DOWN, "name": "DOWN (9)"},
    10: {"code": e.KEY_UP, "name": "UP (10)"},
    11: {"code": e.KEY_ENTER, "name": "ENTER (11)"}
}

def main():
    print(f"RATT User-Space Keypad Daemon Starting...\nTargeting: {CHIP_PATH}")
    
    capabilities = {
        e.EV_KEY: [v["code"] for v in KEYS.values()]
    }
    ui = UInput(events=capabilities, name="ratt-gpio-keys", vendor=0x01, product=0x01)
    
    chip = gpiod.Chip(CHIP_PATH)
    settings = gpiod.LineSettings(direction=Direction.INPUT, active_low=True)
    
    req = chip.request_lines(
        consumer="ratt-keys-daemon",
        config={pin: settings for pin in KEYS.keys()}
    )

    print("Virtual keyboard mounted! Type a physical button on the board now...")
    
    # Track the last known mechanical state internally to prevent ghost-typing spam
    last_state = {pin: False for pin in KEYS.keys()}
    consecutive_reads = {pin: 0 for pin in KEYS.keys()}

    try:
        while True:
            time.sleep(0.02) # 50Hz (20ms interval)
            
            # Fetch all 4 mechanical values inside one clean I2C transaction block
            values = req.get_values()
            
            for idx, (pin, keydata) in enumerate(KEYS.items()):
                # Pull the raw values exactly by list index
                current_raw = (values[idx] == Value.ACTIVE)
                
                # Debounce Logic: Pin must be stable for 3 consecutive ticks (~60ms)
                if current_raw != last_state[pin]:
                    consecutive_reads[pin] += 1
                    
                    if consecutive_reads[pin] >= 3:
                        last_state[pin] = current_raw
                        consecutive_reads[pin] = 0  # reset for next change
                        
                        if current_raw:
                            print(f" >>> DOWN: {keydata['name']}")
                        else:
                            print(f" <<< UP: {keydata['name']}")
                            
                        # Mechanical State is Stable! Emit true Keystroke directly into Linux OS
                        ui.write(e.EV_KEY, keydata["code"], 1 if current_raw else 0)
                        ui.syn()
                else:
                    # Reset the stable counter if the button hasn't triggered a change
                    consecutive_reads[pin] = 0

    except KeyboardInterrupt:
        pass
    finally:
        req.release()
        chip.close()
        ui.close()

if __name__ == "__main__":
    main()
