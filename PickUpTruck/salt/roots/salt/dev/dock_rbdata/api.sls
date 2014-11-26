{% set settings       = salt['pillar.get']('rbdata:settings', {}) %}
{% set image          = salt['pillar.get']('rbdata:image', 'fredmajor/mongobase:latest') %}
{% set name           = salt['pillar.get']('rbdata:contName', 'rbdata') %}
{% set containerid    = salt['grains.get']('id') %}
{% set port       = settings.get('port', '27017') %}
{% set defaultIp  = grains['ip_interfaces']['eth1'][0] %}

include:
  - docker

{{ name }}-image:
  docker.pulled:
    - name: {{ image }}
    - require_in: {{ name }}-container

{{ name }}-container:
  docker.installed:
    - name: {{ name }}
    - image: {{ image }}
    - hostname: {{ containerid }}
    - require_in: {{ name }}

mongodb:
  group:
    - present
    - gid: {{ settings.get('mongo_guid', '1111') }}
  user:
    - present
    - uid: {{ settings.get('mongo_uid', '1111') }}
    - groups:
      - mongodb
    - require:
      - group: mongodb
    - require_in: {{ name }}-data-path

{{ name }}-data-path:
  file.directory:
    - name: {{ salt['pillar.get']('rbdata:settings:local_data_dir', '/data/db') }}
    - user: mongodb
    - group: mongodb
    - mode: 755
    - makedirs: True
    - require_in: {{ name }}
    - require:
      - group: mongodb
      - user: mongodb
    - recurse:
        - user
        - group

{{ name }}:
  docker.running:
    - container: {{ name }}
    - name: {{ name }}
    - image: {{ image }}
    - port_bindings:
        "27017/tcp":
            HostIp: "{{ salt['pillar.get']('rbdata:settings:bind_ip', '127.0.0.1') }}"
            HostPort: "{{ salt['pillar.get']('rbdata:settings:port', '27017') }}"
    - binds:
        {{ settings.get('docker_mount_dir', '/data/db') }}:
            bind: /data/db
            ro: False
