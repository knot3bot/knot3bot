#!/usr/bin/env python3
"""
knot3bot Configuration Wizard

Interactive script to configure knot3bot
"""

import os
import json
import sys

def get_input(prompt, default=None):
    """Get user input with optional default"""
    if default:
        prompt = f"{prompt} [{default}]: "
    else:
        prompt = f"{prompt}: "
    
    try:
        value = input(prompt).strip()
        return value if value else default
    except (EOFError, KeyboardInterrupt):
        print("\n\nCancelled.")
        sys.exit(1)

def main():
    print("=" * 50)
    print("  knot3bot Configuration Wizard")
    print("=" * 50)
    print()
    
    # Determine config path
    home = os.path.expanduser("~")
    config_dir = os.path.join(home, ".knot3bot")
    config_path = os.path.join(config_dir, "config.json")
    
    print(f"Config will be saved to: {config_path}")
    print()
    
    # Load existing config if available
    config = {}
    if os.path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                config = json.load(f)
            print("✓ Loaded existing configuration")
            print()
        except Exception as e:
            print(f"Warning: Could not load existing config: {e}")
            print()
    
    # Provider selection
    providers = [
        "openai",
        "anthropic", 
        "kimi",
        "minimax",
        "zai",
        "bailian",
        "volcano",
        "tencent",
        "kimi-plan",
        "minimax-plan",
        "bailian-plan",
        "volcano-plan",
        "tencent-plan",
    ]
    
    print("Select provider:")
    for i, p in enumerate(providers, 1):
        print(f"  {i}. {p}")
    print()
    
    default_provider = config.get("provider", "openai")
    while True:
        try:
            choice = get_input("Enter number", str(providers.index(default_provider) + 1) if default_provider in providers else "1")
            idx = int(choice) - 1
            if 0 <= idx < len(providers):
                config["provider"] = providers[idx]
                break
            print("Invalid selection, try again.")
        except ValueError:
            print("Please enter a number.")
    
    print()
    
    # API key
    current_key = config.get("api", {}).get("key")
    key = get_input(f"Enter API key for {config['provider']}", current_key or "(leave blank to use env var)")
    if key and key != "(leave blank to use env var)":
        if "api" not in config:
            config["api"] = {}
        config["api"]["key"] = key
    elif "api" in config and "key" in config["api"]:
        del config["api"]["key"]
    
    print()
    
    # Model
    default_models = {
        "openai": "gpt-4o",
        "anthropic": "claude-3-5-sonnet",
        "kimi": "kimi-k2.5",
        "minimax": "MiniMax-M2.7",
        "zai": "glm-4.7",
        "bailian": "qwen3.5-plus",
        "volcano": "doubao-seed-1-8-251228",
        "tencent": "hunyuan-lite",
        "kimi-plan": "kimi-k2.5",
        "minimax-plan": "MiniMax-M2.7",
        "bailian-plan": "qwen3.5-plus",
        "volcano-plan": "ark-code-latest",
        "tencent-plan": "hunyuan-lite",
    }
    
    default_model = config.get("api", {}).get("model", default_models.get(config["provider"], "gpt-4o"))
    use_default = get_input(f"Use default model {default_model}? (Y/n)", "Y").strip().lower()
    
    if use_default.startswith("n"):
        model = get_input("Enter model name", default_model)
        if "api" not in config:
            config["api"] = {}
        config["api"]["model"] = model
    else:
        if "api" not in config:
            config["api"] = {}
        config["api"]["model"] = default_model
    
    print()
    
    # Server port
    default_port = config.get("server", {}).get("port", 38789)
    port = get_input("Server port", str(default_port))
    try:
        port_int = int(port)
        if "server" not in config:
            config["server"] = {}
        config["server"]["port"] = port_int
    except ValueError:
        print(f"Invalid port, keeping default: {default_port}")
    print()
    
    # Save config
    os.makedirs(config_dir, exist_ok=True)
    
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    
    print("✓ Configuration saved!")
    print()
    print("You can now run:")
    print("  knot3bot                    # CLI mode")
    print("  knot3bot --server          # Server mode")
    print()

if __name__ == "__main__":
    main()
