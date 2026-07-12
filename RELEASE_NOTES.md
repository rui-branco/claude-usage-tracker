### Prevent sleep when lid is closed

The widget now has a native switch (above the footer) that keeps the Mac awake while the lid is closed.

- Uses the system `pmset -a disablesleep` flag — the only mechanism available to a non-entitled app, since regular power assertions cannot block lid-close sleep and the private IOKit `AppliesOnLidClose` assertion is not permitted. Note it disables system sleep entirely while on, not just lid-close sleep
- The first change asks for an administrator password once: that single authorization installs a narrowly-scoped sudoers rule (only the two exact `pmset -a disablesleep 1|0` commands for your UID, validated with `visudo`) and applies the change. Every toggle after that is instant, with no password. To remove the rule later: `sudo rm /etc/sudoers.d/claude-usage-tracker-pmset`
- The switch tracks the real system state: it re-reads `pmset -g` after every change and each time the popover opens, so it stays honest after a crash, relaunch, or external `pmset` change
- Heads-up: this is a persistent system-wide setting — it stays on after quitting the app. Turn it off before packing your Mac; keeping it on may increase heat and battery use
