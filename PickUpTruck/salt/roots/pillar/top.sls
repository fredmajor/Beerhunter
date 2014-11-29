base:
  'rbGet*prod* or G@role:rbGetProd  or rbDb*prod*':
    - match: compound
    - shotgun.prod
  'rbGet*qa* or G@role:rbGetQa  or rbDb*qa* or dev.beerhunter.pl':
    - match: compound
    - shotgun.qa
  'devVagrant':
    - shotgun.dev

