#cloud-config

---
write-files:
  - path: /etc/conf.d/nfs
    permissions: '0644'
    content: |
      OPTS_RPC_MOUNTD=""
  - path: /opt/bin/wupiao
    permissions: '0755'
    content: |
      #!/bin/bash
      # [w]ait [u]ntil [p]ort [i]s [a]ctually [o]pen
      [ -n "$$1" ] && \
        until curl -o /dev/null -sIf http://$${1}; do \
          sleep 1 && echo .;
        done;
      exit $$?

hostname: master
coreos:
  etcd2:
    name: master
    listen-client-urls: http://0.0.0.0:2379,http://0.0.0.0:4001
    advertise-client-urls: http://$$private_ipv4:2379,http://$$private_ipv4:4001
    initial-cluster-token: k8s_etcd
    listen-peer-urls: http://$$private_ipv4:2380,http://$$private_ipv4:7001
    initial-advertise-peer-urls: http://$$private_ipv4:2380
    initial-cluster: master=http://$$private_ipv4:2380
    initial-cluster-state: new
  fleet:
    metadata: "role=master"
  units:
    - name: generate-serviceaccount-key.service
      command: start
      content: |
        [Unit]
        Description=Generate service-account key file

        [Service]
        ExecStartPre=-/usr/bin/mkdir -p /opt/bin
        ExecStart=/bin/openssl genrsa -out /opt/bin/kube-serviceaccount.key 2048 2>/dev/null
        RemainAfterExit=yes
        Type=oneshot
    - name: setup-network-environment.service
      command: start
      content: |
        [Unit]
        Description=Setup Network Environment
        Documentation=https://github.com/kelseyhightower/setup-network-environment
        Requires=network-online.target
        After=network-online.target

        [Service]
        ExecStartPre=-/usr/bin/mkdir -p /opt/bin
        ExecStartPre=/usr/bin/curl -L -o /opt/bin/setup-network-environment -z /opt/bin/setup-network-environment https://github.com/kelseyhightower/setup-network-environment/releases/download/v1.0.0/setup-network-environment
        ExecStartPre=/usr/bin/chmod +x /opt/bin/setup-network-environment
        ExecStart=/opt/bin/setup-network-environment
        RemainAfterExit=yes
        Type=oneshot
    - name: fleet.service
      command: start
    - name: flanneld.service
      command: start
      drop-ins:
        - name: 50-network-config.conf
          content: |
            [Unit]
            Requires=etcd2.service
            [Service]
            ExecStartPre=/usr/bin/etcdctl set /coreos.com/network/config '{"Network": "${flanneld_cidr}", "Backend": {"Type": "vxlan"}}'
    - name: docker.service
      command: start
      drop-ins:
        - name: 60-wait-for-flannel-config.conf
          content: |
            [Unit]
            After=flanneld.service
            Requires=flanneld.service
            Restart=always
            Restart=on-failure
    - name: kube-apiserver.service
      command: start
      content: |
        [Unit]
        Description=Kubernetes API Server
        Documentation=https://github.com/GoogleCloudPlatform/kubernetes
        Requires=setup-network-environment.service etcd2.service generate-serviceaccount-key.service
        After=setup-network-environment.service etcd2.service generate-serviceaccount-key.service

        [Service]
        EnvironmentFile=/etc/network-environment
        ExecStartPre=-/usr/bin/mkdir -p /opt/bin
        ExecStartPre=/usr/bin/curl -L -o /opt/bin/kube-apiserver -z /opt/bin/kube-apiserver https://storage.googleapis.com/kubernetes-release/release/${kubernetes_release}/bin/linux/amd64/kube-apiserver
        ExecStartPre=/usr/bin/chmod +x /opt/bin/kube-apiserver
        ExecStartPre=/opt/bin/wupiao 127.0.0.1:2379/v2/machines
        ExecStart=/opt/bin/kube-apiserver \
        --service_account_key_file=/opt/bin/kube-serviceaccount.key \
        --service_account_lookup=false \
        --admission_control=NamespaceLifecycle,NamespaceAutoProvision,LimitRanger,SecurityContextDeny,ServiceAccount,ResourceQuota \
        --runtime_config=api/v1 \
        --allow_privileged=true \
        --insecure_bind_address=0.0.0.0 \
        --insecure_port=8080 \
        --kubelet_https=true \
        --secure_port=6443 \
        --service-cluster-ip-range=10.100.0.0/16 \
        --etcd_servers=http://127.0.0.1:2379 \
        --public_address_override=$${DEFAULT_IPV4} \
        --logtostderr=true
        Restart=always
        RestartSec=10
    - name: kube-controller-manager.service
      command: start
      content: |
        [Unit]
        Description=Kubernetes Controller Manager
        Documentation=https://github.com/GoogleCloudPlatform/kubernetes
        Requires=kube-apiserver.service
        After=kube-apiserver.service

        [Service]
        ExecStartPre=/usr/bin/curl -L -o /opt/bin/kube-controller-manager -z /opt/bin/kube-controller-manager https://storage.googleapis.com/kubernetes-release/release/${kubernetes_release}/bin/linux/amd64/kube-controller-manager
        ExecStartPre=/usr/bin/chmod +x /opt/bin/kube-controller-manager
        ExecStart=/opt/bin/kube-controller-manager \
        --service_account_private_key_file=/opt/bin/kube-serviceaccount.key \
        --master=127.0.0.1:8080 \
        --logtostderr=true
        Restart=always
        RestartSec=10
    - name: kube-scheduler.service
      command: start
      content: |
        [Unit]
        Description=Kubernetes Scheduler
        Documentation=https://github.com/GoogleCloudPlatform/kubernetes
        Requires=kube-apiserver.service
        After=kube-apiserver.service

        [Service]
        ExecStartPre=/usr/bin/curl -L -o /opt/bin/kube-scheduler -z /opt/bin/kube-scheduler https://storage.googleapis.com/kubernetes-release/release/${kubernetes_release}/bin/linux/amd64/kube-scheduler
        ExecStartPre=/usr/bin/chmod +x /opt/bin/kube-scheduler
        ExecStart=/opt/bin/kube-scheduler --master=127.0.0.1:8080
        Restart=always
        RestartSec=10
  update:
    group: alpha
    reboot-strategy: off
