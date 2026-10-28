variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}



variable "postgres_version" {
  type        = number
  default     = 18
  description = "PostgreSQL major version to install, from 14 to 18."

  validation {
    condition     = contains([14, 15, 16, 17, 18], var.postgres_version)
    error_message = "postgres_version must be a major PostgreSQL still supports and PGDG still builds: 14, 15, 16, 17 or 18."
  }
}

variable "listen_addresses" {
  type        = string
  default     = "localhost"
  description = "Addresses PostgreSQL listens on, comma-separated, such as \"localhost\", \"*\" or \"127.0.0.1,10.0.0.5\". Changing it restarts PostgreSQL."

  validation {
    condition     = can(regex("^[*A-Za-z0-9.:%_-]+( *, *[*A-Za-z0-9.:%_-]+)*$", var.listen_addresses))
    error_message = "listen_addresses must be a comma-separated list of host names or IP addresses, or \"*\"."
  }
}

variable "settings" {
  type        = map(string)
  default     = {}
  description = "postgresql.conf settings, such as { shared_buffers = \"256MB\", max_connections = \"200\" }. They go to conf.d/conn3x.conf, and changing them restarts PostgreSQL."

  validation {
    condition     = alltrue([for k, v in var.settings : can(regex("^[a-z_][a-z0-9_.]*$", k)) && !strcontains(v, "\n")])
    error_message = "Setting names use lowercase letters, digits, _ and ., and values can't contain line breaks."
  }

  validation {
    condition     = !contains(keys(var.settings), "listen_addresses")
    error_message = "Set listen_addresses with its own input, not in settings."
  }

  validation {
    condition     = can(regex("^[0-9]+$", lookup(var.settings, "port", "5432")))
    error_message = "port must be a number."
  }
}

variable "hba" {
  type = list(object({
    type     = string
    database = string
    user     = string
    address  = optional(string)
    method   = string
  }))
  default = [
    { type = "local", database = "all", user = "all", method = "peer" },
    { type = "host", database = "all", user = "all", address = "127.0.0.1/32", method = "scram-sha-256" },
    { type = "host", database = "all", user = "all", address = "::1/128", method = "scram-sha-256" },
  ]
  description = "pg_hba.conf rules, in order. A rule letting postgres in over the local socket with peer always comes first. Changing them reloads PostgreSQL."

  validation {
    condition     = alltrue([for r in var.hba : contains(["local", "host", "hostssl", "hostnossl", "hostgssenc", "hostnogssenc"], r.type)])
    error_message = "Each rule's type must be local, host, hostssl, hostnossl, hostgssenc or hostnogssenc."
  }

  validation {
    condition     = alltrue([for r in var.hba : contains(["trust", "reject", "scram-sha-256", "md5", "password", "gss", "sspi", "ident", "peer", "pam", "ldap", "radius", "cert"], r.method)])
    error_message = "Each rule's method must be one of trust, reject, scram-sha-256, md5, password, gss, sspi, ident, peer, pam, ldap, radius or cert."
  }

  validation {
    condition     = alltrue([for r in var.hba : (r.type == "local") == (r.address == null)])
    error_message = "A local rule takes no address, and every other rule needs one, such as \"10.0.0.0/8\"."
  }

  validation {
    condition     = alltrue([for r in var.hba : can(regex("^[^\\s#]+$", r.database)) && can(regex("^[^\\s#]+$", r.user)) && can(regex("^[^\\s#]+$", coalesce(r.address, "-")))])
    error_message = "database, user and address can't contain spaces or #."
  }
}

variable "users" {
  type        = list(string)
  default     = []
  description = "Roles to create with LOGIN. Each needs a password in user_passwords."

  validation {
    condition     = alltrue([for u in var.users : can(regex("^[a-z_][a-z0-9_]{0,62}$", u)) && !startswith(u, "pg_")])
    error_message = "User names use lowercase letters, digits and _, start with a letter or _, are at most 63 characters, and can't start with pg_."
  }
}

variable "user_passwords" {
  type        = map(string)
  default     = {}
  ephemeral   = true
  sensitive   = true
  nullable    = false
  description = "Password for each of users, by name. Pass it at run time with -var or TF_VAR_user_passwords; it never reaches state or the plan."

  validation {
    condition     = alltrue([for u in var.users : length(lookup(var.user_passwords, u, "")) > 0])
    error_message = "Each of users needs a non-empty password in user_passwords."
  }
}

variable "databases" {
  type        = map(string)
  default     = {}
  description = "Databases to create, each mapped to its owner, such as { app = \"app\" }. The owner must be one of users or an existing role."

  validation {
    condition     = alltrue([for d, o in var.databases : can(regex("^[a-z_][a-z0-9_]{0,62}$", d)) && can(regex("^[a-z_][a-z0-9_]{0,62}$", o))])
    error_message = "Database and owner names use lowercase letters, digits and _, start with a letter or _, and are at most 63 characters."
  }
}
