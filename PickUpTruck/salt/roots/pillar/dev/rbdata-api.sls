rbdata-api:
  image: "fredmajor/rbdata:latest"
  contName: "rbdata-api"
  mongo_state_name: {{ salt['pillar.get']('rbdata-storage:contName', 'rbdata-storage') }}
  settings:
    mongo_host: {{ salt['pillar.get']('rbdata-storage:contName', 'rbdata-storage') }}
    mongo_port: {{ salt['pillar.get']('rbdata-storage:settings:port', '27017') }}
    api_bind_ip: "193.168.1.2"
    api_bind_port: "3000"

