# Desktop additions to a host repo

What the Arch Workstation book's Desktop chapter adds to a machine's
host repo (`~/arch`): the lines of `packages.txt` and `units.txt` are
appended to the repo's own, and `etc/` is copied over the repo's
`etc/`. Then `admin apply`, and reboot.

`DESKTOP=1 just test-vm` does exactly that after the base install,
reboots into greetd, and checks it.
