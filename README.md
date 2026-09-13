# linux-setup-scripts

made by Reedman27

setup scripts for going from a fresh install to an actually usable
workstation without manually clicking through installers for an hour.
idempotent so you can just run them again if something breaks halfway
through — they won't double-install stuff or freak out.

## scripts

| script | for | notes |
|---|---|---|
| `ubuntu_setup_system.sh` | Ubuntu 25.10+ / 26.04 LTS+ | rips out snap completely and pins it so it can't sneak back in. also guards gnome so `autoremove` can't take it out as collateral damage |
| `vanillaos_setup_system.sh` | Vanilla OS 3.x "Reunion"+ | runs straight in the default VSO/apt shell — vanilla doesn't even have snap to deal with in the first place |

both scripts get you:
- the basics: `git`, `neovim`, `alacritty`, `btop`, `fastfetch`, and sets zsh as your default shell
- brave, discord, tailscale
- steam (native on ubuntu, flatpak on vanilla — debian sid's steam packaging is not worth fighting)
- cider — tries its apt repo first (only if it's actually reachable, so a dead repo can't nuke the whole script), otherwise it'll tell you to grab the AppImage instead. **not** using the flatpak build here on purpose since flatpak sandboxing breaks discord rich presence
- librepods for airpods support, pulled straight from the latest github release
- a pile of flatpak apps: nheko, aonsoku, gnome extension manager, gnome tweaks, openbubbles, proton vpn, bottles, vscodium, greenlight, lrcget, geary, localsend, thunderbird, vlc, and sober
- a little flatpak wrapper function it drops in your shell rc that asks user vs system scope every time you install something, like opensuse does

## how to run it

```bash
chmod +x ubuntu_setup_system.sh      # or vanillaos_setup_system.sh
./ubuntu_setup_system.sh
```

run it as yourself, not as root — both scripts will just refuse if you try
to run them with `sudo ./script.sh` directly, do the sudo prompts as they
come instead.

logs to `/tmp/` with a timestamp every run, spits out a pass/fail list for
everything at the end so you can actually see what worked, and asks if you
wanna reboot when it's done.

## why not just one script for both

ubuntu and vanilla os handle packages way too differently to force into one
file cleanly — ubuntu's apt just runs on the host no questions asked, vanilla
runs it inside VSO and leans on flatpak a lot harder for anything apt can't
handle nicely (steam, most gui stuff). tried combining them, wasn't worth it,
split em up instead.

## stuff worth knowing

- cider's a little finicky — the apt repo it uses is small and goes down
  sometimes, so the script checks it's actually up before touching anything.
  if it's down, just grab the AppImage yourself from cider.sh
- librepods ships its appimage as a github pre-release, not a full release,
  so the script has to pull the whole release list instead of just hitting
  `/releases/latest` (that endpoint straight up skips pre-releases)
