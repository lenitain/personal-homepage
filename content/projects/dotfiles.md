# Dotfiles

My system configuration, managed declaratively with [mise](https://mise.jdx.dev/).

**Source:** [github.com/lenitain/dotfiles](https://github.com/lenitain/dotfiles)

## Stack

**Distro:** [CachyOS](https://cachyos.org/) (Arch-based)

| Layer            | Tool                                                                                                                                                                          |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Display manager  | [greetd](https://git.sr.ht/~kennylevinsen/greetd) + [tuigreet](https://github.com/apognu/tuigreet)                                                                            |
| Compositor       | [niri](https://github.com/YaLTeR/niri)                                                                                                                                        |
| Status bar       | [waybar](https://github.com/Alexays/Waybar)                                                                                                                                   |
| Launcher         | [fuzzel](https://codeberg.org/dnkl/fuzzel)                                                                                                                                    |
| Lock screen      | [swaylock](https://github.com/swaywm/swaylock)                                                                                                                                |
| Notification     | [mako](https://github.com/emersion/mako)                                                                                                                                      |
| Screenshot       | [grim](https://github.com/emersion/grim) + [slurp](https://github.com/emersion/slurp) + [satty](https://github.com/gabm/satty)                                                |
| Screen recording | [wl-screenrec](https://github.com/russelltg/wl-screenrec)                                                                                                                     |
| Input method     | [fcitx5](https://fcitx-im.org/) (on [Rime](https://rime.im/)-[Wanxiang](https://github.com/amzxyz/rime_wanxiang))                                                             |
| Voice input      | [Just Talk](https://github.com/whoamihappyhacking/just-talk-go)                                                                                                               |
| Terminal         | [Foot](https://codeberg.org/dnkl/foot)                                                                                                                                        |
| Shell            | [Fish](https://fishshell.com/)                                                                                                                                                |
| Editor           | [Neovim](https://neovim.io/) (on [lazy.nvim](https://github.com/folke/lazy.nvim))                                                                                             |
| File manager     | [Yazi](https://github.com/sxyazi/yazi)                                                                                                                                        |
| Multiplexer      | [Zellij](https://github.com/zellij-org/zellij)                                                                                                                                |
| Browser          | [qutebrowser](https://github.com/qutebrowser/qutebrowser)                                                                                                                     |
| PDF viewer       | [zathura](https://pwmt.org/projects/zathura/)                                                                                                                                 |
| VCS              | [Git](https://git-scm.com/) ([lazygit](https://github.com/jesseduffield/lazygit)) / [Jujutsu](https://github.com/martinvonz/jj) ([lazyjj](https://github.com/Cretezy/lazyjj)) |
| System monitor   | [btop](https://github.com/aristocratos/btop)                                                                                                                                  |

**Fonts:**

- Monospace: [Maple Mono NL NF CN](https://github.com/subframe7536/maple-font)
- Sans-serif: [Noto Sans](https://fonts.google.com/noto/specimen/Noto+Sans) + Noto Sans CJK SC
- Serif: [Noto Serif](https://fonts.google.com/noto/specimen/Noto+Serif) + Noto Serif CJK SC

**Theme:** [Everforest Dark Medium](https://github.com/sainnhe/everforest) — applied consistently across terminal, editor, file manager, status bar, lock screen, notification daemon, PDF viewer, system monitor, git TUI, fzf, and btop.

## Design

Why not just image a machine? Because an image is mostly noise — the OS, every binary, every cache, months of accumulated state. It's a black box that rots.

The point is that a real environment carries very little information. What _defines_ my setup is a short list of choices: which tools, which versions, which config, what it looks like. That's all text. The binaries behind them are just what any machine installs from packages — there's nothing worth capturing. So a few megabytes of plain text is enough to describe a complete working setup.

Being text — not a black box — keeps it reproducible, diffable, and portable.

What it covers, roughly:

- **Dev tools** — versioned Go, Node, Python, Lua, Zig
- **My dotfiles** — shell, editor, terminal, file manager
- **System packages** — what pacman installs
- **System settings** — login, display manager, containers
- **Environment mirrors** — faster installs in China
- **One-off jobs** — tasks to run after setup

A fresh machine comes up with one command:

```bash
mise run bootstrap
```

It installs tools, deploys dotfiles, adds packages, applies system settings, and runs the post-setup jobs.
