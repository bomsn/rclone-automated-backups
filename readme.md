## Rclone Automated Backups

Automate backups of WordPress sites — and arbitrary server directories — to any cloud storage provider that rclone supports. Create full-site, database-only, incremental, or files-only backups on a daily, weekly, or monthly schedule.

WordPress is the primary, fully-supported use case. The tool also handles non-WordPress directories ( forums, custom apps, static sites, anything else under a path you control ) and can dump any MySQL database — not only the one wp-cli reads from `wp-config.php`.

![Screenshot](/screenshot.png)

## Requirements

Always required:
- SSH and root access to your server. The script manages system cron, so it must be run as root ( via `sudo` ).
- [rclone](https://rclone.org/) installed.

Required for WordPress backups using the wp-cli driver ( the default for `full` / `database` / `incremental` types ):
- [wp-cli](https://wp-cli.org/) installed.
- A PHP CLI binary findable by the resolver — on PATH, or under one of:
  - `/opt/plesk/php/*/bin/php` ( Plesk )
  - `/opt/cpanel/ea-php*/root/usr/bin/php` ( cPanel / EasyApache )
  - `/usr/local/bin/php` or `/usr/bin/php` ( standard fallbacks )
- On servers with several PHP versions ( CloudPanel, Plesk ), pass `--php-binary /usr/bin/php8.3` ( your site's version ) when creating a backup. The backup then always uses that PHP and stops with an error if it is removed, instead of quietly using another version.

Required for the `mysqldump` database driver ( alternative to wp-cli, used for non-WP databases or when wp-cli is unavailable ):
- `mysqldump` and `mysql` client binaries.

Required for the `files` backup type:
- `tar` ( present on every Linux distribution by default ).
- Python 3.11 or later for descriptor-based, owner-isolated file restores.

## Optional
- [restic](https://restic.readthedocs.io/en/stable/020_installation.html) to add incremental backup support ( no setup or configuration needed ).
- A working mail sender ( `mail` / `mailutils` or `sendmail` ) if you want an email alert when a backup fails.

## Compatibility

Tested on the following hosting environments:
- Plesk ( Ubuntu / CentOS )
- cPanel / WHM
- Vanilla LAMP / LEMP ( Ubuntu 22.04 reference target )

## Getting Started

Follow these steps to set up automated backups:

### How to use:
- Connect to your server via SSH: `ssh root@server.ip.address`
- Download this repo:

```shell
apt-get -y install wget git
git clone https://github.com/bomsn/rclone-automated-backups.git rclone-backups
```
- Run the initialization script:

```shell
cd rclone-backups
sudo bash config.sh
```

You'll have options to add domains and configure backups.

The script will guide you through the process. When adding a site, you can let the script auto-discover WordPress installs on the server and pick from a list, enter a WordPress path manually, or enter a non-WordPress directory ( for use with the `files` type or the `mysqldump` driver ). Then configure your rclone remote( s ) and create backups, choosing a type ( see [Backup types](#backup-types) ), a schedule ( daily; weekly on a weekday you pick; or monthly on a day you pick, including the last day of the month ), a backup time and a retention period. When configuring a backup the script also auto-detects cache and junk folders ( caches, `node_modules`, backup-plugin folders, stray logs ) and offers to exclude them.

**Note:** the domains and associated paths will be saved to the `definitions` file, you can change it later if needed. However, note that changing the file doesn't change any running backups.

That's it, once you've completed all the configuration steps, a cron job will be created to take backups automatically using rclone. Feel free to use the menu again to make as many automated backups as you want.

## Backup types

| Type | What it captures | Database step | When to use |
|------|------------------|---------------|-------------|
| `full` | Site files + database in one `tar.gz` | wp-cli ( default ) or mysqldump | The standard WordPress backup ( files + DB together ) |
| `database` | Database only ( compressed `.sql.gz` ) | wp-cli ( default ) or mysqldump | Lightweight daily companion to a weekly `full` |
| `incremental` | Files + database via encrypted, deduplicated restic snapshots | wp-cli ( hardcoded ) | Nightly recovery points alongside a periodic `full` |
| `files` | Directory only ( `tar.gz` ); no database | none | Any non-WordPress directory ( forums, static sites, custom apps without a DB ) |

## Database drivers

The `full` and `database` types accept a `--db-driver` knob:

| Driver | How it reads credentials | When to use |
|--------|--------------------------|-------------|
| `wpcli` ( default ) | From `wp-config.php` in the site path | Standard WordPress sites |
| `mysqldump` | From `--db-name` / `--db-user` / `--db-pass` / `--db-host` flags | Non-WordPress databases, or WordPress sites where wp-cli / PHP is unavailable |

When the `mysqldump` driver is used, the database credentials are stored base64-encoded ( not encrypted ) inside the generated backup script, which only root can read. At backup time the script writes a private temporary client-options file and calls `mysqldump --defaults-extra-file=...`, keeping credentials out of the dump command's arguments. The temporary file is removed after the dump. Protect any credentials initially supplied through command-line flags from shell history and other local users.

### Incremental backups: what to know

- The site's files are read as the site's own user, packed, then handed to restic from a private folder only root can read. This stops a website from tricking the backup into reading files outside the site.
- That needs free disk space while it runs: about three times the size of the site, plus 64 MB. Restic's deduplication saves storage and upload, not local reading.
- Keep the restic password and your storage credentials somewhere off the server ( a password manager ), or you can't restore if the server is lost.
- If a server crashed during a backup, check for leftover `rclone-automated-backups.*` temporary folders before deleting them.

### Where the tool keeps its files

New installs keep the site list, logs and generated backup jobs in `/var/lib/rclone-automated-backups`, outside any website. Always run the tool as root, and never keep it or its jobs inside a website folder. If an older install kept its files somewhere else, point to them with `sudo RCLONE_BACKUP_STATE_DIR=/path/to/old/state bash config.sh`. Existing cron schedules are never moved or rewritten.

**After updating this tool, regenerate your existing backups** ( disable and recreate them in the menu ). Each generated cron script contains its own copy of the code, so a `git pull` alone doesn't change backups that already exist.

`mysqldump` is invoked with `--single-transaction --quick --routines --events --triggers`. The `--single-transaction` flag provides a consistent snapshot for InnoDB tables; databases that use MyISAM tables may need `--lock-tables` instead, which can be added by editing the generated script.

### Non-interactive ( headless ) usage

Every option can be passed as a flag, so a backup can be created in a single command — handy for scripting many sites at once:

```shell
sudo bash config.sh \
  --domain example.com --type full --frequency weekly --day monday \
  --time 02:00 --retention 30 --remote mydrive --location backups/example
```

| Flag | Required | Description |
|------|----------|-------------|
| `--domain` | yes | site domain or identifier |
| `--type` | yes | `full`, `incremental`, `database` or `files` |
| `--frequency` | yes | `daily`, `weekly` or `monthly` |
| `--time` | yes | backup time `HH:MM`, in the server's timezone |
| `--retention` | yes | days to keep: `3`, `7`, `30`, `90` or `180` |
| `--remote` | yes | rclone remote name |
| `--location` | yes | backup location on the remote |
| `--path` | new sites | path; required when the domain is not already saved. Must point at a WordPress install for `full` / `incremental` / `database` with the default `wpcli` driver; can be any directory for `--type files` or for `--db-driver mysqldump` |
| `--day` | weekly / monthly | weekday ( `monday`..`sunday` ) or month day ( `1`..`28`, or `last` ) |
| `--exclude` | no | comma-separated paths, or `none`; omit to auto-detect cache / junk folders |
| `--password` | incremental | restic repository password |
| `--db-driver` | no | `wpcli` ( default ) or `mysqldump`; not valid with `--type files` / `incremental` |
| `--db-name` | mysqldump | database name |
| `--db-user` | mysqldump | database user |
| `--db-pass` | mysqldump | database password |
| `--db-host` | no | mysqldump host ( default: `localhost` ) |
| `--php-binary` | no | PHP to run wp-cli with, e.g. `/usr/bin/php8.3`; recommended on servers with several PHP versions |
| `--no-initial` | no | skip the immediate first backup; let the schedule take it ( default: run the first backup right away ) |
| `--yes` | no | assume yes to confirmations |

By default the first backup runs immediately ( in the foreground, so you see whether it succeeded ); the cron schedule takes every backup after that. After any interactive run, the script prints the equivalent one-line command so you can copy it to reproduce or automate the same backup.

### Upgrading from `rclone-automated-backups-for-wordpress`

The repo was renamed from `rclone-automated-backups-for-wordpress` to `rclone-automated-backups`. Existing installs can either let GitHub auto-redirect on `git pull`, or update the remote explicitly:

```shell
git remote set-url origin https://github.com/bomsn/rclone-automated-backups.git
git pull
```

On first run after the upgrade, `sudo bash config.sh` will show all existing backups in the management UI and existing scheduled cron jobs continue to fire — the tool reads both the new `/etc/cron.d/rclone-automated-backups` file and the legacy `/etc/cron.d/rclone-automated-backups-by-alikhallad` file, and any backup script generated by the new code mutually excludes against any in-flight script generated before the rename via dual file-locking. No manual migration step is needed.

### Restoring: source site or another path/site

When you restore a backup ( **Manage backups → View/restore remote backups** ), the first question is *where* it lands:

1. **Source ( live )** — the original site the backup came from. Files are written back in place, the database is imported into the live DB, and a pre-restore backup of the live site is taken first as a safety net.
2. **Another path / site** — a different directory and database you name. You enter the target path; the tool reads it, resolves the destination database, redirects **every** file write and the database import there, and — for WordPress targets — rewrites the site URL so the restored copy points at the target site, not the live one. Handy for a test/clone restore, or for restoring a backup onto a different site entirely.

How the target database is resolved:

- For an existing WordPress destination, its own `wp-config.php` and database are kept. The current destination URL is captured before import and restored with `wp search-replace`; stored filesystem paths are updated when the directory changes. WordPress runs under the destination's non-root Unix owner using the selected PHP CLI, including on hosts whose default PHP command uses CGI. A root-owned WordPress tree must have its correct site ownership restored first.
- If the target has no `wp-config.php` ( a `files` backup, a `mysqldump` backup, or a WordPress backup landing on a fresh/empty path ), the tool prompts you for the target database name / user / password / host and imports into that database. When the restored files include a `wp-config.php` ( a WordPress backup ), it is updated with the credentials you gave so the site can connect. URL rewriting is left to you in this case.

Safety guards that make an accidental live restore impossible when restoring elsewhere:

- The target path must be an existing directory, absolute, and never `/`. The tool also checks it is still the same folder right before writing.
- The restore **aborts** if the target path equals, sits inside, or contains the source path, or if the target database equals the source database.
- The target URL must differ from the source URL ( you are re-prompted otherwise ).
- A resolved summary ( files → path, DB → target, URL → old → new ) must be confirmed before anything is written, and the source path and database are never referenced when restoring elsewhere.
- The archive is checked before any files are cleared. Files are written as the destination site's user; entries that try to escape the folder, special files and links pointing outside it are refused. Normal links inside the site still work.
- The database dump stays in a private temporary folder during the restore, and the import can't run local commands or read other files on the server.

**Before restoring**, take the destination site offline ( maintenance mode ) and pause its cron jobs; the tool doesn't do this for you. Keep it offline until the restored site works. When restoring a copy of a live shop to staging, switch off its outgoing email, payments and webhooks first.

Use a separate remote folder for each site. A backup that uploaded fine isn't proven until you have restored it once; tests for archive and incremental restores are in `tests/`.

> Note: URL rewriting runs only when the target is a working WordPress install. For non-WordPress / explicit-credential restores the data is restored and imported, but `siteurl` / `home` are left as-is. The target install is also assumed to use the same table prefix as the backup.

### Subsequent Use:

If you want to add more websites, create additional backups, disable or delete existing backups, restore the remote backups created by the script ( to the live site or to another path/site ), or set an email address for backup-failure alerts ( under **Manage backups → Configure email notifications** ), just run the config script again `sudo bash config.sh` and use the available options.
