resource "local_file" "ansible-inventory" {
    count = var.power_state == "active" ? 1 : 0
    content = templatefile("${path.module}/hosts.yml.tmpl",
    {
        server_ips = openstack_compute_floatingip_associate_v2.os_floatingips_associate.*.floating_ip
        server_names = openstack_compute_instance_v2.os_instances.*.name # we could use this instead of an generically generated index name
        prj_name = var.project
    })
    filename = "${path.module}/ansible/hosts.yml"
}

resource "null_resource" "ansible-execution" {
    count = var.do_ansible_execution && var.power_state == "active" ? 1 : 0

    triggers = {
        always_run = "${timestamp()}"
    }

    provisioner "local-exec" {
        command = "ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_SSH_PIPELINING=True ANSIBLE_CONFIG=ansible.cfg ansible-playbook -i hosts.yml --forks=10 playbook.yml"
        working_dir = "${path.module}/ansible"
    }
    provisioner "local-exec" {
        command  = "pip3 install python-openstackclient"

    }

    depends_on = [
        local_file.ansible-inventory,
    ]
}

resource "null_resource" "shelve-unshelve" {
      count = var.instance_count

      provisioner "local-exec" {
        command = "openstack server shelve ${openstack_compute_instance_v2.os_instances[count.index].id} --wait && sleep 30"
      }
      
      provisioner "local-exec" {
        command = "openstack server unshelve ${openstack_compute_instance_v2.os_instances[count.index].id} --wait"
      }
      depends_on = [
        null_resource.ansible-execution
      ]
}