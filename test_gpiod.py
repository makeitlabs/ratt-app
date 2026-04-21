import gpiod
import sys

print("--- Checking Physical Hardware Offsets ---")
try:
    chip = gpiod.Chip("/dev/gpiochip0")
    
    info = chip.get_info()
    num_lines = info.num_lines
    print(f"Chip {info.name} ({info.label}) has exactly {num_lines} lines (0 through {num_lines-1}).")
    
    number = 496
    print(f"\nPersonalityBase.py is requesting line offset: {number}")
    
    if number >= num_lines:
        print(f"\n[CRITICAL HARDWARE MISMATCH]")
        print(f"The pin number {number} is higher than the maximum hardware pin ({num_lines-1}) on this chip.")
        print("Because there are no other gpio expansion chips loaded (like your old gpiochip496 expander), allocating 496 physically fails.")
        print("QtGPIO.py correctly aborted the invalid hardware pin request, which is exactly why PersonalityBase.py fell back to Simulated GPIO.")
        print("\nTo fix this for your new hardware: You must edit 'PersonalityBase.py' and change `GPIO_PIN_IN0 = 496` "
              "to physically valid pins on the Pi for your new board layout (e.g., GPIO 17, 27, etc.)")
    else:
        print(f"Pin {number} is valid.")
        
except Exception as e:
    import traceback
    traceback.print_exc()
