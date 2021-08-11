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

# Licence

  Apache v2.0
