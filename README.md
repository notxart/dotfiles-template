# My Personal Dotfiles for Bash

This repository serves as a robust, modular boilerplate for Bash configuration files, optimized for a modern development workflow. The setup is designed to be portable, maintainable, and strictly compliant with the XDG Base Directory Specification.

![Screenshot](https://github.com/user-attachments/assets/34cfa27f-0d63-4ef5-8ba9-71be6aa0a7ae)

## ✨ Features

- **Modern Prompt**: Styled with [Starship](https://starship.rs/), providing rich, context-aware information.
- **Enhanced Shell Experience**: Powered by [ble.sh](https://github.com/akinomyoga/ble.sh) for syntax highlighting, auto-suggestions, and an advanced line editor with Vi mode.
- **Fuzzy Search Everywhere**: [fzf](https://github.com/junegunn/fzf) integration for blazing-fast history search (Ctrl+R) and file finding.
- **Smart Directory Navigation**: [zoxide](https://github.com/ajeetdsouza/zoxide) learns your habits, allowing you to jump to frequent directories with short commands.
- **XDG Compliance**: Keeps your `$HOME` directory clean by storing configuration, data, and cache files in standard locations (`~/.config`, `~/.local/share`, etc.).
- **Multi-Identity Git**: Easily manage work and personal Git profiles using conditional includes.
- **Automated Setup**: A single script to install tools and set up configurations across different systems (supports Debian/Ubuntu, Fedora, Arch Linux, and macOS).

## 🚀 Installation

To ensure you can manage your own configurations and sync them across your machines, **do not clone this repository directly**. Instead, follow the steps below to create your own copy.

1. **Create Your Repository**

    Click the ![Use this template](https://custom-icon-badges.demolab.com/badge/Use_this_template-238636) button on GitHub to generate a new repository from this template. This detaches your dotfiles from the upstream, allowing you to push changes and maintain your own version.

2. **Clone and Install**

    Once you have your own repository, clone it to your local machine. It is recommended to clone into `~/dotfiles` to keep your home directory organized.

    1. Clone your repository to a hidden directory. (Replace `<YOUR_USERNAME>` with your actual GitHub username)

        ```sh
        git clone https://github.com/<YOUR_USERNAME>/dotfiles.git ~/dotfiles
        ```

    2. Navigate to the directory.

        ```sh
        cd ~/dotfiles
        ```

    3. Execute the installation script.

        ```sh
        chmod u+x install.sh
        ./install.sh
        ```

        > [!NOTE]
        > **Starship Installation**: The script prioritizes installing starship via your system's package manager. If your distribution is older (e.g., Debian 12, Ubuntu 24.04) and does not include Starship in its repositories, the script will automatically fallback to the official Starship installer script. No manual action is required.

    The script will:
    1. Install necessary dependencies (starship, fzf, zoxide, etc.) via your system's package manager.
    2. Back up any existing configuration files to `~/dotfiles_backup_<timestamp>`.
    3. Create symlinks from `~/dotfiles` to the appropriate locations (mostly `~/.config/`).

3. **Restart Shell**

    Open a new terminal window or run `source ~/.bashrc` to apply the changes.

## 🔧 Customization

This setup is designed to be extensible without modifying the core files, preventing merge conflicts when you update the core logic.

### Adding Personal Aliases or Scripts

The proper way to add your own configurations is to create a new file in the `config/bash/rc.d/` directory. The scripts are loaded in ***lexicographical order***.

For example, create `config/bash/rc.d/99-local.sh`:

```sh
# My custom aliases
alias k="kubectl"

# My custom functions
my_func() {
  echo "Hello from my local config!"
}
```

Then, run `./install.sh` again to ensure symlinks are correct (though for `rc.d` files, no new symlinks are needed as the directory is already linked).

### Git Identity Setup

This template uses a split-config approach for Git to separate personal and work identities.

1. **Primary Identity**: Edit `config/git/config` in your repo. Change the `[user]` section to your default Git profile.
2. **Work Identity**: Edit `config/git/work`. This file is conditionally included.
3. **Activation**: In `config/git/config`, update the path in `[includeIf "gitdir:~/workspace/"]` to match your work projects directory.
    > [!IMPORTANT]
    > Any git repository inside `~/workspace/` (or your chosen path) will automatically use the configuration defined in `config/git/work`.

### WSL integration

If you want to use applications that interact with the Windows PATH in WSL (e.g. VS Code, explorer.exe), but don't want WSL to access the entire Windows PATH, first add the following to `/etc/wsl.conf`:

```toml
[interop]
enabled = true
appendWindowsPath = false
```

Next, in `config/bash/rc.d/30-wsl.sh`, change `vscode_user_profile='/mnt/c/Users/Foo'` to your own Windows user path. Also, specify the Windows app alias and full application path you want to use using `alias`.

## 📦 Managing Your Dotfiles

Since you have cloned your own repository, you can now track changes to your configuration:

```sh
cd ~/dotfiles
git add .

# Replace `<COMMIT_MSG>` with your actual commit message, e.g., "feat: added new alias for kubectl"
git commit -m <COMMIT_MSG>

git push
```

On a new machine, simply repeat the Installation steps using your repository URL to synchronize your environment.
