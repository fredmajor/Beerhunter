{% set settings       = salt['pillar.get']('rbget:settings', {}) %}
{% set image          = salt['pillar.get']('rbget:image', 'fredmajor/rbget') %}
{% set tag            = salt['pillar.get']('rbget:tag', 'latest') %}
{% set name           = salt['pillar.get']('rbget:contName', 'rbget') %}
{% set containerid    = salt['grains.get']('id') %}
{% set env = pillar.get('shotgun_role', '') %}

{% if pillar.get('shotgun_role', '') == "dev" %}
{% set defaultIp  = grains['ip_interfaces']['eth1'][0] %}
{% else %}
{% set defaultIp  = grains['ip_interfaces']['eth0'][0] %}
{% endif %}

include:
  - docker

{{ name }}-image:
  docker.pulled:
    - name: {{ image }}
    - tag: {{ tag }}
    - force: True
    - require_in: {{ name }}-container

{{ name }}-stop-if-old:
  module.run:
    - name: docker.stop
    - container: "{{ name }}"
    - timeout: 30
    - unless: docker inspect --format '{{ '{{' }} .Image {{ '}}' }}' {{ name }} | grep $(docker images --no-trunc | grep "fredmajor/{{ image }}" | grep "{{ tag }}" | awk '{ print $3 }')
    - require:
      - docker: {{ name }}-image

{{ name }}-remove-if-old:
  module.run:
    - name: docker.kill
    - container: "{{ name }}"
    - unless: docker inspect --format '{{ '{{' }} .Image {{ '}}' }}' {{ name }} | grep $(docker images --no-trunc | grep "fredmajor/{{ image }}" | grep "{{ tag }}" | awk '{ print $3 }')
    - require:
      - module: {{ name }}-stop-if-old

{{ name }}-container:
  docker.installed:
    - name: {{ name }}
    - image: {{ image }}
    - hostname: {{ containerid }}
    - command:
      - "--workerstotal={{ settings.get('workers_total', '1') }}"
      - "--myworkerno={{ settings.get('my_worker_no', '1') }}"
      - "--batchsize={{ settings.get('batch_size', '20') }}"
      - "--bigbatchratio={{ settings.get('big_batch_ratio', '10') }}"
      - "--rbdataapiurl={{ settings.get('rbdata_api_url', defaultIp ) }}"
    - require_in: {{ name }}

{{ name }}:
  docker.running:
    - name: {{ name }}
    - container: {{ name }}
    - image: {{ image }}

