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

      port "haproxy_export" {
        static = [[ .haproxy.export_port ]]
      }

      port "prometheus_ui" {
        static = 9090
      }
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

    task "haproxy_prometheus" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image = "prom/haproxy-exporter:latest"

        args = ["--haproxy.scrape-uri", "http://127.0.0.1:[[.haproxy.ui_port]]/?stats;csv"]

        ports = ["haproxy_export"]
      }

      service {
        name = "haproxy-exporter"
        port = "haproxy_export"

        check {
          type     = "http"
          path     = "/metrics"
          interval = "10s"
          timeout  = "2s"
        }
      }

      resources {
        cpu    = 100
        memory = 32
      }
    }

    task "haproxy" {
      driver = "docker"
      config {
        image        = "haproxy:[[.haproxy.version]]"
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
   no log
frontend http_front
   bind *:[[ .haproxy.http_port ]]
   default_backend http_back
backend http_back
    balance roundrobin
    server-template webapp [[ .haproxy.pre_provisioned_slot_count ]] _[[ .haproxy.consul_service_name ]]._tcp.service.consul resolvers consul resolve-opts allow-dup-ip resolve-prefer ipv4 check
resolvers consul
    nameserver consul 127.0.0.1:[[ .haproxy.consul_dns_port ]]
    accepted_payload_size 8192
    hold valid 5s
EOF
        destination = "local/haproxy.cfg"
      }

      resources {
        cpu    = [[ .haproxy.resources.cpu ]]
        memory = [[ .haproxy.resources.memory ]]
      }
    }

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
  scrape_interval:     5s
  evaluation_interval: 5s
scrape_configs:
  - job_name: haproxy_exporter
    static_configs:
      - targets: [127.0.0.1:[[ .haproxy.export_port ]]]
EOH

        change_mode   = "signal"
        change_signal = "SIGHUP"
        destination   = "local/config/prometheus.yml"
      }

      resources {
        cpu    = 100
        memory = 512
      }

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
    }
  }
}