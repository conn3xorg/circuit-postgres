output "config_dirs" {
  description = "Directory holding postgresql.conf and pg_hba.conf on each host, by host name."
  value       = { for name, h in local.hosts : name => h.conf }
}

output "services" {
  description = "systemd unit running PostgreSQL on each host, by host name."
  value       = { for name, h in local.hosts : name => h.service }
}
