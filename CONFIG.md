# RATT Configuration Guide

The RATT application is configured via an INI file (usually `ratt.ini` or similar, depending on your deployment). Below is a reference for configuring the system.

## Example File
See the `conf/ratt.ini-example` and `conf/ratt-devhost.ini-example` files for reference templates.

## Main Configuration Sections

### `[General]`
- `Diags`: Display diagnostics overlays (true/false)
- `ToolDesc`: Friendly name of the tool (e.g. "Laser Cutter")
- `NetworkInterfaceName`: Network interface name (e.g. `wlan0`)
- `NodeId`: Unique node identifier

### `[Personality]`
The `Personality` section determines the behavior pattern the hardware will follow.

#### Available Personalities (`Class`)
Must match a python file `Personality<Class>.py` in the `personalities/` directory.
- `Simple`: A generic tool personality that enables a single output when granted access and monitors an optional main power sensor or E-Stop.
- `HardwareSetup`: A diagnostic personality providing a GUI to monitor real-time GPIO inputs and manually toggle GPIO outputs for hardware testing.
- `AutoLift`: Disables active current sensing and safety checks, instead relying on a fixed timeout delay (`TimeoutSeconds`). This guarantees users have an uninterrupted window of time to move the automotive lift (e.g. to recover from an error) without the system logging them out the moment they release the lift control buttons.
- `Epilog`: Epilog Laser Cutter. Uses three distinct outputs (e.g. Laser Enable, External Fan, and a third inverted active-low signal). Re-maps its "activity sensing" to `IN1` to read a direct activity signal from the laser rather than using a standard clamp-on current sensor.
- `LaserCutter`: Old Rabbit Laser Cutter. Implements strict Gantry Homing logic via limit switches. Currently considered obsolete/legacy.
- `Mopa`: MOPA Fiber Laser. Activates **two** hardware outputs simultaneously when enabled (Machine Enable and Fan).
- `ProtoTrak`: ProtoTrak Mill. Activating the automatic CNC capability requires a separate "Advanced Endorsement" authorization over the basic DRO-only mode. Grants power to an additional output (`OUT1`) if the user has the required advanced endorsement flag.
- `Tormach`: Tormach 1100 CNC Mill. Introduces a complex "Spindle Lock" safety mechanism that requires users to rescan their RFID badge after a specific state change to unlock the spindle using a secondary relay.
- `Waterjet`: Protomax Waterjet. Identical functionally to `Simple`, but triggers special GUI workflows for Resource Managers to mark their usage time as a "Free Tier / Non-billable" maintenance session when reporting to the backend.

#### Common Personality Options
- `Class`: The personality class to use from the list above.
- `MonitorToolPowerEnabled`: Enable/Disable sensing if the tool's main power is ON.
- `MonitorEstopEnabled`: Enable/Disable continuous E-Stop monitoring.
- `SafetyCheckEnabled`: Enable Safety Checklist procedure before taking action.
- `PassiveSafetyCheckEnabled`: Ensures machine switches are OFF before granting power.
- `TimeoutSeconds`: Timeout before warning/logging out an inactive user.
- `PasswordEnabled`: Require secondary password string before activation.
- `Password`: The password string to authenticate against.
- And various other Personality-specific timers, pins, and strings.

### `[GPIO]`
Configure simulated components or hardware logic polarities.
- `Simulated`: Uses a simulated software GUI for diagnosing states instead of physical hardware access (true/false).
- `InputNames`: Comma-separated names for the 4 input channels (e.g., `IN1,IN2,IN3,IN4`)
- `OutputNames`: Comma-separated names for the 4 output channels (e.g., `OUT1,OUT2,OUT3,OUT4`)
- `InputActiveLow`: Comma-separated indicators for inverting inputs (1 for active low, 0 for normal logic). e.g., `1,0,0,0` will invert the `IN0` circuit only. Useful for NC E-stops or hardware with opposite default states.
- `OutputActiveLow`: Comma-separated indicators for inverting outputs (1 for active low, 0 for normal logic). e.g., `1,0,0,0` will invert the `OUT0` circuit only.

### `[Auth]` / `[HTTPS]` / `[MQTT]` / `[RFID]`
These sections handle system integration configuration such as broker hosts, cert files, API auth settings, and hardware serial ports configurations.
