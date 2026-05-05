# Sunshine

This repo contains work to set up accelerated desktops on research clouds with a little more ease. Currently set up to work on ubuntu 22, but plans are to explore 24 soon.

## how to use

* source your cloud file
* run `terraform plan --out plan; terraform apply "plan"`
* for some reason still need to reboot last time to get sunshine service started