job [[ template "job_name" . ]] {
  [[ template "region" . ]]
  datacenters = [[ .haproxy.datacenters | toPrettyJson ]]
  type        = "service"
  
  constraint {
    attribute = "${attr.kernel.name}"
    value     = "linux"
  }

  group "haproxy" {
    count = [[ .haproxy.instances ]]
    network {
      port "http" {
        static = [[ .haproxy.http_port ]]
      }

      port "haproxy_ui" {
        static = [[ .haproxy.ui_port ]]
      }

      [[- if .haproxy.dataplane.enabled ]]
      port "haproxy_dataplane" {
        static = [[ .haproxy.dataplane.port ]]
      }
      [[- end ]]

      [[- if .haproxy.monitoring.enabled ]]
      port "haproxy_exporter" {
        static = [[ .haproxy.export_port ]]
      }
      
      port "prometheus_ui" {
        static = 9090
      }
      [[- end ]]
    }

    service {
      name = "haproxy"
      check {
        name     = "alive"
        type     = "tcp"
        port     = "http"
        interval = "10s"
        timeout  = "2s"
      }
    }

    [[- if .haproxy.monitoring.enabled ]]
    task "haproxy_exporter" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image = "prom/haproxy-exporter:latest"

        args = ["--haproxy.scrape-uri", "http://[[.haproxy.address]]:[[.haproxy.ui_port]]/?stats;csv"]

        ports = ["haproxy_exporter"]
      }

      service {
        name = "haproxy-exporter"
        port = "haproxy_exporter"

        check {
          type     = "http"
          path     = "/metrics"
          interval = "10s"
          timeout  = "2s"
        }
      }

      resources {
        cpu         = 100
        memory      = 32
        memory_max  = 64
      }
    }
    [[- end ]]

    task "haproxy" {
      driver = "docker"
      config {
        image        = "haproxytech/haproxy-debian:[[.haproxy.version]]"
        network_mode = "host"
        volumes = [
          "local/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg",
        ]
      }

      template {
        data = <<EOF
defaults
   mode http
frontend stats
   bind *:[[ .haproxy.ui_port ]]
   stats uri /
   stats show-legends
frontend http_front
   bind *:[[ .haproxy.http_port ]]
   default_backend http_back
   option contstats
backend http_back
    balance roundrobin
    server-template webapp [[ .haproxy.pre_provisioned_slot_count ]] _[[ .haproxy.consul_service_name ]]._tcp.service.consul resolvers consul resolve-opts allow-dup-ip resolve-prefer ipv4 check
resolvers consul
    nameserver consul 127.0.0.1:[[ .haproxy.consul_dns_port ]]
    accepted_payload_size 8192
    hold valid 5s
[[- if .haproxy.dataplane.enabled ]]
userlist haproxy-dataplaneapi
    user [[ .haproxy.dataplane.user ]] insecure-password [[ .haproxy.dataplane.pass ]]
program api
   command /usr/bin/dataplaneapi --host [[ .haproxy.dataplane.host ]] --port [[ .haproxy.dataplane.port ]] --haproxy-bin /usr/local/sbin/haproxy -c /usr/local/etc/haproxy/haproxy.cfg -r "kill -SIGUSR2 1" -d 5 -u haproxy-dataplaneapi
   no option start-on-reload
[[- end ]]
EOF
        destination = "local/haproxy.cfg"
      }

      resources {
        cpu         = [[ .haproxy.resources.cpu ]]
        memory      = [[ .haproxy.resources.memory ]]
      }
    }

    [[- if .haproxy.monitoring.enabled ]]
    task "prometheus" {
      driver = "docker"

      config {
        image = "prom/prometheus"

        args = [
          "--config.file=/etc/prometheus/config/prometheus.yml",
          "--storage.tsdb.path=/prometheus",
          "--web.console.libraries=/usr/share/prometheus/console_libraries",
          "--web.console.templates=/usr/share/prometheus/consoles",
        ]
        network_mode = "host"

        volumes = [
          "local/config:/etc/prometheus/config",
        ]

        ports = ["prometheus_ui"]
      }

      template {
        data = <<EOH
---
global:
  scrape_interval:     1s
  evaluation_interval: 1s
scrape_configs:
  - job_name: haproxy_exporter
    static_configs:
      - targets: [{{ range service "haproxy-exporter" }}'{{ .Address }}:{{ .Port }}',{{ end }}]
EOH
        destination   = "local/config/prometheus.yml"
      }

      resources {
        cpu    = [[ .haproxy.monitoring.cpu ]]
        memory = [[ .haproxy.monitoring.memory ]]
      }

      [[- if .haproxy.monitoring.consul ]]
      service {
        name = "prometheus"
        port = "prometheus_ui"

        check {
          type     = "http"
          path     = "/-/healthy"
          interval = "10s"
          timeout  = "2s"
        }
      }
      [[- end ]]
    }
    [[- end ]]

  }
}