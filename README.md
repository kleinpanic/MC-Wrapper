# MC-Wrapper

A powerful, tmux-friendly Bash wrapper for running and managing your Minecraft server.  
Features: automatic log rotation, Discord notifications, RCON/FIFO command support, periodic metrics, in-game chat commands (teleport, backup, gamemode, fun commands, and more), graceful shutdown/countdown, and world backups.

## 🚀 Features

- **tmux-friendly** launch loop with automatic restart on crash  
- **Graceful shutdown**: 5→1 countdown, `save-all`, and clean `stop`  
- **In-game chat commands** at three privilege levels (L1–L3), including:
  - Teleport to named or arbitrary coordinates  
  - Backups, gamemode, weather, time, server info (heap/CPU/RAM/I/O/NET)  
  - Fun commands: ping, joke, dance, haiku, coinflip, dice, draw, story  
  - User management: ban/unban, op/deop, kick, add/remove privileges  
- **Discord integration**: post join/leave/backup/achievement/shutdown notices  
- **Automatic daily log rotation**  
- **World backups** with timestamped directories  
- **Metrics polling** (CPU, RAM, disk IOPS, network throughput)  
- **Location bookmarks** stored in `locations.json` for quick teleports  
- **RCON/FIFO** dual support (auto-detects `mcrcon`)

## 📦 Dependencies

| Tool      | Purpose                                  | Install (Debian/Ubuntu)                          |
|-----------|------------------------------------------|--------------------------------------------------|
| Java 17+  | Runs the Minecraft server JAR            | [Download Oracle/OpenJDK](https://adoptium.net/) |
| tmux      | Session manager                          | `sudo apt install tmux`                          |
| jq        | JSON parsing (`locations.json`)          | `sudo apt install jq`                            |
| sysstat   | `iostat` for disk I/O metrics            | `sudo apt install sysstat`                       |
| ifstat    | network throughput metrics               | `sudo apt install ifstat`                        |
| mcrcon    | RCON command forwarding (optional)       | Download from github                             |
| curl      | Discord webhook notifications            | `sudo apt install curl`                          |
| bash 4.4+ | Script runtime (uses associative arrays) | (bundled with most distros)                      |

> **Note**: On Arch Linux, use `pacman -S tmux jq sysstat ifstat curl`.

> **Another note**: mccron is only available through github, or on Arch through some weird external package manager that is not packman. It is however, not needed.

## 🛠 Installation

1. **Clone** this repository (coming soon):  
   ```bash
   git clone https://github.com/<your-username>/mc-wrapper.git
   cd mc-wrapper
````

2. **Make executable**:

   ```bash
   chmod +x mc-wrapper.sh
   ```
3. **Reminder**: 
   It is adviced before running the script to move it into your Minecraft directory, where your server.jar is located. You will run into errors or have to change the code if this is not done. I will fix this in updates to come.
4. **Configure** by editing `wrapper.conf` (will be auto-created on first run).
5. **Run** inside `tmux`:

   ```bash
   tmux new -s minecraft './mc-wrapper.sh -c path/to/wrapper.conf'
   ```
   or if the wrapper.conf is in the same dir as the mc-wrapper.sh just run it without any flags.

## ⚙️ Configuration

On first launch, `wrapper.conf` and `locations.json` are generated with defaults.
Example `wrapper.conf` overrides:

```ini
JAR="server.jar"
XMX="3G" 
XMS="1G"
NOGUI_FLAG="nogui"
LOGDIR="./logs"
RESTART_DELAY=15
DISCORD_WEBHOOK="https://discord.com/api/webhooks/…"
RCON_ENABLED=true
PRIV_FILE="./privileged_users.conf"
METRICS_INTERVAL=10
TMUX_SESSION="minecraft"
WORLD_DIR="./world"
BACKUP_DIR="./backups"
```
> **Note**: if you do not have a discord webhook, leave it as is, the program will still run. 
> **XMX/XMS Note**: It is important to know these values are the max and min (respectively) for your heap allocation to the server.jar. this is configurable, and is dependent on your needs for the server, your ram availability and how many users will be on the server.

## 🧰 Usage

```bash
./mc-wrapper.sh [options]
```

| Option                   | Description                                        |
| ------------------------ | -------------------------------------------------- |
| `-c, --config FILE`      | Path to `wrapper.conf` (default: `./wrapper.conf`) |
| `-n, --nogui`            | Force headless mode (`nogui`)                      |
| `-g, --gui`              | Force GUI mode                                     |
| `-w, --without-commands` | Disable in-game chat commands                      |
| `-v, --version`          | Print script version                               |
| `-h, --help`             | Show this help message                             |

### In-Game Chat Commands

* **Teleport**:

  * `server tp <location>` (e.g. `spawn`, `home`)
  * `server tp <x> <y> <z>` (absolute or relative `~` coords)
* **Backup**: `server backup`
* **Gamemode**: `server gamemode <creative|survival|spectator> [player]`
* **Metrics**: `server cpu`, `server ram`, `server io`, `server net`, `server heap`, `server uptime`
> **Note**: these metrics are designed to be gathered from an Arch linux machine. cannot guarantee portability.
* **Weather/Time**: `server weather <clear|rain|thunder>`, `server day`, `/server night`
* **Fun**: `server ping`, `server joke`, `server dance`, `server haiku`, etc.
> **Note**: Plan to add more. 
* **Admin (L1)**: `server ban <player>`, `server op <player>`, `server kick <player>`, `server addpriv <user> [1-3]`, `server removepriv <user>`

See full help in-game with `server help` or `server help <command>`.

## 💡 Roadmap

* ✅ Graceful shutdown with countdown
* ✅ Discord & RCON/FIFO support
* ✅ Teleport bookmarks & `locations.json`
* 🔄 **Future**: Metrics dashboard web UI
* 🔄 **Future**: Plugin-style architecture for custom commands
* 🔄 **Future**: Windows/Cygwin compatibility
* 🔄 **Future**: Docker container for zero-setup deployment

Contributions are **welcome**! Please open issues or submit PRs.

## 🤝 Contributing

1. Fork the repo
2. Create a feature branch: `git checkout -b feature/YourFeature`
3. Commit your changes
4. Push to your fork & open a Pull Request
5. Ensure your code follows the existing style (Bash strictness, comments, logging)

## 📄 License

This project is licensed under the [MIT License](LICENSE).
Feel free to use, modify, and distribute!

---

> Crafted by **kleinpanic**.

