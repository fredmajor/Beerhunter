rbdata-storage:
  image: "fredmajor/mongobase:latest"
  contName: "rbdata-storage"
  settings:
    port: "27017"
    bind_ip: "193.168.1.2"
    local_data_dir: "/data/db"
    docker_mount_dir: "/data/db"
    mongo_uid: "1111"
    mongo_guid: "1111"

