# ansible-role-docker-compose-stack

Ansible role that configures a docker-compose stack with systemd.


## Usage

`requirements.yml`:

```yaml
---
- src: aklinkert.docker_compose_stack
```

`group_vars/fah.yml`:
```yaml
fah_docker_compose_stack_file: |
  version: '3.5'
  services:
    fah:
      image: johnktims/folding-at-home:latest
      restart: always
      ports:
        - "127.0.0.1:7396:7396"
      devices:
        - "/dev/nvidia0:/dev/nvidia0"
        - "/dev/nvidiactl:/dev/nvidiactl"
        - "/dev/nvidia-uvm:/dev/nvidia-uvm"
      command:
        - "--user={{ fah_name }}"
        - "--team={{ fah_team }}"
        - "--power=full"

fah_docker_compose_stack_create_files:
  - name: file.txt
    mode: "0600"

fah_docker_compose_stack_additional_files:
  - name: file_content.txt
    content: |
      test-content
```

`playbook.yml`:

```yaml
- name: Install docker-compose service
  hosts: fah
  become: true
  roles:
    - role: aklinkert.docker_compose
      vars:
        docker_compose_stack_name: fah
        docker_compose_stack_file: "{{ fah_docker_compose_stack_file }}"
        docker_compose_stack_additional_files: "{{ fah_docker_compose_stack_additional_files }}"
        docker_compose_stack_create_files: "{{ fah_docker_compose_stack_create_files }}"
```

## Restart behaviour

The stack is restarted (handler `docker-compose-restart`) only when needed:

- the compose file, an additional file or the systemd unit changed,
- `pull` fetched a different image (image IDs of the stack's services before
  and after the pull differ),
- an earlier run did not complete a restart it needed (e.g. a later task
  failed): the role writes `.restart-pending` into the stack directory as soon
  as a config change, a new image or a stopped stack is detected, and the
  handler removes it after a successful restart, or
- no container of the stack is running (`compose ps -q` is empty): a stack
  without a running container is started again. Set
  `docker_compose_stack_restart_when_stopped: false` to leave a stack alone
  that was stopped on purpose. docker-compose v1 lists stopped containers in
  `ps -q` too, so this check does not trigger there.

A lost systemd `daemon-reload` is recovered too (`systemctl show
NeedDaemonReload`). A run with unchanged config, unchanged images and a running
stack changes nothing and restarts nothing. Out-of-band changes (an image
pulled by hand while the containers keep running the old one) are not detected.

Services with a `build:` key are never pulled, with or without `image:`
(their image is built locally, a pull would fail or fetch the wrong one); only
the other services are pulled. The role parses the output of `compose config`
(YAML, never logged because it contains interpolated secrets; on failure only
stderr is shown) and `image inspect` (JSON), so it works with docker compose
and `nerdctl compose`. Images are inspected with `docker_compose_image_cli`
(default: the first word of `docker_compose_binary`, full path kept, if its
basename is `nerdctl`, else `docker`). A failing inspect after the pull fails
the role. In check mode the pull is skipped and nothing is restarted.

## Tests

`tests/run.sh` (needs docker with compose and ansible-playbook, runs in CI via
`.github/workflows/test.yml`) pushes images to a throwaway local registry
(pinned by digest) and asserts: a running stack with current images reports no
change and notifies nothing, also on repeated runs; an updated image (old one
kept locally, same tag) notifies once; a notification or compose file change lost to a failed play is
recovered on the next run; a stopped stack notifies (unless opted out); build-only and multiple
services work; check mode without a compose file does not fail. The systemd
handlers are replaced by counting ones.

# Licence

  Apache v2.0
