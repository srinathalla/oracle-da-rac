output "aix_instance_all_private_ips" {
  description = "All private IPs of all AIX AIX instances"
  value = flatten([
    for m in module.pi_instance_aix : m.pi_instance_private_ips
  ])
}
