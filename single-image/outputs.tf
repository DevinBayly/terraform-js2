output "instance_uuids" {
  value = tolist(openstack_compute_instance_v2.os_instances.*.id)
}

output "vm_usernames" {
  value = local.vm_usernames
}
