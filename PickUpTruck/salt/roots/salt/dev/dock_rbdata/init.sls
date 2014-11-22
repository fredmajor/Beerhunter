include:
  - docker

rbdata-image:
  docker.pulled:
    - name: fredmajor/rbdata
    - require_in: rbdata-container

rbdata-container:
  docker.installed:
    - name: rbdata
    - image: fredmajor/rbdata
    - hostname: rbdata
    - require_in: rbdata

rbdata-data-path:
  file.directory:
    - name: {{ salt['pillar.get']('mongodb:settings:data_dir', '/data/db') }}
    - mode: 755
    - makedirs: True
    - require_in: rbdata
  #  - recurse:
  #      - user
  #      - group

rbdata:
  docker.running:
    - container: rbdata
    - name: rbdata
    - image: fredmajor/rbdata
    - port_bindings:
        "27017/tcp":
            HostIp: "{{ salt['pillar.get']('mongodb:settings:bind_ip', '127.0.0.1') }}"
            HostPort: "{{ salt['pillar.get']('mongodb:settings:port', '27017') }}"
    - volumes:
      - {{ salt['pillar.get']('mongodb:settings:data_dir', '/data/db') }}: /data/db

