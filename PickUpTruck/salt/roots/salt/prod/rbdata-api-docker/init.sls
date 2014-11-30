{% set settings       = salt['pillar.get']('rbdata-api:settings', {}) %}
{% set image          = salt['pillar.get']('rbdata-api:image', 'fredmajor/rbdata:latest') %}
{% set name           = salt['pillar.get']('rbdata-api:contName', 'rbdata-api') %}
{% set containerid    = salt['grains.get']('id') %}
{% if pillar.get('shotgun_role') ==  "dev" %}
{% set defaultIp  = grains['ip_interfaces']['eth1'][0] %}
{% else  %}
{% set defaultIp  = grains['ip_interfaces']['eth0'][0] %}
{% endif %}
{% set mongo_state_name = salt['pillar.get']('rbdata-api:mongo_state_name','rbdata-storage') %}
{% set apiport = settings.get('api_bind_port', '3000') %}
{% set  tag = settings.get('tag', 'latest') %}
{% set env = pillar.get('shotgun_role', '') %}

include:
  - docker
  - {{ mongo_state_name }}-docker

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
    - command:
      - "--mongoport={{ settings.get('mongo_port', '27017') }}" 
      - "--mongohost={{ settings.get('mongo_host', 'rbdata-storage') }}"
      - "--apiport={{ apiport }}"
    - require_in: {{ name }}

{{ name }}:
  docker.running:
    - container: {{ name }}
    - name: {{ name }}
    - image: {{ image }}
    - port_bindings:
        "{{ apiport }}/tcp":
            HostIp: ""
            HostPort: "{{ apiport }}"
    - links:
        {{ settings.get('mongo_host', 'rbdata-storage') }}: {{ settings.get('mongo_host', 'rbdata-storage') }}
