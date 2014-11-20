include:
  - docker

rbget-image:
  docker.pulled:
    - name: fredmajor/rbget
    - require_in: rbget-container

rbget-container:
  docker.installed:
    - name: firstrbget
    - image: fredmajor/rbget
    - require_in: rbget

rbget:
  docker.run:
    - name: /bin/bash
    - container: firstrbget

