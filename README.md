# linux-setup-scripts

made by Reedman27

setup scripts for going from a fresh install to an actually usable
workstation without manually clicking through installers for an hour.
they're idempotent too, so you can just run them again if something breaks
halfway through — they won't double-install stuff or freak out.

## scripts

| script                      | for                                       | notes                                                                                                                                    |
| --------------------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `ubuntu_setup_system.sh`    | Ubuntu 25.10+ / 26.04 LTS+                | rips out snap completely and pins it so it can't sneak back in. also guards gnome so `autoremove` can't take it out as collateral damage |
| `popos_setup_system.sh`     | Pop!_OS 22.04+, including COSMIC releases | same general setup, tuned for Pop!_OS/COSMIC — includes fastfetch handling and a COSMIC-inspired Alacritty theme                         |
| `vanillaos_setup_system.sh` | Vanilla OS 3.x "Reunion"+                 | built for Vanilla's VSO environment and leans more on flatpak where apt packages don't make sense                                        |

## what they install

* basics: `git`, `neovim`, `alacritty`, `btop`, `fastfetch`, `zip`, `unzip`, and sets zsh as your default shell
* brave, discord, tailscale
* steam — native on Ubuntu/Pop!_OS, flatpak on Vanilla
* cider — tries its apt repo first if it's actually reachable so a dead repo can't nuke the whole script. otherwise it'll tell you to grab the AppImage. **not** using the flatpak build since sandboxing breaks discord rich presence
* librepods for airpods support, pulled straight from the latest GitHub release
* flatpaks: nheko, aonsoku, extension manager, gnome tweaks, openbubbles, proton vpn, bottles, vscodium, greenlight, lrcget, geary, localsend, thunderbird, vlc, and sober
* shared `.zshrc` pulled from this repo (backs up your existing one first) — oh-my-zsh, autosuggestions, syntax highlighting, completions, fastfetch-on-launch, and a flatpak scope picker built right into the dotfile

## how to run

```bash
git clone https://github.com/Reedman27/linux-setup-scripts.git
cd linux-setup-scripts
chmod +x popos_setup_system.sh
./popos_setup_system.sh
```

replace `popos_setup_system.sh` with whichever script matches your distro.

run it as yourself, not root — the scripts handle sudo prompts themselves
and will refuse to run if you use `sudo ./script.sh`.

logs go to `/tmp/` with a timestamp every run, and you'll get a pass/fail
list at the end so you can see what worked. asks if you wanna reboot when
it's done too.

## stuff worth knowing

* **fastfetch** isn't available on every Ubuntu/Pop!_OS base, so the scripts check if it's already available first and only fall back to the maintainer PPA if needed. it's installed separately too, so if fastfetch has a repo problem it can't drag the rest of your packages down with it
* **Pop!_OS gets a COSMIC-inspired Alacritty theme** — dark purple/indigo with transparency and a blur request. blur depends on compositor support, so worst case you just get transparency. existing configs get backed up first
* **cider's apt repo can be flaky**, so the scripts check that it's actually reachable before touching it. if it's down, just grab the AppImage instead
* **librepods uses a GitHub pre-release**, so the script checks the release list instead of using `/releases/latest`, since GitHub skips pre-releases there
* **separate scripts because distro packaging is different** — Ubuntu/Pop!_OS can mostly use apt directly while Vanilla OS uses VSO and benefits from leaning harder on flatpak. one mega-script would've just been distro-specific spaghetti

## why this exists

because setting up a new Linux install should take one script, not an hour
of copying commands from twelve different tabs.
