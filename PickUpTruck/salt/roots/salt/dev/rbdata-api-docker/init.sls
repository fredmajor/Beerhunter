{% set settings       = salt['pillar.get']('rbdata-api:settings', {}) %}
{% set image          = salt['pillar.get']('rbdata-api:image', 'fredmajor/rbdata:latest') %}
{% set name           = salt['pillar.get']('rbdata-api:contName', 'rbdata-api') %}
{% set containerid    = salt['grains.get']('id') %}
{% set defaultIp  = grains['ip_interfaces']['eth1'][0] %}
{% set mongo_state_name = salt['pillar.get']('rbdata-api:mongo_state_name','rbdata-storage') %}
{% set apiport = settings.get('api_bind_port', '3000') %}

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

{{ name }}:
  docker.running:
    - container: {{ name }}
    - name: {{ name }}
    - image: {{ image }}
    - require: {{ mongo_state_name }}
    - command: 
      - "--mongohost={{ settings.get('mongo_host', 'rbdata-storage') }}"
      - "--mongoport={{ settings.get('mongo_port', '27017') }}"
      - "--apiport={{ apiport }}"
    - port_bindings:
        "{{ apiport }}/tcp":
            HostIp: "{{ settings.get('api_bind_ip', '127.0.0.1') }}"
            HostPort: "{{ apiport }}"
    - links:
        {{ settings.get('mongo_host', 'rbdata-storage') }}:"{{ settings.get('mongo_host', 'rbdata-storage') }}"
