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

rbdata:
  docker.running:
    - container: rbdata
    - name: rbdata
    - image: fredmajor/rbdata

