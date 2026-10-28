# Facts give each host's distribution, which picks where PostgreSQL comes
# from and where its files live.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }
}

locals {
  v        = var.postgres_version
  codename = { "22.04" = "jammy", "24.04" = "noble", "26.04" = "resolute", "12" = "bookworm", "13" = "trixie" }

  apt_hosts    = { for name, h in var.hosts : name => h if data.conn3x_host.facts[name].os_family == "debian" }
  fedora_hosts = { for name, h in var.hosts : name => h if data.conn3x_host.facts[name].os_id == "fedora" }
  el_hosts     = { for name, h in var.hosts : name => h if data.conn3x_host.facts[name].os_family == "redhat" && data.conn3x_host.facts[name].os_id != "fedora" }

  # Where each host's cluster lives. Debian and Ubuntu keep the configuration
  # in /etc and create the cluster when the package installs; the Red Hat
  # family keeps it in the data directory and leaves initdb to the circuit.
  layout = {
    debian = {
      conf    = "/etc/postgresql/${local.v}/main"
      data    = "/var/lib/postgresql/${local.v}/main"
      bin     = "/usr/lib/postgresql/${local.v}/bin"
      service = "postgresql@${local.v}-main"
      initdb  = "pg_createcluster ${local.v} main"
    }
    el = {
      conf    = "/var/lib/pgsql/${local.v}/data"
      data    = "/var/lib/pgsql/${local.v}/data"
      bin     = "/usr/pgsql-${local.v}/bin"
      service = "postgresql-${local.v}"
      initdb  = "/usr/pgsql-${local.v}/bin/postgresql-${local.v}-setup initdb"
    }
    fedora = {
      conf    = "/var/lib/pgsql/data"
      data    = "/var/lib/pgsql/data"
      bin     = "/usr/bin"
      service = "postgresql"
      initdb  = "postgresql-setup --initdb"
    }
  }
  hosts = {
    for name, f in data.conn3x_host.facts : name => local.layout[f.os_family == "debian" ? "debian" : f.os_id == "fedora" ? "fedora" : "el"]
  }

  port = try(var.settings.port, "5432")

  conf = join("", [for k, val in merge(var.settings, { listen_addresses = var.listen_addresses }) : "${k} = '${replace(val, "'", "''")}'\n"])

  # The first rule lets the circuit itself, running psql as postgres over the
  # local socket, manage roles and databases whatever the other rules say.
  hba = join("", concat(
    ["# Managed by Conn3x.\nlocal all postgres peer\n"],
    [for r in var.hba : "${join(" ", compact([r.type, r.database, r.user, r.type == "local" ? "" : r.address, r.method]))}\n"],
  ))

  password_dir = "/etc/conn3x/postgres"
}

# PGDG's apt repository. Each Debian and Ubuntu release has its own suite.
circuit "postgres_apt" {
  hosts = local.apt_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "repo" {
    repository {
      name       = "pgdg"
      url        = "https://apt.postgresql.org/pub/repos/apt"
      key        = file("${path.module}/files/pgdg-deb.asc")
      suites     = ["${local.codename[data.conn3x_host.facts[each.key].os_version]}-pgdg"]
      components = ["main"]
    }
  }

  step "server" {
    package {
      name = "postgresql-${local.v}"
    }
  }
}

# PGDG's yum repository for Rocky Linux, AlmaLinux and RHEL, one per major.
# PGDG signs each architecture's packages with its own key. The packages are
# named postgresqlNN-*, so they don't clash with the distribution's own
# postgresql packages, and EL10 has no module to disable.
circuit "postgres_el" {
  hosts = local.el_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "repo" {
    repository {
      name = "pgdg${local.v}"
      url  = "https://download.postgresql.org/pub/repos/yum/${local.v}/redhat/rhel-$releasever-$basearch"
      key  = file("${path.module}/files/pgdg-rpm-${data.conn3x_host.facts[each.key].arch}.asc")
    }
  }

  step "server" {
    package {
      name = "postgresql${local.v}-server"
    }
  }
}

# PGDG doesn't build for Fedora 45, or for Fedora on arm64, so Fedora gets
# its own packages. Fedora ships each supported major as postgresqlNN-server,
# or plain postgresql-server for its default major, which also answers to
# the versioned name.
circuit "postgres_fedora" {
  hosts = local.fedora_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "server" {
    package {
      name = "postgresql${local.v}-server"
    }
  }
}

circuit "postgres" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Creates the cluster where the package didn't. On Debian and Ubuntu it
  # already exists, so this only runs if someone removed it.
  step "initdb" {
    command {
      command = local.hosts[each.key].initdb
      creates = "${local.hosts[each.key].data}/PG_VERSION"
    }
    depends_on = [conn3x_package.postgres_apt__server, conn3x_package.postgres_el__server, conn3x_package.postgres_fedora__server]
  }

  step "include_dir" {
    line {
      path   = "${local.hosts[each.key].conf}/postgresql.conf"
      regexp = "^#?include_dir\\b"
      line   = "include_dir = 'conf.d'"
    }
  }

  step "conf_dir" {
    directory {
      path  = "${local.hosts[each.key].conf}/conf.d"
      owner = "postgres"
      group = "postgres"
      mode  = "0700"
    }
  }

  step "config" {
    file {
      path    = "${local.hosts[each.key].conf}/conf.d/conn3x.conf"
      content = local.conf
      owner   = "postgres"
      group   = "postgres"
      mode    = "0600"
    }
  }

  step "hba" {
    file {
      path    = "${local.hosts[each.key].conf}/pg_hba.conf"
      content = local.hba
      owner   = "postgres"
      group   = "postgres"
      mode    = "0600"
    }
    notify = [handler.reload]
  }

  # listen_addresses, port and many settings only take effect on a restart.
  # It runs here rather than in a handler so the steps below, which connect
  # on the configured port, find the server running with the new settings.
  # On a first apply it's what starts the server.
  step "restart" {
    command {
      command = "systemctl restart ${local.hosts[each.key].service}"
      triggers = {
        include_dir = conn3x_line.postgres__include_dir[each.key].revision
        config      = conn3x_file.postgres__config[each.key].revision
      }
    }
  }

  step "running" {
    service {
      name    = local.hosts[each.key].service
      state   = "started"
      enabled = true
    }
  }

  step "password_dir" {
    directory {
      path = local.password_dir
      mode = "0700"
    }
  }

  # Each password lands in a root-only file, never in state or the plan.
  step "password" {
    for_each = toset(var.users)
    file {
      path       = "${local.password_dir}/${item.key}"
      content_wo = var.user_passwords[item.key]
    }
  }

  step "role" {
    for_each = toset(var.users)
    command {
      command = "cd / && runuser -u postgres -- ${local.hosts[each.key].bin}/psql -X -q -p ${local.port} -v ON_ERROR_STOP=1 -c 'CREATE ROLE \"${item.key}\" LOGIN'"
      unless  = "cd / && runuser -u postgres -- ${local.hosts[each.key].bin}/psql -X -tA -p ${local.port} -c \"SELECT 1 FROM pg_roles WHERE rolname = '${item.key}'\" | grep -qx 1"
    }
  }

  # Sets the password when its file changed or the role was created. The
  # password reaches psql on stdin as part of the SQL, so it never shows in
  # ps. psql sends it to the server as a literal, and the server stores only
  # its SCRAM hash.
  step "set_password" {
    for_each = toset(var.users)
    command {
      command = "cd / && { printf 'ALTER ROLE \"${item.key}\" PASSWORD \\047'; sed \"s/'/''/g\" ${local.password_dir}/${item.key} | tr -d '\\n'; printf '\\047;\\n'; } | runuser -u postgres -- ${local.hosts[each.key].bin}/psql -X -q -p ${local.port} -v ON_ERROR_STOP=1"
      triggers = {
        password = conn3x_file.postgres__password["${each.key}/${item.key}"].revision
        role     = conn3x_command.postgres__role["${each.key}/${item.key}"].revision
      }
    }
  }

  step "database" {
    for_each = var.databases
    command {
      command = "cd / && if runuser -u postgres -- ${local.hosts[each.key].bin}/psql -X -tA -p ${local.port} -c \"SELECT 1 FROM pg_database WHERE datname = '${item.key}'\" | grep -qx 1; then runuser -u postgres -- ${local.hosts[each.key].bin}/psql -X -q -p ${local.port} -v ON_ERROR_STOP=1 -c 'ALTER DATABASE \"${item.key}\" OWNER TO \"${item.value}\"'; else runuser -u postgres -- ${local.hosts[each.key].bin}/psql -X -q -p ${local.port} -v ON_ERROR_STOP=1 -c 'CREATE DATABASE \"${item.key}\" OWNER \"${item.value}\"'; fi"
      unless  = "cd / && runuser -u postgres -- ${local.hosts[each.key].bin}/psql -X -tA -p ${local.port} -c \"SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${item.key}'\" | grep -qx '${item.value}'"
    }
  }

  handler "reload" {
    service {
      name   = local.hosts[each.key].service
      action = "reload"
    }
  }
}
