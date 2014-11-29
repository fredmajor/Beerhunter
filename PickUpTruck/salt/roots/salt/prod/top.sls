base:
  'rbGet*prod* or G@role:rbGetProd  or rbDb*prod*':
    - match: compound
    - nginx

qa:
  'rbGet*qa* or G@role:rbGetQa  or rbDb*qa*':
    - match: compound
    - docker
    - basicutils

dev:
  'devVagrant':
    - docker
    - rbdata-storage-docker
    - rbdata-api-docker
    #    - rbget-docker

