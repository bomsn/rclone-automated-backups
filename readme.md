## Rclone Automated Backups for WordPress

Automate WordPress backups to various cloud storage providers using rclone automation. Create full-site, database-only, or `restic`-based incremental backups on a daily, weekly, or monthly schedule.

![Screenshot](/screenshot.png)

## Requirements
- SSH and root access to your server. The script manages system cron, so it must be run as root (via `sudo`).
- [wp-cli](https://wp-cli.org/) installed.
- [rclone](https://rclone.org/) installed.

## Optional
- [restic](https://restic.readthedocs.io/en/stable/020_installation.html) to add incremental backup support ( no setup or configuration needed ).
- A working mail sender (`mail` / `mailutils` or `sendmail`) if you want an email alert when a backup fails.

## Getting Started

Follow these steps to set up automated WordPress backups:

### How to use:
- Connect to your server via SSH: `ssh root@server.ip.address`
- Download this repo zip file:

```shell
apt-get -y install wget git
git clone https://github.com/bomsn/rclone-automated-backups-for-wordpress.git rclone-wordpress
```
- Run the initilization script

```shell
cd rclone-wordpress
sudo bash config.sh
```  

You'll have options to add domains and configure backups. 

The script will guide you through the process. When adding a site, you can let the script auto-discover WordPress installs on the server and pick from a list, or enter the path manually. Then configure your rclone remote(s) and create backups, choosing a type (full site, database-only, or incremental), a schedule (daily, weekly, or monthly), a backup time and a retention period.

**Note:** the domains and associated paths will be saved to `definitions` file, you can change it later if needed. However, note that changing the file doesn't change any running backups.

That's it, once you've completed all the configuration steps, a cron job will be created to take backups automatically using rclone. Feel free to use the menu again to make as many automated backups as you want.

### Subsequent Use:

If you want to add more websites, create additional backups, disable or delete existing backups, restore the remote backups created by the script, or set an email address for backup-failure alerts (under **Manage backups → Configure email notifications**), just run the config script again `sudo bash config.sh` and use the available options.
