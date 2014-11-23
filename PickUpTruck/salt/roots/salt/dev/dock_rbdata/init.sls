include:
  - docker

rbdata-image:
  docker.pulled:
    - name: mongo:2.8.0
    - require_in: rbdata-container

rbdata-container:
  docker.installed:
    - name: rbdata
    - image: mongo:2.8.0
    - hostname: rbdata
    - require_in: rbdata

rbdata-data-path:
  file.directory:
    - name: {{ salt['pillar.get']('mongodb:settings:data_dir', '/data/db') }}
    - user: mongodb
    - group: mongodb
    - mode: 755
    - makedirs: True
    - require_in: rbdata
    - recurse:
        - user
        - group

rbdata:
  docker.running:
    - container: rbdata
    - name: rbdata
    - image: mongo:2.8.0
    - port_bindings:
        "27017/tcp":
            HostIp: "{{ salt['pillar.get']('mongodb:settings:bind_ip', '127.0.0.1') }}"
            HostPort: "{{ salt['pillar.get']('mongodb:settings:port', '27017') }}"
    - volumes:
      - {{ salt['pillar.get']('mongodb:settings:docker_mount_dir', '/data') }}: /data

