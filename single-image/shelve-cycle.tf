# Shelve/unshelve cycle, run after ansible has finished configuring the instances.
#
# The API calls deliberately run on the control node rather than on the VM. An
# earlier attempt ran openstack.cloud.server_action from inside the ansible play
# targeting the VM itself, which killed its own ssh session the moment the shelve
# took effect and left the host UNREACHABLE.
resource "null_resource" "shelve_unshelve_cycle" {
  count = var.do_shelve_cycle && var.do_ansible_execution && var.power_state == "active" ? var.instance_count : 0

  # keyed on the instance id so the cycle runs once per instance lifetime; using
  # timestamp() here would shelve a vm that someone may be actively using
  triggers = {
    server_id = openstack_compute_instance_v2.os_instances[count.index].id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    on_failure  = continue

    environment = {
      SERVER_ID   = openstack_compute_instance_v2.os_instances[count.index].id
      FLOATING_IP = openstack_compute_floatingip_associate_v2.os_floatingips_associate[count.index].floating_ip
      GAP_SECONDS = tostring(var.shelve_gap_seconds)
    }

    command = <<-EOT
      set -uo pipefail
      log() { echo "[shelve-cycle][$SERVER_ID] $*"; }

      # preflight - never break a deployment over a post-config step
      if ! command -v openstack >/dev/null 2>&1; then
        log "WARNING: 'openstack' CLI not found on control node - skipping cycle"; exit 0
      fi
      if ! openstack server show "$SERVER_ID" -f value -c status >/dev/null 2>&1; then
        log "WARNING: cannot query server (missing OS_* credentials?) - skipping cycle"; exit 0
      fi

      # poll nova instead of relying on 'openstack server shelve --wait', which
      # is not available in every python-openstackclient version
      wait_for_status() { # $1 = egrep pattern, $2 = timeout seconds
        local pattern="$1" deadline status
        deadline=$(( $(date +%s) + $2 ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
          status=$(openstack server show "$SERVER_ID" -f value -c status 2>/dev/null || echo UNKNOWN)
          log "status=$status (waiting for /$pattern/)"
          echo "$status" | grep -Eq "$pattern" && return 0
          [ "$status" = "ERROR" ] && { log "ERROR: server entered ERROR state"; return 1; }
          sleep 10
        done
        log "WARNING: timed out waiting for /$pattern/"; return 1
      }

      # 1. settle: let ansible ssh ControlPersist masters expire and disks flush
      log "settling $${GAP_SECONDS}s after ansible"; sleep "$GAP_SECONDS"

      # 2. shelve
      log "shelving"
      openstack server shelve "$SERVER_ID" >/dev/null 2>&1 || log "WARNING: shelve returned non-zero"
      wait_for_status 'SHELVED' 600 || log "WARNING: continuing without confirmed shelved state"

      # 3. gap
      log "holding $${GAP_SECONDS}s while shelved"; sleep "$GAP_SECONDS"

      # 4. unshelve - this one must not be left half-done
      log "unshelving"
      openstack server unshelve "$SERVER_ID" >/dev/null 2>&1 || log "WARNING: unshelve returned non-zero"
      if ! wait_for_status '^ACTIVE$' 900; then
        log "retrying unshelve once"
        openstack server unshelve "$SERVER_ID" >/dev/null 2>&1 || true
        wait_for_status '^ACTIVE$' 900 \
          || log "ERROR: not ACTIVE - run 'openstack server unshelve $SERVER_ID' manually"
      fi

      # 5. gap
      log "waiting $${GAP_SECONDS}s for guest boot"; sleep "$GAP_SECONDS"

      # 6. did the floating ip survive the offload?
      if [ -n "$${FLOATING_IP:-}" ]; then
        if openstack server show "$SERVER_ID" -f value -c addresses 2>/dev/null | grep -q "$FLOATING_IP"; then
          log "floating ip $FLOATING_IP still attached"
        else
          log "WARNING: floating ip $FLOATING_IP missing - re-associating"
          openstack server add floating ip "$SERVER_ID" "$FLOATING_IP" || log "WARNING: re-association failed"
        fi

        # 7. confirm ssh is genuinely back before terraform reports success
        for _ in $(seq 1 60); do
          timeout 5 bash -c "cat < /dev/null > /dev/tcp/$FLOATING_IP/22" 2>/dev/null \
            && { log "ssh reachable"; break; }
          sleep 10
        done
      fi

      log "cycle complete"; exit 0
    EOT
  }

  depends_on = [null_resource.ansible-execution]
}
