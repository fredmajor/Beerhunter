base:
  'rbGet*prod* or G@role:rbGetProd  or rbDb*prod*':
    - match: compound
    - nginx

qa:
  'rbGet*qa* or G@role:rbGetQa  or rbDb*qa* or dev.beerhunter.pl':
    - match: compound
    - docker
    - rbdata-storage-docker
    - rbdata-api-docker

dev:
  'devVagrant':
    - docker
    - rbdata-storage-docker
    - rbdata-api-docker
    #    - rbget-docker

