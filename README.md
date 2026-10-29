# circuit-postgres

A Conn3x circuit that installs PostgreSQL from the PostgreSQL project's own repositories, sets up the cluster, and creates the roles and databases your apps log in with. You get the current major on Rocky Linux, Ubuntu and Debian rather than whatever the distribution froze at release, and a config you can review in `conn3x plan` before it reaches the server.

Passwords never land in state. You pass them in at run time through an ephemeral variable, and the plan shows only that a password changed.

## Usage

```hcl
variable "app_db_password" {
  type      = string
  ephemeral = true
  sensitive = true
}

module "postgres" {
  source = "github.com/conn3xorg/circuit-postgres?ref=v0.2.0"

  hosts                = { db = "192.168.1.30" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  listen_addresses = "*"
  settings         = { shared_buffers = "1GB", max_connections = "200" }
  hba = [
    { type = "local", database = "all", user = "all", method = "peer" },
    { type = "host", database = "app", user = "app", address = "192.168.1.0/24", method = "scram-sha-256" },
  ]

  users          = ["app"]
  user_passwords = { app = var.app_db_password }
  databases      = { app = "app" }
}
```

Then run `conn3x init` and `conn3x apply` with the password in the environment:

```sh
export TF_VAR_app_db_password='...'
conn3x apply
```

A second `conn3x plan` says `No changes.` Every plan needs the password too, since Conn3x checks the file on the host against it.

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry. Give each one's distribution in `os` too: the circuit picks its packages by distribution, and Conn3x can't ask a host that doesn't exist yet. If `os` turns out not to match the host, Conn3x stops before configuring it. Set `os` as well when you put `depends_on` on this module: `depends_on` holds back reading the hosts until the apply, so without `os` the plan fails with `Invalid for_each argument`.

