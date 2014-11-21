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
    - require_in: rbdata

rbdata:
  docker.run:
    - container: rbdata

