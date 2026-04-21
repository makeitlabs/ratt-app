import gpiod

print("--- Testing gpiod Chip methods ---")
try:
    chip = gpiod.Chip("/dev/gpiochip0")
    print(f"Successfully opened {chip}")
    print("Methods available on Chip object:")
    
    methods = [m for m in dir(chip) if not m.startswith('_')]
    print("  ->", ", ".join(methods))
    
    print("\nAttempting to find way to get line 0...")
    line = None
    
    if hasattr(chip, 'get_line'):
        line = chip.get_line(0)
        print("Used get_line(0) successfully.")
    elif hasattr(chip, 'line'):
        line = chip.line(0)
        print("Used line(0) successfully.")
    elif hasattr(chip, 'get_lines'):
        lines = chip.get_lines([0])
        line = lines[0] if lines else None
        print("Used get_lines([0]) successfully.")
        
    print(f"Yields Line Object: {line}")
    if line:
        print("Methods available on Line object:")
        line_methods = [m for m in dir(line) if not m.startswith('_')]
        print("  ->", ", ".join(line_methods))
        
except Exception as e:
    import traceback
    traceback.print_exc()
