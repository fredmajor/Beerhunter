{% set settings       = salt['pillar.get']('rbdata-storage:settings', {}) %}
{% set image          = salt['pillar.get']('rbdata-storage:image', 'fredmajor/mongobase:latest') %}
{% set name           = salt['pillar.get']('rbdata-storage:contName', 'rbdata-storage') %}
{% set containerid    = salt['grains.get']('id') %}
{% if pillar.get('shotgun_role', '') == "dev" %}
{% set defaultIp  = grains['ip_interfaces']['eth1'][0] %}
{% else %}
{% set defaultIp  = grains['ip_interfaces']['eth0'][0] %}
{% endif %}
{% set env = pillar.get('shotgun_role', '') %}
{% set  tag = settings.get('tag', 'latest') %}

include:
  - docker

{{ name }}-image:
  docker.pulled:
    - name: {{ image }}
    - require_in: {{ name }}-container
    - force: True

{{ name }}-stop-if-old:
  module.run:
    - name: docker.stop
    - container: "{{ name }}"
    - timeout: 30
    - unless: docker inspect --format {{ '{{' }} .Image {{ '}}' }} {{ name }} | grep $(docker images --no-trunc | grep "fredmajor/{{ image }}" | grep "{{ tag }}" | awk '{ print $3 }')
    - require:
      - docker: {{ name }}-image

{{ name }}-remove-if-old:
  module.run:
    - name: docker.kill
    - container: "{{ name }}"
    - unless: docker inspect --format {{ '{{' }} .Image {{ '}}' }} {{ name }} | grep $(docker images --no-trunc | grep "fredmajor/{{ image }}" | grep "{{ tag }}" | awk '{ print $3 }')
    - require:
      - module: {{ name }}-stop-if-old

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

{% if env == "dev" %}
{{ name }}-data-path:
  file.directory:
    - name: {{ settings.get('local_data_dir', '/data/db') }}
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
{% endif %}

{{ name }}:
  docker.running:
    - container: {{ name }}
    - name: {{ name }}
    - image: {{ image }}
    - port_bindings:
        "27017/tcp":
            HostIp: "{{ defaultIp }}"
            HostPort: "{{ settings.get('port', '27017') }}"
{% if env == "dev" %}
    - binds:
        {{ settings.get('docker_mount_dir', '/data/db') }}:
            bind: /data/db
            ro: False
{% endif %}