```hcl
hosts = {
  for name, d in digitalocean_droplet.db : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

## What it does

On each host, in order:

1. Adds the PGDG repository and its signing key, from the keys in [files](files): `apt.postgresql.org` on Debian and Ubuntu, `download.postgresql.org` on Rocky Linux, AlmaLinux and RHEL. On Fedora it uses Fedora's own packages instead (see below).
2. On the Red Hat family, before PostgreSQL starts, when `settings` sets a `port` other than 5432, installs `policycoreutils-python-utils` and labels the port `postgresql_port_t` with `semanage`, so SELinux lets PostgreSQL bind it. Hosts with SELinux off skip the label.
3. Installs the server for `postgres_version`: `postgresql-18` on Debian and Ubuntu, `postgresql18-server` on the Red Hat family.
4. Creates the cluster if it doesn't exist. Debian and Ubuntu do this when the package installs; on the Red Hat family the circuit runs `postgresql-18-setup initdb`, or `postgresql-setup --initdb` on Fedora, once.
5. Turns on `include_dir = 'conf.d'` in `postgresql.conf` and writes `conf.d/conn3x.conf` from `listen_addresses` and `settings`.
6. Writes `pg_hba.conf` from `hba`, with one rule ahead of yours: `local all postgres peer`, which the circuit needs to manage roles.
7. Checks the new files before anything restarts or reloads. `postgres -C` parses the configuration the way a server start would, and the running server reads `pg_hba.conf` through `pg_hba_file_rules`. A misspelt setting, a bad value such as `shared_buffers = "1 GiB"` or a rule PostgreSQL rejects fails the apply with PostgreSQL's own message, and the server keeps running on what it had. Fix the input and apply again. On a first apply there's no server running to ask about `pg_hba.conf`, so a bad rule fails the start instead.
8. Restarts PostgreSQL when `conn3x.conf` or the include line changed, then keeps it running and enabled at boot. Restarting on any settings change is deliberate: `listen_addresses`, `port`, `shared_buffers` and plenty of others do nothing until a restart.
9. For each of `users`, writes its password to `/etc/conn3x/postgres/NAME` (root only, mode 0600), creates the role with `LOGIN`, and sets the password whenever that file changed.
10. Creates each of `databases` with its owner, or changes the owner of one that exists.
11. Reloads PostgreSQL when `pg_hba.conf` changed, after everything else, so open connections survive.

The circuit runs `psql` as `postgres` over the local socket. A password reaches `psql` on standard input, so it never shows up in `ps`, and the server stores only its SCRAM hash. It does travel through the server's statement handling, so don't turn on `log_statement = 'all'` while you change one.

If someone edits `conn3x.conf` or `pg_hba.conf` by hand, the next plan shows the difference and the apply puts yours back, restarting or reloading as above.

### Where things live

| | Debian, Ubuntu | Rocky Linux, AlmaLinux, RHEL | Fedora |
| --- | --- | --- | --- |
| Configuration | `/etc/postgresql/18/main` | `/var/lib/pgsql/18/data` | `/var/lib/pgsql/data` |
| Data | `/var/lib/postgresql/18/main` | `/var/lib/pgsql/18/data` | `/var/lib/pgsql/data` |
| systemd unit | `postgresql@18-main` | `postgresql-18` | `postgresql` |

The `config_dirs` and `services` outputs give the same per host.

### Fedora

PGDG doesn't publish packages for Fedora 45, or for Fedora on arm64, so on Fedora the circuit installs Fedora's own `postgresqlNN-server`. Fedora 45 ships 16, 17 and 18. Other majors fail at the package step.

### What it doesn't cover

- **Upgrades between majors.** Changing `postgres_version` doesn't upgrade anything. It installs the new major beside the old one with an empty cluster, which this circuit isn't tested for. Move your data across with `pg_upgrade` or a dump first.
- **Removal.** Taking a user or database out of the inputs leaves it in PostgreSQL. Drop it in `psql` first.
- **Role attributes.** Roles get `LOGIN` and nothing else. Grant `CREATEDB`, `SUPERUSER` or table privileges yourself.
- **TLS, replication, backups and extensions.** None of these are set up.
- **Firewall.** The circuit doesn't open port 5432. The [firewall circuit](https://github.com/conn3xorg/circuit-firewall) can.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`, which a host created in the same plan needs. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `postgres_version` | number | `18` | Major version to install: 14, 15, 16, 17 or 18. |
| `listen_addresses` | string | `"localhost"` | Addresses to listen on, comma-separated, such as `"*"` or `"127.0.0.1,10.0.0.5"`. Changing it restarts PostgreSQL. |
| `settings` | map(string) | `{}` | `postgresql.conf` settings, such as `{ shared_buffers = "1GB" }`. Changing them restarts PostgreSQL. Set `listen_addresses` with its own input. |
| `hba` | list(object) | Local peer, and scram-sha-256 from `127.0.0.1` and `::1` | `pg_hba.conf` rules, in order. Each has `type`, `database`, `user`, `method`, and `address` for every type but `local`. An address with a `/` must be a valid CIDR network. `method` is one of `trust`, `reject`, `scram-sha-256`, `md5`, `password`, `gss`, `sspi`, `ident`, `peer`, `pam`, `ldap`, `radius` or `cert`. Changing them reloads PostgreSQL. |
| `users` | list(string) | `[]` | Roles to create with `LOGIN`. Names use lowercase letters, digits and `_`, and can't start with `pg_`. |
| `user_passwords` | map(string), ephemeral | `{}` | Password for each of `users`, by name. Every user needs one. |
| `databases` | map(string) | `{}` | Databases to create, each mapped to its owner, such as `{ app = "app" }`. The owner must be one of `users` or a role that already exists. |

## Outputs

| Name | Description |
| --- | --- |
| `config_dirs` | Directory holding `postgresql.conf` and `pg_hba.conf` on each host, such as `{ db = "/etc/postgresql/18/main" }`. |
| `services` | systemd unit running PostgreSQL on each host, such as `{ db = "postgresql@18-main" }`. |

## Requirements

Requires Conn3x v0.6.5 or later and systemd on each host, with outbound HTTPS to apt.postgresql.org or download.postgresql.org, or to Fedora's mirrors on Fedora.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13, with PostgreSQL 18. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes, and connects over TCP as the example's user with its password. The same was run by hand on arm64, along with a misspelt setting, a bad value and a rejected `pg_hba.conf` rule, each of which failed the apply and left the server running, and a move to port 5433.

All of that ran in containers, where SELinux is off. On a Rocky Linux 10 droplet with SELinux enforcing, a server on port 5433 was applied by hand: the circuit labelled 5433 `postgresql_port_t`, the second plan had no changes, `SELECT 1` worked over TCP, and the audit log had no denials. PGDG's server runs as `unconfined_service_t` there, so the label wasn't what let it bind. Fedora's own server runs confined as `postgresql_t`, and on a Fedora 44 droplet with SELinux enforcing the same checks passed with no denials. An AlmaLinux 10 droplet behaved like Rocky. Both came back after a reboot with the server running and the second plan clean.

## License

MPL-2.0. See [LICENSE](LICENSE). PostgreSQL itself is under the PostgreSQL License.
